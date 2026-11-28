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
| Manaflow rights-controlled | GPL-3.0-or-later; separately offered commercial terms only when Manaflow controls the necessary rights |
| Chromium-derived | Preserve BSD-3-Clause copyright, license, source revision, and modification notice |
| Helium-derived | Preserve GPL-3.0-only copyright, exact source revision, and modification notice; exclude from commercial-license claims |
| Mixed provenance | Preserve every applicable notice and document the copied regions; do not replace the obligations with an `OR` expression |
| Other dependency | Preserve its upstream license and add exact source/artifact identity to generated notices |

A root license never overrides a more specific file-level or third-party
license. The initial private tree's generic Chromium headers are not accepted
as classification evidence; each file must be reviewed against its history and
upstream sources.

"Rights-controlled" is intentionally narrower than "authored." Git authorship
alone does not establish employment assignment, contractor assignment,
employer authorization, patent rights, or an effective relicensing grant.

## License policy decision

The desktop Browser follows cmux's existing GPL-3.0-or-later policy for
Manaflow rights-controlled code. The import does not switch cmux or this
directory to AGPL. GPL already covers distribution of modified desktop forks;
AGPL's additional source requirement is material when a modified program is
offered for remote interaction over a network. If cmux later ships a hosted
service for which that distinction matters, license it as a separately
reviewed component rather than changing the desktop product incidentally.
AGPL obligations attach to the AGPL-covered network-interactive program; they
do not automatically relicense independent neighboring services. If an
AGPLv3-covered component is combined with GPLv3-covered code, the GPLv3/AGPLv3
section 13 compatibility rule and the AGPL network-source requirement for the
combination must be reviewed as part of that service's architecture.

Manaflow can release later versions of rights-controlled code under different
terms, but an already published GPL or AGPL grant remains available for that
published version. Third-party rights and outside contributions do not become
relicensable merely because Manaflow maintains the repository.

## Release composition

The public GPL release and any future commercial release have different
composition gates.

| Component | Public GPL release | Future commercial release |
| --- | --- | --- |
| Manaflow rights-controlled Browser code | GPL-3.0-or-later with complete corresponding source | Eligible only after chain-of-title and contributor-grant review |
| Chromium-derived code | Preserve BSD-3-Clause notices and generated Chromium credits | Permissive terms may allow use; retain every notice and condition |
| Ghostty and Bonsplit | Preserve MIT notices plus every transitive dependency obligation | Permissive portions may allow use; audit the exact linked/resource closure |
| Helium-derived code | Preserve GPL-3.0-only terms, provenance, and source | Exclude, replace independently, or obtain separate permission |
| uBlock Origin | Preserve GPL-3.0-only terms and provide exact corresponding source | Not covered by Manaflow's commercial offer; exclude or use only in a counsel-reviewed aggregation that preserves its GPL rights |
| cmux TUI | Preserve its GPL terms and corresponding source | Exclude from commercial claims unless all necessary rights exist; a process boundary is not by itself a legal conclusion |
| Static LGPL components | Preserve notices/source and provide the required relinking route | Remove, link appropriately, or provide the exact relinking materials and permissions required by the license |
| Fonts, themes, and other resources | Ship only resources with per-item redistribution provenance | Same requirement; an application license cannot cure a missing asset license |

## Dependency obligations

- **Chromium:** pin a full source commit and DEPS state. Generate the shipped
  target's license/credits output with Chromium's license tooling.
- **Ghostty:** use the root gitlink, retain its MIT notice, and include licenses
  for linked libraries, fonts, themes, and shell-integration resources. The
  current Darwin link includes static GNU gettext/libintl 0.24 under
  LGPL-2.1-or-later even when Ghostty is built with `-Di18n=false`; that option
  disables catalogs but does not remove the unconditional Darwin link. Inspect
  the produced archive rather than treating a build flag as license evidence.
  The embedded font closure includes JetBrains Mono 2.304 under OFL-1.1 and
  Nerd Fonts Symbols Only 3.4.0 under MIT; preserve their exact notices, and
  review OFL Reserved Font Name conditions before modifying or rebuilding the
  OFL font. Do not infer that every converted theme is MIT from the theme
  collection's license; ship only themes with verified per-theme
  redistribution provenance.
- **cmux TUI:** build the sibling workspace and record the exact helper receipt.
- **Helium:** retain exact patch provenance and GPL-3.0-only terms. A future
  proprietary Browser requires independently reimplementing or separately
  licensing Helium-derived behavior.
- **Bonsplit:** preserve the MIT notice and exact source revision for adapted
  split-layout and animation behavior, even though cmux already ships Bonsplit
  elsewhere in the monorepo.
- **uBlock Origin:** pin the extension payload digest and upstream source tag,
  preserve GPL-3.0-only notices, and distribute the corresponding source or a
  valid source offer with the binary. Preserve and inventory the extension's
  own embedded third-party licenses and assets as well; the uBlock GPL notice
  is not a substitute for those notices.

## Required gates

- [ ] Canonical private Browser validation is complete and its source SHA is
  frozen.
- [ ] A redacted full-history secret scan and a current-tree scan are clean,
  with false positives documented without publishing candidate secrets.
- [ ] Every imported source file has a reviewed provenance/license mapping.
- [ ] Manaflow has documented ownership or an explicit relicensing grant for
  every rights-controlled contribution.
- [ ] A counsel-approved, versioned ICLA/CCLA workflow records durable,
  affirmative assent for future Browser contributions, including copyright and
  patent grants, contributor representations, employer authority, and
  re-consent when the agreement changes.
- [ ] `cmux-browser/**` is protected by required CODEOWNER review, a required
  contributor-agreement status check, and branch rules that cannot be bypassed
  by an ordinary merge.
- [ ] Private infrastructure defaults and links have been removed or moved to
  a private operations adapter.
- [ ] The Chromium commit, DEPS state, GN arguments, cmux commit, Ghostty
  commit, uBlock payload digest, and all packaged resource manifests are exact.
- [ ] Generated Chromium, Cargo, Ghostty/Zig, resource, and extension notices
  are included in the app and its About UI.
- [ ] Static LGPL dependencies have an explicit GPL-compliance path; any
  commercial build instead omits them, links them appropriately, or ships the
  relinkable material and permissions their license requires.
- [ ] Complete corresponding source can be reconstructed for the distributed
  GPL build.
- [ ] Fast public CI passes without private infrastructure.
- [ ] A trusted full Chromium build and the terminal-render XCUITest matrix
  pass against the packaged application.
- [ ] The final public diff passes code review and a release-compliance review.

This engineering inventory is not a legal opinion. Manaflow should have
counsel review chain of title, contributor agreements, static LGPL compliance,
and any commercial distribution before relying on the dual-license path.
