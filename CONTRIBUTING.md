# Contributing to cmux

## Prerequisites

- macOS 14+
- Xcode 15+
- [Zig](https://ziglang.org/) (install via `brew install zig`)

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
   - Build the GhosttyKit.xcframework from source
   - Create the necessary symlinks

3. Build the debug app:
   ```bash
   ./scripts/reload.sh --tag my-feature
   ```
   The script prints the `.app` path. Cmd-click to open, or pass `--launch` to open automatically.

## Development Scripts

| Script | Description |
|--------|-------------|
| `./scripts/setup.sh` | One-time setup (submodules + xcframework) |
| `./scripts/reload.sh` | Build Debug app (pass `--launch` to also open it) |
| `./scripts/reloadp.sh` | Build and launch Release app |
| `./scripts/reload2.sh` | Reload both Debug and Release |
| `./scripts/rebuild.sh` | Clean rebuild |

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

### Basic tests (run on VM)

```bash
ssh cmux-vm 'cd /Users/cmux/cmux && xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" build && pkill -x "cmux DEV" || true && APP=$(find /Users/cmux/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/cmux DEV.app" -print -quit) && open "$APP" && for i in {1..20}; do [ -S /tmp/cmux.sock ] && break; sleep 0.5; done && python3 tests/test_update_timing.py && python3 tests/test_signals_auto.py && python3 tests/test_ctrl_socket.py && python3 tests/test_notifications.py'
```

### UI tests (run on VM)

```bash
ssh cmux-vm 'cd /Users/cmux/cmux && xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" -only-testing:cmuxUITests test'
```

## Validating a fork PR without full Xcode

cmux is a macOS app, so building it locally requires the full Xcode.app, not
just the Command Line Tools. Outside contributors who only have Command Line
Tools cannot produce a runnable `.app` locally, and the `CI` / `Activation
performance` checks on a fork PR stay pending until a maintainer approves them
and do not publish a downloadable build.

To get a trusted build of a fork PR, a maintainer can dispatch the **Fork PR
artifact** workflow (`.github/workflows/fork-pr-artifact.yml`):

1. A maintainer reviews the fork diff and copies the exact PR **head commit
   SHA** (the full 40-character SHA, e.g. from the PR's Commits tab or
   `gh pr view <N> --json headRefOid -q .headRefOid`).
2. They run the workflow against that SHA:

   ```bash
   gh workflow run "Fork PR artifact" --repo manaflow-ai/cmux \
     -f head_sha=<full-40-char-head-sha> \
     -f pr_number=<PR number>
   ```

   or via the Actions tab → **Fork PR artifact** → **Run workflow**.
3. The workflow builds the same unsigned universal Release app that CI's
   `release-build` job compiles and uploads it as the `cmux-unsigned-<PR>`
   artifact (a `cmux-unsigned.zip`), downloadable from the run summary.

Security: the workflow is `workflow_dispatch` only, so only users with write
access to the repo can trigger it. It builds **only the exact SHA the
maintainer entered** (fetched as a pinned commit object, never a mutable
branch ref), so a contributor cannot substitute different code after review.
The build is unsigned, uses no release secrets, and checks out with
`persist-credentials: false` so the fork's build scripts never see the workflow
token.

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
