# cmux Browser import provenance

This document is the release gate for moving cmux Browser from its private
development repository into public `manaflow-ai/cmux` history. The import uses
a curated snapshot rather than publishing the private repository's Git graph.

## Snapshot identity

The snapshot commit, tree hash, import timestamp, and immutable private archive
tag will be recorded in the source-import commit. The imported bytes must land
unchanged in that commit; path relocation and public-build rewrites belong in
later commits so reviewers can reproduce the import independently.

## Included source

- Chromium overlay sources and build metadata
- Chromium patch fixtures and compatibility tests
- build, packaging, verification, and updater scripts after secret and
  infrastructure review
- XCUITest and host-side test harnesses
- durable architecture and contributor documentation

## Excluded material

- the private repository's commit history, side branches, refs, and stash
- local `dist` symlinks and generated application bundles
- Chromium checkouts, `out/` directories, caches, staged frameworks, and
  generated Xcode projects
- private hostnames, tailnet addresses, developer paths, signing material,
  release credentials, and fleet-specific builder adapters
- transient implementation ledgers, screenshots containing local identity or
  paths, and tool stubs that are unavailable to public contributors

## License classes

Every imported source path must be classified before public distribution.

| Class | Required treatment |
| --- | --- |
| Manaflow-authored | cmux GPL-3.0-or-later/commercial policy and Manaflow copyright |
| Chromium-derived | Preserve BSD-3-Clause copyright, license, source revision, and modification notice |
| Helium-derived | Preserve GPL-3.0-only copyright, exact source revision, and modification notice; exclude from commercial-license claims |
| Mixed provenance | Preserve every applicable notice and document the copied regions; do not replace the obligations with an `OR` expression |
| Other dependency | Preserve its upstream license and add exact source/artifact identity to generated notices |

A root license never overrides a more specific file-level or third-party
license. The initial private tree's generic Chromium headers are not accepted
as classification evidence; each file must be reviewed against its history and
upstream sources.

## Dependency obligations

- **Chromium:** pin a full source commit and DEPS state. Generate the shipped
  target's license/credits output with Chromium's license tooling.
- **Ghostty:** use the root gitlink, retain its MIT notice, and include licenses
  for linked libraries, fonts, themes, and shell-integration resources.
- **cmux TUI:** build the sibling workspace and record the exact helper receipt.
- **Helium:** retain exact patch provenance and GPL-3.0-only terms. A future
  proprietary Browser requires independently reimplementing or separately
  licensing Helium-derived behavior.
- **Bonsplit:** preserve the MIT notice and exact source revision for adapted
  split-layout and animation behavior, even though cmux already ships Bonsplit
  elsewhere in the monorepo.
- **uBlock Origin:** pin the extension payload digest and upstream source tag,
  preserve GPLv3 notices, and distribute the corresponding source or a valid
  source offer with the binary.

## Required gates

- [ ] Canonical private Browser validation is complete and its source SHA is
  frozen.
- [ ] A redacted full-history secret scan and a current-tree scan are clean,
  with false positives documented without publishing candidate secrets.
- [ ] Every imported source file has a reviewed provenance/license mapping.
- [ ] Private infrastructure defaults and links have been removed or moved to
  a private operations adapter.
- [ ] The Chromium commit, DEPS state, GN arguments, cmux commit, Ghostty
  commit, uBlock payload digest, and all packaged resource manifests are exact.
- [ ] Generated Chromium, Cargo, Ghostty/Zig, resource, and extension notices
  are included in the app and its About UI.
- [ ] Complete corresponding source can be reconstructed for the distributed
  GPL build.
- [ ] Fast public CI passes without private infrastructure.
- [ ] A trusted full Chromium build and the terminal-render XCUITest matrix
  pass against the packaged application.
- [ ] The final public diff passes code review and a release-compliance review.

This engineering inventory is not a legal opinion. Manaflow should have
counsel review chain of title, contributor agreements, static LGPL compliance,
and any commercial distribution before relying on the dual-license path.
