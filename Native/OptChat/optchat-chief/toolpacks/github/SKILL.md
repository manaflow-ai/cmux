---
name: github-signin
description: Sign this Chief in to GitHub with its own login (device code by default, a fresh code until approved, a self-wake to post each new code; or a fine-grained token, a GitHub App, the Mac's gh). Use on your first turn when the GitHub line says you are not signed in, when a push or gh call fails for auth, or when the person asks to sign in, rotate or sign out.
cmux-managed: true
---

# GitHub sign-in for this Chief

Shipped by the `github` tool pack (plans/cmux-next/chief-toolpacks-DESIGN.md): `chief github VERB`
is `chief pack VERB github` (`pat` is `paste`, `mac` is `share`).

Every Chief has its own GitHub login (plans/cmux-next/chief-github-DESIGN.md). It is kept
per Chief in a secret store and given to your `gh` and `git` on every turn: you never paste
a token into a file, a repo, a reply or a log. Offer sign-in once when you are not signed
in; do not ask which option, start the default (the device code) and name the others in one
line.

## 1. Where you stand

- Cloud Chief (a turn machine): the last line of your instructions says "GitHub: signed in
  as ..." or "not signed in". `chief-github status` shows who, kind, scopes and expiry.
- Local Chief (the Mac): `chief github status`. With no login of its own a local Chief uses
  the Mac's `gh` login (kind `mac`); that is fine unless the person wants this Chief to have
  its own, or the Mac's gh is signed out.

## 2. Device code (the default)

1. Start it: `chief-github login` (Cloud) or `chief github login` (local). It prints the card:
   the code in backticks and the page as a Markdown link alone on the next line:
   `[github.com/login/device](https://github.com/login/device)`.
2. Post the card as your reply, as it is: keep the page a Markdown link, never a bare or
   bold URL (`**https://…**` does not open in every chat). One tap copies the code and one
   opens the page. Add one line: "Other ways: a fine-grained token, a GitHub App, or
   the Mac's gh login."
3. Do not wait in the turn. The sign-in keeps going after your turn ends: GitHub is polled
   until the person approves, and when a code ends (about 15 minutes) a new code is made at
   once, for up to 3 hours.
4. Wake yourself to post the next code. A code nobody used is dead, so set a timer for when
   it ends:
   - Cloud Chief: `chief-github login` already set `chief-wake` for that time (it prints
     "chief-wake set"); otherwise run `chief-wake SECONDS "GitHub code ended: chief-github
     status, post the new code"` with the `wake_in` it printed.
   - Local Chief: call your `sleep` tool last, with the seconds the card names
     (`sleep(SECONDS, "GitHub code ended: chief github status, post the new code")`).
5. When "[wake] GitHub code ended ..." starts a turn: run the status. Signed in: say "Signed
   in to GitHub as LOGIN" and stop (no new timer). Still pending: post the new card (the
   code changed) and set the next timer the same way. No pending code and not signed in
   (3 hours passed or it was denied): say so in one line and stop; sign-in starts again only
   when the person asks.
6. A message from the person ("done", "approved") during the wait: run the status first.
   On a Cloud Chief `chief-github wait 60` returns at once when it is approved and makes `gh`
   and `git` in this same machine use the new login.

## 3. Other ways

- Fine-grained token (least access): the person makes one at
  [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new): Resource owner the org, only the
  repos you need, Repository permissions Contents: Read and write, Pull requests: Read and
  write, Workflows: Read and write (pushes that touch .github/workflows need it), Metadata:
  Read. They paste it to you; write it to a file in the turn machine's temp dir, run
  `chief-github pat FILE` (local: `chief github pat FILE`), then delete the file. Never echo
  it back. The status shows its expiry; rotate before then with a new one.
- GitHub App (an org that wants a bot identity): `chief-github app APP_ID INSTALLATION_ID
  KEY.pem` with the App's private key. Each turn gets a fresh installation token (1 hour);
  the login shows as `APP-SLUG[bot]` with the App's permissions.
- The Mac's gh login: `chief-github mac` (Cloud: copies the Mac's `gh auth token` through
  `mac --`), `chief github mac` (local: drop this Chief's own login and use the Mac's again).

## 4. Rotate and sign out

- Rotate: sign in again (`login` or `pat`); the new token replaces the old at once.
- Sign out: `chief-github logout` / `chief github logout`. It forgets the token here and says
  where to revoke it at GitHub ([github.com/settings/applications](https://github.com/settings/applications)
  for the device login). Pass that line on, the page as a Markdown link.

## Never

- Never put a token in a reply, a file in a repo, a commit, a log or a subagent task.
- Never ask the person which way to sign in first; start the device code.
- Never leave a dead code as the last thing in the chat while sign-in is pending: post the new one.
