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
| 4 | finished turn (real Claude Code chat, `claude/haiku`) | background | long look shows its last line ("Ready"); system Reply, typed text, Send | Needed and finished | one | tunnel | Pass (delivery). The phone sent `session/prompt` over the link; the Mac's acpmux refused it as a Mac-started chat ("This chat runs with your Mac's Claude permissions…"), and the phone posted that reason as "Not sent to Rig Mac". The refusal is acpmux's existing policy, not this PR's; a phone-started chat is not refused | `evidence/rows/rows-claude-longlook.jpg`, `rows-claude-reply-typed.jpg`, `rows-claude-reply-sent.jpg` |
| 5 | error (fake agent `net-fail-once`) | background | system Reply | Needed and finished | one | tunnel | Pass (delivery). Banner "stopped with an error" with the error text; the reply reached the Mac, which refused it because the fake agent's mode (`normal`) is not one a phone may prompt (`acpmux_policy` `PHONE_MODES`); the phone showed that reason | `evidence/rows/` (banner in `rows-terminal-banner.jpg`) |
| 6 | terminal (OSC 9 from a shell, `printf '\e]9;…'`) | background | banner | Everything | one | tunnel | Pass. Title "Terminal · rows-shell" (fixed, never the program's), body "Build finished on the rig", subtitle "rows-shell · Rig Mac" | `evidence/rows/rows-terminal-banner.jpg` |
| 7 | question | background | banner with Show previews off | previews off | one | tunnel | Pass. Banner "Your agent has a question" / "Rig Mac"; the question's text is nowhere on the lock screen | `evidence/rows/rows-previews-off-banner.jpg` |
| 8 | terminal agent question (real Claude Code in a cmux terminal) | foreground, background, not running | Feed card, long look multi-choice, cold open | Needed and finished | one | tunnel | Pass. See "Terminal-hosted questions" below | `push-matrix-terminal-questions.md` |

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
   A prompt with no single-use Allow now matches the Feed (`phoneOptions`):
   it offers the agent's Always allow and Deny, and acpmux's refusal says to
   allow it on the Mac, instead of a lone Deny.

4. **A terminal agent's question pushed without its options** and **5. its tap opened an
   empty chat**: see `push-matrix-terminal-questions.md` ("Failures found and fixed").

## Pruned

- **Delivery "fallback"**: PR B only.
- **Levels "Only when I'm needed" and "Everything", and a Mac turned off**: the phone's
  setting is a filter in the Worker (`kinds`, `mutedMacs`, `wants`); a simulator cannot
  hold an APNs token, so the Worker never sends to it and a live row shows nothing the
  Worker tests do not (`backend/test/rich-push.test.ts`: per-kind filtering, muted Macs,
  `wants`). The phone side of the setting (Settings → Notifications syncing `kinds`,
  `mutedMacs`, `previews`) is `NotificationLevelTests` and was seen live (row 7's page).
- **App state "foreground" for every kind**: a foreground app shows the same banner
  (`willPresent` returns `.banner`) unless that chat is on screen, which
  `PushResponseTests` covers; rows 1–3 and 8 ran foreground and background.
- **Two Macs, push from the non-focused Mac**: the second rig Mac on this account
  (another agent's, same computer) folds into one listed Mac (`MacRoster`, #24167), so
  this rig cannot show two separate Macs. Routing a push to its own Mac is
  `NotificationRouteTests.anotherMacsWorkspaceWithTheSameIdIsNotOpened` and
  `MultiMacFeedTests`; a tap `touch`es the push's own Mac (live: answers above went to
  the pushing Mac while another Mac was focused).
- **Long look "+" attachment**: PHPicker inside a notification extension needs a photo
  library and a person's pick; the simulator's picker cannot be driven from AXe inside
  SpringBoard's extension host. The attachment path is unit tested
  (`PushFormTests`, `PushOutbox` attachments, L4 cleanup).

## Terminal-hosted questions

Reserved for the terminal-question lane (Claude Code AskUserQuestion running
in a terminal tab).

## PR B: encrypted fallback, sealed pushes, terminal replies (live, 2026-10-23)

Rig on `mini-cmux11s-mac-mini`: a hidden rig Mac from fleet build `3c9f88b876a1` (PR B
head, tag `mobile-e2e-pushfb`), the PR B Worker under `wrangler dev` on the mini
(API 0.14.0, memory store), and the `termq-phone` simulator with the PR B Demo build.
Both reach the Worker through `notify-tap.mjs`, which keeps every notify body and every
sealed mailbox blob (ciphertext only). The Mac and phone are paired, and the phone gave
the Mac its push key. Run scripts: `push-matrix/fallback_run.py` and
`push-matrix/replay_run.py`. `xcrun simctl push` runs no Notification Service Extension,
so a DEBUG simulator stand-in (`SimulatedServiceExtension`) runs the extension's own
code (`ServicePush`) on the delivered body.

| # | Case | Result | Evidence |
| --- | --- | --- | --- |
| B1 | A Claude Code turn ends on the rig Mac | Pass. The host sent the push sealed for the phone, with no content in the clear; the Worker sent the v3 body "cmux" / "New notification from Rig Mac", category `CMUX_MOBILE_SEALED` | `notify-capture.jsonl` |
| B2 | A terminal program asks for a reply (`cmux notify --reply`); the Mac's link frozen (its host `SIGSTOP`ped); the app killed; the person replies from the lock screen | Pass. The sealed push opened on the phone ("Terminal · fallback-shell", "Deploy tag: Which tag should I deploy?"). Reply → `v2.4.1` → Send woke the app. The link was unreachable, so it posted the reply sealed to the mailbox. When the host resumed it took the item ("mailbox reply applied") and typed it into that program, which printed `GOT V2.4.1` | `evidence/fallback/fallback-banner.jpg`, `fallback-longlook.jpg`, `fallback-after-send.jpg`, `fallback-results.json` |
| B3 | Replay: the service posts the captured sealed reply again (a fresh hub that forgot it) | Pass. Nothing was typed again: the terminal shows one `V2.4.1`. The Mac answered with the first outcome from its spent store, signed | `replay-results.json` |
| B4 | Tamper: one byte of the sealed blob flipped | Pass. Rejected `unsealed`, signed by the Mac | `replay-results.json` |
| B5 | Rebind: the genuine blob posted under another reply id | Pass. Rejected `unsealed` (the seal binds the id) | `replay-results.json` |
| B6 | Expiry: the captured reply replayed 13 minutes later | Pass. Rejected `expired`, signed | `replay-results.json` |
| B7 | Settings → Notifications: Everything | Pass. Synced to the Worker; the Mac's next notify answer wants `terminal`. At "Needed and finished" the Mac sent no terminal push: correct | `pb-settings-everything.jpg` |

Signature checks (a reply signed by a key that isn't the paired phone's, or a forged
sealed push) need a second phone key or the Mac's box key on the rig, so they ran as
tests, not live: `mailbox::tests` (bad signature, unpaired, removed) on rbx, and
`PushTrustGateTests` (a forged box, a foreign banner over a genuine box) on mini-cmux7s.

Failures found and fixed in this round:

1. **The long look of a sealed push was empty.** It read "Open cmux to see this
   notification", and a terminal notification had no Reply. The content extension lacked
   the shared push keychain group, so it could not open the box. Fixed in `project.yml`,
   the entitlements and `testflight-build.sh`; `scripts/check-notification-extension.sh`
   now checks it (red, then green).
2. **Rig only:** the macOS signal numbers (18 is SIGTSTP there) froze the host when the
   script meant to resume it; the script now uses named signals. A system-launched app
   lost the rig's service override; DEBUG now remembers it. A repeated mailbox reply now
   logs as a repeat instead of "applied".
