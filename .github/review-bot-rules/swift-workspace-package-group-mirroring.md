# Workspace Package-Group Mirroring

Every Swift package lives physically under exactly one group folder — `Packages/Shared/` (both apps), `Packages/iOS/` (iOS app only), or `Packages/macOS/` (macOS app only) — and `cmux.xcworkspace/contents.xcworkspacedata` must mirror that folder shape exactly. Drift means the workspace no longer shows packages grouped like the directory tree, and CI fails.

Report a failure when the diff:

- Adds a new directory under `Packages/{Shared,iOS,macOS}/` without a matching `FileRef` in the corresponding group in `cmux.xcworkspace/contents.xcworkspacedata`.
- Moves a package between group folders without regenerating the workspace (the move should be `git mv` followed by `python3 scripts/check-workspace-package-groups.py --write`).
- Hand-edits `contents.xcworkspacedata` group membership in a way that diverges from the physical `Packages/` folder structure.
- Places a package in the wrong group for its consumers (used by both apps → `Shared`; iOS-only → `iOS`; macOS-only → `macOS`).

Allowed cases:

- Workspace changes produced by `check-workspace-package-groups.py --write` that match the folder structure.
- Non-package directory additions under `Packages/` that are intentionally not workspace FileRefs.

cmux-specific emphasis:

- The folder is the source of truth; never hand-edit workspace group membership. Cross-group deps use `.package(path: "../../<Group>/<Name>")`.
- CI guard: `python3 scripts/check-workspace-package-groups.py --check`. Flag the drift pre-merge.

When reporting, name the package directory and the missing or wrong `contents.xcworkspacedata` group entry.
