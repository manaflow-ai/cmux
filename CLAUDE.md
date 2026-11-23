# cmux agent notes

The rules every agent needs in every session here. Everything else lives on the page that owns it (the
[table below](#where-the-rest-lives)); read the matching skill or page before changing an area.

**Manaflow AI team members and their agents:** read the private [cmuxterm-hq CLAUDE.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/CLAUDE.md) and [AGENTS.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/AGENTS.md) before fleet or CI work. They are the entry point for fleet builds, CI routing, agent coordination, and landing rules. Start fleet work at [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md). Before building a tool or calling yourself blocked, find the team's existing one in the [team-tools catalog](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/skills/agents/team-tools/SKILL.md) (exact commands, proven runs); with an hq checkout beside this one it is `../cmuxterm-hq/skills/agents/team-tools/SKILL.md`, and `scripts/install-team-tools.sh` there puts it in every session. External contributors can ignore this block; those links return 404 for them.

## The loop: use it first, then test

Write the code, put it into your running cmux, use it (screenshot, video, click through it), and only then run
the slow checks: compile, CI, gallery, suites. Before asking for a dev build, run `cmux app try .` on a Mac in
your checkout: it clones your nightly beside the person's cmux and swaps your web UI and daemon Rust in (`--stop`
deletes the clone; off a Mac it prints the fleet route, `cmux-ci hot-verify N --look`).

| Layer | Into the running app |
|---|---|
| Web (`webviews/`) | `cmux customize use pr:N`, `branch:NAME`, `sha:SHA` or `dir:PATH [--watch]`; back with `cmux customize library off NAME` |
| Terminal daemon, acpmux Rust (`cmux-tui/`) | `scripts/cmux-next/hot-apply.py plan SHA`, `apply SHA`, `rollback` |
| A whole PR, branch or commit | `cmux app try <PR\|branch\|sha>`, back with `cmux app try undo` |
| Web from your checkout, hot reload on save | `cmux live start --worktree <checkout>` |
| Daemon Rust from your checkout | `cmux live start --rust` |
| Swift inside function bodies | live code on a Debug base: `cmux live start --swift` ([live code](docs/cmux-next/live-code.md)) |
| String catalogs (`.xcstrings`), Cloud wire types (`clients/ts`) | `cmux app try`: no build (Swift's translations wait for one) |
| Backend, images, workers, CI | no app change: `cmux-ci test -- CMD` on Linux; a copy of the NIGHTLY signs in to Cloud (`cmux app try .`) |
| Swift signatures, stored properties, Rust the app links, resources | a build; `hot-apply.py plan` says which and why |

Full loop: the [cmux-hot-loop skill](skills/cmux-hot-loop/SKILL.md) and
[docs/cmux-next/hot-reload.md](docs/cmux-next/hot-reload.md#the-loop).

A signed-in build to drive is a copy of a signed-in app, not an "authenticated dev build": `cmux app try <PR|sha>`
in your NIGHTLY (production account), `cmux-ci run ... --sign-in agent` for an agent step, `--for-person` on a
Swift build handed to a person. Table: [cmux-hot-loop, Signed in](skills/cmux-hot-loop/SKILL.md#signed-in-without-an-authenticated-dev-build).

## Every session

- **Agents never compile or test on the person's Mac.** No local `swift build`/`swift test`, `xcodebuild`,
  `cargo build|test|clippy` or `scripts/reload.sh`: run them on the fleet (`cmux-ci run --class CLASS --script
  ... --ref SHA`, `cmux-ci build cmux --ref SHA`). Never bypass the PATH guards. Details:
  [verification rules](skills/cmux-dev-workflow/references/verification-rules.md).
- **Never quit, kill, relaunch or replace the user's running cmux** (`/Applications/cmux.app`,
  `com.cmuxterm.app`), and never set `CMUX_ALLOW_REPLACING_RUNNING_CMUX`. Reproduce in a tagged build.
- **Wait on GitHub with one shared waiter, never a poll**: one background `glaeda-gh wait pr OWNER/REPO#N --sha
  FULL_SHA` per PR, or the acpmux `run_wait` tool; never `gh pr checks --watch`, `gh run watch` or a sleep loop
  ([verification rules](skills/cmux-dev-workflow/references/verification-rules.md)).
- **Make worktrees with `python3 scripts/cmux_worktree.py add -b BRANCH PATH origin/feat-cmux-next`** (APFS clones
  of a seed: about 4 s, almost no disk); never symlink node_modules or share one Cargo target dir
  ([worktrees](skills/cmux-dev-workflow/SKILL.md#worktrees)).
- **Scope every search** to your worktree or a named subfolder, never `..`, `~`, `/` or `$TMPDIR`.
- **Before every push**, `python3 scripts/cmux-next/prepush-gate.py` (the pre-push hook runs it) and, for
  `webviews/` or `web/`, `scripts/web-lint.sh`. Never `--no-verify` or `CMUX_NEXT_CHECKS_SKIP_REASON` unless the
  failure is in files you did not touch, and then say so. Gate rules: [code rules](docs/cmux-next/code-rules.md);
  failed pushes: [pushing](skills/cmux-dev-workflow/references/pushing.md).
- **Classic is frozen.** Work only on cmux-next paths; never change the files in
  [`.github/classic-frozen.txt`](.github/classic-frozen.txt) (Leo, 2026-11-04). The `ios/` classic iPhone app is
  retired; cmux-next's is `cmux-next-ios/`.
- **Each area stays in its language** ([`.github/language-boundaries.toml`](.github/language-boundaries.toml),
  Lawrence's rule relayed by Leo, 2026-11-10): new logic is Rust; Swift and React only where that file says.
  The `language-boundaries` check enforces it.
- **macOS and iOS parity.** Every new cmux-next macOS feature also works in the iPhone app (`cmux-next-ios/`),
  with a row in [cmux-next-ios/verify/parity-mac.md](cmux-next-ios/verify/parity-mac.md); the exceptions
  (Mac-only chrome, what [cmux-next-ios/SECURITY.md](cmux-next-ios/SECURITY.md) forbids a phone) are recorded
  there. A phone path that needs new trust policy goes to Leo as one decision first (`tbd-leo add`, with a recommendation).
- **Dev builds are separate.** A tagged dev build (Mac and iPhone) never sees or changes another build's
  backend data or local state, nor nightly's or stable's, and never reuses NIGHTLY's sign-in. The pre-push
  gate's "Build spaces" and "Dev build state is its own" checks enforce it:
  [dev build spaces](skills/cmux-dev-workflow/references/dev-build-spaces.md).
- **Agents may add CI gates, perf-gate rows, CI jobs and CI tests** (Aziz 2026-11-18 lifted the "no new CI" rule;
  perf runs still never block a push, merge or nightly). Each fix still gets a regression test you run on the fleet.
- **Nightlies never use Blacksmith, run on one signing Mac, and nobody cancels them** (Lawrence, 2026-10-30
  and 2026-11-04): [landing](docs/ci/landing.md#ci-runners-and-nightlies).
- **A change to the Mac or iOS app is done when the person can open it**: the report ends with the dev build
  link, the fleet simulator evidence and the iPhone install result
  ([finishing a task](skills/cmux-dev-workflow/references/finishing-a-task.md)). A docs-only change gives the
  file path instead.

## CI, review and merge

Into `feat-cmux-next` you merge your own PR, pinned (`gh pr merge N --squash --match-head-commit <sha>`), once it
causes no red of its own; review runs beside it. Into `main` it needs a review SHIP at the head. Never `--admin`.
Adding a test or a CI job needs no CI thought: put the test where the code's tests already live, and the routers run only what a diff can affect from each job's declared inputs. A new PR job gets an entry in its router's map; one you forget is recorded as runs-always by `scripts/ci/job_inputs.py fix` (the PR autofix), never refused. Team members: [the CI protocol](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/ci/protocol.md).
Which CI a PR runs: [CI coverage](skills/cmux-testing/references/pr-ci-coverage.md). Full rules:
[landing](docs/ci/landing.md).

## Settings on every surface

A new or changed cmux-next setting also works from the command palette, the `cmux` CLI and the MCP tools:
declare it once as a `SettingDescriptor` in `SettingsSchema`
([agent checklist](plans/cmux-next/settings-surfaces.md#agent-checklist)).

## Area instructions

Read these before working in their scope; nested files may not load automatically:

- `Packages/iOS/`: [Packages/iOS/AGENTS.md](Packages/iOS/AGENTS.md) (the Apple HIG rule for iPhone UI).
- Cloud backend code (control plane, VM API routes, provider drivers, billing, entitlements, the NEXT Worker):
  new code goes to the private manaflow-ai/cmux-platform repository, not here. Read
  [skills/cmux-backend/SKILL.md](skills/cmux-backend/SKILL.md) first.
- `web/` or any cmux Cloud database work: [web/AGENTS.md](web/AGENTS.md).
- `cmux-tui/`: [cmux-tui/AGENTS.md](cmux-tui/AGENTS.md).
- `Packages/macOS/`, `App/`, `Native/` (the Mac app's Swift): [Packages/macOS/AGENTS.md](Packages/macOS/AGENTS.md)
  (where a change goes, what a lane VM can check, the common reds).
- `backend/`, `workers/`, `services/`: [backend/AGENTS.md](backend/AGENTS.md) (test one file, the migration and
  catalog reds).
- `scripts/`, `tests/`, `ci/`: [scripts/AGENTS.md](scripts/AGENTS.md); `.github/workflows/`:
  [.github/AGENTS.md](.github/AGENTS.md) (find and run one script's tests, add a workflow).
- `webviews/`: [webviews/README.md](webviews/README.md).
- `cmux-next-ios/`: [cmux-next-ios/CLAUDE.md](cmux-next-ios/CLAUDE.md) and
  [cmux-next-ios/SECURITY.md](cmux-next-ios/SECURITY.md).

## Where the rest lives

| Touching | Read before editing |
| --- | --- |
| Setup, tagged builds, scoped verification | [CONTRIBUTING.md](CONTRIBUTING.md#getting-started), [verification rules](skills/cmux-dev-workflow/references/verification-rules.md), [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md) |
| Hooks, lints, pushing | [hooks and lints](skills/cmux-dev-workflow/references/hooks-and-lints.md), [pushing](skills/cmux-dev-workflow/references/pushing.md) |
| Code rules, hot paths, crash classes, Swift namespaces | [code rules](docs/cmux-next/code-rules.md), [PATTERNS.md](plans/cmux-next/PATTERNS.md), [design-lessons.md](docs/cmux-next/design-lessons.md) |
| Dev build backend data, local state and sign-in | [dev build spaces](skills/cmux-dev-workflow/references/dev-build-spaces.md) |
| Finishing a task: dev build, simulator, iPhone hand-off | [finishing a task](skills/cmux-dev-workflow/references/finishing-a-task.md) |
| Outside PRs, licenses, PR text, CI, review and merge | [landing](docs/ci/landing.md), [STYLE.md](STYLE.md), [risk tiers](docs/ci/risk-tiers.md) |
| Screenshots and clips for a PR: crop, before/after, trim | [evidence](skills/cmux-review/references/dogfood-and-merge.md) and `scripts/media/media_polish.py --help` |
| Screenshots and clips for a PR: crop, before/after, trim | [evidence](skills/cmux-review/references/dogfood-and-merge.md) and `scripts/media/media_polish.py --help` |
| Typing paths, SwiftUI list/store boundaries, rendering, find layering, UTTypes or OS-specific bugs | [cmux-debugging](skills/cmux-debugging/SKILL.md) |
| Packages, workspace groups, lockfiles or feature flags | [cmux-architecture](skills/cmux-architecture/SKILL.md) |
| Submodules or GhosttyKit | [cmux-ghostty](skills/cmux-ghostty/SKILL.md) |
| The cmux-next iPhone app (`cmux-next-ios/`, `Packages/iOS/`, the mobile Rust crates) | [cmux-ios](skills/cmux-ios/SKILL.md): fleet simulator tests, App Review gate, TestFlight, how iOS PRs merge |
| User-facing strings, docs or help | [cmux-localization](skills/cmux-localization/SKILL.md); report the localization audit |
| A change people will notice (What's New, update card) | [release-notes/next/WRITING.md](release-notes/next/WRITING.md); add one curated highlight file in the same commit, never a commit subject |
| New cmux shortcuts | [cmux-keyboard-shortcuts](skills/cmux-keyboard-shortcuts/SKILL.md) |
| Tests or target wiring | [cmux-testing](skills/cmux-testing/SKILL.md); [adding a test](skills/cmux-testing/references/adding-a-test.md): CI finds it; Python tests take a lane entry; the `cmux` CLI is cmux-tui Rust |
| Multiple entrypoints or a bug that tests previously missed | [cmux-shared-behavior](skills/cmux-shared-behavior/SKILL.md); share action/mutation paths, verify every entrypoint, and cover the missed repro |
| v2 socket methods, remote CLI relay (default deny) | [relay authorization](skills/cmux-socket-policy/references/remote-relay-authorization.md) |
| Every task skill | [skills/README.md](skills/README.md) |
