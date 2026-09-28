# Contributing to cmux

For issues, RFCs, pull requests, and progress updates, follow the short [writing guide](STYLE.md).

Start with the [verification ladder](docs/contributor-verification.md) to choose the
smallest useful check for your change. It includes a local path that does not require
maintainer runner access or shared backend credentials.

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

## Ghostty Submodule

The `ghostty` submodule points to [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty), a fork of upstream Ghostty. To change it, rebuild `GhosttyKit.xcframework`, or pull in upstream, follow the [cmux-ghostty skill](skills/cmux-ghostty/SKILL.md): push the submodule commit to the fork before committing the pointer in this repository. Fork changes and conflict notes are in [docs/ghostty-fork.md](docs/ghostty-fork.md).

## Pull Requests

- Describe the change as the [writing guide](STYLE.md) says and fill in the pull request template, including what ran.
- For a bug fix, commit the failing regression test before the fix; see [regression commits](skills/cmux-testing/SKILL.md#reproduce-and-repair).
- Fill in the template's `## Changelog` section: one `Added`/`Changed`/`Fixed`/`Removed` line for a user-visible change, or `none`. Don't edit [CHANGELOG.md](CHANGELOG.md); the release builds it from these lines.
- Sign the [CLA](CLA.md) once by commenting `I have read the CLA Document v2.2 and I hereby sign the CLA` on your pull request. The CLA check asks for it on your first pull request.

Agents working in this repository also follow [CLAUDE.md](CLAUDE.md) (also `AGENTS.md`).

## License

By contributing to this repository, you agree that:

1. Your contributions are licensed under the license of the directory you contribute to: the Business Source License 1.1 (`BUSL-1.1`) for the server directories listed in [LICENSE](LICENSE) (`web/`, `workers/ci-artifacts/`, `workers/iroh-v2/`, `workers/presence/`, `services/iroh-relay-minter/`, `cmux-tui/relays/cloudflare-do/`), and the project's GNU General Public License v3.0 or later (`GPL-3.0-or-later`) everywhere else unless a file states otherwise.
2. You grant Manaflow, Inc. a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, reproduce, modify, sublicense, and distribute your contributions under any license, including a commercial license offered to third parties.
