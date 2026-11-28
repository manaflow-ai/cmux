# Mac presence on a cold open

Leo, 2026-11-21: "isn't there some sort of like, you know, ultra light keep alive that we can have
on our own servers, right? ... Or I mean, of course like barring that, of course, it's just like,
well just connect the fucking shit from iOS to Mac. Like just do it well, do it properly"

The goal: within about 1 s of opening the app, the phone knows whether its Mac is up, and it has
a fresh route before the person taps. Direct iPhone to Mac when it can reach it, relay otherwise.

The light keepalive already exists. Each Mac host sends a text `ping` every 15 s on its signaling
socket. The hub answers it with `pong` as a hibernation auto-response: the Durable Object never
wakes, and the runtime keeps the ping's time. Until now the phone was never told that time. This
design gives it that, and stops the phone waiting on a cached answer.

## Where the server lives

The phone's signaling socket (`/v1/teams/:id/signal`, `hello` and `presence`) is the `TeamHub`
Durable Object in `cmux-next-ios/backend/src/team-hub.ts`, one per user. `workers/device-hub` is a
different service (the remote screen share hub, `UserDO`). It has its own 75 s silence sweep, but the
iPhone app never talks to it. Everything below is about `cmux-next-ios/backend`.

## What a cold open costs today

The phone has a launch snapshot (`LiveSnapshotStore`), so this is the common case. Each step names
its `ConnectTimeline` mark (`timing launch <mark>` in the device log). I found no recorded
on-device numbers for the network steps in the repo, so this lists what each step waits on. Measure
it from the device log of a cold launch.

| Step | Mark | What it waits on |
| --- | --- | --- |
| Snapshot | `snapshot_restored` | Local disk only. Shows the Macs with the `isOnline` saved last time. |
| Link socket | `prewarmed` | Token from the Keychain, then TLS and the upgrade to the Worker, a token check, and the hub's accept. The hub sends `hello` with live presence. The link's Rust client drops that `hello`: nothing reads it. |
| Retarget | none | `LinkMachine.target` picks the remembered Mac. It dials only when the cached `isOnline` is true. Otherwise the phase is `macOffline` and nothing dials. |
| Bootstrap | `registered`, `macs_loaded` | `POST /v1/me/bootstrap`: two device registrations (database writes and hub calls), the team's Macs, the account's Macs (a Stack team list), and ICE, all at once. It returns when the slowest part does. The Server-Timing example in PROTOCOL.md shows `db` at 82 ms of a 101 ms request. Stack adds more on a cold isolate. |
| Presence socket | none | Starts only after bootstrap (`startPresence`). A second TLS connection and upgrade, then a second `hello`. |
| First dial | `dial_start`, `endpoints_gathered`, `wg_init_sent`, `wg_resp_received`, `link_ready`, `link_connected` | The phone's STUN gather (one round trip, 150 ms grace for a second server, 1.5 s at most) with a TURN allocation beside it. Then `wg-init` through the hub, the Mac's own STUN gather, `wg-resp` back, the WireGuard handshake, route confirmation, and the TCP stream to `10.77.0.1:7420`. |
| Daemon | `daemon_channel_open`, `first_daemon_response` | The daemon channel over the link, then its first answer. |
| First terminal frame | none | The terminal's attach and replay. No mark times it yet (`workspace_row_live` is the list row, not the terminal). |

## Why a stale snapshot says offline

The snapshot saves each Mac's `isOnline` when it was last written (`scheduleSnapshotSave`, after
`applyMacs`). A Mac that slept, restarted, or lost its socket to a Worker deploy at that moment is
saved as offline. At the next launch `retarget()` finds no online target. `LinkMachine` resets to
`macOffline` and does not dial. The Mac's real state arrives only with bootstrap's `macs_loaded`,
one full bootstrap later. Then the dial starts from zero.

It also fails the other way. The hub's `online` means "the socket is open". A sleeping Mac keeps
its socket half open, and `TeamHub` has no silence sweep, so `online` stays true for minutes. A
cached or live `online: true` then sends `wg-init` into a dead socket. The phone waits out the 8 s
`answer_timeout` before it says anything.

So `online` alone can't answer "is the Mac up right now", cached or not.

## Ideas considered

**(a) Freshness in every Mac listing.** The hub already keeps each Mac socket's last ping time
(`getWebSocketAutoResponseTimestamp`, used by connectivity alerts). It can add `quietMs`, the ms
since it last heard the Mac, to `hello`, `presence` and the Mac routes, and so to bootstrap.
`quietMs` is relative to the hub's own clock, so the phone's clock doesn't matter. Under 18 s (the
link's `FRESH_WITHIN`) means awake. Past it means online but likely asleep. It costs nothing per
ping, and old phones ignore the field. Adopted.

**(b) Never gate the first dial on the cached `isOnline`.** At launch, dial the focused Mac from the
snapshot alongside the link socket's open, whatever the cache says. The dial asks the truth itself:
the hub answers `wg-init` to a Mac with no open socket with `error offline` at once, one hub round
trip. Also read the `hello` the prewarmed link socket already gets, and apply its `quietMs`,
instead of waiting for bootstrap and a second socket. Adopted: this is most of the win.

**(c) Pre-introduction.** When the phone's socket says hello, the hub tells the focused Mac to
gather STUN and publish fresh WireGuard endpoints. This saves only the Mac's own STUN gather, about
one round trip, because the Mac's socket is already warm from its 15 s pings. The hub also doesn't
know which Mac the phone will focus, so it would wake every Mac of the user on every phone open.
Not now. If measurements show the Mac's gather in the critical path, add it as a phone-sent
`warm` signal (an unknown kind that older Macs ignore), not as a hub broadcast.

**(d) APNs or background work.** Not needed. The person opens the app in the foreground, and the
signaling socket answers in one round trip. A silent push can't make the Mac's state fresher than
the hub already has it. Background App Refresh could refresh the snapshot, but (a) and (b) make a
stale snapshot harmless, so that would add cost for nothing.

## The design

Adopt (a) and (b).

1. **Hub** (done in this change). Each online Mac in `hello.macs`, `presence`,
   `GET /v1/teams/:teamId/macs` and `GET /v1/me/macs` (so also `POST /v1/me/bootstrap`) carries
   `quietMs`. It is the time since the hub last heard that socket, from its connect or its last
   application ping. It is absent for an offline Mac and from an older hub. Nothing else changes.
   - `cmux-next-ios/backend/src/team-hub.ts`: `MacPresence.quietMs`, `FRESH_MS`, `quietMs()`.
   - `cmux-next-ios/backend/src/index.ts`: `quietOf` in the two Mac routes.
   - `cmux-next-ios/backend/test/mac-freshness.test.ts`, `test/me.test.ts`.
   - `cmux-next-ios/PROTOCOL.md`: "Mac freshness".
2. **Link client** (Rust). Add `quiet_ms: Option<u64>` to `MacPresence` in
   `cmux-next-ios/rust/crates/cmux-mobile-link/src/signaling.rs`. Surface the link socket's
   `SignalingEvent::Hello` through `cmux-mobile-link-ffi` to Swift, so the prewarmed socket's
   `hello` is the first presence the phone applies. Fresh-or-not is a Rust function
   (`quiet_ms < FRESH_WITHIN`), per the language rule.
3. **Phone** (Swift glue).
   - `LiveAPI.Mac` (`CmuxMobileLive/LiveAPI.swift`): decode `quietMs`.
   - `MacDevice` gets a freshness: `fresh`, `stale` (online but quiet past 18 s), `offline`, or
     `unknown` (from the cache, or from an older hub).
   - `LiveCoordinator.restoreSnapshot` marks restored Macs `unknown`, not offline. `LinkMachine`
     dials an `unknown` target, and treats an `offline` error for that dial as the answer
     (`macOffline`, no retry loop). A `stale` Mac gets one dial with a short answer timeout.
   - `LiveCoordinator.startTeam` starts `startPresence` together with bootstrap, not after it.
   - The link socket's `hello` is applied like the presence `hello` (`applyMacs`).
   - These touch `LinkMachine.swift`, `LiveCoordinator.swift` and `LiveCoordinator+Links.swift`.
     The parent lane is editing those, so this change leaves them alone.
4. **Measure.** Add a `presence_fresh` mark when the first listing with `quietMs` arrives. Report
   launch to `presence_fresh` and launch to `link_connected`, with a fresh and with a stale
   snapshot, from one device and harness, before and after.

Expected result. The truth arrives with the first socket's `hello`: one TLS connection plus an
upgrade after the token, about the time of `prewarmed`. That no longer waits on bootstrap and a
second socket. A stale "offline" cache no longer delays the dial. A sleeping Mac is reported
asleep at once, instead of after an 8 s timeout. The route is direct when STUN finds one, TURN
when not, as today.

## What this doesn't change

The hub's `online` stays "the socket is open", and its socket closing rules stay. Admission,
signaling, and the dial's route order (direct UDP, TURN over UDP, TURN over TLS) stay. No API
version bump: the field is additive, like `machineId` was.
