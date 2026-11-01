# Screen Sharing: see and control a Mac from the iPhone

Settings › Screen Sharing lists the account's Macs from the device hub
(docs/device-hub/PROTOCOL.md). Tapping a Mac asks it for a session: Full Control
by default, or View Only from the row's menu or the Viewer setting. The first
time, the Mac asks its person (Allow once, Always allow, Deny). Once approved,
its screen opens full screen in CmuxScreenKitUI.

| Piece | Where |
| --- | --- |
| This iPhone as a hub device (platform `ios`) | `Packages/Shared/CmuxDeviceHub`, a portable copy of the Mac's CmuxNextDevices. The simulator has no Secure Enclave, so it uses software P-256 keys in the Keychain. |
| Hub lifecycle, Mac list, push routing | `CmuxMobileScreenSharing/ScreenSharingService.swift`. Created on sign-in, opened when the page first shows, signed out and stopped on sign-out. |
| One session as the viewer | `ScreenSharingViewer.swift`. Request, then wait for approval, then the ticket, then the stream. It ends on deny, revoke or end. One ticket serves one stream (`reconnectLimit` 0). |
| Viewer choices | `ScreenSharingPreferences.swift`: quality, fit, stats, input mode, and what Connect asks for, kept on the phone. |
| UI | `ScreenSharingPage.swift`. The screen turns with the phone (`ScreenSharingOrientation`); the rest of the app stays portrait. |
| Mac side | Unchanged. The tagged cmux NEXT app's Share This Mac host. Input fixes are in PR #27706. |

The hub a build uses: DEBUG builds use the dev hub (`cmux-device-hub-dev`), or
`CMUX_MOBILE_DEVICE_HUB_URL`. Every other build uses production, the same split
as the Mac app.

## Live rig

The viewer is a Debug simulator build on aws-m4pro-6, driven by
`UITests/ScreenSharingLiveUITests.swift`. The host is a tagged Mac build on
mini 2, launched from the mini's own cmux.app so it inherits Screen Recording
and Accessibility. Both sign in as the agent test account
(`~/.secrets/cmux-dev-agent-auth.env`), so they are the same hub user.

```sh
# Host (mini 2): copy issmac1/, InputProbe (swiftc -O InputProbe.swift -o InputProbe), run-host.sh and hub.py to ~/iss-rig.
# Put the credentials in ~/iss-rig/private/creds.env (0600), then:
cmux workspace create --name "iOS screen sharing host" --command "$HOME/iss-rig/run-host.sh issmac1"
python3 ~/iss-rig/hub.py issmac1 set_shared '{"shared":true}'

# Viewer (from this checkout):
verify/screen-sharing/rig.sh sync && verify/screen-sharing/rig.sh seed-xcf && verify/screen-sharing/rig.sh sim
verify/screen-sharing/rig.sh build
CREDS=~/.secrets/cmux-dev-agent-auth.env MAC="iOS Rig Mac mini" verify/screen-sharing/rig.sh test run1
# While the phone waits on "Waiting for <Mac>", answer as the Mac's person:
ssh mini-cmuxs-mac-mini-2 'python3 ~/iss-rig/hub.py issmac1 approve always_full'
```

InputProbe sits in front on the host and shows every event it receives:
button, click count, modifiers, scroll deltas and precision, drags and keys.
So each step's screenshot, taken from the phone, shows what the Mac received.
It also writes the same events to `~/iss-rig/probe-<tag>.jsonl`.

## What each step proves

| Step | Phone | Mac (InputProbe) |
| --- | --- | --- |
| 04 | Stream with stats (fps, path, round trip) | — |
| 05 | Tap | `left-down clicks=1` |
| 06 | Double tap | `left-down clicks=2` |
| 07 | Two-finger tap | `right-down` |
| 08 | Hold, then drag | `left-drag` …, `left-up drags=N` |
| 09 | Keyboard, typing | `key chars=h` … |
| 10 | Sticky ⌘, then tap | `⌘left-down` (needs PR #27706 on the host) |
| 11 | Turn to landscape | The screen fills the phone |
| 12 | Close | The session ends on both sides (`viewer_disconnected` in the audit) |

XCUITest cannot pan with two fingers. Scroll is covered by the host's
injection tests (PR #27706) and CmuxScreenKit's encoding tests, and is not
part of the live run.
