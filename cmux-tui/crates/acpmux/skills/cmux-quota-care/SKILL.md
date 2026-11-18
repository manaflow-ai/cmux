---
name: cmux-quota-care
description: "Spend less of the person's GitHub API quota, disk and CPU: wait for CI with one bounded `acpmux ci wait` instead of a sleep loop or `--watch`, back off on rate limits, clean up worktrees and build output when work is done. Use before waiting on CI, a pull request or a workflow run, before any loop that reads GitHub, after a pull request merges or closes, and when the disk is filling up."
---

# Quota care

Every agent on this machine shares one GitHub API quota (5,000 REST calls an hour for a
signed-in person), one disk and one CPU. A loop that runs `gh pr checks` every ten seconds
spends the hour's quota for every other agent and for the person, and a dozen finished
worktrees with their build output fill a laptop's disk. These rules keep each agent's cost
small and bounded. `"$ACPMUX_BIN"` runs the acpmux CLI (see the `acpmux` skill); `acpmux`
below means it.

## Waiting for CI: one bounded wait, never a loop

- Wait with one command that ends by itself:

  ```bash
  acpmux ci wait pr 812 --timeout 2400          # a pull request's checks
  acpmux ci wait run 123456789 --timeout 1800   # one workflow run
  ```

  It exits 0 green, 1 red (naming the failing checks), 3 at the timeout. `--repo OWNER/REPO`
  when `origin` is not the repository; `--json` for a script.
- Run it in the background (your harness's background command), so the person can talk to
  you while it waits; you are woken when it exits. Do not check on it in between.
- Its reads are conditional: a read where nothing changed is a `304 Not Modified`, which
  GitHub does not count against the quota, and the cache is shared, so two agents waiting on
  one pull request cost what one does. It slows down on its own while nothing changes and
  when the quota runs low, and waits out GitHub's `Retry-After`.
- Size `--timeout` to the job (a few minutes for a lint, about an hour for a full build).
  Past it, act: read the failing run's log, rerun a flaky job once, or report that it is
  stuck. Never start the same wait again unchanged.
- Never: `sleep N` loops around `gh`, `gh run watch`, `gh pr checks --watch`,
  `watch gh ...`, `until ...; do sleep; done`, or a foreground `sleep` of a minute or more.
  Each of these reads the full answer every few seconds and pays for every read.
- Without acpmux (another machine, a plain shell), do the same by hand: one read, then
  `gh run watch RUN --interval 60` at most once, in the background, under `timeout`.

## Reading GitHub without wasting quota

- Read once and keep the answer: don't re-read a pull request, run or file you already
  have in this turn. Read a file from your checkout (`git show origin/BRANCH:PATH`) instead of
  the API.
- Batch: `gh pr list --json number,headRefOid,statusCheckRollup` reads many pull requests
  in one call; one GraphQL query beats one REST call per item. Never sweep every job of
  every run.
- Ask for only what you need: `--json` with the fields you read, `--limit`, `per_page`.
- `gh api rate_limit` costs nothing: check it before a large read, and stop when
  `remaining` is low. On a `403` or `429`, wait out `Retry-After` (or until
  `x-ratelimit-reset`), then retry once; a secondary rate limit wants at least a minute.
  Never retry in a tight loop.
- Writes (comments, labels, pushes) count more against the secondary limits: one comment
  with everything, not one per finding.

## Disk: clean up after yourself

- When your pull request merges or closes, remove what you made for it: your worktree
  (`git worktree remove PATH`, only one you created and that is clean and pushed), your
  build output (`target/`, `node_modules/`, `.build/`, DerivedData of your tag), and your
  background processes (by the PID you started, never by name).
- Let acpmux judge the rest. It keeps any worktree a session or a process still uses,
  archives work that lives only in a worktree into git before removing it, and can put any
  of them back:

  ```bash
  acpmux worktree clean --dry-run    # what a cleanup would do, and why
  acpmux worktree clean              # archive and remove idle worktrees, trim build output
  acpmux worktree restore BRANCH     # put one back
  ```

- Reuse instead of copying: one build-output folder per repository (Cargo's
  `CARGO_TARGET_DIR`, a shared package cache), a sparse or shallow checkout when you need a
  few folders, `git worktree add` instead of a fresh clone.
- Never delete what you did not create, and never by glob or name across folders you did
  not make.

## CPU and long commands

- Every command you start has an end: a `timeout`, a `--timeout`, a count (`-n 1`) or a
  deadline. A watcher, dev server or poller you start in the background gets a stop
  condition and is stopped when you are done.
- Build and test only what changed (`cargo test -p CRATE NAME`, one test file), not the
  whole workspace, and not twice for the same tree.
- Scope searches to your checkout or one folder: never `find ~` or `rg /`.
