# Sync Branch

Get the current branch ready: update all submodules to their latest remote main, merge from main, and rebase.

**Important: Never push automatically. Always ask the user before any push.**

## Steps

1. **Update submodules to latest**
   - For each submodule (ghostty, homebrew-cmux, vendor/bonsplit):
     - `cd <submodule>`
     - `git fetch origin`
     - Check if behind: `git rev-list HEAD..origin/main --count`
     - If behind, merge: `git merge origin/main --no-edit`
   - Do NOT push submodules. We only land submodule changes via PRs.
   - Go back to repo root

2. **Commit submodule updates on main**
   - `git checkout main && git pull origin main`
   - Check if any submodules changed: `git diff --name-only` (look for submodule paths)
   - If changed, stage and commit: `git add ghostty homebrew-cmux vendor/bonsplit && git commit -m "Update submodules: <brief description>"`
   - **Do not push.** Ask the user if they want to push.

3. **Rebase current branch on main**
   - `git checkout <original-branch>`
   - `git rebase main`
   - If conflicts, resolve them and continue
   - **Do not push.** Ask the user if they want to force-push the rebased branch.

4. **Report status**
   - Show what submodules were updated and by how many commits
   - Show if rebase was clean or had conflicts
   - Show current branch and commit

## Notes

- Never commit a submodule pointer in the parent repo unless the submodule commit is reachable from the submodule's remote main (per CLAUDE.md pitfall about orphaned commits)
- If no submodules need updating and main has no new commits, just say "Already up to date"
- If on main already, skip step 3
