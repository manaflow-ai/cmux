# Pull

Pull latest main and update all submodules to their latest remote main. No commits, no pushes.

## Steps

1. `git pull origin main`
2. For each submodule (ghostty, homebrew-cmux, vendor/bonsplit):
   - `cd <submodule>`
   - `git fetch origin`
   - Check if behind: `git rev-list HEAD..origin/main --count`
   - If behind, merge: `git merge origin/main --no-edit`
   - Do NOT push. We only land submodule changes via PRs.
   - Go back to repo root
3. `git submodule update --init --recursive`
4. Report: current commit, which submodules were updated and by how many commits
