# Pull

Pull latest main and update all submodules to their latest remote main. No commits, no pushes.

## Steps

1. `git pull origin main`
2. For each of `ghostty`, `homebrew-cmux`, `vendor/bonsplit`: `git fetch origin`, check `git rev-list HEAD..origin/main --count`, and if behind run `git merge origin/main --no-edit`. Do not push; submodule changes land only via PRs.
3. `git submodule update --init --recursive`
4. Report the current commit, plus which submodules moved and by how many commits.
