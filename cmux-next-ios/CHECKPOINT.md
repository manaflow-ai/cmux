# cmux-next-ios checkpoint — 2026-10-19 (latest; older entries below)

Branch `feat-cnx-ios` (integration), head `3d125593` plus this note. Checkpoint branch:
`feat-cnx-ios-checkpoint-20261019`. Not a state we're satisfied with; it goes to cmux INTERNAL
so the team can dogfood it.

| Piece | State | Where |
| --- | --- | --- |
| iOS app | Production build `3d125593` on the user's phone (2026-10-16) | `~/cmux-mobile-builds/20261016-3d1255930b-prod/` |
| Mac app | Integrated build `6b2ed0bb` (Codex from phone, browser host, terminal daemon fixes, Codex hook fix) | `~/cmux-mobile-builds/20261015-6b2ed0bb5d-mac-prod/`, branch `feat-cnx-ios-macnext`, notes `cmux-next-ios/verify/mac-build.md` |
| Prod backend | `https://mobile-api.cmux.dev` Worker 0.8.0, prod Stack only | `cmux-next-ios/backend` |
| Parity | Rounds 1–3 done; table and gaps | `cmux-next-ios/verify/parity-mac.md` |
| Terminal | Gate `verify/design/terminal/ACCEPTANCE.md` NOT passed; latest verifier REJECT (round 11); round-12 fixes (tab close confirm, N3 cursor row, N1 prune black, A6, N5) merged but not re-verified | `verify/design/terminal/qa-round-12.md`, `VERIFY-round11.md` |
| Open PRs (not merged) | #20757 Codex hooks (main, green), #20770 port to cmux-next, #20809 attach sizing (cmux-next) | GitHub |
| Overnight summary and pending decisions | | `cmux-next-ios/verify/MORNING-2026-10-15.md` |

Known open terminal items: Jump-to-bottom pill on the first frame (N4), active-card cut (N6),
review items A3/A4/A5/A7, timing rows never measured under acceptable load, 60-minute sessions.

TestFlight (cmux INTERNAL, `dev.cmux.app.internal`, app 6791408425): blocked only on a
distribution signing identity; prod backend live; ASC key `cmux-shared Team Key` validates.

# cmux-next-ios checkpoint — 2026-10-13 ~21:50 PT

Branch `feat-cnx-ios` (integration). Checkpoint branch: `feat-cnx-ios-checkpoint-20261013`.

## What ships today

| Piece | State | Where |
| --- | --- | --- |
| iOS app (`cmux-next-ios/`) | Builds; production build 38181 (`50c3104d`) on the user's phone | `~/cmux-mobile-builds/20261014-50c3104dfc-prod/` |
| Mac app (cmux-next + bundled `cmux-mobile-host`) | Side-by-side production build "cmux NEXT mobile" running on the user's Mac | `~/cmux-mobile-builds/20261013-2f984af108-mac-prod/`; source `feat-cnx-ios-machost` |
| Dev backend | `https://cmux-mobile-api-dev.debussy.workers.dev` (dev + prod Stack) | `cmux-next-ios/backend` |
| Prod backend | `https://mobile-api.cmux.dev` (API 0.7.0, prod Stack only), PlanetScale `cmux/cmux-next-ios-prod` | `cmux-next-ios/backend` |
| Shared UI packages | CmuxTabsKit == origin/feat-cmux-next-tabs-kit 0ea4df4e; CmuxConversation == origin/feat-imsg-parity-gui c735526c | `cmux-next-ios/scripts/check-tabskit-sync.sh` |

Pairing between the user's real iPhone and real Mac works (WebRTC direct, WireGuard via TURN).
Note: the next iOS production build points at the PROD Worker; the running Mac app still
points at DEV — ship the two together (machost agent is switching the Mac Release URL).

## In flight (agent branches; uncommitted work lives in their worktrees under `worktrees/`)

fastconn (warm connect, latency, honest cached states, keepalive interop), termlive (input lane),
chieflive (real Mac Chief, parity, details toggles), browserstream (browser tabs as video),
machost (Mac production readiness: notarized release, relay security analysis, device identity,
Settings → Mobile, PR into feat-cmux-next — not merged), approvals (Face ID-signed approvals,
device trust, Require Face ID; mid-merge), dataflow (phone tabs → Mac, attachments, dead settings),
wsdesign (Workspaces list design⇄implement loop), prodinfra (DB cred → 1Password, prod test account),
APNs key creation via the user's ASC tab, e2erig (E2E production-journey rig + latency suite).

## Known blockers / audit

`cmux-next-ios/verify/production-audit.md` (15 blockers, ~60 majors/minors; each assigned).

## Decisions taken by the user

TestFlight → cmux INTERNAL (dev.cmux.app.internal), version 1.1.0; old INTERNAL workflow paused
(`gh workflow enable ios-testflight.yml --repo manaflow-ai/cmux` to resume); CI signing ON HOLD
(release environment only admits main/rc/**/v*); no upload until an E2E verification round is
production-acceptable; production choices approved (prod backend, Face ID approvals, APNs,
Apple sign-in, device removal, notarized Mac app); Chief over the link approved.

## How to resume

1. `git -C worktrees/feat-cnx-ios pull`; `cmux-next-ios/scripts/check-tabskit-sync.sh`.
2. Build: `cmux-next-ios/scripts/demo-build.sh --config Production --ref <sha> --skip-mac`.
3. Install: `xcrun devicectl device install app --device 00008150-0005154E0E84401C <app>`.
4. E2E: `cmux-next-ios/verify/e2e/run.sh` (once the e2erig agent lands it).
5. Rules: one simulator per agent (delete when done); real cmux-next builds only for live checks;
   process headroom guard (procs < 6500).

## Update 2026-10-13 ~22:40 PT

- Merged into `feat-cnx-ios`: fastconn (Worker 0.8.0, batched requests, warm connect), termlive
  (input lane; mock terminal removed), push entitlement limited to TestFlight builds (`a986e386`).
  Head `a074414f`; production iOS build `~/cmux-mobile-builds/20261014-a074414f18-prod/` (not installed: phone away).
- Mac: PR https://github.com/manaflow-ai/cmux/pull/20414 (not merged; user says "merge" after trying).
  Production Mac build `~/cmux-mobile-builds/20261014-127d9ed1df-mac-prod/cmux NEXT iOS Test.app`
  (`dev.cmuxterm.app.next.iostest`, prod Worker). B15 (signed, notarized) blocked: nightly-next notarization paused.
- nx-remote host `cmux-lawrence-2` unreachable (no alias/DNS); Swift tests run on `mini-cmuxs-mac-mini-2`
  with the locally built xcframework copied over.
- Open: cmux-tui drops terminal input under a fast flood ("Broken pipe"), see `verify/terminal-input-lane.md`;
  phone UI to remove stale Macs (API ready); design loops: workspaces (implementing), onboarding (designer).

## Update 2026-10-14 ~01:45 PT

- `feat-cnx-ios` head `1c0f5bd0`: + removemac, Workspaces redesign, onboarding (3 rounds, converged),
  Face ID approvals (phone side), hangfix, wsfields, review fixes, E2E rig. Prod iOS build
  `~/cmux-mobile-builds/20261014-ae6354ff98-prod/`. Mac PRs: #20414 (machost), draft #20491 (approvals, stacked).
- E2E (iOS 26.5, Mac 604fc689): 17 pass / 4 fail / 3 blocked. Echo idle 15/32 ms, flood 0/17 ms,
  link up 1.16/1.27 s (met); settled list 4.2/4.5 s and tab switch 1.17/1.28 s (missed, perf agent on it).
  Failing: Files preview (Mac refuses "no workspace roots are shared"), terminal scrolled past prompt,
  removed Mac comes back (machost), settled-list latency. Blocked: agent chat/Feed (no free agent), Chief send.
- In flight: termfix, perf, Home+Chief implementer, terminal designer, machost (pairing dialog + removal regression).
