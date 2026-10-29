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
| Permission | "<Agent> needs permission", the command or tool title | the last lines and the request | Allow once, Deny (as the Feed, `phoneOptions`: acpmux refuses a lasting grant from a phone, `remote.lasting_grant_refused`; a prompt with no single-use Allow keeps its Always allow, and acpmux's refusal says why) | the chat |
| Finished turn | "<Agent> finished", the last line | the last 4 messages up to the reply, "+" (Photos, Files), the system reply field | none: the reply field is at the bottom | the chat |
| Error | "<Agent> stopped with an error" | same | same | the chat |
| Chief | "Chief", the reply's first lines | Chief's header (its avatar and name, the Mac), the last 4 messages up to the reply as Messages bubbles, "+" (Photos), the system reply field | none: the reply field is at the bottom | that Chief's conversation |
| Terminal (OSC 9, 777, 99) | "Terminal · <workspace>", the program's title and body | the program's title and body (the screen stays on the Mac until PR B seals payloads) | none (Reply is PR B, needs device unlock) | the terminal tab |

Thread per session (`thread-id`), the collapse rules from #23803 unchanged.

## Choices and why

- **Face ID stays where it is.** An Allow or an answer is signed by the
  approval key, which needs Face ID (`verify/phone-approvals.md`). iOS shows
  Face ID only in a foreground app, so Allow and every answer
  are foreground actions: the app opens on the chat, asks Face ID and sends.
  Deny and text replies need no signature, so they are background actions
  (device unlock required), delivered without opening the app.
- **Collapsed buttons are dynamic.** The content extension sets
  `extensionContext.notificationActions` from the payload, so a question's
  own options are the buttons. Without the extension (watch, an older
  build) the static category offers "Answer…".
- **Replying.** The reply field is the system's own, at the bottom of the
  long look (the category's Reply action): it sends in the background,
  without opening the app. The extension sets no "Reply" button beside it
  (the button opened a second field and read as unexplained). As in
  Messages, "+" in the view attaches photos (PHPicker) and, for an agent's
  chat, files (a copy from the document picker, at most 25 MB); Chief's
  messages carry text and photos only. What "+" picks is copied into the App
  Group outbox and staged under the notification's request id
  (`PushOutbox.stage`); the app delegate takes it with the Reply
  (`takeStaged`) and sends text and attachments together. A build without
  the App Group shows no "+". A question's free text is an "Other answer"
  field above Submit.
- **History.** The last 4 messages up to and including the notified one
  (`PushHistory`): the chat the app saved when it last went to the
  background (Chief's conversation too, with its name and avatar), then the
  push's message, once. The push's `tail` is the same reply cut into lines,
  never a second bubble; a chat saved before the push never holds it.
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

## Security review (#24156)

- **Retries.** A "Couldn't reach <Mac>" notification carries only the reply's
  id; the reply waits in the app's own Application Support, never the App
  Group, and is taken only for a notification the app posted itself. A
  remote push can't carry a reply in.
- **Answers name their labels.** A button or the form sends the option's
  label with its index; the app refuses when the Mac's option there no longer
  reads so (a cut label matches by its start). The Face ID sheet names the
  chosen answers ("Answer “Yes, deploy”"), or the Mac's own title for an
  Allow, with "…" when cut.
- **Redaction.** The Mac redacts credentials in every text it sends
  (PROTOCOL.md "Push notifications"). Titles and last lines can still name
  paths and command arguments; terminal screens are never sent.
- **Terminal notifications.** The banner title is "Terminal · <workspace>"
  (a program never writes it); one per tab in 10 s, ten a minute, in their
  own rate bucket on the Worker.
- **Lock screen.** With Show previews off the static buttons stay (no option
  labels); the saved chat loads into the long-press view only while the phone
  is unlocked. With Require Face ID on, Reply and Deny open the app (behind
  its lock) instead of running in the background.
- **Previews off.** The static buttons stay (their titles never name an
  option on the lock screen), so a Reply button shows beside the field there.
- **Leftovers.** Attachments are deleted once sent and after 15 minutes; the
  outbox and retries are cleared on sign-out.

## Tap routing

A tap opens the exact screen on the notification's Mac, in every app state:

| Kind | Opens |
| --- | --- |
| question, permission, completed, failed | the chat (`sessionId`), else the workspace tab (`workspaceId` + `tabId`), else the Feed item |
| chief | Home, that Mac's Chief conversation |
| terminal | the terminal tab (`tabId`) in its workspace |
| a browser tab (`tabId` names one) | the browser tab |

The route waits for that Mac's tree (cold launch) while it can still arrive:
at most 10 s, and not at all when the Mac is offline, its last dial failed, or
the phone may not dial it. Then the Feed opens. Going to another tab while it
waits drops the route. A locked app (Settings → Require Face ID) opens the
route after unlock.

## Settings → Notifications

- Level: **Only when I'm needed** (`question`, `permission`), **Needed and
  finished** (default, adds `completed`, `chief`), **Everything** (adds
  `failed`, `terminal`).
- Per Mac: on or off (`mutedMacs`).
- Show previews (`previews`).

All three sync with `PUT /v1/devices/:id/push`; the Worker filters, and the
notify answer's `wants` lets the Mac skip kinds no phone wants (terminal). The
Mac tries a skipped kind again 15 s after the answer, so a phone that turns a
kind on gets it within about that.

Migration from the three earlier switches: Finished off becomes Only when I'm
needed, anything else Needed and finished. Questions always push now (an ask
needs an answer), and the default level no longer pushes errors: they are in
Everything only. A phone that had Errors on (the old default) gets no error
push until the person picks Everything.

## Extensions and signing

| Target | Debug / Demo bundle | Production | TestFlight (cmux INTERNAL) |
| --- | --- | --- | --- |
| app | `dev.cmux.mobile$(TAG)` | `dev.cmux.mobile.prod` | `dev.cmux.app.internal` |
| content extension | `….notification-content` | `dev.cmux.mobile.prod.notification-content` | `dev.cmux.app.internal.notification-content` |
| service extension (PR B) | `….notification-service` | `dev.cmux.mobile.prod.notification-service` | `dev.cmux.app.internal.notification-service` |

App Group `group.<app bundle id>` holds the outbox and chat snapshots. PR B
adds a shared keychain group for the push key.

### What is registered (App Store Connect, shared key RUML2V4CW7, 2026-10-21)

| Object | Id | Notes |
| --- | --- | --- |
| App ID `dev.cmux.app.internal.notification-content` | `95D6H7C27F` | App Groups capability on |
| App ID `dev.cmux.app.internal.notification-service` | `437CM874CF` | App Groups on; for PR B |
| App ID `dev.cmux.mobile.prod.notification-content` | `HZ5P6QYS87` | App Groups on |
| App ID `dev.cmux.mobile.prod.notification-service` | `8Y56F2B472` | App Groups on; for PR B |
| Profile "cmux Internal Distribution Notification Content" | `TCVW3L4742` | App Store; the same 5 certificates as "cmux Internal Distribution" (local signing) |
| Profile "cmux Internal Distribution Notification Service" | `3GT3TN7853` | App Store; same certificates; PR B |
| Profile "cmux Internal Distribution CI Notification Content" | `D23DRMH6ZH` | App Store; CI's certificate (as "cmux Internal Distribution CI") |
| Profile "cmux Internal Distribution CI Notification Service" | `Y6PCSLK3AC` | App Store; CI's certificate; PR B |

An older `dev.cmux.app.internal.NotificationService` App ID (`2V7RGMF6C2`, the
earlier iOS app's) exists and is not used. No certificate or key was created.

Not registered yet, on purpose: the App Groups `group.dev.cmux.app.internal`
and `group.dev.cmux.mobile.prod`. The asc CLI (and the App Store Connect API)
cannot create an App Group, and adding the App Groups capability to
`dev.cmux.app.internal` invalidates the two active "cmux Internal
Distribution" profiles (local and CI, the CI one also a release secret). So
device builds sign without the App Group (`CMUX_MOBILE_APP_GROUP=NO`, the
default for device SDKs; simulator builds always have it): the extension shows
the notification and its buttons, and its option rows and composer open the
app on the chat instead of handing over the answer.

A build without the App Group must never ask for it: TestFlight 1.2.0
(20261026194905) was killed by the launch watchdog (0x8BADF00D) because a view
body called `containerURL(forSecurityApplicationGroupIdentifier:)` on the main
thread for the unentitled group, and that synchronous XPC to containermanagerd
did not answer. `PushAppGroup.resolved()` now resolves the group once, off the
main thread, only when the executable's own signed entitlements name it
(`SignedEntitlements`), and gives up after 2 s; Info.plist names the group
only when `CMUX_MOBILE_APP_GROUP=YES`. Require Face ID reaches the extension
through the push keychain group (`PushSharedPreference`), which every build is
signed with. To turn the handover on:

1. In the developer portal, create the App Groups above and assign them to
   the app and extension App IDs (needs an Account Holder or Admin in the
   browser; the API key cannot).
2. Regenerate "cmux Internal Distribution", "cmux Internal Distribution CI"
   and the four extension profiles, update the release secret
   `IOS_BETA_PROVISIONING_PROFILE_INTERNAL_BASE64`.
3. Build with `CMUX_MOBILE_APP_GROUP=YES`, and add
   `com.apple.security.application-groups` to the entitlement sets
   `testflight-build.sh` checks and signs.

### Signing

- `project.yml`: the app's id is `CMUX_MOBILE_APP_BUNDLE_ID`; the extension is
  `$(CMUX_MOBILE_APP_BUNDLE_ID).notification-content`. TestFlight
  configurations name each target's profile (`CMUX_MOBILE_APP_PROFILE`,
  `CMUX_MOBILE_CONTENT_EXTENSION_PROFILE`), so no build passes one global
  `PROVISIONING_PROFILE_SPECIFIER` (that gave the extension the app's profile).
- `testflight-build.sh` fetches both profiles (or
  `CMUX_MOBILE_CONTENT_EXTENSION_PROFILE_PATH` / `_NAME` in CI), checks the
  one identity is in both, exports with both in `provisioningProfiles`, signs
  the extension first when signing an unsigned archive (`--from-archive`), and
  checks the embedded extension (id, version, entitlements) in the archive and
  in the IPA.
- `ios-internal-nightly.yml` names the CI extension profile. Its signing job
  runs the script from `rc/cnx-ios-builder`, so that branch must be
  fast-forwarded to a commit with this change before the first INTERNAL build
  that has the extension, or the old script stops at "the app has an
  extension".
- `demo-build.sh` needs no change: automatic signing and the team wildcard
  development profile cover the extension.
