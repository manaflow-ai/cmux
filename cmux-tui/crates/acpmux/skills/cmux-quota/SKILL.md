---
name: cmux-quota
description: "Wait without wasting quota or the machine: wait for CI or a pull request with one shared waiter instead of a polling loop, handle a GitHub rate limit by its reset, give every wait a deadline, and clean up only what you made (your own processes, regenerable caches, your own worktrees). Use when you would wait for CI or checks, poll GitHub, retry after a rate limit, run a long wait, free disk space, or stop processes."
---

# Waiting and cleaning up without waste

The person's GitHub quota, CPU and disk are shared by every agent on the machine. One
agent polling CI every 10 seconds can spend the hour's GitHub budget for all of them, and
a stray process or a wrong delete costs the person real work. These rules keep that from
happening.

## Wait for CI with one waiter, never a loop

To wait for a pull request's checks, start this once, in the background (your harness's
background shell), and go on with other work:

```bash
acpmux pr-wait 1234 --repo OWNER/REPO --sha "$(git rev-parse HEAD)" --timeout 3600
```

- Every agent on this machine waiting on the same pull request shares one poller: one of
  them asks GitHub, the rest read its answer. Ten waiters cost one call per interval.
- It polls more slowly as the wait gets longer (15 s at first, at most every 90 s), and on a
  rate limit it sleeps until GitHub's reset instead of asking again.
- Exit 0 green (or merged), 1 a failing check (or closed), 3 timed out, 4 the head moved
  off `--sha` (someone pushed: wait on the new head). `--until merged` waits for a merge.
- `--sha` is the commit you pushed, so an old head's green never counts as yours.
- Waiting on another agent's turn: `acpmux wait SESSION --timeout N`.

Never write these; each spends a call every few seconds for as long as it runs:

- `while`/`until` loops around `gh pr checks`, `gh run view`, `gh api` or `curl`.
- `gh run watch`, `gh pr checks --watch`, `watch gh ...`.
- `sleep N` then a status read, repeated by hand across turns.
- A loop that waits for a file to appear with nothing that ends it.

## One question, one call

- One pull request's whole state: the `pr_state` tool (in the acpmux tools), or one
  `gh pr view N --json state,headRefOid,statusCheckRollup` with only the fields you need.
- Many pull requests or issues: one `gh pr list --json ...` or one GraphQL query, not one
  call per item.
- Don't re-read what you just read: keep the answer and reuse it in the same turn.
- `gh api rate_limit` costs nothing: read it before a large batch.
- A conditional REST read (`-H 'If-None-Match: "ETAG"'`) answered `304 Not Modified` costs
  no quota.

## When GitHub says rate limit

- Primary limit (`API rate limit exceeded`): read when it resets with
  `gh api rate_limit --jq .resources.graphql.reset` (or `.core.reset` for REST), then wait
  until that time. Retrying sooner is refused and still counts.
- Secondary limit (`secondary rate limit`, `abuse detection`): stop for at least a minute,
  then go on more slowly, one call at a time.
- Any other failure (5xx, timeout): retry a few times with a growing pause (30 s, 60 s,
  2 min), then report it. Never retry in a tight loop.
- A rate limit is not a reason to switch tokens, accounts or machines.

## Every wait has a deadline

- Give every wait a bound: `--timeout`, `timeout 600 cmd`, a harness timeout. A wait with
  no end keeps the session alive for nothing.
- Pick the bound from what you wait for (a test suite: its usual time plus half), not the
  largest number allowed.
- Past the deadline, act: read why it is slow, report it, or try another way. Don't start
  the same wait again unchanged.
- A foreground `sleep` of a minute or more parks your session; use a background wait that
  tells you when it ends.
- A helper or subagent you start gets a stop condition and a deadline in its brief. If one
  goes quiet past its deadline, check on it or replace it.

## Stop only your own processes

- Keep the PID (or process group) of what you start in the background, and stop that one
  when you are done with it: `kill PID`, or `kill -- -PGID` for its group.
- Never `pkill`, `killall` or `kill $(pgrep NAME)`: a name matches the person's own
  programs and other agents' work.
- Never stop the person's apps, editors, terminals, servers you did not start, or another
  agent's processes, even when they look stuck. Say what you saw instead.

## Free disk only from what can be made again

Before deleting anything, look at it: what it is, how big, and who made it.

Safe to delete, because a build or tool makes it again:

- Build output: `cargo clean` (or the stale profile folder under `target/`), `.next/`,
  `dist/` and `build/` of a project you built, `__pycache__/`, `.pytest_cache/`.
- Package caches through their own command: `npm cache clean --force`, `pnpm store prune`,
  `bun pm cache rm`, `pip cache purge`, `go clean -cache`, `docker builder prune`.
- Your own scratch files in a temporary folder.

Never delete:

- Source, a worktree or clone with uncommitted or unpushed work, or a branch nobody merged.
- Anything you did not create, the person's files, other agents' folders, chat transcripts,
  credentials or settings.
- With a glob or a name pattern across folders you have not listed first.

A worktree you made goes when its work is merged or pushed and nothing runs in it:
`git worktree remove PATH` (never `--force` over changes you have not looked at).
