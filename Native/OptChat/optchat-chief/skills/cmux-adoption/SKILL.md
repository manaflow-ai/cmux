---
name: cmux-adoption
description: Help the person get more out of cmux: check their setup, use cmux from their iPhone (pair the iOS app, Action Button "Call Chief"), set up cmux on another computer (Mac or Linux) so agents run there, and join it over Tailscale (add the device, approve it, check that this Mac reaches it). Use when the person mentions their phone, being away from the desk, another computer, a server or Linux box, Tailscale, or asks what else cmux can do.
cmux-managed: true
---

# Help the person adopt more of cmux

You do the setup; the person does only what a person must do (a sign-in,
installing an app on their phone, approving a device). Every command here
prints JSON; read it, do not guess. Talk to the person in plain words: say
"your private network of devices (Tailscale)", not "tailnet ACL".

## When to bring it up

Suggest a step only when it fits what the person is doing, once per topic,
in one line. If they say no or ignore it, do not ask again in this chat.

| They say or do | Suggest |
| --- | --- |
| "on my phone", "while I'm out", "away from my desk", "can you ping me" | The iPhone app (section 2) |
| "my other Mac", "my server", "Linux box", "GPU machine", "run it on X" | cmux on that computer (section 3) |
| A long job that would block this Mac | Running it on another computer they own (section 3) |
| "Tailscale", "can't reach X", "how do I connect" | The Tailscale steps (section 4) |
| "what else can cmux do?" | Run the check (section 1) and offer the one or two gaps that matter most |

## 1. Check first (the doctor)

Run these read-only checks before you suggest or change anything:

```sh
cmux version --json                         # which cmux and app this is
cmux setup status                           # every setup task's state, with its fix
cmux setup tailnet --dry-run                # Tailscale and "serve this Mac" (needs no change to read)
cmux host list --json                       # the person's other machines that serve cmux
cmux acp host ls --json                     # agent peers: connected, outdated
cmux acp host candidates --json             # Tailscale machines that could be added
cmux settings get mobile.allowIPhoneConnections  # whether phones may connect
cmux accounts list --json                   # signed in to cmux (the phone needs the same account)
```

Then tell the person, in at most four lines, what works and the one next step
worth doing. Example: "Your Mac is on Tailscale and 3 of your machines are
reachable. Phones can connect, but no phone is paired yet: want the iPhone app?"

## 2. The iPhone app

What it gives them: their Home and Chief chats, agent sessions and terminals
on their Mac, from the phone. On an iPhone 15 Pro or later the Action Button
can start a voice note to you: iPhone Settings > Action Button > Shortcut >
cmux > "Call Chief". Siri works too: "Call my Chief in cmux", "Record a
voice note for my Chief in cmux". The note is transcribed on the phone and
sent to you as a message with the audio.

Getting the app: it is in beta on TestFlight for cmux team testers. If the
person has no TestFlight invite, say it is not public yet; never promise a
date and never send them a link you have not checked.

Pairing (no Tailscale needed on the phone; the phone finds the Mac through
the cmux account):

1. The Mac is signed in to cmux: `cmux accounts list --json`. Signed out:
   `cmux cloud sign-in`, and the person finishes the sign-in in the browser.
2. Phones may connect: `cmux settings get mobile.allowIPhoneConnections`. Only
   the person turns it on (agents are refused): when it is false, the page in
   step 3 has the switch; tell them to press Allow iPhone Connections there.
3. `cmux cloud open-mobile-pairing` opens the Mobile Pairing page beside the
   chat. It says one of: signed out, phone access off, preparing, ready, or
   failed (with the reason). Wait for ready.
4. The person opens cmux on the iPhone and signs in with the same account;
   the Mac appears there. The first time, the Mac asks to allow that phone
   (Allow on the prompt or on the page).

Their one step: install the app and sign in on the phone.

## 3. cmux on another computer

Pick the path by what the person wants:

- **You (the Chief) run agents there**, on a Mac or Linux: add it as an
  agent peer over ssh. Path B. This is the default.
- **Use another Mac's sessions from this Mac** (open its terminals and
  agents here): it serves cmux over Tailscale. Path A. Both can be on at
  once.
- **The person can't give you ssh and wants one line to paste**: Path C.

### Path A: serve it over Tailscale (a Mac with the cmux app)

On the new Mac (the person runs these, or you do over ssh):

1. Tailscale is installed and signed in with the same account as this Mac
   (section 4).
2. The same cmux app as on this Mac is installed (`cmux version --json`
   here names it). Its CLI is inside the app:
   `"/Applications/APP.app/Contents/Resources/bin/cmux"` (APP as installed,
   for example `cmux NIGHTLY`).
3. Serve it:
   ```sh
   "/Applications/APP.app/Contents/Resources/bin/cmux" setup tailnet
   ```
   (A cmux build older than `cmux setup tailnet`: `... cmux host enable
   --json`.) Read `state`: `ok` or `changed` means it serves; the
   `needs_user` kinds are in section 4. A Mac tagged in Tailscale has no
   owner: ask the person for their Tailscale login and run `cmux setup
   tailnet --owner LOGIN`.
4. Back on this Mac, check that you reach it:
   ```sh
   cmux host list --json        # the new machine is listed, "access": "owner"
   cmux host dial NAME          # {"ok": true, ...}
   ```
   NAME is the machine's Tailscale name (`verify` in the setup result names
   the exact command). Then the person can open it from the app: New
   Workspace on Machine.

Undo: `cmux host disable --json` on that Mac.

Not for Linux yet: the public installer
(`curl -fsSL https://cmux.com/tui/install-static.sh | sh`) installs the
cmux of the `main` branch, which has no `cmux host` or `cmux acp` (checked
2026-10-22: it answers `unknown resource scope "host"`). For a Linux box use
Path B.

### Path B: an agent peer over ssh

From this Mac:

```sh
cmux acp host candidates --json                   # pick the machine (online, not already_peer)
cmux setup machine SSH_TARGET --name NAME --dry-run
cmux setup machine SSH_TARGET --name NAME
cmux acp host doctor NAME --json                  # step by step; add --fix to repair
```

This is the route for Linux and for any machine you can ssh to. When this
build cannot run there (another OS or CPU), the result says to install
from the app: the person clicks Machines > Add Machine in cmux, which puts
the right build on the machine; then run `cmux setup machine` again.
SSH_TARGET is `user@host` or the Tailscale name. It uses key-only ssh: if
the machine refuses, the result is `needs_user` with the ssh command to
try; hand the person that. With Tailscale SSH on (section 4) no key is
needed. Undo: `cmux acp host rm NAME`. Follow the `cmux-setup` skill for
every state of `cmux setup machine`. Ask before adding a machine the person
did not name.

### Path C: one pasted line (a Mac with the cmux app)

```sh
cmux acp host ticket new --role client --ttl 30m --json
```

Where the same cmux app is installed, hand the person `join_command` from
the result with the app's CLI path in front (`"/Applications/APP.app/
Contents/Resources/bin/cmux" host join 'TICKET'`): it joins that machine to
this Mac (role client: it uses this Mac's sessions). Do not hand out
`install_command` yet: it installs the `main` branch's cmux, which cannot
join (see Path A). The ticket works once and expires.
`cmux acp host ticket ls --json` shows tickets and paired machines;
`cmux acp host ticket revoke ID` ends one.

## 4. Tailscale: add a device

Tailscale makes a private network of the person's devices. The person
signs in; you do the rest. `cmux setup tailnet` on the new computer names
the one step it still needs (`user_action.kind`):

| kind | What the person does |
| --- | --- |
| `install` | Install Tailscale: Mac App Store or https://tailscale.com/download. Linux: `curl -fsSL https://tailscale.com/install.sh \| sh` |
| `start` | Open the Tailscale app (Mac), or `sudo systemctl enable --now tailscaled` (Linux) |
| `sign_in` | Run `tailscale up` (Linux: `sudo tailscale up`) and finish the sign-in at the link it prints, with the same account as their other devices |
| `approve` | A Tailscale admin approves the device at https://login.tailscale.com/admin/machines |
| `wait` | Nothing: run the check again in a few seconds |
| `owner` | Tell you their Tailscale login (a tagged server has no owner) |

Run `cmux setup tailnet` again after each step.

Good to know, say it only when it applies:

- Tailscale SSH lets you reach a Linux box without ssh keys: on that box
  `sudo tailscale up --ssh`. The tailnet policy must allow it; the default
  policy lets a person ssh to their own devices, and may ask them to confirm
  in the browser now and then.
- A server added with an auth key (`sudo tailscale up --auth-key=KEY
  --advertise-tags=tag:NAME`): the key is a secret. The person creates it at
  https://login.tailscale.com/admin/settings/keys and types the command
  themselves; never ask for the key in chat. A tag needs an owner rule
  (`tagOwners`) in the tailnet policy, and the tagged machine needs
  `cmux setup tailnet --owner LOGIN`.
- Access rules: cmux on the new computer admits only its owner (and logins
  added with `cmux host allow LOGIN`, or a teammate with `cmux host grant
  LOGIN --scope status|agents|shell`). The tailnet policy must also let this
  Mac reach TCP port 7319 on it. The default policy allows everything; a
  custom one needs a rule like
  `{"action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self:7319"]}`
  (for a tagged server, `"dst": ["tag:NAME:7319"]`). When `cmux host dial
  NAME` fails while `tailscale ping NAME` works, this rule is the cause.

## What you do, what the person does

| You | The person |
| --- | --- |
| Run every check and every `cmux` command | Sign in to Tailscale and to cmux in the browser |
| Open the pairing page | Turn on iPhone connections, install the iPhone app, sign in there, allow it on the Mac |
| Install cmux on a machine you can ssh to, add it as a peer, serve it | Approve a new device when their tailnet asks for it; click Add Machine when the build must come from the app |
| Mint a pairing ticket and hand them the line | Paste the line on a machine you cannot reach |
| Verify with `cmux host dial NAME` and say it works | Give you their Tailscale login for a tagged server |

Never read or type a password, an auth key or a sign-in code. After a
change, say in one line what now works and how to undo it.
