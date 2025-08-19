#!/usr/bin/env bash
#-----------------------------------------------------------------------------
#
#  TSDuck - The MPEG Transport Stream Toolkit
#  Copyright (c) 2005-2026, Joey Ekstrom
#  BSD-2-Clause license, see LICENSE.txt file or https://tsduck.io/license
#
#  Update the Nix fetchurl/fetchFromGitHub URLs and hashes in the hardware
#  SDK packages (pkg/nix/dtapi.nix, pkg/nix/vatek.nix) to match whatever
#  the upstream projects are currently shipping.
#
#-----------------------------------------------------------------------------

set -euo pipefail

SCRIPT=$(basename "$0")
ROOTDIR=$(cd "$(dirname "$0")/../.."; pwd)
SCRIPTSDIR="$ROOTDIR/scripts"
NIXDIR="$ROOTDIR/pkg/nix"

# Define these as DTAPI support is only supported for nix on those platforms
export LOCAL_OS=linux
export LOCAL_ARCH=x86_64
export CHECKTLS_DONE=
export NODTAPI=
export DTAPI_ORIGIN=

VATEK_RELEASE_URL=https://api.github.com/repos/VisionAdvanceTechnologyInc/vatek_sdk_2/releases/latest

# Source the config scripts to get the functions out.
. "$SCRIPTSDIR/dtapi-config.sh"

# Apply sed expressions to a file (in-place), or show the resulting diff
# in dry-run mode.
find_and_replace() {
    local file="$1"
    shift
    if $OPT_DRY_RUN; then
        echo "--- would apply to $file ---"
        sed "$@" "$file" | diff -u "$file" - || true
    else
        sed -i "$@" "$file"
    fi
}

# DTAPI
update_dtapi() {
    local nix_file="$NIXDIR/dtapi.nix"
    [[ -f "$nix_file" ]] || error "dtapi.nix not found at $nix_file"

    info "--- DTAPI ---"

    # Discover and download the current SDK tarball.
    local url=$(get-url)
    [[ -n "$url" ]] || error "get-url returned empty"
    info "URL: $url"

    info "downloading ..."
    OPT_FORCE=false download-dtapi

    # Retrieve the path to the cached tarball.
    local tarball=$(get-tarball)
    [[ -n "$tarball" ]] || error "get-tarball returned empty (download may have failed)"
    info "tarball: $tarball"

    # Compute the Nix hash.
    info "computing hash ..."
    local hash_sri=$(nix hash file --type sha256 --sri "$tarball") \
        || error "nix hash file failed"
    info "hash: $hash_sri"

    # Get the version string
    local version=$(basename "$tarball" | sed -n 's/^LinuxSDK_\([^.]*\)\.tar\.gz$/\1/p') \
        || error "no version in filename"
    info "version: $version"

    # Patch dtapi.nix.
    info "updating $nix_file ..."
    find_and_replace "$nix_file" \
        -e "s|url = \"[^\"]*\";|url = \"$url\";|" \
        -e "s|hash = \"[^\"]*\";|hash = \"$hash_sri\";|" \
        -e "s|version = \"[^\"]*\";.*|version = \"$version\";|"

    info "DTAPI update complete"
}

# VATek
# Get Vatek API source tarball URL for the latest release.
get-vatek-url() {
    # Use the GitHub REST API to get the source tarball of the latest release of the Vatek API.
    curl -sL "$VATEK_RELEASE_URL" |
    grep '"tarball_url"' |
    sed 's/.*"tarball_url"[ :"]*\([^"]*\)".*/\1/' |
    head -1
}

update_vatek() {
    local nix_file="$NIXDIR/vatek.nix"
    [[ -f "$nix_file" ]] || error "vatek.nix not found at $nix_file"

    info "--- VATek ---"
    info "discovering VATek release ..."
    local src_url=$(get-vatek-url)
    [[ -n "$src_url" ]] || error "get-src-url returned empty"
    info "src URL: $src_url"

    local tag=$(basename "$src_url")
    [[ -n "$tag" ]] || error "could not extract tag from src URL"
    info "tag: $tag"

    # Strip a leading 'v' for the bare version number used in vatek.nix.
    local version="${tag#v}"
    info "version: $version"

    info "prefetching from GitHub (this may take a moment) ..."
    local prefetch_json=$(nix-prefetch-github VisionAdvanceTechnologyInc vatek_sdk_2 --rev "$tag") \
        || error "nix-prefetch-github failed"

    # Extract the hash field with jq
    local hash=$(echo "$prefetch_json" | jq -r '.hash') || hash=
    [[ -n "$hash" && "$hash" != "null" ]] || error "could not extract hash from nix-prefetch-github output"
    info "hash: $hash"

    # Patch vatek.nix.
    info "updating $nix_file ..."
    find_and_replace "$nix_file" \
        -e "s|version = \"[^\"]*\";|version = \"$version\";|" \
        -e "s|hash = [^;]*;|hash = \"$hash\";|"

    info "VATek update complete"
}

# ---------------------------------------------------------------------------
# Option parsing
# ---------------------------------------------------------------------------
OPT_DTAPI=false
OPT_VATEK=false
OPT_DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dtapi)
            OPT_DTAPI=true  ;;
        --vatek)
            OPT_VATEK=true  ;;
        --dry-run)
            OPT_DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $SCRIPT [--dtapi] [--vatek] [--dry-run]"
            echo "  --dtapi   Update pkg/nix/dtapi.nix"
            echo "  --vatek   Update pkg/nix/vatek.nix"
            echo "  --dry-run Print changes without writing files"
            echo "  (no flags) Update both"
            exit 0
            ;;
        *)
            error "invalid option $1 (use --dtapi, --vatek, --dry-run, --help)"
            ;;
    esac
    shift
done

# If neither was specified, do both.
if ! $OPT_DTAPI && ! $OPT_VATEK; then
    OPT_DTAPI=true
    OPT_VATEK=true
fi

# ---------------------------------------------------------------------------
$OPT_DTAPI && update_dtapi
$OPT_VATEK && update_vatek
