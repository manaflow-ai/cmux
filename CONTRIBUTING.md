# Contributing to cmux

## Prerequisites

These prerequisites are for native app development. For documentation or portable
contributor tooling, start with [fast checks](#fast-checks-before-building-or-pushing)
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

## Fast checks before building or pushing

For edited Swift, use `python3 scripts/verify-local.py --swift-changed` to discover
staged, unstaged and untracked files automatically. Add a base ref, such as
`--swift-changed origin/main`, to include committed branch changes. Use
`--only swift-syntax --swift-changed` for the parser-only edit loop. The
[command guide](docs/verification-receipts.md) also covers explicit files, piped
NUL-delimited paths and JSON stdout. Parsing does not replace typechecking or tests.

Run `python3 scripts/verify-local.py` to run the same static checks as CI locally,
without Xcode, package installs, submodules or an app build. It checks localization,
project configuration, generated policy, test-target wiring, package grouping and
feature flags, and runs the project normalizer's tests. Failures show the diagnostic
and a command to rerun just that check, for example:

```sh
python3 scripts/verify-local.py --only project --only test-wiring
```

These are static sanity checks, not Swift compilation or app tests. Add
`--receipt /tmp/cmux-preflight.json` when handing the result to another contributor.
See [local verification](docs/verification-receipts.md) for scope and receipt limits.

## Team dogfood setup

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

Choose the checks that establish your change's behavior using the
[validation guide](skills/cmux-testing/references/local-vs-ci-validation.md).
Portable contributor tooling needs its focused tests; Swift app/test changes need
native compilation and execution; UI/socket changes need the correct tagged app.
A static preflight pass is not a substitute for those checks.

The guide links the existing test commands and explains build-only versus
executed-test evidence. Follow [current build routing](AGENTS.md) for native
capacity; do not revive old SSH/VM recipes or launch an untagged app.

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
