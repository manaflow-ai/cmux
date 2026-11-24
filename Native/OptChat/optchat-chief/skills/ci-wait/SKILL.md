---
name: ci-wait
description: Wait for CI, an Actions run or a pull request's checks without polling, and decide what a red means. Use whenever you would wait for CI, watch a run, or answer "is it green".
cmux-managed: true
---

# Waiting for CI

A wait costs nothing when one waiter does it and wakes you once. A loop that
re-reads GitHub on a timer spends the person's API quota, and it leaves you
looking busy while nothing moves.

## 1. Read once

- A pull request: the `pr_state` tool (one line: open or merged, failing checks
  by name, pending count), or `gh pr view N --json statusCheckRollup,mergeable,headRefOid`.
- A run: `gh run view RUN_ID --json status,conclusion,jobs`.

Green or red: you are done waiting, go to section 3.

## 2. Wait once, with a deadline

Pick the first that exists:

| Waiting for | Use |
| --- | --- |
| A run or a PR's checks, then a message when done | the `run_wait` tool (it uses glaeda-gh when installed, else one shared `gh` watch) |
| A PR to settle or merge, now in this call | the `pr_wait` tool (repeat it for longer; it costs no GitHub calls) |
| No acpmux tools | `timeout 1800 gh run watch RUN_ID --repo OWNER/REPO --exit-status`, or `timeout 1800 gh pr checks N --watch --interval 30` |

- One waiter per run or PR. Never start a second one for the same thing.
- Size the deadline to the job (a lint: minutes; a full build: up to an hour).
- A subagent whose last step is this wait runs it in the foreground and ends
  once with the result. A background wait that ends after you stop wakes you,
  then Chief, a second time.
- A Chief uses its `watch` tool with the same command, tells the person what
  it waits for, and ends the turn.

## 3. What the result means

- **Green:** say so with the run or PR link; land if the task says to (skill `landing`).
- **Red:** read the failing job's log once: `gh run view RUN_ID --log-failed | tail -80`.
  - It fails the same way on the base branch (look at the base's latest run of
    that workflow): it is not yours. Say so in one line and go on.
  - Infrastructure (runner lost, cancelled, network, rate limit): rerun the failed
    jobs once, `gh run rerun RUN_ID --failed`, and wait once more. A second
    infrastructure red is reported, not rerun.
  - Your change broke it: fix it, push, and wait again from section 1.
- **Past the deadline:** read the state once, report what is pending and since
  when, and what you will do (rerun, report, or a follow-up). Never "still waiting".

## Never

- No `sleep` loop around `gh`, no `gh api` or `gh run view` re-read on a timer.
- No rerun of a check that fails the same way on the base branch.
- No "it is probably fine": a check you did not read is unknown, say so.
