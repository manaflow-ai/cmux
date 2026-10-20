# Phone pairing and Face ID approvals

Branch `feat-cnx-ios-approvals`. Production audit items B2 (device trust),
B5 (Allow and answers from the phone) and B11 (Require Face ID).

Before this change:

- a Stack token was the whole device trust: anything holding one could pose
  as a phone and reach the Mac's terminals and agents;
- a phone could only deny: acpmux treats the `cmux-mobile-host` splice as a remote
  (`Web`) connection, and an allow or an answer needs the Mac app's person
  proof (`live.md`, finding 1);
- Settings → Require Face ID was saved and never read.

This page is the design, the security analysis for
https://github.com/manaflow-ai/cmux/issues/13742 (a trust-policy change),
and the verification record.

## Recommendation for #13742

Adopt Mac-approved device keys for every phone link, and Face ID signed
approvals for Allow and question answers:

- A token alone never reaches a Mac service: the Mac's user approves each
  phone once ("Allow “<phone>” to connect to this Mac?"), and every link
  proves the approved key.
- An Allow or an answer from the phone counts only with a Secure Enclave
  signature made after Face ID (or the device passcode), for that one prompt,
  option, answer set, Mac and daemon run, within 5 minutes, once.
- Deny and decline stay unsigned: narrowing needs no proof.

The user approved this approach for production on 2026-10-13.

## Design

### Keys on the phone (`CmuxMobileLive/PhoneKeys.swift`)

The phone makes two P-256 keys in the Secure Enclave the first time it needs
them. Only the enclave's encrypted blobs are stored, in the Keychain with
`ThisDeviceOnly` protection. A private key never leaves the enclave.

| Key | Access control | Used for |
| --- | --- | --- |
| identity | `.privateKeyUsage`, after first unlock | Each link's pairing challenge, with no prompt. |
| approval | `.privateKeyUsage` + `.userPresence`, when unlocked | Each Allow or answer: Face ID, with the device passcode as the fallback. |

Two keys, not one: a link is set up on every launch, foreground and network
change, and must not prompt; an approval must always prompt.

DEBUG builds on a simulator, which has no Secure Enclave, use software keys in
the Keychain, and `signApproval` still runs an `LAContext`
`.deviceOwnerAuthentication` check (Face ID matched with `xcrun simctl`).
Release builds never take that path: without an enclave the phone has no keys,
cannot pair with a Mac that requires pairing, and cannot approve.

The keys, like the link device ids, belong to one account on the phone
(`identity.<user id>`, `approval.<user id>`) and survive sign-out, so the same
account signing in again is the phone its Macs approved and nobody is asked
again (`verify/persistence.md`). Settings → Devices → "Remove This iPhone from
My Macs" asks the linked Mac to forget the phone (`auth` with
`action: unpair`, signed by the identity key), deletes both keys and redials;
the next link makes new keys, and the Mac asks again. Account deletion deletes
the keys and device ids too. Before 2026-10-14 sign-out did the removal.

### Pairing on every link (`cmux-mobile-host/src/pairing.rs`)

The first channel of every link is `auth`:

1. The phone opens `auth` with `{identityKey, approvalKey, name, action}`.
   Keys are 65-byte X9.63 points as lowercase hex.
2. hostd sends `{challenge, mac}`: 32 random bytes and its own device id. The
   phone refuses to sign a challenge that names another Mac.
3. The phone signs, with the identity key:
   `cmux-mobile-link-auth-v1 \0 mac \0 phone \0 nonce \0 identityKey \0 approvalKey \0 action`.
   `phone` is the link's device id, which the backend stamps on every signal
   (hostd never takes it from the arguments).
4. hostd verifies the signature. Then:
   - the device id with both keys is on the app's approved list: `{ok}`;
   - otherwise hostd emits `pair_request` to the app, sends `{pending}`, and
     waits up to 120 s for the app's next `devices` line to approve or deny.
     It asks only once the app sent its first `devices` line (waiting up to
     10 s), within the prompt limits in PROTOCOL.md "Pairing" (one `auth` per
     link, 3 new keys per device and 6 in all per 10 minutes, 10 minutes of
     silence for a device after a refusal). `pair_request` carries
     `registered_at_ms`, the device's registration date, for the dialog.
5. A channel the phone opens after `auth` waits for its outcome, at most
   the signature and approval waits, so a link still opens its workspaces,
   chats and Feed channels at once (fast connect). It is served only if
   `auth` passes, and closed `unpaired` otherwise. A channel with no `auth`
   opened before it (`echo` included) is refused `unpaired` at once.
   hostd counts running `auth` channels in open order, so a failed one (an
   unpair) does not refuse what another still holds.

The phone opens `auth` first (`LinkPairing.open`, no round trip), then the
`daemon` and `version` channels, then answers the challenge. Terminal, file,
upload and browser channels open only on a link whose `auth` has opened, and
terminals reattach (on the input lane, another stream) only after pairing
passes.

Unsupervised hostd (tests, `run-host.sh`) has no app to approve and serves
links as before. The app always runs hostd supervised.

**The Mac proves its own key (trust on first use).** The phone adds
`macNonce` (its own random nonce) to `auth`. The Mac app keeps a long-lived
P-256 identity key in its Keychain and hands it to hostd over stdin
(`mac_identity`). The challenge then also carries `macKey` (X9.63 hex) and
`macSignature` over
`cmux-mobile-mac-identity-v1 \0 mac \0 phone \0 macNonce \0 challenge`. The phone
(`LinkPairing`, `MacPins`) pins `macKey` per Mac device id the first time
pairing passes. After that, a Mac that proves another key, sends none, or
answers without `auth` is refused `mac_identity_changed` before the phone
signs anything, and the phone says "This Mac's identity changed…". Removing
the Mac in Settings → Paired Macs forgets the pin; when it adds itself again,
the phone pins its key again. A Mac that never sent a key (an older one) is
served unpinned.

### Chief question answers (`cmux-mobile-host/src/chief_answers.rs`)

A question part in a Chief conversation can grant something, so a paired
phone's `conversation-op` `question.answer` counts only with its approval
key's signature, as an agent answer in acpmux does. The command carries
`approval: {approver, nonce, expiresAt, signature}` over
`cmux-mobile-chief-answer-v1 \0 mac \0 approver \0 conversation \0 message_id \0
part_index \0 nonce \0 expiresAt \0 sha256(canonical answer)`. hostd checks
that the approver is the link's phone, uses that phone's paired approval key,
the expiry is at most 300 s ahead, and the nonce was not spent; then strips
`approval` and forwards the op. Unsigned or wrong answers are refused
`forbidden` before the Chief owner sees them. The phone signs after Face ID
(`ChiefAnswerSigner`, `ChiefDaemonBackend.answerQuestion`).

### The Mac (`CmuxNextMobile`, the iPhone host)

- `pair_request` shows a cmux dialog, app-wide: "Allow “<phone>” to connect to
  this Mac?". The body names the account and the approval key's fingerprint.
  Allow pairs it; Don't Allow refuses that identity key (it does not ask
  again; a new key, after "Remove This iPhone from My Macs", asks again). Closing
  the dialog without an answer decides nothing.
- One dialog per phone at a time; a repeated request while it is open is
  dropped.
- `MobileHostPairedDevices` keeps the list per signed-in user in a 0600 file in the
  app's cmux-mobile-host state folder. Another user starts empty, and signing out of
  the Mac clears it.
- The list goes to hostd as the `devices` control line (at start and on every
  change), and to acpmux as approvers (`_acpmux/approvers_set`), on the app's
  own person-proven unix connection (`MobileHostApproverSync`). That connection stays
  open; a new connection after a daemon restart sends the list again.
- Settings → Mobile can show `paired` (name, paired date, key fingerprint) and
  revoke one with `revokePhone(id:)`, which also ends its live links. Removing a phone from the account
  (`removePhone(id:)`) also forgets it here. A phone whose person chose "Remove This
  iPhone from My Macs" asks to be forgotten (`unpaired`); sign-out does not.

### Approving (`CmuxMobileLive/AcpmuxHub.swift`)

An Allow from any surface (the chat's permission bar, the Feed's buttons and
its Allow swipe, and later Chief) and every question answer go through
`AcpmuxHub.respond` or `answer`. For anything but a reject option, the hub:

1. reads the prompt with `_acpmux/info`: its `decisionNonce`, the daemon run
   `personInstance`, and the option's kind;
2. asks for Face ID. The system sheet names the tool ("Allow “rm -rf
   build”") or says "Send your answer to the agent";
3. signs and sends `_acpmux/permission_respond` with
   `_meta.acpmux = {decisionNonce, approverDecision: {approver, expiresAt,
   signature}}`.

A reject option is never signed and never prompts. A cancelled Face ID sends
nothing and says so under the card.

The signed payload:

```
acpmux-approver-decision-v1 \0 instance \0 macDevice \0 approver \0 session
\0 permission \0 option \0 nonce \0 expiresAt \0 answersDigest
```

- `instance`: the daemon run's `personInstance`.
- `macDevice`: the Mac's mobile device id (the app sets it with the approvers).
- `approver`: the phone's link device id.
- `expiresAt`: Unix seconds, now + 120 s on the phone.
- `answersDigest`: lowercase hex SHA-256 of the answers in canonical JSON
  (keys in byte order, no whitespace, only `"`, `\` and control characters
  escaped), or empty for a plain allow.

The signature is ECDSA P-256 / SHA-256, raw `r || s` as lowercase hex.
acpmux, hostd and the phone each have a test with the same fixed vectors.

### What acpmux checks (`hub/approvers.rs`)

- `_acpmux/approvers_set {macDevice, approvers: [{id, publicKey, name}]}`
  and `_acpmux/approvers` are accepted only from the person's connection.
  Everyone else, Web connections included, gets `permission.person_required`.
  At most 16 approvers; a bad entry refuses the whole set. The set lives in
  memory only, never in a file.
- A `permission_respond` with `approverDecision` counts when, in the person
  check and again under the prompt's lock:
  - the prompt is pending with that `decisionNonce`;
  - the approver is enrolled and the signature verifies over this daemon
    run, the enrolled Mac id, the session, permission, option, nonce, expiry
    and the digest of the answers it carries;
  - `now <= expiresAt <= now + 300 s`;
  - it carries no `answeredBy` (that stays the person's own claim);
  - the nonce has not counted yet. The answer that counts spends it (the same
    spent store as the Mac's HMAC decision proof), so a replay or a racing
    second answer counts nothing.
- From a Web connection the existing rule still holds: only `allow_once` or
  `reject_once`, never a lasting grant.
- Anything else is `permission.person_required` and the prompt stays pending.

### App lock (`CmuxMobileShell/AppLock.swift`)

With Settings → Require Face ID on, cmux opens locked and locks again when it
goes to the background. Face ID, or the passcode, unlocks it. The lock is its
own window above alerts, so it covers sheets and full-screen covers too, and
the same window covers the app while it is inactive, so the app switcher
snapshot shows the lock. Only a return from the background (or the launch)
asks for Face ID by itself; a cancelled Face ID stays cancelled until the
person taps Unlock. A device with no passcode cannot check the owner, so it
stays unlocked.

## Security analysis

Following the relay rules in the repository's CLAUDE.md:

- **Default deny.** hostd's service list is unchanged. The new `auth` service
  is the only one open before pairing. Its arguments are two public keys, a
  display name and `pair` or `unpair`; nothing in them names a command, a
  path, a session or another device.
- **Scoped ids.** The device id comes from the backend-stamped signal
  envelope, never from the phone's arguments. `unpair` works only for the
  link's own device id with its approved identity key.
- **Local command or content execution.** None is added. `auth` runs no
  process and reads no file. acpmux's new methods change an in-memory key list
  and are person-only.
- **Access to unowned objects.** A signature binds one prompt, option,
  answer set, Mac and daemon run; it cannot answer another prompt, another
  session or another Mac.
- **Local-state exposure.** hostd sends the phone only its challenge and the
  Mac's own device id. The paired list stays on the Mac (0600).
- **Residual risks.**
  - The Worker relays WireGuard and DTLS keys, so it remains trusted for the
    transport. A Worker that relays a pairing challenge to the real phone
    could ride its link. Binding the pairing signature to the transport keys
    (channel binding) is a follow-up.
  - A same-user process that writes the app's paired-devices file can add its
    own key, which the app then gives hostd and acpmux. That is the same class
    as the existing same-uid file-write risk in acpmux (`hub/person.rs`: an
    agent that edits `config.json` can already widen the policy).
  - The first pairing prompt asks the person at the Mac. If nobody is there,
    the phone waits 120 s; Retry (Workspaces) asks again on the same link,
    so an Allow given on the Mac since takes effect.
  - Prompt fatigue: hostd limits prompts per device id and in all, and a
    refusal silences that device id for 10 minutes whatever key it brings
    (PROTOCOL.md "Pairing"). The dialog can show the device's registration
    date (`registered_at_ms`).

## Tests

- Rust, acpmux (`cargo test -p acpmux`): `hub::approvers` unit tests (the
  fixed vector, every field change, expiry, revocation, bad sets) and four
  integration tests in `tests/person_allow.rs` against the real daemon:
  only the person enrolls; a signed allow counts once and stops when revoked;
  a signed answer covers exactly its answers.
- Rust, cmux-mobile-host (`cargo test -p cmux-mobile-host`): the fixed challenge vector,
  the standing rule, the `devices` control line, and two end-to-end tests over
  the fake signaling server: a token alone reaches no service, a forged
  signature asks nobody, the Mac's approval opens the link, the next link
  passes at once, a new approval key asks again, unpair reaches the app, and
  a refused phone is closed `denied`; channels opened behind `auth` wait for
  it and are refused when it fails (`channels_opened_after_auth_wait_for_it`);
  a failed `auth` does not refuse what another running one holds
  (`pairing::tests::waiters_follow_every_running_auth`).
- Swift, CmuxMobileLiveTests: the same vectors (canonical answers, payload, link
  challenge); the hub signs an allow and not a deny, and a cancelled Face ID
  sends nothing.
- Swift, CmuxNextMobileTests (`MobileHostPairingTests`): pairing events, decisions,
  the `devices` line and acpmux params, and the per-user 0600 file.

## Known gaps

- Chief over the link has no permission card yet (`live.md` finding 7). When
  it gets one, its Allow goes through `AcpmuxHub.respond` and is signed.
- Settings → Mobile rows for paired phones (with Remove) are for the Mobile
  page's owner (`feat-cnx-ios-machost`): the service publishes `paired` and
  `revokePhone(id:)`.
- On a Mac without PR https://github.com/manaflow-ai/cmux/pull/20491, the
  pairing prompt is only an app-scope cmux dialog. While cmux is not the
  active app, macOS may refuse its activation, and the dialog shows only when
  the person brings cmux forward. #20491 (`feat-cnx-ios-approvals`, f8afcd1d
  and later) adds a system notification with Review, a Dock bounce, and
  Settings → Mobile → Connection Requests. The phone's banner says "Look for
  cmux on your Mac", which is true with or without #20491.
- The dialog is excluded from screen capture (`CmuxDialogCaptureExcludedHost`),
  so the live record below has its accessibility text, not a picture.
- (Fixed 2026-10-14.) The Feed used to mark a permission "Allowed" before
  Face ID. It now says "Waiting for Face ID…" until the signed Allow went
  out; a cancelled or failed Face ID puts the card back with the reason.
- acpmux refuses a paired phone's answer for a session whose mode is not one
  of the harness's web asking modes, even when signed ("this session runs in
  mode normal, which does not ask before it acts …"). Real harnesses declare
  theirs; the live run's fake harness needed `webAskingModes`.

## Verification

### Automated (final head)

| Check | Where | Result |
| --- | --- | --- |
| `cargo test --workspace`, `cargo clippy --workspace --all-targets -D warnings`, `cargo fmt --check` (`cmux-next-ios/rust`) | local | pass (86 tests) |
| acpmux `cargo test -p acpmux` | Blacksmith Testbox | not run: the Blacksmith CLI is not installed on this Mac |
| CmuxMobileKit `swift build` | local, Xcode 27 | pass |
| CmuxMobileKit `swift test` | `mini-cmuxs-mac-mini-2`, Xcode 26.3 | 238 tests in 75 suites pass (`approvals/cmux_mobile_kit-swift-test.txt`); CmuxTabsKit built unpatched |
| CmuxNextMobile CmuxMobileHost and pairing tests (`MobileHostTests`, `MobileHostPairingTests`) | mini, the CmuxMobileHost sources in a standalone package (stub `CmuxNextWakeups` ledger) | 20 tests pass (`approvals/mac-cnxhost-swift-test.txt`) |
| iOS app, Production, generic iOS Simulator | local, `-jobs 4` | BUILD SUCCEEDED |
| cmux-next Mac app | fleet job `324bc2c9589b4c5077ddf403`, commit `82c49e22a702`, `cmux DEV cmux-mobile-approvals-fin` | done (aws-m4pro-3, 13.5 min) |

### Live (2026-10-14)

- **Mac:** `mini-cmuxs-mac-mini-2`, the fleet build above in the `cmux` GUI
  session, signed in with the DEBUG agent credential, Settings → Mobile on,
  `ACPMUX_HOME` with acpmux's credit-free fake agent as the default harness
  (`verify/scripts/approvals-mac.sh`). Approvals were raised with
  `acpmux new -m fake "ask: …"` / `"question: …"`.
- **Phone:** one headless simulator `cmux-mobile-approvals-fin` (iPhone 17 Pro, iOS
  26.5), Debug build, same account, pinned to that Mac
  (`-cmuxMobile.live.mac.<team> <id>`), `-cmux-mobile-demo approve` with a plan
  (`verify/scripts/approvals-phone.sh`). Face ID was enrolled, matched and
  failed with `simctl` BiometricKit notifications; Cancel was a real tap
  (`axe`). The user's own Macs were never paired or dialed.
- The Mac's pairing prompt was answered through its accessibility buttons,
  as a person clicks; `debug.dialog` cannot press it.

Evidence is in `verify/approvals/` (`live/`, `lock/`).

| Item | Result | Evidence |
| --- | --- | --- |
| First pair: the Mac asks | Pass. hostd held `version` and `daemon` behind `auth`; the Mac showed "Allow “cmux-mobile-approvals-fin” to connect to this Mac?", the account, and the device key fingerprint | `live/mac-1-pair-prompt-ax.txt`, `live/mac-hostd.log`, `live/mac-app-pairing.log` |
| Approve, then the link works | Pass. Allow → `paired`; the held channels and `acpmux`, `chief` were served; the Feed live; the next launch passed with no prompt | `live/p1-phone-2-paired-feed.png`, `live/phone-demo-steps.log` |
| Allow needs Face ID: no match | Pass. Allow raised Face ID; a failed face and Cancel sent nothing (acpmux kept the prompt `waiting`); the card says "Not approved: Face ID was cancelled." | `live/p1-phone-3-allow-faceid.png`, `live/p1-phone-4-nomatch.png`, `live/p1-phone-5-cancelled.png` |
| Allow needs Face ID: match | Pass. The signed allow counted: the agent replied `chose yes` | `live/p2-phone-1-allow-faceid.png`, `live/acpmux-replies.txt` |
| Answer needs Face ID | Pass. A question answer raised Face ID and counted with exactly its answer (`{"Which branch should I deploy?": "A"}`) | `live/p2-phone-3-answer-faceid.png`, `live/p2-phone-4-answered.png` |
| Deny unsigned | Pass. Deny went out while the Allow's Face ID sheet was still up, with no prompt of its own: `chose no` | `live/p2-phone-1-allow-faceid.png`, `live/acpmux-replies.txt` |
| Require Face ID | Pass. With the setting on, cmux opened behind Face ID; a failed face and Cancel kept it locked; a match unlocked it; leaving for Settings and coming back locked it again. Off, it opened unlocked | `lock/1-…` to `lock/5-…` |
| Refused key | Pass. A new phone key asked again; Don't Allow closed `auth` `denied`; the phone shows "cmux’s Mac mini (2) did not allow this iPhone"; the next link was refused in 11 ms with no new prompt, and the channels held behind it were refused `unpaired` | `live/mac-2-second-pair-prompt-ax.txt`, `live/p5-phone-1-denied.png`, `live/p6-phone-2-denied-banner.png`, `live/mac-hostd.log` |
| Sign-out unpairs (superseded 2026-10-14: sign-out keeps the pairing, and "Remove This iPhone from My Macs" sends this `unpair`; `verify/persistence.md`) | Pass after a fix (below). The phone's `auth` `unpair` reached the app: "phone ccf5433a signed out; forgetting it", and acpmux dropped it as an approver | `live/mac-app-pairing.log` |

Found and fixed during the run:

1. **Simulator keys.** iOS 26.5 simulators report a Secure Enclave
   (`SecureEnclave.isAvailable`) but refuse to make enclave keys
   (LocalAuthentication -1020), so DEBUG simulator pairing failed.
   `PhoneKeys` now never uses the enclave on a simulator.
2. **Sign-out did not unpair.** The link went idle as the session ended,
   before `signedOut()` asked the Mac to forget the phone, so the unpair never
   left. The unpair now runs in `willSignOut`, before the session ends
   (bounded with push unregistration to 3 s); `signedOut()` still deletes
   the keys.
3. **Fast connect with pairing** (merge of `feat-cnx-ios`): hostd refused the
   channels the phone opened in parallel with `auth`. They now wait for it.

Not run: an unsigned Allow from a phone against the live Mac (the phone
never sends one); acpmux's `person_allow.rs` covers it. The acpmux suite on
the Testbox (above).
