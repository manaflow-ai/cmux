# cmux agent notes

Keep repo-wide decisions here; procedures belong in [CONTRIBUTING.md](CONTRIBUTING.md),
[area instructions](#area-instructions) and [task skills](skills/README.md).
Read the matching skill before changing an area, then only the references needed.

**Manaflow AI team members and their agents:** read the private [cmuxterm-hq CLAUDE.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/CLAUDE.md) and [AGENTS.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/AGENTS.md) before fleet or CI work. They are the entry point for fleet builds, CI routing, agent coordination, and landing rules. Start fleet work at [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md). External contributors can ignore this block; those links return 404 for them.

## Verification and isolation

- Before committing, setup or a native build, [choose scoped verification](skills/cmux-testing/references/local-vs-ci-validation.md).
  Start with `python3 scripts/verify-local.py`; docs and portable tooling need no app build.
  Run repository commands only in a [trusted checkout](docs/contributor-verification.md#trust-boundary),
  including `verify-local.py --help`, `--list` and `--repo`. Push does not run checks for you.
- **Web lints before every commit and push.** If the change touches `webviews/` or `web/`, run
  that area's lints from its folder first (`bun install --frozen-lockfile` once per checkout) and
  fix every error.
  Never push with a lint failure; a base lint red skips the CI tests after it. These are the
  checks CI runs on every `feat-cmux-next` push:
  - `webviews/`: `bun run check` (Oxlint, Oxfmt, type check, layer and protocol checks).
    `bun run check:fix` repairs formatting.
  - `web/`: `bun run typecheck`, `bun run lint:complexity` and
    `bun tools/generate-managed-iroh-relay-catalog.ts --check`. Also run
    `bunx eslint <changed files>` and add no new ESLint errors (the full `bun run lint` has old errors).
- Use [CONTRIBUTING.md](CONTRIBUTING.md#getting-started) for setup. Tagged reloads default to
  `CMUX_DEV_BACKEND_MODE=local`; cmux-next needs no shared backend. Follow [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md)
  for commands and cache reuse; team fleet tasks start at
  [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md).
  Never use bare `xcodebuild` or an untagged `cmux DEV.app`. Clean up only your own tags.
- A same-repo app PR gets a fleet dogfood build and link comment only while it has the
  `dev-build` label. Add it when someone will dogfood the PR, not by default; under load
  the fleet builds the newest push, and the comment says how to build a skipped commit.
- Never quit, kill, relaunch, replace or launch-profile the user's running cmux
  (`/Applications/cmux.app`, `com.cmuxterm.app`), including through a Release build or
  another bundle with that ID. Never set `CMUX_ALLOW_REPLACING_RUNNING_CMUX`; only the
  user may. Reproduce in a tagged build and attach profiling to its PID.
- Dogfood through `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh`, never `/tmp/cmux-cli`.
  Never report raw `.app` paths or `file://` URLs.
- The app package needs Swift tools 6.2 and deploys to macOS 14; the classic Swift 6.0 rule
  does not apply here. Check Release compiles and macOS 14 limits with
  [toolchain compatibility](skills/cmux-architecture/references/swift-6-0-compatibility.md).

## Web lint before push

Run `scripts/web-lint.sh` before you push web or webviews changes; the pre-push
hook enforces it. It runs, on what you changed against `origin/feat-cmux-next`,
the `bun run check` that CI runs for `webviews/` and `cmux-tui/frontends/web/`
(Oxfmt, Oxlint with the type check, browser-lane and style checks) and ESLint on
changed `web/` files. `scripts/web-lint.sh --fix` autofixes what the tools can;
commit the result. The hook comes with `scripts/install-git-hooks.sh` (run by
`scripts/setup.sh`; one run covers every worktree of the clone). Skip it only with
`CMUX_WEB_LINT_SKIP_REASON="<failing check> is red on base <sha>"`; the
`web lint (fast)` job of cmux-next-web.yml still checks every feat-cmux-next push.

## Swift namespace convention

Public and package types in package source must expose an instance surface or
be scoped onto the owning type; caseless namespace enums and all-static public
or package types are lint violations. Run
`./scripts/lint-ios-package-conventions.sh --namespace-fix` before committing.
When installed with `scripts/install-git-hooks.sh --namespace-fix`, the
pre-push hook runs the fixer and stops so changed files can be reviewed,
staged, and committed. CI keeps the non-mutating lint as the backstop.

Claude Code and Codex post-edit hooks (`.claude/settings.json`, `.codex/hooks.json`)
run the same fixer on edited `Packages/**/*.swift` files; they print repairs and never fail an edit.

## Area instructions

Read these before working in their scope; nested files may not load automatically:

- `ios/` or `Packages/iOS/`: [ios/AGENTS.md](ios/AGENTS.md).
- `web/` or any cmux Cloud database work: [web/AGENTS.md](web/AGENTS.md).
- `cmux-tui/`: [cmux-tui/AGENTS.md](cmux-tui/AGENTS.md).

## Contributions and publication

Before fixing a bug or adding a feature, search open upstream PRs by symptom or
issue number. Prefer landing an outside contributor's existing PR; push fixups
only when maintainer edits are allowed, and explain the changes. If using their
approach in your own PR, credit them in every such commit with `Co-authored-by`
using their commit email, link your PR from theirs and thank them. Let a human
close it; never close an outside PR without a human-written explanation.

The server directories listed in [LICENSE](LICENSE) (`web/`, `workers/ci-artifacts/`,
`workers/iroh-v2/`, `workers/presence/`, `services/iroh-relay-minter/`,
`cmux-tui/relays/cloudflare-do/`, `backend/`) use the Business Source License, which needs
every outside author's CLA grant. Do not merge a PR that changes those
directories while CLA Assistant is red, and do not copy an outside
contributor's work there under a `Co-authored-by` trailer unless that person
has signed the CLA. Keep code that ships in the macOS or iOS app out of those
directories.

Read [STYLE.md](STYLE.md) before drafting or revising issues, PR descriptions,
RFCs or progress updates. Fill the PR's `## Changelog` section with one
`Added`/`Changed`/`Fixed`/`Removed` line for user-visible changes, otherwise `none`.
Do not edit `CHANGELOG.md` in feature PRs; release tooling owns it.

## CI, review and merge

- Commit the failing behavioral regression before its fix; record the same
  focused command's red and green results ([testing policy](skills/cmux-testing/SKILL.md#reproduce-and-repair)).
  A bug-fix PR body names that command, its failure on the base and its pass on the head,
  then an `### Observed / Not run` section: what you ran and saw, then what you only read
  or didn't run.
- Check executed tests on the current SHA; green skipped jobs do not establish coverage.
  Add `full-ci` only for an agreed broad validation plan, naming the extra lanes and why
  ([CI coverage](skills/cmux-testing/references/pr-ci-coverage.md)); never for a rerun or extra confidence.
- Keep branches current locally with `scripts/merge-main.sh`; follow
  [the merge-main guide](docs/ci/merge-main.md) and never force-push over its merge.
- `gh pr merge` saying "base branch policy prohibits the merge" means the token lacks the `workflow`
  scope or GitHub timed out, not a rule: run `gh auth refresh -h github.com -s workflow`, or merge with
  `gh api -X PUT repos/OWNER/REPO/pulls/N/merge -f merge_method=squash -f sha=SHA`, which names the cause. Never `--admin`.
- A first implementation pass ends with passed scoped verification and an open PR;
  do not watch CI or run speculative reviews by default.
- Never hand-edit or hand-merge generated files (`settings-schema.json`, `settings-schema.sources.sha256`,
  `docs/mdm/*`). On a conflict take either side; the PR or base autofix regenerates them (#21946, #21985).
- Webview UI screenshots come from the gallery advisory run: add a gallery entry with fixture states.
  Mac captures (the `cmux-next media` tours) are only for native/AppKit UI or real end-to-end flows.
- Every `feat-cmux-next` PR gets a `risk:low|medium|high` label from its paths, and the
  `risk evidence` check stays red until the description has that tier's evidence
  ([risk tiers](docs/ci/risk-tiers.md)). Low: no red of its own (green CI into main). Medium (UI): a screenshot under
  `## Proof`, next to its cmux-design-references match. High (release, migrations, defaults,
  protocol spec, pins and merge gates at any size; daemon and runtime changes over 40 lines;
  taking back a change merged in the last week): also `Review:` with the reviewed SHA and
  `Runtime test:` with the run that executed it; PRs here skip Swift tests, so dispatch `cmux-next.yml`.
  Ship user-visible high-tier behavior behind a default-off setting. After merging high tier,
  check the first nightly-next that has it; revert with `gh-merge-green --revert` if it broke
  and the fix misses the next cut. Never add `risk:waived`; only a maintainer does.
- Before opening a PR and before merging, check it against [REVIEW.md](REVIEW.md) (draft),
  the mistakes our review history keeps catching.
- Before merging, use a [review subagent](skills/cmux-review/SKILL.md), correctness
  first; a second model is not a review gate. Into `main`, wait for checks relevant to the
  change; into `feat-cmux-next`, pending checks don't hold it (below). Disclose skipped verification on the PR. `main` is nightly: fix forward,
  do not revert.
- Into `main`, app/runtime/UI merges require the user’s explicit approval after dogfood **or a direct merge directive**
  (`merge`, `merge it`, `auto-merge`; not `finish`, `lgtm` or `ship it`). Into `feat-cmux-next`, the
  `ready-to-land` label after your review is the hand-off (below). Follow
  [dogfood, re-dogfood and merge receipts](skills/cmux-review/SKILL.md#dogfood-and-merge).
  Notify with `cmux notify` when a socket is available.
- A red on every PR is a base red: fix it first in its own PR, which lands at once. Two fixes that
  are each red on the other's red get combined into one PR. A base lint red also skips the tests
  after it in the same job (#22197), which is why it goes first.
- Classify each non-green check on the current head before changing source: a changed-file
  defect (fix it), a base finding (the same check red at the base tip or on several unrelated PRs
  at once: link it in a PR comment; it does not block), a wrapper such as `Web status` (follow its root check), or a
  cancelled or infrastructure run (rerun the same SHA). A push supersedes earlier CI and review
  results. Gallery captures and full webview sweeps are advisory
  ([check progression](docs/contributor-verification.md#pr-check-progression)).
- **Into `feat-cmux-next`, a PR lands when it is reviewed and causes no red of its own.** Base
  findings (above), flakes and pending checks never hold it; fixes found later go in follow-ups.
  When your review subagent passes (and the risk tier's evidence is in the description), add the
  `ready-to-land` label. A label older than the head's last push doesn't count: after any later
  push, remove and add it again. `next-autoland` on Huge Blue then merges that exact head
  (leo-workspace `tools/next_autoland.py`). It also requires `ci-status` to have run, a red
  `risk evidence` or `merge freeze` keeps the PR out, and it reads the merge freezes again right
  before merging. Don't wait for, rerun or fix base reds in your PR; a red it causes keeps it out
  until you fix it. Don't merge with `gh-merge-green` here (`--revert` still works).
- **Into `main`, the normal merge path is `gh-merge-green`** and main's rulesets. It refuses a PR
  that touches a path an open `merge-freeze` issue freezes, or when the freeze state can't be read;
  only the freeze owner's `freeze-ok` label lets that PR through ([merge freezes](docs/ci/merge-freeze.md)).

## Implementation rules by task

Use these existing owners instead of duplicating their checklists here:

| Touching | Read before editing |
| --- | --- |
| Typing paths, SwiftUI list/store boundaries, rendering, find layering, UTTypes or OS-specific bugs | [cmux-debugging](skills/cmux-debugging/SKILL.md) |
| Packages, workspace groups, lockfiles or feature flags | [cmux-architecture](skills/cmux-architecture/SKILL.md) |
| Submodules or GhosttyKit | [cmux-ghostty](skills/cmux-ghostty/SKILL.md) |
| User-facing strings, docs or help | [cmux-localization](skills/cmux-localization/SKILL.md); report the localization audit |
| New cmux shortcuts | [cmux-keyboard-shortcuts](skills/cmux-keyboard-shortcuts/SKILL.md) |
| Tests or target wiring | [cmux-testing](skills/cmux-testing/SKILL.md); CmuxNext tests need no wiring; the `cmux` CLI is cmux-tui Rust (tests run with cargo on a Testbox or CI) |
| Multiple entrypoints or a bug that tests previously missed | [cmux-shared-behavior](skills/cmux-shared-behavior/SKILL.md); share action/mutation paths, verify every entrypoint, and cover the missed repro |

## Remote CLI relay

For v2 socket methods and remote CLI changes, read [relay authorization](skills/cmux-socket-policy/references/remote-relay-authorization.md).
The legacy `RemoteRelayCommandPolicy` was deleted with `CmuxRemoteWorkspace`; any
remote relay cmux-next adds must default to deny the same way. Allowlist only for a needed remote
flow, scoped to the session's objects; command-bearing params stay denied on
every method, with no exceptions. The PR must analyze local command/content
execution, access to unowned objects and local-state exposure, and include the
required policy tests and ID scoping. Unsafe local effects must be redesigned.
Never allowlist terminal spawn/respawn without live verification that it executes
on the remote host. An allowlist addition without this analysis blocks review.
