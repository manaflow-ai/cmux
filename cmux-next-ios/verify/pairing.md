# Pairing: finding the Mac in any space (2026-10-13)

A production user sat on setup's "Connect your Mac … Waiting for your Mac…"
forever, with the Mac app online and Settings → Mobile → Allow iPhone
Connections turned on. This page covers the fixes and how they were verified.

## What was wrong

1. **Live data started only after setup.** `LiveCoordinator` was created by
   the shell (`ShellView.startLive`). During setup the phone never registered
   and never fetched Macs or presence. A `wrangler tail` of the user's run
   recorded zero requests in 90 s. Setup's team picker showed every team as
   "No Macs yet", and the pair step could never flip.
2. **Discovery looked only in the active team.** The Mac registers in the Mac
   app's selected team, or in `personal-<sub>`. The phone looked only in its
   own active team. When the two sides chose different spaces, the phone never
   saw the Mac.
3. **Create Team appeared while the team list was still loading.** The
   coordinator's team list starts as `[]`, and setup took that to mean
   "no teams".
4. **The copy named the wrong Mac setting.** It said "Settings → iPhone". The
   Mac's section is Settings → Mobile.
5. **hostd got a 401 right after sign-in** (`POST /v1/devices: 401`) and
   recovered 5 s later with a force-refreshed token. See "The hostd 401" below.

## What changed

- **Backend 0.5.0** (`cmux-next-ios/backend`, deployed to dev):
  - `GET /v1/me/macs` returns the caller's own Macs in every team the caller
    still belongs to and in its personal space, each with its `teamId` and
    presence (PROTOCOL.md).
  - When a token's `kid` is missing from the cached JWKS, or the JWKS fetch
    fails, the Worker refetches the keys at once and verifies the token again.
    jose's own refetch waits out a 30 s cooldown.
  - A 401 now ends with the reason, for example `(expired)`, `(restricted)` or
    `(unknown_key)`. It never echoes the token. The log records the project,
    the reason and the `kid`.
  - The dev Hyperdrive config now has query caching disabled. Its default 60 s
    cache hid a newly registered Mac from `/macs` and `/me/macs`, and made
    `prefs` reads stale. Both smoke runs were flaky until this changed.
- **App:**
  - `RootView` creates `LiveCoordinator` at sign-in, so setup and the shell
    share it.
  - Discovery polls `/v1/me/macs`: every 4 s while the active team has no
    online Mac, otherwise every 30 s, and at once on foreground. It shows each
    Mac in its current team and removes it from any team it moved out of.
  - The personal space joins the team list while a Mac lives in it.
  - The phone moves to the team of an online Mac while the active team has no
    online Mac. It moves when a Mac comes online elsewhere, or moves to another
    team while online. It also moves for any online Mac while the active team
    has no Mac at all, unless the user picked that team in the sidebar.
  - The Stack selection follows the move, and the shell shows a toast.
    `AppStore.mergeDiscoveredMacs` and `teamToFollow` hold this logic, and
    `DiscoveryTests` covers it.
- **Workspaces empty state:** it now says "No Macs in <team> yet." When
  another team has one of the account's Macs, it says "<Mac> is in <team>."
  and shows a "Switch to <team>" button.
- **Team list as a state:** `TeamListState` is loading, loaded or failed.
  `CmuxMobileAuthModel` fetches the teams itself, because the coordinator cannot tell
  "none" from "not loaded". Setup shows skeleton rows (SPEC 7.1) until the
  list loads, and a Retry state if the fetch fails. Create Team appears only
  when the loaded list is empty, and it now has "Not now" to continue in the
  personal space. Setup's steps are fixed once the list has loaded.
- **No Mac on this account:** discovery records how many Macs the account
  has anywhere (`AppStore.accountMacCount`). When that is zero, setup and the
  Workspaces empty state say "No Macs are signed in as <email>. If your Mac
  uses a different account, sign in with the same one on both." Another sign-in
  method can create a second account for the same person. Workspaces adds an
  Account Settings link, and the mock screenshot is `mock/other-account.png`
  (`-cmux-mobile-setup-pair -cmux-mobile-setup-pair-other-account`).
- **Copy:** the Mac step now reads "Settings → Mobile → Allow iPhone
  Connections". Once the Mac is found, the status line says which team it is
  in.

## The hostd 401

The Worker could not log a reason before this change, so the old log cannot
show which cause applied. Two causes fit the evidence: a 401 on the first
token, then success on a forced refresh 5 s later.

- **A key the cached JWKS lacked.** Stack's production JWKS publishes two
  ES256 keys. Before this change, a token signed with a key added after the
  isolate cached the set failed until jose's 30 s cooldown passed. The Worker
  now refetches the keys immediately (tested in `test/me.test.ts`
  "signing keys").
- **A restricted token** from a session that had not finished signing in.
  Restricted and anonymous tokens are signed with keys outside the default
  JWKS (`?include_restricted=true` adds two more `kid`s). They are rightly
  refused, and the 401 now says `(restricted)`.

A clock-skew or `nbf` problem is unlikely: the Worker allows 60 s of skew, and
hostd checks `exp` itself. If the 401 happens again, the hostd log line now
names the reason.

## Verification

### Unit tests

- `backend`: `npx vitest run` passed 26 tests. `test/me.test.ts` covers:
  - Macs across a team and the personal space, with presence
  - a Mac that moved to another space
  - per-user and per-project scoping
  - the 401 reasons
  - the immediate JWKS refetch, for an unknown `kid` and for a failed fetch
- `CmuxMobileModelTests`: 33 tests passed (Swift Testing, run on macOS through a
  package with only `CmuxMobileModel`). They include:
  - `TeamListStateTests`: an empty publish is not an answer, a failure leads
    to retry, and a loaded list is never hidden by a later failure
  - `DiscoveryTests`: the merge and move, the personal space joining the
    list, following, a team the user pinned, offline Macs, a Mac that moves
    while online, and the empty-state offer

### Live smoke

`STACK_EMAIL=… STACK_PASSWORD=… bun scripts/smoke.ts`, plus the same with
`CMUX_MOBILE_TEAM=personal`, against the dev Worker 0.5.0. Every check passed,
including the new "my macs in every space" and "401 names the reason" checks.
Credentials came from 1Password and were never printed.

### Simulator, mock mode

Headless `cmux-mobile-pair-ios26` (iPhone 17 Pro, iOS 26.5); Simulator.app was never
opened. `verify/record-pairing.sh <udid> <dir>` records each scenario at 30
fps, splits every frame and OCRs each one with
`verify/scripts/ocr-frames.swift`.

| Scenario | Result |
| --- | --- |
| `onboarding`: cold launch signed out, email sign-in, setup with `CMUX_MOBILE_MOCK_TEAMS_DELAY=2` | Of 497 frames, none contains "Create your team" or "Create team". After the code, frames 272 to 335 (2.1 s) show skeleton rows, then "Choose a team" (`onboarding-transition.png`) |
| `elsewhere`: `-cmux-mobile-setup-pair -cmux-mobile-setup-pair-elsewhere` | "Waiting for your Mac…" until frame 156, then "Aziz's Mac Studio is online in Personal" and Continue |
| `empty`: `-cmux-mobile-demo connect-mac-elsewhere` | Shows "No Macs in Manaflow yet.", "mini 1 is in Build Fleet." and "Switch to Build Fleet". The switch runs the button's own action and shows the Build Fleet list |

### Live, dev Worker and the dev test account

- **Setup:** hostd ran on `mini-cmuxs-mac-mini-2` in `~/cmux-next-ios-e2e/pair`
  (removed afterwards). The account has one Stack team, so setup opened on
  Connect your Mac in that team (`live/setup-live-follow.png`).
  - 21:01:12: hostd was online in `personal-<sub>`. Within 1 s of launch the
    step read "cmux-mobile-pair mini is online in Personal", with Continue.
  - 21:01:41: hostd restarted in the Stack team. While the phone sat in
    Personal, the step went to "Waiting…" at once. At 21:01:49 it read
    "cmux-mobile-pair mini is online in cmux Agent DEV's Team".
- **`wrangler tail --env dev` during setup** (`live/worker-tail.txt`, ids
  redacted):
  - 21:01:12–13: `POST /v1/devices` ×2, `GET /v1/me/macs`,
    `GET /v1/teams/personal-<sub>/macs`, then `/v1/ice` and the signaling
    socket
  - 21:01:43: `GET /v1/me/macs`
  - 21:01:48: `GET /v1/me/macs`, then the device moves and
    `GET /v1/teams/<team>/macs`
- **Shell:** with the phone in the Stack team and hostd brought online in
  Personal, the phone moved to Personal by itself. The Workspaces tab showed
  "cmux-mobile-pair mini Online · Connected · WebRTC direct · 0 ms".

## Found during verification

- The first build followed only Macs that newly came online. A Mac that
  re-registered into another team while online was missed: the phone stayed in
  Personal while the Mac's row moved away. `previouslyOnline` now keys on
  (Mac, team) through `DiscoveredMac.placement`, with a regression test, and
  the live run above uses the fixed build.
- `simctl spawn … defaults write` did not reach the app's preferences on this
  runtime. The live run edited the container's plist with the app stopped.

## Known gaps

- `personal-4f1dd4fd-…` in a `wrangler tail` of the dev Worker belongs to the
  dev test account that this verification used, not to the user's phone. The
  user's phone and Mac may still be on different Stack users. The new "No
  Macs are signed in as <email>" line says so on the phone. The Mac's
  Settings → Mobile does not yet show which account email the Mac registered
  as. That is a Mac-side change for `feat-cnx-ios-machost`.

- Production builds talk to this same dev Worker (PROTOCOL.md), so the fix
  is live for them now. The production Hyperdrive placeholder in
  `wrangler.jsonc` notes that caching must be disabled there too.
- The smoke script leaves `smoke-mac-renamed` rows in the test account. Before
  this change they were invisible across spaces; they now appear as offline
  Macs in Personal and in the team.
- The Mac's How to Connect text is still "sign in with the same account as
  this Mac". It is correct now that the phone searches every space. The Mac
  side's one wrong path (`scripts/cmux-next/build-mobile-host.sh`, "Settings >
  Accounts > iPhone") is fixed on `feat-cnx-ios-machost-copy`.

## Sign out during setup (start over)

Every setup page now has a footer: "Signed in as <email> · Sign out". This
includes Choose a team, Create your team, Connect your Mac, notifications,
and the loading and failure states. Sign out asks "Sign out and start over?"
before it acts.

Every sign-out path goes through `RootView.signedOut()`: the setup footer,
Settings → Log out, and a session the service ended. It does the following:

- signs out of Stack: the coordinator drops the session and its Keychain
  tokens, and `CmuxMobileAuthModel` resets its team list
- stops and drops `LiveCoordinator` (discovery, presence and the link)
- runs `AppStore.resetForSignOut`, which clears teams, Macs, workspaces, link
  status and the stored per-account preferences:
  - the last team
  - setup complete
  - team appearances
  - remembered Macs and directories
  - the last tab per workspace
- keeps device preferences such as appearance, terminal settings and
  developer options
- replaces the Keychain device ids. The service binds a device id to its first
  user, so a second account would get `403 not_owner`.
- replays Welcome with its intro

`SignOutResetTests` covers the reset with an isolated `UserDefaults` suite;
CmuxMobileModelTests passes 35 tests.

The recording is `restart/restart.mp4` and `restart/restart-sheet.png`: the
`-cmux-mobile-demo onboarding-restart` demo in mock mode with
`CMUX_MOBILE_MOCK_TEAMS_DELAY=1`, recorded on `cmux-mobile-pair-ios26`. OCR at 2 fps
(`restart/ocr.tsv`) shows this sequence:

1. Email sign-in.
2. Skeleton rows with the footer.
3. Choose a team.
4. The sign-out confirmation.
5. Welcome with its intro.
6. Sign-in as `other@cmux.dev`.
7. Skeleton rows, then notifications, then the shell.

The mock account is always `aziz@example.com`, so the footer shows that email
after both sign-ins. The demo confirms the dialog through its own action, not
a tap. Sign-out was not run against a live Stack session on the simulator.
