# Agent Alarms

Settings → Notifications → Agent Alarms (off by default). When a coding agent is stuck on
you, the iPhone rings a real alarm through AlarmKit (iOS 26). It is the Clock app's kind of
alarm: full screen on the lock screen, and it rings through Silent mode and Focus. Aziz,
2026-11-24: "triggers an alarm (with 30s debouncing enforced to avoid too many consecutive
alarms) whenever a coding agent is bottlenecked by you such as a permission prompt, agent
going down, etc. We should also support that alarm scheduling capability when the app is
down as much as we can."

## What rings

| Trigger | Default | From a push (cmux not open) | From the live Feed (cmux open) |
| --- | --- | --- | --- |
| Permission requests | on | `kind: permission` | a new `FeedItem.Kind.permission` |
| Questions | on | `kind: question` | a new `.question` |
| Terminal agents waiting (Claude Code or Codex in a terminal tab) | on | `kind: terminal`, `state: waiting` | a new `.needsInput` |
| Agent stopped or crashed | on | `kind: failed`, or `kind: terminal` with `state: failed` | a new `.failed` event no older than 5 minutes |
| Mac went offline | **off** | none (an offline Mac sends nothing) | a Mac this phone was connected to that stays unreachable for 60 s while cmux is in front |

Mac went offline is off by default: the phone's own network drops look the same, and an alarm
for those would be noise.

Nothing else rings: finished turns, Chief replies, plain terminal notifications, a muted
chat's notifications, and any push the phone could not open (withheld after sign-out, inert,
stale, or still sealed). A push that would ring still shows its normal notification too.

## The rules (`AgentAlarmGate`, `CmuxMobileNotifications/AgentAlarmPolicy.swift`)

- **30 second debounce, global.** At most one alarm in any 30 seconds, whatever triggers it
  and whichever process sees it (the app or the notification service extension). Both read
  one ledger in the push keychain group. An event inside the window is *held*: its
  notification still shows, the Recent list says "Held: another alarm rang N s before", and it
  never rings later.
- **One alarm per event.** An ask is keyed by its acpmux permission id (`ask:<id>`), the same
  for its push and its Feed row (`ask-<id>`), so seeing it twice rings once. Keys are kept a
  day.
- **The alarm stops itself when the ask closes.** It may be answered on the phone, on the Mac or on
  another device. The Feed watch (`AgentAlarmFeedWatch`) stops the AlarmKit alarm it or the
  extension rang (`AlarmManager.stop`, else `cancel`).
- **A clock moved back** counts as "just rang": hold rather than ring twice.

## Permission

Turning Agent Alarms on is what asks iOS (`AlarmManager.requestAuthorization`, with
`NSAlarmKitUsageDescription` in the app's and the extension's Info.plist). The page shows
**Not asked**, **Allowed**, or **Off** (Off taps through to iOS Settings). If the person
turned AlarmKit off in iOS Settings, every event is logged in Recent as "Not rung: alarm
permission is off" and nothing rings.

## When cmux isn't open

| State of cmux | What rings | How |
| --- | --- | --- |
| In front | everything in the table | the live Feed, each push (`willPresent`), the Mac watch |
| Background, still running | asks and errors | the push's service extension (it runs for every push), then the Feed when the app wakes. The Mac watch pauses: iOS drops the links of a background app on purpose |
| Suspended, or killed by iOS | asks and errors | the notification service extension (`NotificationService`) opens the sealed push, then calls `AgentAlarms.handle` before it gives iOS the banner |
| Swiped away (force-quit) | asks and errors | the same extension: iOS still runs service extensions for a force-quit app's alert pushes |
| Phone off, offline or in Airplane mode | nothing | no push arrives. APNs keeps only the newest push per app and delivers it when the phone is back online, and that push rings then |
| Notifications from the Mac off (Settings → Notifications → Macs), or a build that gets no pushes | nothing while closed | no push arrives; the in-app Feed still rings while cmux is open |
| Mac went offline, cmux closed | nothing | an offline Mac can't push, and the phone runs no code to notice |

### What we looked at and did not use

- **Pre-scheduled "dead man's switch" alarms.** These would be alarms set ahead and pushed
  back by heartbeats, so that a Mac that goes silent rings. iOS gives a closed app no timer to
  push them back with, so every quiet stretch would ring falsely. Not shipped.
- **Background tasks (`BGAppRefreshTask`).** iOS runs them when it chooses, often hours apart,
  and never for a force-quit app. That is too late for "an agent is waiting on you now".
  The push path already covers the same events in seconds.
- **Silent (`content-available`) pushes.** iOS throttles them and drops them for a force-quit
  app. The alert push with `mutable-content` that the Mac already sends runs the service
  extension reliably, so the alarm rides on it.
- **AlarmKit from the extension.** AlarmKit's API is not marked unavailable to app
  extensions, and the extension links it. If iOS refuses the schedule there, the push's
  notification still shows and Recent says "Not rung: iOS refused the alarm". Confirm it on
  each new iOS release with the phone step below.

## Phone calls (Settings → Notifications → Phone Calls)

cmux's own number calls the person and reads out what needs them, for the same events as the
alarm (permission, question, waiting in a terminal, agent stopped with an error) and with the same
30 second window. The **service** places the call, from the Mac's `notify` (PROTOCOL.md "Agent
calls"), so it rings with cmux closed, swiped away, the phone locked, or with notifications off.

- **Provider: Twilio Programmable Voice.** One `POST /2010-04-01/Accounts/:sid/Calls.json`
  per call with inline TwiML, so there is no webhook to host. It needs a paid Twilio account and
  one purchased voice number (`TWILIO_FROM_NUMBER`), set as Worker secrets
  `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` and `TWILIO_FROM_NUMBER`. Until they are set, the
  service answers `configured: false` and the page says calls aren't set up.
- **Voice: MeloTTS** (`@cf/myshell-ai/melotts`, MIT licence) on Cloudflare Workers AI, via the
  Worker's `AI` binding. Twilio fetches the audio from `GET /v1/agent-call/audio/:token`, an
  HMAC-signed link (`AGENT_CALL_AUDIO_KEY`) that holds the sentence and lives 10 minutes; the
  Worker synthesizes it then. Without the binding or key, the call falls back to Twilio's own
  `<Say>` voice. The sentence plays twice, then the call hangs up.
- **What it says:** "Hi, this is cmux. Claude Code on Mac mini needs your permission. Open cmux
  to answer." (`callScript` in `backend/src/agent-call.ts`; names are trimmed to 40 characters
  and stripped of anything a voice can't say).
- **The number** is verified first: the service calls it and reads a 6-digit code (10 minutes,
  5 tries, at most 3 code calls an hour). The app only ever sees it masked.
- **Rules** (`decideCall`): off, no number or trigger off → no call; an event already called
  for (`ask:<permissionId>` or `event:<mac>:<id>`, kept a day) → no call; within 30 s of the
  last call, from any Mac or a test call → held, and the held event never calls later.
  Recent keeps the last 20 calls, held calls and provider failures.
- **Not covered:** "Mac stopped responding" (only the phone can notice it); a Mac that is
  asleep or has no network sends no event, so nothing calls. A phone set to Silence Unknown
  Callers or a Focus that blocks unknown numbers will not ring until the cmux number is saved as
  a contact; the page says so.
- **Verify:** `backend/test/agent-call.test.ts` (rules, script, TwiML, signed audio, verify
  flow, rate limit, notify → call, debounce, duplicate, trigger off, test call, provider
  failure, not configured); `UITests/AgentCallsCaptureUITests.swift` (every page state in
  light and dark, against `AgentCallMockService`, `CMUX_MOBILE_DEV_AGENT_CALL=<scenario>`).

## Verify

- Unit tests: `CmuxMobileKit/Tests/CmuxMobileNotificationsTests/AgentAlarmTests.swift`
  (window edges at 29.9 s and 30 s, the shared ledger across both processes, duplicates, held
  events, triggers, permission refusals, which delivered notifications may ring).
- Simulator capture: `UITests/AgentAlarmsCaptureUITests.swift` and
  `AgentAlarmsDeniedCaptureUITests.swift` (each trigger, the debounce, permission
  states). A simulator runs no service extension. `SimulatedServiceExtension` (DEBUG) runs the
  extension's own chain, alarm step included, on a push given at launch. That is the cold-start
  stand-in for "cmux was not running". The DEBUG hooks `CMUX_MOBILE_DEV_AGENT_ALARM_FEED`,
  `_CLOSE` and `_MAC_OFFLINE` (`AgentAlarmDebug.swift`) drive the Feed and Mac watch paths
  without a Mac.
- Phone: with Agent Alarms on, swipe cmux away, lock the phone, and have an agent on the Mac
  ask for permission. The phone rings within seconds. A second ask within 30 s shows only its
  notification.
