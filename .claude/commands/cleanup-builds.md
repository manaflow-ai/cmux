# Cleanup Dev Builds

Reclaim disk space taken by tagged dev artifacts produced by `./scripts/reload.sh --tag <tag>`. Each tagged build is multi-GB of DerivedData plus per-tag sockets and logs.

## Steps

1. **Preview first.**

   ```bash
   ./scripts/cleanup-dev-builds.sh
   ```

   Shows what would be deleted, what is skipped, and total reclaimable bytes. Dry-run by default; nothing is deleted yet.

2. **Read the preview to the user.** Confirm the active tag and any tag they care about appears under `skipping:` (running, or most recent reload via `/tmp/cmux-last-cli-path`).

3. **Ask the user before deleting.** Do not run `--apply` without explicit user confirmation. Surface any tags they may want to keep so they can add `--keep <tag>`.

4. **Apply.** Once confirmed:

   ```bash
   ./scripts/cleanup-dev-builds.sh --apply
   ```

   Optional: `--keep <tag>` (repeatable) to protect specific tags, `--older-than <DAYS>` to skip anything touched recently.

5. **Report.** Show the freed-bytes total from the script's final line.

## Notes

- Safety rules always on: skip running `cmux DEV <tag>` apps, skip the tag in `/tmp/cmux-last-cli-path` (most recent reload).
- Worktrees existing under HQ are NOT a protection. Use `--keep` for explicit protection.
- The script never touches `GhosttyKit.xcframework` symlinks, the GhosttyKit cache, or anything outside per-tag artifacts.
