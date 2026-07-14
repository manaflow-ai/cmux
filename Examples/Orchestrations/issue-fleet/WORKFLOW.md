# issue-fleet workflow

One task, one git worktree, one agent. Tasks come from the command line
(`--task` / `--tasks-file`); a future fleet engine can feed the same
template from GitHub issues.

- **Work source:** explicit task list per run.
- **Caps:** `concurrency` parameter bounds simultaneous task workspaces.
- **Agent:** `claude` by default; pass `--agent codex` to switch.
- **Steps:** `implement` (agent works until its Stop hook fires) then
  `review` (parks for input if no PR exists). cmux v1 runs the first step;
  the step chain documents intent for the fleet engine.
- **Cleanup:** remove worktrees with `git worktree prune` after branches
  merge; workspaces close like any other cmux workspace.
