# Sync Branch

Get the current branch ready: update all submodules to their latest remote main, merge from main, and rebase.

**Important: Never push automatically. Always ask the user before any push.**

## Steps

1. **Update submodules to latest.** For each of `ghostty`, `homebrew-cmux`, `vendor/bonsplit`: `git fetch origin`, check `git rev-list HEAD..origin/main --count`, and if behind run `git merge origin/main --no-edit`. Do not push submodules; submodule changes land only via PRs.

2. **Commit submodule updates on main.** `git checkout main && git pull origin main`, check `git diff --name-only` for submodule paths, and if any changed: `git add ghostty homebrew-cmux vendor/bonsplit && git commit -m "Update submodules: <brief description>"`. Do not push. Ask the user whether to push.

3. **Rebase the branch on main.** `git checkout <original-branch> && git rebase main`, resolving conflicts and continuing. Do not push. Ask the user whether to force-push the rebased branch. Skip this step if already on main.

4. **Report.** Which submodules moved and by how many commits, whether the rebase was clean or conflicted, and the current branch and commit. If no submodules needed updating and main has no new commits, say "Already up to date".

## Notes

Never commit a submodule pointer in the parent repo unless that submodule commit is reachable from the submodule's remote main (see the submodule-safety pitfall in CLAUDE.md).
