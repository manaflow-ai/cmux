# cmux Browser contributor notes

This directory contains the Chromium-based cmux Browser product. It is a
source overlay and build harness, not a Chromium checkout. Never vendor
Chromium, generated build output, signed applications, update keys, or private
builder configuration here.

## Repository boundaries

- Resolve the cmux TUI backend from `../cmux-tui`.
- Resolve Ghostty from the repository's `../ghostty` gitlink.
- Keep Chromium overlay paths under `overlay/` identical to their destination
  paths in a Chromium source tree.
- Derive paths from the monorepo and Browser roots. Do not add developer home
  directories, private hostnames, tailnet addresses, or volume paths.
- Pin Chromium with a full commit ID and preserve enough build metadata to
  reproduce every distributed binary.

## Licensing and provenance

Every imported or new source file must have a recorded provenance and license.
Do not apply the repository's default license over third-party material.

- Manaflow-authored files use the repository's GPL-3.0-or-later/commercial
  policy unless a narrower file-level notice says otherwise.
- Chromium-derived files retain Chromium's BSD-3-Clause notice.
- Helium-derived files retain GPL-3.0-only provenance and the exact source
  revision. Helium-derived code is not available under Manaflow's commercial
  license.
- Other bundled dependencies retain their own terms and must appear in the
  generated notices and corresponding-source manifest.

When changing a shipped dependency, update its exact revision or digest,
source URL, license text, and source-offer record in the same change. A build
must fail closed if any shipped file has no license mapping.

## Validation

Run the fast host, patch-fixture, script, and protocol tests before review.
Release candidates additionally require a full Chromium build, generated
Chromium third-party notices, bundle-license verification, and the macOS
XCUITest terminal-render suite against the exact packaged cmux and Ghostty
revisions.

Never run untrusted pull-request code on a self-hosted builder with private
network access or signing credentials.
