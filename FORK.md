# FORK.md - Wasim's cmux fork

This is a personal fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux). It carries
custom features that do not exist upstream. This file documents what those features are, which files
they live in, and the exact loop to pull in a new upstream version without losing them.

Keep this file fork-only. Upstream never touches `FORK.md`, so it never causes a merge conflict.
That is the whole point: our fork notes live here, not in `CLAUDE.md` (which upstream owns and edits).

## Remotes

- `origin` -> `https://github.com/wasimjalali/cmux.git` (our fork)
- `upstream` -> `https://github.com/manaflow-ai/cmux.git` (the real cmux)

## Our custom features

### 1. Sidebar folder drag-and-drop

Drop a folder onto the sidebar to open it as a new workspace. The workspace shows the folder name
and auto-runs `claude` in it.

Design and plan docs:

- `docs/superpowers/specs/2026-07-11-sidebar-folder-drop-design.md`
- `docs/superpowers/plans/2026-07-11-sidebar-folder-drop.md`
- `docs/superpowers/plans/2026-07-11-sidebar-folder-drop-v2.md`

## Files the fork owns or changes

Knowing this list is what makes updates safe. When an upstream merge conflicts, it will only ever be
in the "modified upstream files" group below. The "fork-only" files never conflict.

**Fork-only new files** (upstream does not have these, so they never conflict):

- `Sources/DirectoryDropFilter.swift`
- `Sources/SidebarDropRegionProbe.swift`
- `Sources/SidebarDropRegionRegistry.swift`
- `cmuxTests/DirectoryDropFilterTests.swift`
- `cmuxTests/SidebarDropRegionRegistryTests.swift`
- the three docs listed above

**Modified upstream files** (this is the conflict surface, check these on every merge):

- `Sources/ContentView.swift` - wires in the drop overlay. Look for `onFoldersDroppedOnSidebar`
  and `.background(SidebarDropRegionProbe())`.
- `Sources/FileDropOverlayView.swift` - fork edits to the drop overlay.
- `Sources/FileDropOverlayViewHitTesting.swift` - fork edits to hit testing.
- `cmux.xcodeproj/project.pbxproj` - wires the new Swift files into the Xcode target.
- `.gitignore` - adds `build-release/`.

## The update loop (run this every time upstream ships a new version)

Follow these steps whenever you want to pull a new cmux version into the fork. This is the system
that keeps our features. Never click the in-app Sparkle "Update" button as your way of updating; that
only swaps the installed binary and does nothing for our source. Updates happen here, in git.

Replace `vX.Y.Z` with the target version (e.g. `v0.64.19`).

```bash
# 0. Start clean on the feature branch that holds our work.
git checkout feat/sidebar-folder-drop
git status   # must be clean

# 1. Get the new upstream version and tags.
git fetch upstream --tags

# 2. See what is coming and where it might conflict with us.
#    BASE is the merge-base; the last arg is the new tag.
BASE=$(git merge-base feat/sidebar-folder-drop vX.Y.Z)
comm -12 \
  <(git diff --name-only $BASE feat/sidebar-folder-drop | sort) \
  <(git diff --name-only $BASE vX.Y.Z | sort)
#    -> the printed files are the only possible conflicts. Expect them to be a
#       subset of the "modified upstream files" list above.

# 3. Do the merge on a dedicated integration branch (keeps the feature branch safe).
git checkout -b merge/upstream-vX.Y.Z feat/sidebar-folder-drop
git merge vX.Y.Z --no-edit
```

### Resolving conflicts

- **`Sources/*.swift`**: keep BOTH sides. Our drop code and upstream's new code should coexist.
  After resolving, confirm our hooks are still present:
  ```bash
  grep -n "onFoldersDroppedOnSidebar\|SidebarDropRegionProbe" Sources/ContentView.swift
  ```
- **`cmux.xcodeproj/project.pbxproj`**: this conflicts because both sides add file entries in the
  same sorted region. The fix is union (keep both), then let the normalizer re-sort:
  ```bash
  # strip only the conflict-marker lines (keeps both sides everywhere)
  grep -vE '^(<<<<<<< HEAD|=======|>>>>>>> vX\.Y\.Z)$' cmux.xcodeproj/project.pbxproj > pbx.tmp
  mv pbx.tmp cmux.xcodeproj/project.pbxproj
  python3 scripts/normalize-pbxproj.py
  bash scripts/check-pbxproj.sh                 # must exit 0
  bash scripts/lint-pbxproj-test-wiring.sh      # must say ok
  git add cmux.xcodeproj/project.pbxproj
  ```
  Then confirm every fork file is still wired (4 refs each is normal):
  ```bash
  for f in DirectoryDropFilter SidebarDropRegionProbe SidebarDropRegionRegistry \
           FileDropOverlayView FileDropOverlayViewHitTesting \
           DirectoryDropFilterTests SidebarDropRegionRegistryTests; do
    echo "$f: $(grep -c "$f.swift" cmux.xcodeproj/project.pbxproj)"
  done
  ```
- **`.gitignore`**: trivial, keep both sides.

### After conflicts are resolved

```bash
# 4. Sync submodules to the merged pointers (upstream often bumps ghostty / bonsplit).
git submodule update --init --recursive

# 5. Commit the merge.
git commit --no-edit

# 6. Build. reload.sh runs ensure-ghosttykit.sh, which repoints GhosttyKit.xcframework
#    to the new ghostty SHA automatically.
./scripts/reload.sh --tag merge-vX-Y-Z

# 7. Run our regression tests.
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=macOS' \
  -only-testing:cmuxTests/DirectoryDropFilterTests \
  -only-testing:cmuxTests/SidebarDropRegionRegistryTests

# 8. Push and open a PR on the fork, then dogfood the tagged build.
git push origin merge/upstream-vX.Y.Z
```

Once the build is dogfooded and good, fast-forward the feature branch to the merge:

```bash
git checkout feat/sidebar-folder-drop
git merge --ff-only merge/upstream-vX.Y.Z
git push origin feat/sidebar-folder-drop
```

## Notes

- The `ghostty` and `vendor/bonsplit` submodules track upstream. Our fork does not modify them, so
  the merge always takes upstream's newer pointer. No submodule conflict expected.
- `GhosttyKit.xcframework` is a symlink into `~/.cache/cmux/ghosttykit/<ghostty-sha>-.../`. Do not
  edit it by hand. `scripts/ensure-ghosttykit.sh` (called by `reload.sh`) points it at the right SHA.
- If a future upstream version renames or heavily rewrites `ContentView.swift`,
  `FileDropOverlayView.swift`, or `FileDropOverlayViewHitTesting.swift`, the merge conflict there may
  need real reintegration, not just union. That is the one case to slow down and read both sides.
