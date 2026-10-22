# Rich push: simulator matrix over the real link

PR #24156 (`feat-cmux-next-ios-rich-push`). Every pushed payload was produced by
the real Mac host: the rig Mac's `cmux-mobile-host` reports to the dev Worker
through `push-matrix/notify-tap.mjs`, a pass-through that records each
`/notify` body, and `push-matrix/apns-from-capture.ts` turns that body into the
APNs JSON with the Worker's own `parseNotify` and `apnsPayload`. The JSON then
goes into the simulator with `xcrun simctl push`. Replies travel over the
phone's real WireGuard link to that Mac (path `direct`, through the dev Worker's
signaling), and every delivery is checked on the Mac (`acpmux last <session>`),
never on the phone.

## Rig

| Part | What |
| --- | --- |
| Host | `mini-cmux10s-mac-mini`, everything under `~/richpush-verify/` (`src`, `rig`, `mac-src`, `dd`, `payloads`, `evidence`, `bin/rig`, `bin/ph`, `bin/run-event`) |
| Mac | fleet build of this branch, tag `mobile-e2e-richpush` (bundle `com.cmuxterm.app.debug.mobile.e2e.richpush`), hidden (`open -g -j`), isolated config and acpmux home, settings only through `open --env`, `CMUX_NEXT_MOBILE_API_URL` = the notify tap. Agents: acpmux's credit-free fake agent through `verify/scripts/e2e_agent.py` (`ask:`, `ask-always:`, `question:`, `multi:`) |
| Phone | one simulator `richpush-phone` (iPhone 17 Pro, iOS 26.5), Demo build with `CMUX_MOBILE_PUSH=YES` (so the app registers categories and the Settings page shows the levels; the simulator has no APNs token, so pushes go in with `simctl push`) |
| Input | AXe HID touches into the simulator only; Face ID through `simctl` BiometricKit notifications. Nothing on the laptop is driven and no app takes focus |
| Scripts | `push-matrix/pushrig.py` (Mac), `push-matrix/pushphone.py` (phone), `push-matrix/notify-tap.mjs`, `push-matrix/apns-from-capture.ts` |

The long look is opened with the notification's Options → View, the same
long look a long press opens: AXe's long press does not reach SpringBoard's
gesture recognizer.

## Results

| # | Kind | App state | Action | Settings | Macs | Delivery | Result | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | question, one choice | background | inline button "A" | Needed and finished | one | tunnel | Pass (after fixes 1, 2). App opens on the Feed, Face ID, Mac: `chose allow_once {"Which branch should I deploy?": "A"}` | `evidence/r01-actions.png`, `r01-faceid.png`, `r01-answered.png`, `r01-inline-option-bg.mp4` |
| 2 | permission | background | inline Deny | Needed and finished | one | tunnel | Pass. Background action, no Face ID, Mac: `chose no` | `evidence/r02-actions.png`, `r02-permission-deny-bg.mp4` |
| 2b | permission offering only Always | background | buttons shown | Needed and finished | one | tunnel | Pass (after fix 3). Only Deny is offered | `evidence/v2c-actions.png` |
| 3 | question, multi-select | background | long look: check lint and e2e, Submit | Needed and finished | one | tunnel | Pass. Checkboxes, Submit enables, app opens, Face ID, Mac: `chose allow_once {"Which checks should run?": "lint, e2e"}` | `evidence/r03-expanded.png`, `r03-checked.png`, `r03-after-submit.png`, `r03-answered.png`, `r03-multi-submit.mp4` |

Rows 1 to 3 were rerun on the head with the review fixes (`85e23d99`):
same results (`v1-*`, `v2-*`, `v3-*` on the rig).

## Failures fixed

1. **The long look was blank.** The content extension trapped at launch
   (`__extensionContextClass != nil`): its binary never loaded
   UserNotificationsUI, where iOS finds the extension's context class. So the
   expanded view was an empty card and the buttons stayed the static
   category's ("Answer…"). Fixed by linking the framework (`project.yml`);
   `scripts/check-notification-extension.sh` fails a build that does not
   (red, then green). Commits `0baa95fc`, `e56581dd`.
2. **Every notification button crashed the app.** The async
   `userNotificationCenter(_:didReceive:)` returned on a background thread and
   UIKit aborted while updating the app snapshot in its completion (SIGABRT in
   `_performBlockAfterCATransactionCommitSynchronizes`). The completion
   handler now runs on the main actor after the reply is handled. Commit
   `e0633250`.
3. **Always allow passed Face ID, then said "Not sent".** acpmux refuses a
   lasting grant from a phone (`remote.lasting_grant_refused`, as the Feed
   already says). The notification button and the long look's row are gone;
   Allow once and Deny stay. `PushAlwaysAllowTests` (red, then green).

## Pruned

- **Delivery "fallback"**: PR B only.

## Terminal-hosted questions

Reserved for the terminal-question lane (Claude Code AskUserQuestion running
in a terminal tab).
