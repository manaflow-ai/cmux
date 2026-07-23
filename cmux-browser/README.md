# cmux Browser

cmux Browser combines Chromium web surfaces with Ghostty terminal frontends
backed by the cmux TUI process. It is being moved into this repository so the
Browser, its terminal protocol, and its exact Ghostty dependency can be built
and reviewed from one public source tree.

The Browser is maintained as a small source overlay and patch set against an
exact Chromium revision. Chromium itself is not vendored into this repository.

## Import status

The public import is staged deliberately:

1. establish the provenance, licensing, and reproducibility contract;
2. import one curated source snapshot without private Git history;
3. make monorepo-relative build and dependency changes in reviewable commits;
4. add public CI and release-compliance gates; and
5. publish a Browser artifact only after the full build and UI matrix passes.

The source snapshot is not release-ready until every item in
[`IMPORT_PROVENANCE.md`](IMPORT_PROVENANCE.md) is resolved.

## Planned layout

- `overlay/` mirrors paths in the Chromium source tree.
- `patches/` contains reviewable changes to existing Chromium files.
- `scripts/` bootstraps, applies, builds, tests, packages, and verifies the
  pinned product.
- `tests/` contains UI and end-to-end coverage.
- `tools/` contains focused local test harnesses.
- `docs/` contains durable architecture and contributor documentation.

## License

This import does not change cmux's root license. Browser code for which
Manaflow controls the necessary rights is available under
GPL-3.0-or-later. Manaflow may separately offer commercial terms only for
those rights-controlled portions. This is not a blanket dual-license claim
over the Browser binary or every file in this directory.

Third-party and derived files retain their original licenses. In particular,
Chromium-derived material is BSD-3-Clause, Helium-derived material and uBlock
Origin are GPL-3.0-only, and Ghostty and Bonsplit are MIT;
none is relicensed merely by being stored or distributed with the Browser.

AGPL is not the default for the desktop Browser. Its additional protection is
aimed at modified software offered for remote network use, while GPL already
requires source for distributed desktop forks. A future hosted service may use
AGPL as a separately reviewed component decision, but changing this directory
to AGPL would require a distinct policy and legal review.

Manaflow may offer later versions of code for which it controls the copyright
under different terms. That does not revoke the rights already granted for a
published GPL version, and it does not extend to third-party code or outside
contributions without the necessary relicensing rights.

See [`IMPORT_PROVENANCE.md`](IMPORT_PROVENANCE.md) for the import boundary and
the repository's `THIRD_PARTY_LICENSES.md` for shipped notices.
