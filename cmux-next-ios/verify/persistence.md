# What the phone remembers

Branch `feat-cnx-ios-persist`. User report (2026-10-14): after signing out and
back in, the phone counted as a new device and every Mac asked "Allow … to
connect?" again.

## What reset, and why

Sign-out did three things that each made the Mac ask again:

1. `RootView.accountChanged` set `auth.willSignOut` to unregister push **and**
   call `LiveCoordinator.unpair()`, which sent `auth` `action: unpair` to the
   linked Mac. The Mac app removed the phone from its approved list.
2. `unpair()` (or, without a live session, `RootView.signedOut`) called
   `PhoneKeys.reset()`, which deleted both Secure Enclave keys. The next link
   made new keys, and a Mac approves a device id together with its keys.
3. `RootView.signedOut` called `DeviceIdentity.reset()`, which deleted the
   link and presence device ids. The next sign-in registered a new device id,
   so the Mac saw a different phone.

The pinned Mac keys (`mac-pins.json`) were never reset. Sign-out also deleted
the account's preferences (`AppStore.resetForSignOut`), so setup ran again
and the remembered Mac per team was lost.

## The design now

- **Device identity is per account and survives sign-out.** Device ids are
  Keychain items `link.<user id>` and `presence.<user id>`; the pairing keys
  are `identity.<user id>` and `approval.<user id>`. The same account signing
  in again is the phone its Macs approved, so no Mac asks. Another account
  gets its own ids and keys. The first load after this change adopts the
  single pair an older build kept (it belonged to the account signed in then,
  because older builds deleted it on every sign-out).
- **Why that is safe.** A Mac admits a link only when the Worker-stamped
  `fromUserId` is its own user (`cmux-mobile-host` `host::admitted`), the device id
  is one that user registered (the Worker answers `403 not_owner` for another
  user's id), and the phone proves the keys the Mac's person approved for that
  id. The Mac keeps that list per signed-in Mac user (`MobileHostPairedDevices.userID`).
  So another account on this phone reaches none of the first account's Macs,
  and the keys never leave the enclave.
- **Sign-out** stops pushes (`DELETE /v1/devices/:id/push`, before the session
  ends), stops live data, and removes the account's data from the phone: the
  Feed archive and its items in memory, the workspace snapshots and unsent
  Chief messages. It puts the account's preferences away under its id
  (`AccountPreferences`). It never contacts a Mac. Code:
  `CmuxMobileLive/AccountSignOut.swift`.
- **Settings → Devices → Remove This iPhone from My Macs** (destructive, with
  the app's usual Cancel/Remove alert): the linked Mac forgets the phone (signed
  `unpair`), this account's keys are deleted, and the link redials, so the Mac
  asks again. The device ids stay. Code: `LiveCoordinator.removeThisPhoneFromMacs`.
- **Account deletion** forgets this account's keys, device ids, Mac pins,
  preferences record and Feed read marks.
- **Upgrading from an older build.** Older builds kept one unkeyed set (device
  ids, keys, Mac pins, live preferences) and deleted it on every sign-out, so
  a set that exists belonged to whoever was signed in. The first launch of this
  build adopts it for that account when it is signed in. When it launches
  signed out (that session ended without a sign-out here), it drops the set
  (`AccountSignOut.settleLaunchSignedOut`), so the next account never inherits
  it. Preferences written after a sign-out (a view saving as it fades out)
  belong to nobody and are dropped at the next sign-in.
- **Keychain read errors** (before the first unlock, say) never replace a
  stored device id or key: the run uses a temporary id, and writes update in
  place (`SecItemUpdate`, else add).

## Every item

| Item | Where | Sensitivity | Per account | Sign-out | Before |
| --- | --- | --- | --- | --- | --- |
| Stack sign-in tokens | Keychain (`KeychainStackTokenStore`, per bundle) | secret | n/a (one session) | deleted | same |
| Link and presence device ids | Keychain, `AfterFirstUnlockThisDeviceOnly`, `link.<user>` / `presence.<user>` | identifier | yes | **kept** | deleted |
| Identity key (Secure Enclave blob) | Keychain, `AfterFirstUnlockThisDeviceOnly`; the key needs no prompt | secret, device-bound | yes | **kept** | deleted |
| Approval key (Secure Enclave blob) | Keychain item `AfterFirstUnlockThisDeviceOnly`; the key itself is `WhenUnlocked` + user presence | secret, device-bound | yes | **kept** | deleted |
| The Mac's approval of this phone | Mac: `paired-devices.json` (0600, per Mac user) | trust | Mac user | **kept** | revoked (`unpair`) |
| Pinned Mac identity keys | App Support `mac-pins-<user>.json`, complete file protection | public keys | **yes** | kept | one shared `mac-pins.json` |
| Push registration | Worker | identifier | n/a | unregistered | same |
| Signed-in user cache, has-tokens flag | UserDefaults `cmuxMobile.auth.cachedUser`, `cmuxMobile.auth.hasTokens` (auth runtime) | low | n/a | cleared | same |
| Selected team | UserDefaults `cmuxMobile.auth.selectedTeam` (auth runtime) | low | n/a | cleared; the service returns it at sign-in | same |
| Setup done | UserDefaults `cmuxMobile.setupComplete` | low | yes (`AccountPreferences`) | **put away, back at sign-in** | deleted: setup ran again |
| Remembered Mac per team | UserDefaults `cmuxMobile.live.mac.<team>` | low | yes | **put away, back** | deleted |
| Last open workspace and tab | UserDefaults `cmuxMobile.lastOpenLocation` | low (ids) | yes | **put away, back** | cleared |
| Last tab per workspace | UserDefaults `cmuxMobile.lastTabByWorkspace` | low (ids) | yes | **put away, back** | deleted |
| New-workspace Mac, recent folders, Mac filter, team colors, last team | UserDefaults `cmuxMobile.workspaces.newMac`, `cmuxMobile.workspaces.recentDirectories.*`, `cmuxMobile.workspaces.macFilter.*`, `cmuxMobile.teamAppearance.*`, `cmuxMobile.lastTeamID` | low (ids, folder paths) | yes | **put away, back** | deleted |
| Device settings (transport, appearance, haptics, terminal font, follow-up, wrap, key clicks, notification kinds, Require Face ID) | UserDefaults `cmuxMobile.settings.*` | low | no: the phone's | kept | kept |
| Developer options | UserDefaults `cmuxMobile.dev.*` (DEBUG) | low | no | kept | kept |
| Chief Hide Alerts / Read Receipts | UserDefaults `cmuxMobile.chief.<conversation>.*` | low | by conversation id (one owner's) | kept | kept |
| Feed items | App Support `Feed/<user>.json` | private (agent names, places, turn text) | yes | **deleted** (and cleared in memory) | kept on disk |
| Feed read marks | App Support `Feed/read-<user>.json` | low (event ids) | **yes** | kept | one shared `read.json` |
| Workspace snapshots | App Support `cmux-mobile-live/snapshot-<user>.json` | private (workspace titles, folders) | yes | deleted | same |
| Unsent Chief messages | App Support `cmux-mobile-chief-outbox.json` | private (message text, images) | no | **discarded** | kept: the next account would send them |
| Diff "viewed" marks | UserDefaults `cmuxMobile.diff.viewed` | low (file paths with a diff fingerprint) | no | kept | kept |

Open: the diff "viewed" marks hold file paths and are not per account yet. They
only mark a diff that matches path and content, so another account sees no
effect, but the paths stay in the phone's defaults. Follow-up: key them by
account like the Feed read marks.

## Tests

CmuxMobileKit, Swift Testing:

- macOS (`swift test` on `mini-cmuxs-mac-mini-2`, Xcode 26.3):
  `DeviceIdentityPersistenceTests`, `PhoneKeysPersistenceTests`,
  `RemoveThisPhoneUnpairTests`, `AccountSignOutTests`, `AccountPreferencesTests`,
  plus `MacPinTests`, `FeedReadMarksTests`, `DiscoveryTests`,
  `LastOpenRestoreTests`: 47 tests, all pass (after the review fixes).
- iOS 26 simulator (`xcodebuild test -scheme CmuxMobileKit-Package`, `ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES`, on `mini-cmuxs-mac-mini-3` because mini-2's disk was
  full): the same suites plus `RemoveThisPhoneCoordinatorTests`,
  `MacRemovalTests`: 22 tests pass. The whole `CmuxMobileLiveTests`, `CmuxMobileModelTests`
  and `CmuxMobileShellTests`: all pass except `MacSelectionTests`, which fails only
  when run with the other suites (it reads `cmuxMobile.live.mac.t1` in
  `UserDefaults.standard`, which `MacRemovalTests` also changes) and passes
  alone; it predates this branch.

What they check: sign-out never calls the Mac removal and keeps the device
ids and keys; the same account gets the same ids and keys after sign-out, and
another account gets its own; the removal sends a signed `unpair` and replaces
the keys but keeps the ids; preferences come back for the same account only;
a deleted account keeps nothing; Feed read marks are per account.

## Live run

Not completed (2026-10-14 15:20 PT). The rig step is ready:
`verify/e2e/run.sh --mac-app "<cmux-mobile-e2e-1bd377aa app>" --no-build --latency none
--sim-name cmux-mobile-persist-ios26 --steps fresh_install,sign_in,choose_space,mac_discovered,persist_approval`.
`persist_approval` signs out and in, checks that the rig Mac's
`paired-devices.json` is unchanged and the link reconnects, then taps Settings
→ Devices → Remove This iPhone from My Macs and waits for a new approval of
new keys for the same device id. It records `persist-approval.mp4` in the run
folder.

What happened on four attempts against `cmux-mobile-e2e-1bd377aa` (the only built Mac
app with pairing and the DEBUG pairing seed), on a laptop at load 50 to 65,
with three other sessions taking turns on the rig:

- `145811`: sign-in failed in the rig (the number layout did not switch in
  time). `sim.py` now retries the switch once.
- `150505`: setup did not reach the tab bar. A rerun of the same three steps
  without the Mac (`/tmp/cmux-mobile-persist-dbg`) passed: setup advanced to
  Workspaces normally, so this was the load, not this branch.
- one run stopped at the 585 s bound while the simulator booted.
- `151341`: fresh install, sign-in and setup passed; the rig Mac's
  `cmux-mobile-host` never started (the run log says "cmux-mobile-host NOT running"; its log
  has not moved since 14:31), so no link and no pairing to check. A
  `SecurityAgent` process was running; whether it held a Keychain prompt for
  the rig app was not checked (that needs the screen).

Rig fixes on this branch: `mac.running_rig_apps` skips apps `lsappinfo`
still lists after they exit (they blocked every run), and `sim.softtype`
retries a slow layout switch.
