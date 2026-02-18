# Sync Branch

Get the current branch ready: update all submodules to their latest remote main, merge from main, and push.

## Steps

1. **Update submodules to latest**
   - For each submodule (ghostty, homebrew-cmux, vendor/bonsplit):
     - `cd <submodule>`
     - `git fetch origin`
     - Check if behind: `git rev-list HEAD..origin/main --count`
     - If behind, merge: `git merge origin/main --no-edit`
   - For ghostty specifically, push the merge to the fork: `git push origin HEAD:main`
     - Verify with: `git merge-base --is-ancestor HEAD origin/main`
   - Go back to repo root

2. **Commit submodule updates on main**
   - `git checkout main && git pull origin main`
   - Check if any submodules changed: `git diff --name-only` (look for submodule paths)
   - If changed, stage and commit: `git add ghostty homebrew-cmux vendor/bonsplit && git commit -m "Update submodules: <brief description>"`
   - Push main: `git push origin main`

3. **Rebase current branch on main**
   - `git checkout <original-branch>`
   - `git rebase main`
   - If conflicts, resolve them and continue
   - Force push if branch was already pushed: `git push --force-with-lease origin <branch>`

4. **Report status**
   - Show what submodules were updated and by how many commits
   - Show if rebase was clean or had conflicts
   - Show current branch and commit

## Notes

- Never commit a submodule pointer in the parent repo unless the submodule commit is reachable from the submodule's remote main (per CLAUDE.md pitfall about orphaned commits)
- If no submodules need updating and main has no new commits, just say "Already up to date"
- If on main already, skip step 3
