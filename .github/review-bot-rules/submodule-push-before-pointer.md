# Submodule Push Before Pointer

A submodule pointer bump that lands on a commit not reachable from the submodule's canonical remote branch orphans the SHA: the next `git submodule update` (CI, a fresh clone, another contributor) cannot fetch it, breaking the build. The orphaning is invisible in the parent diff, which only shows a new `Subproject commit <sha>`.

Report a failure when the diff:

- Changes a submodule pointer (a `Subproject commit` gitlink change for `ghostty`, `vendor/*`, or any path in `.gitmodules`) without evidence in the PR description that the new SHA is reachable from the submodule's canonical remote branch.
- Bumps the `ghostty` submodule without the output (or an equivalent claim) of `cd ghostty && git merge-base --is-ancestor HEAD origin/main` (or `manaflow/main` for the fork).
- Lands a submodule pointer on a commit authored on a detached HEAD or a temporary/feature branch that has not been pushed to the submodule's remote.

Allowed cases:

- A pointer bump whose PR description shows the submodule commit is already pushed and is an ancestor of the canonical remote branch.
- `.gitmodules` URL/branch edits that do not change a pinned commit.

cmux-specific emphasis:

- For `ghostty`: push to the `manaflow` fork's `main` BEFORE committing the updated pointer in the parent repo (`docs/ghostty-fork.md`, `skills/cmux-ghostty`). Never commit the pointer from a detached HEAD.
- The failure mode is a CI checkout that cannot fetch the submodule SHA; flag it pre-merge, not after the build breaks.

When reporting, name the submodule and the unreachable or unverified SHA.
