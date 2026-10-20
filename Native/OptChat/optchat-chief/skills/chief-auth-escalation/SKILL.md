---
name: chief-auth-escalation
description: Drive a sign-in, passkey or 2FA for a subagent so the user only touches the Touch ID sensor. Use when a "[aN] needs a sign-in" note arrives (a subagent called escalate_auth), or when your own work hits a login page.
cmux-managed: true
---

# Sign-ins for the user, down to one touch

The user wants sign-ins to cost them one finger on the Touch ID sensor and
nothing else (Lawrence 2026-10-20). A subagent never waits on a login tab:
it calls `escalate_auth`, and you, the Chief, do the rest at once, before
other queued work.

## 1. Read the escalation

The note reads `[aN] needs a sign-in (KIND) on SITE: REASON. Page: URL.`
KIND is `password`, `passkey`, `2fa` (a code or a security key after the
password) or `oauth` (a "Sign in with ..." page).

## 2. Open the page in the column right of your chat

- `cmux browser right navigate --url URL --agent "<your name>"` opens your
  own tab in the column right of your chat in Home (or reuses it) without
  moving the user's focus. Never open it in your chat's pane.
- Passkey and security-key sites: the platform authenticator (Touch ID,
  iCloud Keychain passkeys) needs WebAuthn in the pane; see "Where passkeys
  work" below.

## 3. Fill what you may

- Look first: `cmux browser right snapshot --interactive --agent "<your name>"`,
  then `click`, `fill` and `press` by the refs it gives.
- You may type the user name or e-mail address the user already gave you
  or the site shows, click buttons and choose "Use a passkey", "Security
  key", "Touch ID" or "Sign in with passkey".
- Never read, type, paste, log or store a password, a one-time code or a
  recovery code. If the page needs a password, prefer in this order:
  1. a passkey button on the page (many sites put it beside the password
     field or after the user name);
  2. the password manager's autofill (the browser's saved password or the
     user's password manager extension), which the user confirms with
     Touch ID;
  3. the user types it: post one line and wait.
- Never import cookies or sign-ins from another browser without the
  user's Allow (`cmux browser import-cookies ... --reason`).

## 4. Trigger the Touch ID sheet

Click the passkey, security-key or Touch ID button, or, when the page has
already started WebAuthn, leave it waiting. macOS then shows its Touch ID
sheet over cmux. Check that the page waits on the authenticator (snapshot:
"Waiting for your security key", a passkey sheet, or the page's own
spinner).

## 5. Ask for the touch, once

Post one short line, nothing more:

`Needs you: touch the sensor (SITE)`

Do not explain the flow, and do not ask "should I". If the site has no
passkey or security key step and needs a password or code typed by hand,
the line is `Needs you: sign in to SITE in the right pane` instead.

## 6. Watch, then hand back

- Watch the tab (`cmux browser right state` or `snapshot`: its URL leaves
  the login page) for up to 10 minutes; never poll faster than
  every 5 seconds.
- When it is signed in: `tell(aN, "Signed in to SITE in tab <tab id>;
  go on.")`. The subagent then drives that tab or its own.
- When the user does not touch the sensor within 10 minutes, tell the
  subagent so, and leave the line standing; do not ask again.

## What this skill does not do

- It never stores passwords or codes, and never passes a sign-in to a
  subagent: the subagent uses the signed-in browser profile.
- It does not approve money, legal or destructive steps: those still need
  the user's own words.

## Where passkeys work in cmux-next

- CEF (Chromium) panes: WebAuthn with the platform authenticator (Touch ID
  and iCloud Keychain passkeys) and USB or NFC security keys.
- WebKit panes: WebAuthn needs the app's web-browser entitlement
  (`com.apple.developer.web-browser.public-key-credential`); without it
  `navigator.credentials.get` fails with NotAllowedError, so use a CEF
  pane for passkey sites.
