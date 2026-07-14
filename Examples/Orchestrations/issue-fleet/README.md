# issue-fleet

The first-party example cmux orchestration template: dispatch a list of
tasks across a fleet of coding agents, one git worktree and one cmux
workspace per task, grouped in the sidebar.

```bash
cmux orchestration install Examples/Orchestrations/issue-fleet
cmux orchestration run issue-fleet \
  --task "Fix the flaky scroll test" \
  --task "Add --json to cmux top"
```

The install interview asks for the target repository (`repo_root`) and a
concurrency cap. The first run shows the template's agent commands and
substrate and asks for confirmation.

This template is also the format's living test fixture: the
`CmuxOrchestration` package tests validate it on every CI run. See
`docs/orchestrations.md` for the full format.
