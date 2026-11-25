# cmux agent notes

Rules for every session; detail is on the linked pages ([map](#where-the-rest-lives)): read one before changing its area. Maintainers' notes: their private docs.

**On your own machine** (any contributor's agent; all rules apply):
- Build a tagged build, never over the installed cmux: `./scripts/setup.sh` once, then `CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag <tag>`. Python in `scripts/`, `tests/` runs directly; `cmux-tui/` takes a focused `cargo test`.
- Before pushing: `python3 scripts/verify-local.py`, plus `scripts/web-lint.sh` for `webviews/`, `web/`.
- PR against `feat-cmux-next`; check CI once with `gh pr checks N`; Testing says what you ran and couldn't.
- Person path (build, test, land, tree map): [docs/start-here.md](docs/start-here.md).

## The loop: use it first, then test

Put it in your running cmux and use it (screenshot, video, click) before compile, CI, suites. Before asking for a dev build: `cmux app try .` (a nightly clone with your web UI and daemon Rust; `--stop` deletes it).
- Web: `cmux customize use pr:N|branch:NAME|sha:SHA|dir:PATH [--watch]`; off: `cmux customize library off NAME`. Hot reload: `cmux live start --worktree <checkout>`.
- Daemon/acpmux Rust (`cmux-tui/`): `scripts/cmux-next/hot-apply.py plan|apply SHA`, `rollback`; from checkout: `cmux live start --rust`.
- Whole PR/branch/sha: `cmux app try <ref>`, `cmux app try undo`. Swift in function bodies: `cmux live start --swift` on a Debug base ([live code](docs/cmux-next/live-code.md)).
- `.xcstrings`, `clients/ts`: `cmux app try`, no build. Backend, images, workers, CI: area tests (`verify-local.py`). Swift signatures, stored properties, linked Rust, resources: a build (`hot-apply.py plan` says why).
- Signed in = a copy of a signed-in app: `cmux app try <PR|sha>` in your NIGHTLY, `--for-person` on a Swift build for a person ([cmux-hot-loop](skills/cmux-hot-loop/SKILL.md#signed-in-without-an-authenticated-dev-build), [hot-reload](docs/cmux-next/hot-reload.md#the-loop)).

## Every session

- Web or daemon change: no build, `cmux app try .`; else a tagged build. Never bypass the PATH guards ([verification rules](skills/cmux-dev-workflow/references/verification-rules.md)).
- Never quit, kill, relaunch or replace the user's cmux (`/Applications/cmux.app`, `com.cmuxterm.app`) or set `CMUX_ALLOW_REPLACING_RUNNING_CMUX`; reproduce in a copy.
- Never poll GitHub: `gh pr checks N` once; no `--watch`, `gh run watch` or sleep loops.
- Worktrees: `python3 scripts/cmux_worktree.py add -b BRANCH PATH origin/feat-cmux-next`; never symlink node_modules or share a Cargo target ([worktrees](skills/cmux-dev-workflow/SKILL.md#worktrees)).
- Scope searches to your worktree or a subfolder, never `..`, `~`, `/`, `$TMPDIR`.
- Before every push: `scripts/cmux-next/prepush-gate.py` (the hook runs it), web: `scripts/web-lint.sh`. `--no-verify`/`CMUX_NEXT_CHECKS_SKIP_REASON` only for failures in files you didn't touch, said so ([code rules](docs/cmux-next/code-rules.md), [pushing](skills/cmux-dev-workflow/references/pushing.md)).
- Classic is frozen: never change [`.github/classic-frozen.txt`](.github/classic-frozen.txt) files (Leo, 2026-11-04); `ios/` is retired, use `cmux-next-ios/`.
- New logic is Rust; Swift/React only where [`.github/language-boundaries.toml`](.github/language-boundaries.toml) says (Lawrence via Leo, 2026-11-10; check `language-boundaries`).
- Mac/iOS parity: each new macOS feature works in `cmux-next-ios/`, one file per row in [parity-mac/](cmux-next-ios/verify/parity-mac/README.md) (old [parity-mac.md](cmux-next-ios/verify/parity-mac.md) frozen); exceptions per [SECURITY.md](cmux-next-ios/SECURITY.md). New phone trust policy: one decision to Leo first, with a recommendation.
- A tagged dev build (Mac, iPhone) never touches another build's backend data or local state, nightly's or stable's, nor reuses NIGHTLY's sign-in (gate checks; [dev build spaces](skills/cmux-dev-workflow/references/dev-build-spaces.md)).
- Agents may add CI gates, perf-gate rows, jobs, tests (Aziz, 2026-11-18); perf never blocks push, merge or nightly. Every fix gets a regression test.
- Nightlies: no Blacksmith, one signing Mac, never cancelled (Lawrence, 2026-10-30, 2026-11-04; [landing](docs/ci/landing.md#ci-runners-and-nightlies)).
- App change done = person can open it: report ends with the dev build link (web/daemon: `cmux app try <PR>`; a build only if `hot-verify.py plan` or the person asks), simulator evidence, iPhone install result; docs-only: the path ([finishing](skills/cmux-dev-workflow/references/finishing-a-task.md); `cmux-next-ios/scripts/review.sh` uses the tag's own backend, `--backend dev` the shared Workers).

## CI, review and merge

Into `feat-cmux-next` merge your own PR pinned (`gh pr merge N --squash --match-head-commit <sha>`) once it adds no red; review runs beside. Into `main`: a review SHIP at the head. Never `--admin`. Tests go beside the code's tests; a new PR job gets a router map entry (`scripts/ci/job_inputs.py fix` marks a missed one runs-always). [CI coverage](skills/cmux-testing/references/pr-ci-coverage.md), [landing](docs/ci/landing.md).

## Settings on every surface

A new or changed setting works from palette, `cmux` CLI and MCP: one `SettingDescriptor` in `SettingsSchema` ([checklist](plans/cmux-next/settings-surfaces.md#agent-checklist)).

## Where the rest lives

Read the area's file first (nested ones may not auto-load): [cmux-tui](cmux-tui/AGENTS.md), [scripts/tests/ci](scripts/AGENTS.md), [workflows](.github/AGENTS.md), [Mac Swift](Packages/macOS/AGENTS.md) (`Packages/macOS/`, `App/`, `Native/`), [iPhone](cmux-next-ios/CLAUDE.md) + [cmux-ios](skills/cmux-ios/SKILL.md). Cloud backend code goes to private manaflow-ai/cmux-platform. PR text: [landing](docs/ci/landing.md), [STYLE.md](STYLE.md). Noticeable change: one highlight file, same commit ([WRITING.md](release-notes/next/WRITING.md)). Every other area and topic: [docs/agent-index.md](docs/agent-index.md).
