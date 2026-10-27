# cmux-next-ios TestFlight metadata draft (cmux INTERNAL)

Draft for review. Nothing here has been submitted to App Store Connect.

App: **cmux INTERNAL**, bundle `dev.cmux.app.internal`, ASC app id `6791408425`.

## What to Test (build notes, en-US)

Use this for the first cmux-next-ios build. Keep it under 4000 characters. Set it after
upload with `asc builds test-notes` (or the `--test-notes` flag on upload) once the
build is processed.

```text
This is the new cmux mobile app (cmux-next), replacing the previous cmux INTERNAL app.

Before you start: update the cmux-next app on your Mac and turn on Settings > Mobile. Sign in on the Mac and the phone with the same account.

Please test:
- Sign in: Sign in with Apple, Google, GitHub and email code.
- Your Macs: the Mac appears, connects, and reconnects after you lock the phone or switch networks (Wi-Fi to cellular).
- Workspaces: the list matches the Mac; open a workspace and its terminal; type, scroll, rotate the keyboard bar.
- Agent chat: open a Claude or Codex chat, send a prompt, cancel it, change the model or mode.
- Feed: agent events arrive and open the right chat.
- Files: open a file an agent changed and preview it.

Known limits in this build:
- Permission requests can be denied from the phone but not allowed or answered yet.
- New tabs made on the phone do not reach the Mac yet.
- Chief (Home) is offline over the link.
- No push notifications or Live Activities yet, even though Settings shows them.

Report problems with a TestFlight screenshot (it includes the build number).
```

Before using it, check each "Please test" line against the build's state in
`verify/production-audit.md`; drop any flow that is still mock-only or broken in
that build, and update "Known limits".

## Test information (TestFlight > Test Information)

Current values on App Store Connect (read 2026-10-13, unchanged here):

| Field | Current value | Proposed |
| --- | --- | --- |
| Beta app description | "cmux is a remote terminal client for the cmux macOS app. Pair your iPhone with a Mac running cmux to view and control terminal sessions and AI coding agents, with notifications when an agent needs you." | "cmux puts your Mac's cmux workspaces on your iPhone: terminals, AI coding agents and their files, over a private link to your own Mac." (drops "notifications" until push exists) |
| Feedback email | founders@manaflow.com | keep |
| Marketing URL | https://cmux.com | keep |
| Privacy policy URL | https://cmux.com/privacy-policy | keep; confirm it covers the device registry (device id, Mac list) |

## Beta App Review information (needed only for external groups such as "cmux family")

| Field | Current value | Proposed |
| --- | --- | --- |
| Contact | Lawrence Chen, founders@manaflow.com, +1 949 302 0749 | keep, or the person who owns cmux-next-ios |
| Demo account required | yes | yes: a production Stack account with a Mac that stays online running the cmux-next host |
| Review notes | "Sign in, pair with a Mac running cmux, then open and control a terminal session." | "Sign in with the demo account. Its Mac is online with the cmux-next host. Open Workspaces, pick a workspace, open its terminal and type; open an agent chat and send a prompt." |

Internal-group builds (group "cmux INTERNAL") need no Beta App Review.

## Export compliance answers (per build, if no encryption declaration is attached)

The build sets `ITSAppUsesNonExemptEncryption = YES`. App Store Connect asks:

1. Does your app use encryption? **Yes.**
2. Does it qualify for any exemption in Category 5 Part 2 (only Apple OS encryption, authentication only, and so on)? **No.** WireGuard (boringtun), WebRTC (DTLS-SRTP) and rustls encrypt user data with code that is not Apple's.
3. Does it implement proprietary or non-standard algorithms? **No.** Curve25519, ChaCha20-Poly1305, BLAKE2s, AES-GCM, TLS 1.3 and DTLS are published standards.
4. Does it implement standard algorithms instead of, or in addition to, Apple OS encryption? **Yes.**
5. Will it be on the App Store in France? This concerns App Store distribution, not TestFlight. Answer per the release plan; "yes" can require a French encryption declaration before an App Store release there.

Result: mass-market encryption under EAR 740.17(b)(1), no CCATS and no documents to upload. See `verify/testflight-readiness.md` for the reasoning and the optional encryption declaration.
