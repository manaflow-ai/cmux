# Rich, interactive push notifications

Branches: `feat-cmux-next-ios-rich-push` (PR A) and
`feat-cmux-next-ios-push-fallback` (PR B, stacked on A). The wire contract is
PROTOCOL.md "Push notifications (API 0.13.0)". The trust analysis for PR B is
`verify/notifications-trust.md`.

## What a person gets

| Kind | Banner | Long-press (content extension) | Buttons | Tap |
| --- | --- | --- | --- | --- |
| Question, one choice, at most 4 options | "<Agent> asks", the question, `<workspace> · <Mac>` | the chat's last lines, the question, option rows, the composer | one per option | the chat, scrolled to the question |
| Question, multi-select, more than 4 options, several questions or free text | same | option rows (checkboxes for multi-select), Submit, the composer | "Answer…" | the chat |
| Permission | "<Agent> needs permission", the command or tool title | the last lines and the request | Allow once, Always allow (when offered), Deny | the chat |
| Finished turn | "<Agent> finished", the last line | the last lines, the composer | Reply (text) | the chat |
| Error | "<Agent> stopped with an error" | same | Reply (text) | the chat |
| Chief | "Chief", the reply's first lines | the last messages, the composer | Reply (text) | that Chief's conversation |
| Terminal (OSC 9, 777, 99) | the program's title and body | the terminal's last screen as text | Reply (text, PR B, needs device unlock) | the terminal tab |

Thread per session (`thread-id`), the collapse rules from #23803 unchanged.

## Choices and why

- **Face ID stays where it is.** An Allow or an answer is signed by the
  approval key, which needs Face ID (`verify/phone-approvals.md`). iOS shows
  Face ID only in a foreground app, so Allow, Always allow and every answer
  are foreground actions: the app opens on the chat, asks Face ID and sends.
  Deny and text replies need no signature, so they are background actions
  (device unlock required), delivered without opening the app.
- **Collapsed buttons are dynamic.** The content extension sets
  `extensionContext.notificationActions` from the payload, so a question's
  own options are the buttons. Without the extension (watch, an older
  build) the static category offers "Answer…".
- **The composer.** iOS gives an extension no way to start a background
  action from its own view. The system Reply field is the background path;
  the extension's composer (with "+") hands its text and attachments to the
  app through the App Group outbox and opens the app on the chat, which sends
  over the Mac's link. Photos come from PHPicker inside the extension.
- **Preview rendering.** The content extension has a tight memory budget and
  no link. It draws the payload's last lines (and, when the app saved one, the
  chat's recent messages from the App Group) with a small SwiftUI view, not
  CmuxConversation, which pulls Markdown, WebKit and the full chat model.
- **Previews off.** The banner says only the kind and the Mac. The payload
  still carries what the buttons need; the extension shows content only while
  protected data is available (the phone is unlocked).
- **Reply delivery (PR A).** The app delegate gets the action (iOS wakes the
  app in the background), reaches that Mac's link (one link per Mac, #23816)
  through the live coordinator, building it headless on a cold background
  launch, and sends the same request the app sends in-app. Budget: 4 s for
  the link. On failure it posts "Couldn't reach <Mac>" with Retry.
- **Fallback (PR B).** When the link misses its budget, or the app cannot
  run, the reply goes through the Worker sealed to the Mac's identity key and
  signed by the phone's identity key; the Mac applies it only after its own
  checks. Notification content is sealed to the phone's push key and opened
  by a Notification Service Extension.

## Tap routing

A tap opens the exact screen on the notification's Mac, in every app state:

| Kind | Opens |
| --- | --- |
| question, permission, completed, failed | the chat (`sessionId`), else the workspace tab (`workspaceId` + `tabId`), else the Feed item |
| chief | Home, that Mac's Chief conversation |
| terminal | the terminal tab (`tabId`) in its workspace |
| a browser tab (`tabId` names one) | the browser tab |

The route waits for that Mac's tree once (cold launch), then falls back to the
Feed item. A locked app (Settings → Require Face ID) opens the route after
unlock.

## Settings → Notifications

- Level: **Only when I'm needed** (`question`, `permission`), **Needed and
  finished** (default, adds `completed`, `chief`), **Everything** (adds
  `failed`, `terminal`).
- Per Mac: on or off (`mutedMacs`).
- Show previews (`previews`).

All three sync with `PUT /v1/devices/:id/push`; the Worker filters, and the
notify answer's `wants` lets the Mac skip kinds no phone wants (terminal).

## Extensions and signing

| Target | Debug / Demo bundle | Production | TestFlight (cmux INTERNAL) |
| --- | --- | --- | --- |
| app | `dev.cmux.mobile$(TAG)` | `dev.cmux.mobile.prod` | `dev.cmux.app.internal` |
| content extension | `….notification-content` | `dev.cmux.mobile.prod.notification-content` | `dev.cmux.app.internal.notification-content` |
| service extension (PR B) | `….notification-service` | `dev.cmux.mobile.prod.notification-service` | `dev.cmux.app.internal.notification-service` |

App Group `group.<app bundle id>` holds the outbox and chat snapshots. PR B
adds a shared keychain group for the push key.
