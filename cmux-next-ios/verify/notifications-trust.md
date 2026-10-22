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
| Phone push key (P-256 ECDH, Secure Enclave, after first unlock, shared with the service extension) | phone | yes | sealed pushes are opened with it |

The phone sends its push key on every `auth`, with a statement signed by its
identity key; hostd keeps it per paired phone. The Mac sends its box key with
its identity signature in the `auth` challenge; the phone pins it under the
Mac's pinned identity key.

## What the Mac checks before it applies a mailbox reply

In this order; the first failure rejects the reply and reports why:

1. It opens: sealed to this Mac's box key, for this Mac's device id.
2. The phone it names is the one the Worker stamped as the sender, is on the
   Mac's paired list with that identity key, and is neither denied nor
   removed.
3. The phone's identity signature verifies over the canonical reply.
4. It has not expired (`expiresAt` after now and at most 10 minutes ahead).
5. Its id and nonce were never seen (a spent set kept until the expiry
   passes, on disk so a restart does not forget it).
6. Its target is still pending: the question or permission is waiting with
   that permission id (an Allow or an answer carries the acpmux signature,
   which acpmux checks again against its decision nonce, daemon run and
   option); a text reply's session exists; a terminal reply's tab exists and
   its notification is still in the ledger.

Then hostd applies it on its own connection, the same request the phone would
send over the link, through the same policy.

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
>    has not expired (10 minutes at most) and it was never applied before. An
>    Allow or an answer still needs Face ID and the acpmux approval signature,
>    as in the app. The service can delay or drop a reply, and sees its size,
>    timing and target Mac. It can't read, change, forge or replay one.
> 2. **Terminal input from a notification.** Any program in a cmux terminal
>    can raise a notification (OSC 9, 777, 99). Replying sends the text to that
>    terminal as typed input, including from the lock screen after the device
>    is unlocked (Face ID or passcode). A program can word a notification to
>    invite a dangerous reply; the reply is text the person typed, never text
>    the notification supplies, and it only goes to the terminal that asked.
>
> Sealed payloads (the Mac encrypts notification content to the phone) only
> narrow what the service and Apple see, and need no decision.
>
> **Recommendation: approve both,** with these limits kept as tests: a reply
> is at most 4 KB of text, valid 10 minutes, applied once, only to the
> question, permission, session or terminal it names, and only from a phone
> the Mac paired; terminal replies need device unlock; Allow and answers need
> Face ID. Reply "approve the notification fallback" or "keep replies on the
> live link only".

## Verification

See `verify/push-matrix.md` (rows marked PR B) and the tests listed in the PR.
