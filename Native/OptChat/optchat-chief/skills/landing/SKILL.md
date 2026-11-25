---
name: landing
description: Land your own pull request: when to merge, what blocks a merge and what does not, and what to do after. Use after opening a pull request, when its checks finish, or when the person asks you to merge.
cmux-managed: true
---

# Landing a pull request

Work is done when it is on the branch it was meant for, not when a pull
request is open. This is how to get it there without waiting on things that
do not matter, and without merging what does.

Only for a pull request you opened, when the task or the person asked for a
pull request or a merge. Someone else's pull request is theirs: never push to
it or merge it unasked; comment or tell the person instead.

## 1. Merge on green, pinned

When your checks are green (skill `ci-wait`) and nothing in section 2 blocks:

```sh
gh pr merge N --squash --match-head-commit FULL_SHA
```

- `--match-head-commit` pins the merge to the commit you tested: if anyone
  pushed after it, the merge is refused instead of landing untested code.
- A review is welcome, not required, unless the repository's branch rules
  require one: then ask for it once and wait for it like a check.
- The repository has a merge queue or auto-merge: `gh pr merge N --auto
  --squash --match-head-commit FULL_SHA` and wait for the merge.

## 2. What blocks, what does not

Blocks:
- A red check caused by your change.
- A conflict with the base branch: rebase or merge the base yourself, push, wait again.
- A review finding that would break the base branch, lose user data, open a
  security hole, or undo a design the team settled.

Does not block (say it in one line, then merge):
- A check failing the same way on the base branch.
- A check no runner picked up for a long time, when the branch rules do not
  require it.
- Style and nice-to-have review notes: merge, then make them a follow-up issue
  or pull request.

## 3. Never

- Never bypass branch protection (`--admin`) unless the person said so.
- Never merge without the head pin.
- Never force-push a branch someone else also works on.

## 4. After the merge

- Report the merge commit as a link (`[abc1234](https://github.com/OWNER/REPO/commit/SHA)`).
- Delete your branch and remove your worktree.
- Your merge broke the base branch: revert it or fix it forward yourself, the same day.
