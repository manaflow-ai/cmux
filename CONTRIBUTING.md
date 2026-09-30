# Contributing to cmux

New here? Read [docs/start-here.md](docs/start-here.md) first: how to pick an
issue, what you can fix without a Mac, and what happens to your pull request.
This file is the mechanics.

Be nice, assume the best: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

For issues, RFCs, pull requests, and progress updates, follow the short [writing guide](STYLE.md).

Start with the [verification ladder](docs/contributor-verification.md) to choose the
smallest useful check for your change. It includes a local path that does not require
maintainer runner access or shared backend credentials.

## Finding something to work on

Issues carry a severity (`S1: critical` through `S4: cosmetic`), an `area:` label,
and sometimes `good first issue` or `help wanted`. [docs/triage.md](docs/triage.md)
says what each one means, how new issues get labeled automatically, and how to
correct a label that is wrong. Comment on an issue before you start working on it.

## Prerequisites

These prerequisites are for native app development. For documentation or portable
contributor tooling, start with [fast checks](#fast-checks-before-committing-or-building)
and the [validation guide](skills/cmux-testing/references/local-vs-ci-validation.md).

- macOS 14+
- Xcode 26 (the pinned toolchain); Xcode 16.2 on Intel Macs running macOS 14.5 or later also builds the macOS app (best effort, [Swift 6.0 limits](skills/cmux-architecture/references/swift-6-0-compatibility.md))
- [Zig](https://ziglang.org/) (install via `brew install zig`)
- [Rust](https://rustup.rs) — `scripts/setup.sh` requires `rustup`, and every app build compiles
  the bundled `cmux-cua` engine with `cargo`. The official installer puts both in `~/.cargo/bin`,
  which is where `setup.sh` looks:

  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```

  Homebrew's `rustup` formula works too, but it is keg-only and no longer ships `rustup-init`, so
  add `$(brew --prefix rustup)/bin` to `PATH` and run `rustup default stable` yourself.
- On Xcode 26 the Metal compiler is a separately downloaded component, and the build fails
  without it. Select the intended full Xcode installation first (`DEVELOPER_DIR`, if
  exported, overrides `xcode-select`), then install the component:

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

## Getting Started

1. Clone the repository with submodules:
   ```bash
   git clone --recursive https://github.com/manaflow-ai/cmux.git
   cd cmux
   ```

2. Run the setup script:
   ```bash
   ./scripts/setup.sh
   ```

   This will:
   - Initialize git submodules (ghostty, homebrew-cmux)
   - Install the pinned Rust toolchain
   - Fetch a checksum-pinned prebuilt GhosttyKit.xcframework, falling back to building it
     from source with Zig (force the source build with `CMUX_GHOSTTYKIT_NO_PREBUILT=1`)
   - Create the necessary symlinks

   After pulling setup or merge-driver changes into an existing clone, rerun
   `./scripts/install-git-hooks.sh`. It replaces old checkout-relative merge-driver
   commands with trusted copies outside the working tree. If you use a custom
   `core.hooksPath`, the installer preserves it and prints the exact `pre-commit`
   and `post-merge` lines to add. Wire both hooks; until `post-merge` is wired,
   rerun the installer after pulling `main` and before merging an untrusted branch.

3. Build the debug app:
   ```bash
   CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag my-feature
   ```
   `CMUX_DEV_BACKEND_MODE=local` points the build at the local dev origin. Without it, a tagged
   build expects the maintainers' shared dev backend and exits before building.
   The script prints the `.app` path. Cmd-click to open, or pass `--launch` to open automatically.

## Development Scripts

| Script | Description |
|--------|-------------|
| `./scripts/setup.sh` | One-time setup (submodules + xcframework) |
| `CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag <tag>` | Build a tagged Debug app; add `--launch` to open it or `--build-only` for compile-only validation |

See [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md) for cache
reuse, Release variants, and restrictions that protect the running app.

<a id="fast-checks-before-building-or-pushing"></a>

## Fast checks before committing or building

Run `python3 scripts/verify-local.py` on your reviewed checkout. It selects
affected static checks and parses changed Swift, including committed branch edits.
The base comes from local `upstream/HEAD`, then `origin/HEAD`; nothing is fetched.
Use `--list` to preview, `--all` for the full CI static recipe, or `--affected BASE`
to choose a different static comparison base.

Checks cover localization, project/test wiring, package grouping, generated policy
and feature flags. Unknown inputs or a missing base select the full static recipe.
CI also keeps the full static recipe. Failures print a focused rerun command:

```sh
python3 scripts/verify-local.py --only project --only test-wiring
```

Parsing does not replace typechecking, app tests or a build. Add `--receipt -`
for JSON stdout; see the [command guide](docs/verification-receipts.md) for piped
paths, explicit Swift inputs and evidence limits.

The command executes repository Python/shell code, including for help and list.
Use a [trusted checkout](docs/contributor-verification.md#trust-boundary).
Git push does not run it automatically.

## Team Dev Setup

Team members with a Stack account can make DEBUG builds sign in and attach an iOS build automatically; see [team dev setup](docs/team-dev-setup.md).

## Web and JS Tooling

Run Biome from the repository root with:

```bash
bun run biome:check
```

The root `biome.json` intentionally scopes `biome check .` to maintained web and JS/TS sources.
It excludes generated bundles, build outputs, vendored trees, and review-tool metadata such as
`.greptile/`.
Biome formatting and import sorting are disabled for now; do not wire this into required CI until
the remaining source lint diagnostics are paid down.

## Running Tests

Use the [contributor verification ladder](docs/contributor-verification.md): source checks,
focused package tests, app and test compilation, then isolated socket/UI checks and
physical dogfood where the change needs them. Record which layers actually ran in
your PR; a successful parse or build does not mean tests executed.

The guide covers local contributors first. Maintainer-only focused CI dispatch and
fleet access are optional paths, not prerequisites for contributing.

## What CI runs for you

You do not need runner access, a signing identity or a Mac build farm to get a
change tested. Opening the pull request is the request:

- Static checks run on every pull request, and the Linux guards run when your diff
  touches what they cover. `python3 scripts/verify-local.py` runs the checks your
  diff touches and `--all` runs the full recipe CI uses, so fix those before you push.
- Swift, package and tooling tests are routed from your diff. An edited suite runs,
  and an app-source change runs the suites whose tests mention what you changed.
  No label is needed for any of that.
- The broad macOS suite is label-gated. A maintainer adds `full-ci` when a change
  needs those lanes; see [PR CI coverage](skills/cmux-testing/references/pr-ci-coverage.md).
  It is not a review or merge requirement, and it is not a substitute for saying
  what you ran.
- `cmuxUITests/` is not run in full by any pull request job. If your diff touches
  that directory, the `suite-coverage` check fails until a maintainer runs the
  affected classes and records it with `no-full-ci`, because a pull request from a
  fork cannot dispatch those lanes itself.

Read which tests executed on the current commit rather than the color of the
checks list: a skipped job is green and is not coverage. If checks never start on
your first pull request, they are waiting on a maintainer to approve a workflow
run from a new contributor.

## Ghostty Submodule

The `ghostty` submodule points to [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty), a fork of upstream Ghostty. To change it, rebuild `GhosttyKit.xcframework`, or pull in upstream, follow the [cmux-ghostty skill](skills/cmux-ghostty/SKILL.md): push the submodule commit to the fork before committing the pointer in this repository. Fork changes and conflict notes are in [docs/ghostty-fork.md](docs/ghostty-fork.md).

## Pull Requests

- Describe the change as the [writing guide](STYLE.md) says and fill in the pull request template, including what ran.
- For a bug fix, commit the failing regression test before the fix; see [regression commits](skills/cmux-testing/SKILL.md#reproduce-and-repair).
- Fill in the template's `## Changelog` section: one `Added`/`Changed`/`Fixed`/`Removed` line for a user-visible change, or `none`. Don't edit [CHANGELOG.md](CHANGELOG.md); the release builds it from these lines.
- Sign the [CLA](CLA.md) once by commenting `I have read the CLA Document v2.2 and I hereby sign the CLA` on your pull request. The CLA check asks for it on your first pull request.

### What a good one looks like

- One change. A fix plus a reformat is two pull requests, and the reformat will
  hold up the fix.
- A summary that names the problem, then what a person can do after the change.
- Testing that names the commands you ran and what they establish. If you could
  not run a layer, say which one and why, once. "It compiles" and "I ran it" are
  different claims and reviewers read them differently.
- No unrelated formatting, no generated files, no vendored trees, no drive-by
  version bumps.
- User-facing strings localized: see the [localization skill](skills/cmux-localization/SKILL.md).

### How review and merge work

- Automated reviewers comment first, sometimes several of them, sometimes about
  setup that has nothing to do with your diff. Answer what applies and ignore the
  rest. Don't `@`-mention review bots to summon more of them.
- A maintainer reads the description before the diff. If the description doesn't
  say what the change does and what you ran, review stalls there.
- Answer review comments in the thread, push fixups, and say when you're done.
  An unanswered question is the most common reason a finished patch sits still.
  If a pull request goes quiet and you want eyes on it, say so on the same pull
  request instead of opening another.
- A change merges when the CI relevant to it is green, review comments are
  answered, and no product decision is still open. That last one is the usual
  cause of delay on an otherwise good patch: when the open question is what cmux
  should do, a maintainer answers it before the code lands. Ask on the issue
  rather than guessing in code.
- Merges are squash merges, so the pull request title and description become the
  commit that ships. Write them for someone reading `git log` a year from now.
- `main` is what NIGHTLY builds from. When something lands broken we fix forward
  instead of reverting, so a follow-up pull request is routine, not a reprimand.
- If we end up solving the same problem another way, we credit you with a
  `Co-authored-by` trailer and link the change from your pull request.

Agents working in this repository also follow [CLAUDE.md](CLAUDE.md) (also `AGENTS.md`).

## License

By contributing to this repository, you agree that:

1. Your contributions are licensed under the license of the directory you contribute to: the Business Source License 1.1 (`BUSL-1.1`) for the server directories listed in [LICENSE](LICENSE) (`web/`, `workers/ci-artifacts/`, `workers/iroh-v2/`, `workers/presence/`, `services/iroh-relay-minter/`, `cmux-tui/relays/cloudflare-do/`), and the project's GNU General Public License v3.0 or later (`GPL-3.0-or-later`) everywhere else unless a file states otherwise.
2. You grant Manaflow, Inc. a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, reproduce, modify, sublicense, and distribute your contributions under any license, including a commercial license offered to third parties.
