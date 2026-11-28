# Cleanup Dev Builds

Reclaim disk taken by tagged dev artifacts from `./scripts/reload.sh --tag <tag>`. Each tagged build is multi-GB of DerivedData plus per-tag sockets and logs.

## Steps

1. **Preview.** `./scripts/cleanup-dev-builds.sh` is dry-run by default and prints what would be deleted, what is skipped, and total reclaimable bytes.

2. **Read the preview to the user.** Confirm the active tag and any tag they care about appears under `skipping:`.

3. **Ask before deleting.** Never run `--apply` without explicit confirmation. Surface tags they may want to protect with `--keep <tag>`.

4. **Apply.** `./scripts/cleanup-dev-builds.sh --apply`. Optional: `--keep <tag>` (repeatable) to protect specific tags, `--older-than <DAYS>` to skip recently touched artifacts.

5. **Report** the freed-bytes total from the script's final line.

## Notes

Always-on safety rules: skip running `cmux DEV <tag>` apps, and skip the tag in `/tmp/cmux-last-cli-path` (the most recent reload). An existing HQ worktree is not protection; use `--keep`. The script never touches `GhosttyKit.xcframework` symlinks, the GhosttyKit cache, or anything outside per-tag artifacts.
