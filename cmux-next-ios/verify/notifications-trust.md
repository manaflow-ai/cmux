# Notification replies: the encrypted fallback, sealed payloads and terminal input

Branch `feat-cmux-next-ios-push-fallback` (PR B, stacked on the rich push
PR A). Not merged until the person approves the #13742 recommendation below.
The wire format is PROTOCOL.md "Sealed pushes and the reply mailbox"; the
threat model is SECURITY.md "Notification replies".

## What changes

PR A answers a notification only over the Mac's own link (WireGuard, one per
Mac). PR B adds three things:

1. **Sealed notification content.** The Mac encrypts each notification to
   each paired phone's push key and signs it with its identity key. A
   Notification Service Extension on the phone checks the signature against
   the Mac key it pinned at pairing and decrypts. The Worker and APNs see the
   kind, ids, ciphertext and a generic banner ("cmux", "New notification
   from <Mac>").
2. **A reply mailbox.** When the link misses its 4 s budget, or the app
   cannot reach the Mac at all, the phone seals the reply to the Mac's box key,
   signs it with its identity key, and posts it to the Worker. The Worker holds
   it for at most 10 minutes in the user's hub and hands it to the Mac's
   signaling socket. It never holds a key that opens it.
3. **Terminal input from a notification.** A terminal notification (OSC 9,
   777, 99) gets a Reply field. The text goes to that terminal, over the link
   or the mailbox. The action needs the device unlocked.

## Keys

| Key | Where | New? | Used for |
| --- | --- | --- | --- |
| Mac identity (P-256 ECDSA) | the Mac app's Keychain, handed to hostd (`mac_identity`) | no | signs sealed pushes, signs the box key |
| Mac box key (P-256 ECDH) | derived by hostd from the identity key (HKDF, `cmux-mobile-mac-box-v1`) | yes, no new storage | replies are sealed to it |
| Phone identity (P-256, Secure Enclave, no prompt) | phone | no | signs replies and the push key statement |
| Phone approval (Secure Enclave, Face ID) | phone | no | signs an Allow or an answer for acpmux, as in-app |
| Phone push key (P-256 ECDH, Secure Enclave, after first unlock, shared with the service and content extensions) | phone | yes | sealed pushes are opened with it |

The phone sends its push key on every `auth`, with a statement signed by its
identity key; hostd keeps it per paired phone. The Mac sends its box key with
its identity signature in the `auth` challenge; the phone pins it under the
Mac's pinned identity key.

## What the Mac checks before it applies a mailbox reply

In this order; the first failure rejects the reply and reports why:

1. It opens: sealed to this Mac's box key, for this Mac's device id, the
   sender the Worker stamped and the item's id.
2. The phone it names is on the Mac's paired list with that identity key, and
   is neither denied nor removed (checked on every reply).
3. The phone's identity signature verifies over the canonical reply.
4. It has not expired: `expiresAt` is after now, at most 600 s after
   `issuedAt`, and at most 660 s after the Mac's clock (60 s for a phone clock
   that runs ahead).
5. Its id and nonce were never seen. Spent ids and nonces are kept on disk
   until they expire, each id with its outcome; a repeat of a settled id
   answers that first outcome again (so a lost ack never turns into a false
   "applied"), and a file that can't be read applies nothing (fail closed).
6. Its target is still pending: the question or permission is waiting with
   that permission id (an Allow carries the acpmux signature, which acpmux
   checks again against its decision nonce, daemon run and option); a text
   reply's session exists; a terminal reply's notification is still in the
   ledger on that tab, asked for replies, is at most 15 minutes old, and the
   program that posted it (its process-group leader and executable, recorded
   by the daemon when it was posted) still holds the terminal.

Then hostd applies it on its own connection, the same request the phone would
send over the link, through the same policy. A reply hostd can't settle yet
(its app has not sent its keys or paired list, a service is not reachable) is
neither spent nor acknowledged: it stays queued and is tried again.

Every outcome the Mac reports is signed by its identity key; the phone takes
"applied" or a refusal only with that signature, checked against the key it
pinned. The service alone can't make the phone believe a reply was applied.

## The phone (`push-fallback-ios`)

- **Which replies use the mailbox.** A text reply (a finished turn, an error,
  Chief, a terminal), a Deny, and an Allow from a sealed push. An Allow is a
  foreground action: the app opens, asks Face ID once, and signs the acpmux
  approval with the `decisionNonce` and `personInstance` the sealed push
  carried (valid 290 s; acpmux takes at most 300). A question's answers need
  the prompt the link reads, so they never go through the mailbox, and an
  unsealed push's Allow can't either; both say "Couldn't reach <Mac>" with
  Retry. Attachments stay on the link.
- **When.** Only after the link missed its 4 s budget (or the cold-launch
  budget), or failed mid-send. "Couldn't reach <Mac>" shows only when the
  mailbox also failed. The phone then asks after 1, 2, 4 and 8 s what the Mac
  did; it shows the Mac's signed refusal, "<Mac> didn't pick up your reply in
  time" when it expired, or "Not confirmed by <Mac>" while nothing signed came
  back.
- **A reply's window.** 540 s from when the person made it. Retry re-seals it
  with the same window, never a new one; past it, the phone says the reply is
  too old.
- **Terminal input needs the device unlocked.** The terminal Reply action is
  an `authenticationRequired` text action: iOS asks for Face ID or the
  passcode before it hands the text to cmux, on the lock screen too. It is
  offered only for a notification whose poster asked for a reply
  (`notify --reply`, `replyable`), it carries that notification's ledger id,
  and it is text only, at most 4096 bytes. The long-press view has no
  composer for a terminal, and the App Group outbox refuses terminal text
  (anything there may have been written while the phone was locked); the app
  drops any it finds.
- **Which pushes act.** Once a Mac proved a box key after this phone gave it a
  push key, the phone acts on no unsealed push that names that Mac: it shows
  the generic banner, no buttons, and a tap only opens the app. A sealed push
  is opened again from its box when a button is pressed (the service
  extension keeps the box beside the content it wrote), so content the
  service made up is never what an answer is built from. A push older than 15
  minutes keeps its text and tap but loses its buttons.
- **Keys.** The push key is a Secure Enclave key-agreement key (a software key
  on the simulator), readable after the first unlock so the service extension
  can open pushes on a locked phone. It and the trust record (each paired
  Mac's pinned identity key, its box key and the box key's signature) live in
  the keychain group `<team>.<app bundle id>.push`, shared with
  `CmuxMobileNotificationService` and `CmuxMobileNotificationContent` (which only
  reads: it opens the box again before the long look shows rows or buttons). Before each reply the box key's signature
  is checked again against the identity key pinned for that Mac (`MacPins`,
  the app's own store), so a changed keychain entry can't redirect replies.
  Removing a Mac forgets its entry; "Remove This iPhone from My Macs" and
  account deletion delete the key.

## Residual risks

- **Availability.** The service can delay, drop or reorder replies and
  pushes, and fill a Mac's queue (32 pending, 60 posts a minute per user)
  with replies the Mac then rejects, for up to 10 minutes. The phone says
  "Not confirmed" or "Couldn't reach"; nothing wrong is applied.
- **First pairing.** Trust is set on first use: a service that sat in the
  middle of a phone's *first* pairing with a Mac could pin its own identity
  and box keys, then read that phone's mailbox replies and forge its sealed
  pushes. Later pairings are checked against the pin. Binding pairing to the
  transport keys (channel binding) is the follow-up already noted in
  `phone-approvals.md`.
- **Phones without a push key.** An older app (or one whose push key did not
  verify) gets plain content, readable by the service and APNs, as in PR A.
  Every phone with a key gets only boxes.
- **What the service still sees.** Kinds, ids, sizes, timing, the target Mac
  and its name.
- **Terminal text.** A program can word a notification to invite a harmful
  reply. The reply is text the person typed, goes only to the program that
  posted that notification (the same pid and executable) while it still holds its
  terminal, and needs the device unlocked. On a terminal where an agent runs (a
  hook's notification, or `cmux notify --reply` posted from inside the agent), the
  reply is one write bound to that agent's session that the daemon makes only while
  the agent waits at its prompt (`send-expect-agent-v1`), so a Return never lands on
  an approval dialog; a Mac without it, or an agent whose session is unknown, takes
  no reply.
- **Mailbox outcomes.** The Mac signs its outcome over the reply's id, not the
  sealed blob: a service that delivers junk under a real reply's id gets a signed
  rejection, and the phone says the reply wasn't accepted although it never
  arrived. That is the same as the service dropping the reply (availability).

## Recommendation for #13742 (draft, not posted)

> **Trust call: replies to cmux notifications on iPhone without the live link
> (`feat-cmux-next-ios-push-fallback`)**
>
> The cmux iPhone app now answers agent questions, permission requests,
> finished turns, Chief and terminal notifications from the notification
> itself. Over the Mac's own link this adds no new trust (PR A). Two parts do,
> and need a decision before they land:
>
> 1. **Backend-relayed replies.** When the phone can't reach the Mac within a
>    few seconds, the reply goes through the cmux service, sealed to the Mac's
>    key and signed by the phone's Secure Enclave key. The Mac applies it only
>    when the signature is a paired phone's, the target is still pending, it
>    is at most 9 minutes old from when the person sent it (a Retry doesn't
>    extend that; the Mac itself accepts at most 10), and it was never applied
>    before. An Allow still needs Face
>    ID and the acpmux approval signature, as in the app; question answers
>    never take this path (the phone sends none; an answer the Mac received
>    would still need the Face ID approval signature). The Mac signs what it did with each reply, so the
>    phone shows "applied" only on the Mac's word. The service can delay,
>    drop or flood replies (up to 10 minutes, then they expire), and sees
>    their size, timing and target Mac. It can't read, change, forge or
>    replay one, or claim one was applied.
> 2. **Terminal input from a notification.** A program in a cmux terminal that
>    asks for replies (`cmux notify --reply`) gets a Reply button. The text
>    goes as typed input only to the program that posted that notification,
>    only while it (the same pid and executable) still holds the terminal,
>    within 15 minutes, and only after the device is unlocked (Face ID or
>    passcode), from the lock screen too. On a terminal where an agent runs, it
>    goes only while that agent waits at its prompt, never onto an approval
>    dialog. No free text typed into the long-press view reaches a terminal; a
>    terminal agent's question answered there is typed as its option keys,
>    after unlock and only while the terminal shows that very question. A
>    program can word its notification to invite a harmful reply; what is sent
>    is only what the person typed.
>
> Sealed payloads (the Mac encrypts notification content to the phone; the phone
> ignores unsealed pushes from that Mac, and a sealed push acts only under the
> banner and buttons the phone itself wrote from it) only narrow what the service
> and Apple see and can steer, and need no decision.
>
> Residual risks: a service in the middle of a phone's first pairing with a
> Mac could read its replies (trust on first use, as pairing already is);
> phones with an older app still get plain content; the service controls
> availability.
>
> **Recommendation: approve both,** with these limits kept as tests: a reply
> is at most 4 KB of text, valid 9 minutes from when it was made, applied
> once, only to the question, permission, session or terminal program it
> names, and only from a phone the Mac pairs now; terminal replies need
> device unlock and the posting program; Allow needs Face ID. Reply "approve
> the notification fallback" or "keep replies on the live link only".

## Verification

See `verify/push-matrix.md` (rows marked PR B) and the tests listed in the PR.
