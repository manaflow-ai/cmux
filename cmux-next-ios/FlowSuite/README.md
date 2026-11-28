# iOS flow suite

The iOS flows that have broken before, each tied to the tests that prove it and the source paths
that can break it. A gate reads `flows.json` through `select_flows.py` and runs only the flows a pull
request can affect, on the PR merged into today's base.

Sources, with credit: Aziz's iOS testing notes in cmuxterm-hq (the parallel-simulator section of
`skills/ios/ios-dogfood/SKILL.md`, and the iOS checks in `docs/ios/app-store-readiness.md`) moved
here as runnable checks, and the iOS regressions of November 2026 (the table below).
`CHECKLIST.md` holds the steps that still need a person, with the reason for each.

## Run it

```bash
python3 -I cmux-next-ios/FlowSuite/select_flows.py --base origin/feat-cmux-next --head HEAD
python3 -I cmux-next-ios/FlowSuite/select_flows.py --base origin/feat-cmux-next --sim-args --shards 2
python3 -I cmux-next-ios/FlowSuite/test_select_flows.py      # includes --check
```

Each `--sim-args` line is the arguments for one fleet simulator run:

```bash
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --key NAME-SHA \
  --arg test --arg only=A,B --arg ui=C,D --artifact artifacts/ios-sim/evidence.zip
```

`cmux-next-ios/FlowSuite/tagged-sim.sh create TAG` gives a local run its own simulator (Aziz's
rule: one simulator per tag, addressed by UDID, deleted at the end).

## Verify before a PR: `cmux ios verify`

```bash
cmux ios verify                  # the checked-out branch's PR (or: --pr N)
cmux ios verify --plan           # the selection and steps, nothing run
```

`scripts/ci/ios_verify.py` does the following:

1. Merges the moved base into the head and pushes, so a merge combination (rows 4, 5 and 7) breaks here.
2. Selects the flows with `select_flows.py`.
3. Runs the shards in parallel on the warm pool: `CMUX_IOS_VERIFY_WORKERS`, cmux22,cmux23 until cmux25 and
   cmux26 are tagged. Each shard is `test only= ui= video` with a slim simulator, cached DerivedData and the FFI
   cache. A flow marked `"pair_e2e": true` adds `pair-e2e`: a tagged DEBUG Mac pairs, drops and reconnects. The
   flows' `scripts` run too.
4. Diffs the screenshots against the newest passing proof merged into the base.
5. Posts the proof record (`ci/proof-record/`) and reruns the `cmux/ios-fast` gate, which needs a passing record
   at the PR's current head. `vars.CI_IOS_VERIFY_PROOF=0` turns that requirement off.

A flow's macOS `swift` tests are named as delegated to pr pipeline's mac job.

## flows.json

```json
{"version": 1,
 "compile": {"paths": ["cmux-next-ios/**", ...], "swift_roots": [...], "cargo_roots": [...],
             "ignore": ["cmux-next-ios/**/*.md", ...], "scripts": ["cargo check ... -p cmux-mobile-link"]},
 "flows": [{"id": "terminal-first-attach", "title": "...", "source": ["regression:1"],
            "kit": ["CmuxMobileLiveTests/AttachWaitsForTheLinkTests"], "ui": ["TerminalAttachFirstFrameUITests"],
            "swift": [{"package": "Packages/...", "filter": "SuiteName"}], "scripts": ["..."],
            "paths": ["cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/**", ...],
            "smoke": false, "build_for_testing": false}]}
```

- A change is iOS-affecting when a changed file, after `compile.ignore`, matches a compile glob or a
  flow's `paths`. Compile globs are `compile.paths` plus every Swift package and Rust crate the app
  links, followed from `project.yml`, `Package.swift` and `Cargo.toml` path dependencies
  (`--print-compile-paths`), so shared code (Rust core, protocol, tailnet, auth) counts.
- Selected: smoke flows, flows whose `paths` match, and `build_for_testing` flows when compile matched.
  An iOS file that no flow names runs smoke plus the compile check.
- `kit` is `-only-testing` (`TARGET/Suite`) for the kit tests, `ui` is a `CmuxMobileAppUITests`
  class, `swift` is `swift test --package-path P --filter F` on macOS, `scripts` run from the repo root.
- Globs: `**` crosses directories, `*` does not.
- `--check` fails when a named suite, package or path no longer exists, or a regression row has no flow.
  When you rename a suite, update its flow in the same PR.
- Add a flow when an iOS regression ships: `source` gets `regression:N` and a row below.

## Regressions this suite covers

Full rows (why each was not caught, evidence): [REGRESSIONS-2026-11.md](REGRESSIONS-2026-11.md).

| Row | What broke | Root PR | Fix | Flow | Catching test | Would `cmux ios verify` have caught it |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Terminal stuck on its skeleton at first attach | cmux#53596 | cmux#56970 | terminal-first-attach | AttachWaitsForTheLinkTests, TerminalAttachFirstFrameUITests | yes |
| 2 | Key row floats over terminal text when the keyboard shows or hides | cmux#53325 | cmux#56673, cmux#56712 (Aziz) | terminal-key-row-layout | TerminalKeyRowOnDemandUITests (now asserts the row sits on the keyboard), TerminalComposerDockUITests | yes |
| 3 | Workspace row stays highlighted after going back | cmux#53590 | cmux#56970; Aziz's cmux#57347 is a different design, Aziz decides | workspace-row-selection-clears | WorkspaceRowSelectionClearsUITests | yes |
| 4 | App and kit tests stop compiling (7 cross-PR breaks) | several | cmux#55399 | compile-app-and-tests | build-for-testing on the merged tree | yes, base merged first |
| 5 | UITests target, CmuxMobileLive and mobile-link Rust stop building | cmux#53596, #53746, #50638 x #54075 | cmux#55664, #55655 | compile-app-and-tests | build-for-testing, `cargo check -p cmux-mobile-link` | yes, base merged first |
| 6 | Crash when a portrait request is refused | cmux#52610 | cmux#53529 | screen-share-portrait-refused | ScreenSharingOrientationTests | yes |
| 7 | CmuxMobileShellTests stop compiling | cmux#51849 x #48532 | cmux#53217 | compile-app-and-tests | build-for-testing | yes, base merged first |
| 8 | Composer Paste key invisible, glass lost | cmux#48749 | cmux#53471, #56712 | terminal-composer-bar | TerminalComposerBarUITests | yes |
| 9 | Pairing fails with "Mac's identity changed" | cmux#13742 | cmux#57771 | pairing-mac-identity | MobileHostMacIdentityKeychainTests (macOS package) | yes by path; swift test in pr pipeline / mac, plus pair-e2e |
| 10 | Empty state says "Macs asleep" when cmux is not connected | pre-rename copy; cmux#53806 fixed one branch | cmux#57792 (open) | workspaces-empty-state | WorkspaceInboxTests, OfflineWorkspaceAlertUITests; the copy test lands with cmux#57792 | yes |
| 11 | A Mac with no workspaces shows Loading forever; the route flaps | | cmux#57410 (open) | workspaces-empty-mac-loads | WorkspaceInboxTests, NetworkPathFilterTests | yes by path (no replayable root) |
| 12 | ChatMacLookUITests red after cmux#57773 | cmux#57773 | | chat-mac-look | ChatMacLookUITests | yes |
| 13 | Full-screen app's header goes off screen with the keyboard up (PR audit) | cmux#41895 | cmux#42760, #43454 | terminal-keyboard-fullscreen-app | TerminalKeyboardNoResizeUITests | yes |
| 14 | Mac's terminal keeps the phone's size after background or lock (PR audit) | cmux#41902 | cmux#42192 | terminal-size-claim-release | TerminalSizeClaimDebounceTests | yes |
| 15 | App stops compiling: LocalLinkBrowser captured var (PR audit) | cmux#53717 | cmux#55156 | compile-app-and-tests | build-for-testing | yes |
| 16 | Slow chat history never shows "Loading chat…" (PR audit) | cmux#51591 | cmux#54975 | chat-slow-history-loading | StartingAgentSourceTests | yes |
| 17 | macOS half of the kit stops compiling and hides test reds (PR audit) | cmux#56000 | cmux#55509, #56732 | kit-macos-swift-test | `swift test` NoRawTimeoutCopyTests, WorkedFoldTests | yes |
