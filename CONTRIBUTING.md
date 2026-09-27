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
- Xcode 26 (the pinned toolchain); Xcode 16.2 on Intel Macs running macOS 14 also builds the macOS app (best effort)
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
| `./scripts/reload.sh` | Build Debug app (pass `--launch` to also open it) |
| `./scripts/reloadp.sh` | Build and launch Release app |
| `./scripts/reload2.sh` | Reload both Debug and Release |
| `./scripts/rebuild.sh` | Clean rebuild |

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

## Team Dogfood Setup

DEBUG builds can auto-sign-in as you and auto-attach an iOS build to your Mac with no manual steps. Each developer does a one-time setup with their own Stack account.

Run this once:

```bash
scripts/setup-team-dev.sh
```

It prompts for your Stack email and password (the password is never echoed), verifies them against Stack, and writes `~/.secrets/cmuxterm-dev.env` with `chmod 600`. Re-running it is safe; if you are already configured it prints the account and exits. To reset, delete `~/.secrets/cmuxterm-dev.env` and run it again.

After that, every dev build signs you in automatically:

```bash
scripts/dev-setup.sh --tag <your-initials>
```

That builds the tagged macOS DEBUG app auto-signed-in as you, enables the iOS pairing host, mints an attach ticket, and launches the iOS dev build auto-attached to your Mac. Use `--surface mac` for macOS only. See `scripts/dev-setup.sh --help` for all flags.

This is DEBUG-only and per-user. The credentials file lives outside the repo and is never committed; `scripts/cmuxterm-dev.env.example` is the in-repo template. Release builds never read these credentials (the auto-sign-in path is compiled out of release).

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

## Rebuilding GhosttyKit

If you make changes to the ghostty submodule, rebuild the xcframework:

```bash
cd ghostty
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

## Running Tests

Use the [contributor verification ladder](docs/contributor-verification.md): source checks,
focused package tests, app and test compilation, then isolated socket/UI checks and
physical dogfood where the change needs them. Record which layers actually ran in
your PR; a successful parse or build does not mean tests executed.

The guide covers local contributors first. Maintainer-only focused CI dispatch and
fleet access are optional paths, not prerequisites for contributing.

## Ghostty Submodule

The `ghostty` submodule points to [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty), a fork of the upstream Ghostty project.

### Making changes to ghostty

```bash
cd ghostty
git checkout -b my-feature
# make changes
git add .
git commit -m "Description of changes"
git push manaflow my-feature
```

### Keeping the fork updated

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push manaflow main
```

Then update the parent repo:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

See `docs/ghostty-fork.md` for details on fork changes and conflict notes.

## License

By contributing to this repository, you agree that:

1. Your contributions are licensed under the project's GNU General Public License v3.0 or later (`GPL-3.0-or-later`).
2. You grant Manaflow, Inc. a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, reproduce, modify, sublicense, and distribute your contributions under any license, including a commercial license offered to third parties.
