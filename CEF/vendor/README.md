# `vendor/` — CEF binary distribution provisioning

Everything cmux needs to fetch, verify, extract, and prepare the Chromium
Embedded Framework binary distribution lives here. **One place** decides
*which* CEF version cmux uses (`cef.lock.json`) and *how* it's installed
(`fetch_cef.sh`).

## Files

| File | Purpose |
| --- | --- |
| `cef.lock.json` | Pinned CEF version + SHA1 + size + extracted directory name. The only authoritative source of "what CEF do we ship." |
| `cef.lock.schema.json` | JSON Schema for the lockfile. Editors and CI should validate against this. |
| `fetch_cef.sh` | Idempotent download + verify + extract + build wrapper. Called explicitly from `./scripts/setup.sh` and CI provisioning. |
| `README.md` | This file. |

## Quick start

```bash
# Download (or use cache), verify SHA1, extract, build C++ wrapper, populate
# the build's Frameworks/ dir.
vendor/fetch_cef.sh

# Just verify the cached tarball still matches the lockfile.
vendor/fetch_cef.sh --verify

# Print resolved paths and exit (used by Xcode build phases for input/output
# declarations).
vendor/fetch_cef.sh --print-paths
```

## Where the data lives

| Path | Notes |
| --- | --- |
| `~/Library/Caches/cmux-cef-vendor/<version>/<tarball>` | Per-developer cache. Survives `git clean`. CI uses `CEF_VENDOR_CACHE` to point at a cached artefact. |
| `<DEST>/CEF/<extracted_dir>/` | The unpacked CEF distribution. `<DEST>` defaults to the repo's `CEF/` directory. |
| `<DEST>/Frameworks/Chromium Embedded Framework.framework` | Re-laid-out, install-id-fixed, ad-hoc-sig-stripped framework. Ready to be re-signed by the cmux build with Developer ID. |
| `<DEST>/Frameworks/libcef_dll_wrapper.a` | Static wrapper linked into the bridge. |
| `<DEST>/Frameworks/include/` | CEF C++ headers. |

The cache directory is per-version, so multiple cmux checkouts pointing at
different CEF versions don't fight each other.

## Mirror / offline use

In CI or behind restrictive networks, set `CEF_VENDOR_MIRROR` to an internal
HTTPS mirror (R2 / S3 / artefact registry) holding files at
`<MIRROR>/<version>/<tarball>`. The script tries the mirror first and falls
back to `https://cef-builds.spotifycdn.com/` if the mirror is unreachable.
If neither works *and* the cache is empty, the script exits non-zero.

## Updating to a new CEF version

1. Find the new version on https://cef-builds.spotifycdn.com/index.json.
   Use the **standard** distribution for `macosarm64` (not `minimal`,
   `client`, `tools`, or any of the symbol packs).
2. Update `cef.lock.json` with the new `version`, `tarball`, `sha1`,
   `size_bytes`, and `extracted_dir_name`. Keep the JSON sorted and the
   diff minimal.
3. Run `vendor/fetch_cef.sh`. It should download the new tarball and
   verify it against the new SHA1.
4. Run cmux against the new CEF and exercise the dogfood checklist (see
   `MIGRATION_PLAN.md` Phase 8).
5. Commit `cef.lock.json` in a separate PR titled `cef: bump to <version>`.
   Include the cef-builds release notes link in the PR body.

CI gating: a nightly job verifies the lockfile by re-downloading from
`cef-builds.spotifycdn.com` and re-computing the SHA1. If the public CDN
mutates the artefact for the pinned version, the job goes red and a human
investigates before any cmux release.

## Why we don't commit the binaries

| | size |
| --- | --- |
| Tarball (compressed) | ~269 MiB |
| Extracted CEF dir | ~1.4 GiB |
| Frameworks/ output (binary only) | ~210 MiB |

Committing any of these would blow up the cmux repo and the CI checkout
time. The lockfile is 0.5 KiB; that's what we version-control.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 2 | Lockfile parse or argument error. |
| 3 | SHA1 mismatch on lockfile or downloaded artefact. |
| 4 | Network failure with no cache fallback. |
| 5 | C++ wrapper build failed. |

## Source builds vs app runtime

Source checkouts need this SDK because SwiftPM compiles against the CEF headers
and `libcef_dll_wrapper.a`. Installed cmux apps do not require users to run this
script: the app downloads and verifies the pinned runtime on first CEF use.
