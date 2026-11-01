# cmux-next-ios wire contract (v1)

Shared by `cmux-next-ios/backend` (Cloudflare Worker), `cmux-next-ios/rust` (link, hostd,
ffi) and the app. Change this file first, then the implementations.

## Names (API 0.11.0)

The app was built under the development tag "cnx". On 2026-10-20 every wire name moved to
production naming in one step, with no period in which both are accepted: nothing had
shipped outside internal TestFlight, and builds up to 1.2.0 stop connecting once the Worker
and the Mac host run 0.11.0 (internal testers update to the next TestFlight build).

| What | Up to 0.10.0 | From 0.11.0 |
| --- | --- | --- |
| WebSocket subprotocol | `cnx.v1` | `cmux-mobile.v1` |
| Phone approval signature context | `cnx-link-auth-v1` | `cmux-mobile-link-auth-v1` |
| Mac identity signature context | `cnx-mac-identity-v1` | `cmux-mobile-mac-identity-v1` |
| Chief answer signature context | `cnx-chief-answer-v1` | `cmux-mobile-chief-answer-v1` |
| H.264 SEI tag UUID | `cnx-video-tag-v1` | `cmux-mobile-vid1` (16 bytes) |
| Worker to hub headers | `x-cnx-claim`, `x-cnx-subprotocol`, `x-cnx-attachment`, `x-cnx-owner-key` | `x-cmux-mobile-claim`, `x-cmux-mobile-subprotocol`, `x-cmux-mobile-attachment`, `x-cmux-mobile-owner-key` |
| WebRTC data channel labels | `cnx-link`, `cnx-input` | `cmux-mobile-link`, `cmux-mobile-input` |
| Push payload key, categories | `cnx`, `CNX_<KIND>` | `cmuxMobile`, `CMUX_MOBILE_<KIND>` |
| Host supervision variable | `CNX_CONTROL=stdio` | `CMUX_MOBILE_CONTROL=stdio` |
| Hosts | `cnx-ios-api.cmux.dev`, `cnx-ios-api-dev.debussy.workers.dev` | `mobile-api.cmux.dev`, `cmux-mobile-api-dev.debussy.workers.dev` |

Signatures are made and checked over the new contexts only. A phone's identity and
approval keys are unchanged, so a Mac keeps its approvals: it stores keys, not signatures.

## Identity and auth

- Every HTTP call and WebSocket carries `Authorization: Bearer <Stack access token>`
  (WebSocket may use subprotocol `cmux-mobile.v1, bearer.<token>` instead).
  The Worker verifies the JWT against the Stack JWKS of one of its configured
  projects and takes `sub` as `userId`. The dev Worker accepts the dev project
  `454ecd03-1db2-4050-845e-4ce5b0cd9895` (primary) and the production project
  `9790718f-14cd-4f7e-824d-eaf527a82b82`, so dev and production app builds share
  it. The token's `iss` picks the project; signature, `iss`
  (`https://api.stack-auth.com/api/v1/projects/<id>`) and `aud` (`<id>`) are then
  checked against that project only. Other projects, anonymous users,
  restricted users (Stack's `is_restricted`, e.g. sign-up not finished; their
  tokens are signed by keys outside the default JWKS) and mismatched
  `iss`/`aud` pairs get 401. A token whose `kid` is missing from the cached
  JWKS, or a JWKS fetch that failed, refetches the project's keys once at
  once and verifies again (no 30 s cooldown on that path).
- A user is the pair (Stack project, `sub`): the same `sub` in two projects is
  two users. Membership is asked of the caller's own project with the caller's
  own token; a team, a personal space, device ownership and link admission
  never span projects. Stored rows record the project in the owner key
  (`<sub>` for the primary project, `<projectId>:<sub>` otherwise; Stack subs
  are UUIDs and never contain `:`), and the caller's hub is named
  `user:<owner key>` (below). Every `userId`/`ownerUserId`/
  `fromUserId` on the wire stays the bare `sub`.
- Team membership is checked through Stack (cached 60 s, refusals 15 s, per
  team in the caller's own hub): the server API when the Worker has `STACK_SECRET_SERVER_KEY`,
  otherwise the client API (`GET /teams?user_id=me`) with the caller's own
  access token. (Changed: no Stack server key is provisioned for cmux-next-ios, so the
  caller-token path is the default.) v1 admission rule for a link: phone and Mac must belong to the
  same Stack user (the Mac's registering user). Team members cannot dial
  each other's Macs in v1.
- Personal space: teamId `personal-<userId>` (userId = the verified JWT `sub`)
  is a team of one. The id carries no project: Stack subs are random v4 UUIDs, so
  a dev and a production user never share one in practice, and the space behind
  the id is still per project (above), so even a shared sub would give two
  separate spaces. It is admitted for that user only, with no Stack membership
  call; any other user gets `403 not_member`. Every route works with it
  (devices, macs, prefs, signal WebSocket) except
  `POST /v1/teams/:teamId/invites`, which answers `400 bad_request`
  "personal space has no members". Use it when the user has no Stack team.
- Devices: `deviceId` is a client-generated UUID persisted in Keychain;
  `kind` is `mac` or `phone`. A phone keeps one pair of ids (link, presence)
  per account and keeps them across sign-out (`verify/persistence.md`).
- Machine id (added 2026-10-21): each cmux build on a Mac is its own device
  (its own id in its own Application Support folder, its own identity key and
  paired phones), so a Mac running a nightly and a dev build, or one that kept
  a deleted build's record, is on the account more than once. A Mac registers
  `machineId`, the same for every build on that computer: HMAC-SHA256 under
  the key `cmux-mobile machine-id v1` of `<owner sub> NUL <16-byte host UUID>`
  (`gethostuuid`, the IOPlatformUUID), first 16 bytes in lowercase hex. The
  hardware id never leaves the Mac, and two accounts on one Mac get unrelated
  ids. The phone lists one Mac per (owner, machine id), by its most recently
  active build. The other builds stay in Settings → Devices, marked "Another
  cmux build on this Mac"; one links only while something names it (a Feed
  answer or notification of that build) and closes after the idle window. A name is never an
  identity: Macs that share a name stay separate (with the name tag), and a
  Mac with no `machineId` (an older host) is never folded into another.
  Builds stay separate devices on purpose: one shared device id would make
  two running builds replace each other's signaling socket (4000 `replaced`),
  and would make a debug build hold the identity key phones pin for the
  release build.

## HTTP (base: production `https://mobile-api.cmux.dev`, dev `https://cmux-mobile-api-dev.debussy.workers.dev`)

The production Worker `cmux-mobile-api-prod` accepts only the production Stack
project `9790718f-14cd-4f7e-824d-eaf527a82b82` and uses its own database
(PlanetScale `cmux/cmux-next-ios-prod`). The dev Worker accepts both projects for
testing. Production and Release app builds, the Mac app's Release build and
`run-host.sh` default to the production URL.

Errors are `{"error":{"code","message"}}` with codes `unauthorized` (401; the
message ends with the reason in parentheses, one of `malformed`,
`unknown_project`, `expired`, `not_yet_valid`, `bad_claims`, `unknown_key`,
`keys_unavailable`, `bad_signature`, `anonymous`, `restricted`, and never
echoes the token),
`bad_request` (400), `not_member` / `not_owner` / `wrong_team` (403), `not_found` (404),
`rate_limited` (429, with `retry-after` seconds; 0.7.0 per-user limits: 300 requests a minute overall, 30 `GET /v1/ice`, 10 invites, 60 notifications per Mac),
`conflict` (409, 0.14.0: a mailbox item id reused with another blob), `membership_unavailable` / `invite_failed` / `hub_unavailable` (502; `hub_unavailable` since 0.10.0 when the caller's hub refuses a signaling socket for an internal reason).

| Method + path | Body / result |
| --- | --- |
| `POST /v1/devices` | `{deviceId, kind, name, teamId, wgPublicKey?, machineId?, siblingDeviceIds?}` → `{device:{deviceId,ownerUserId,teamId,kind,name,wgPublicKey,machineId?,createdAt,updatedAt,lastSeenAt}}` (upsert; caller must be a team member; a deviceId owned by another user is `403 not_owner`). `machineId` (added 2026-10-21, "Machine id" above; every Mac list, `hello` and `presence` carries it, and omits the key for a Mac that has none) is a Mac's only: 32 lowercase hex digits, else `400`; omitted keeps the stored one. `siblingDeviceIds` (with `machineId`, at most 16 UUIDs) are the device ids of other cmux builds found on the same Mac (their `device-id` files): each that is a Mac of the caller with no machine id yet gets this one, so a deleted build's record is listed as that computer's; another owner's device, a phone or a Mac that reported its own machine id is never changed |
| `GET /v1/teams/:teamId/macs` | → `{macs:[{deviceId,name,online,lastSeenAt,ownerUserId,machineId}]}`: the caller's own Macs registered in `teamId` (caller must be a member). Changed in 0.10.0: a teammate's Macs are never listed (before, every Mac of the team was), so `ownerUserId` is always the caller |
| `GET /v1/me/macs` | → `{macs:[{deviceId,name,teamId,online,lastSeenAt,ownerUserId,machineId}]}`: the caller's own Macs (registered by the caller, the only Macs v1 lets it dial) in every team the caller still belongs to and in its personal space, with presence from the caller's hub. Added in 0.5.0 so a phone finds its Mac whichever team either side has selected; the app polls it (every 4 s while its active team has no online Mac, else every 30 s) and moves to the team of an online Mac. `502 membership_unavailable` when Stack cannot list the caller's teams |
| `GET /v1/teams/:teamId/prefs` | → `{color, emoji, transparent}` for the caller (per user per team; `transparent` added in 0.12.0, always `false` without an icon) |
| `PUT /v1/teams/:teamId/prefs` | `{color?: "#RRGGBB", emoji?: string\|null, transparent?: boolean}`. `emoji` is the avatar glyph: `null` = automatic (team initial), `""` = none (color only), otherwise exactly one grapheme (letter, digit, symbol or emoji; not whitespace). `transparent` (0.12.0) draws that grapheme with no background; `true` needs one (`400` otherwise; `false` is always accepted), `color` stays stored as the fallback for clients that predate it, an `emoji` change to `null` or `""` turns it off, and a PUT that sets `color` without `transparent` (any older build) turns it off. Answers the stored `{color, emoji, transparent}` |
| `POST /v1/teams` | `{name}` (1 to 64 characters, trimmed, no control characters; 3 a minute per user) → `{team:{id,name}}`: creates a Stack team with the caller as creator and first member, using the project's server key (Stack refuses client-side team creation), then grants the caller `team_admin` so the web team settings treat them as its admin. If that grant fails, the team is deleted again and the route answers `502 team_create_failed`. `503 team_creation_unavailable` when the Worker has no server key for the caller's project; `403`/`502 team_create_failed` when Stack refuses. New clients list, create, rename and delete teams through the web team API (`/api/teams`, docs/team-settings-and-invites.md); this route stays for older builds. |
| `POST /v1/teams/:teamId/invites` | `{email}` → `{url, sent:true}`: Stack emails a team invitation whose link opens `url` (the configured callback) with the code. Changed from a bare link: without a Stack server key the API can only send the invitation email, not mint a shareable link. Needs the caller's `$invite_members` team permission. |
| `GET /v1/ice` | → `{iceServers:[{urls:[...],username?,credential?}], ttl, turn}` from the Cloudflare TURN key (generate-ice-servers), STUN `stun:stun.cloudflare.com:3478` always included (STUN only if TURN is unavailable). `turn` (0.7.0) is `false` when no TURN server could be included: clients must say so (off-LAN WebRTC may then fail) instead of failing silently. `ttl` is 1 h (was 4 h) |
| `GET /v1/me/devices` | → `{devices:[{deviceId,kind,name,teamId,createdAt,updatedAt,lastSeenAt,online,machineId,push}]}` (0.7.0): every Mac and phone the caller registered, in any team or personal space. `online` is live presence for Macs and `null` for phones; `push` is whether the phone has an APNs token |
| `DELETE /v1/devices/:deviceId` | → `{deleted:true, deviceId}` (0.7.0). Owner only (`403 not_owner`, `404 not_found`). Deletes the row and its push token; the owner's hub drops the Mac from presence (broadcasting `presence` with `removed:true`), closes the device's signaling socket with code 4002 `removed`, and ends its signaling sessions. A removed device that registers again is a new registration: removal tidies stale devices, it does not ban an id. Used by the phone (Settings → Connection → Macs / Phones) and by the Mac app ("Unpair this Mac") |
| `PUT /v1/devices/:deviceId/push` | `{token, environment, topic, kinds?}` → `{push:{environment,topic,kinds,updatedAt}}` (0.7.0). Phone only, owner only. `token` is the APNs device token in hex (64 to 200 hex digits), `environment` `sandbox` or `production` (the app's `aps-environment`), `topic` its bundle id, which must be one of the Worker's `APNS_TOPICS`. `kinds` is which events to push (default all): `question`, `permission`, `completed`, `failed`, `chief` |
| `DELETE /v1/devices/:deviceId/push` | → `{deleted:true}` (0.7.0): stop pushing to this phone (sign-out, notifications turned off) |
| `POST /v1/devices/:deviceId/notify` | `{eventId, kind, agent?, place?, workspaceId?, tabId?, sessionId?}` → `{configured, sent, failed, dropped, coalesced?}` (0.7.0). `:deviceId` is a Mac the caller owns. Pushes one event to every phone of the same owner that registered a token and wants that `kind`. Content minimization: the Mac sends only a kind, a short agent name (≤ 40 characters) and a short place such as the workspace title (≤ 60); the Worker writes the text itself ("Claude has a question", "Claude needs permission", "Claude finished", "Claude stopped with an error", "Chief replied") with the place as the body, and never forwards agent output, prompts, tool arguments or paths. The payload's `mobile` object carries `{mac, kind, eventId, workspaceId, tabId, sessionId}` so a tap opens that tab. APNs `thread-id` is the `sessionId`, so a phone groups a session's notifications (0.13.0: `<mac>:<sessionId>` and the other fields of "Push notifications" below, which also add the answer's `wants`). The collapse id is `eventId` (≤ 64) for a question or permission; for a finished turn, an error or a Chief reply it is one id per session (`turn-<sessionId>`, hashed when longer than 64), so a newer one replaces the older. The Worker passes at most one turn-ending event per Mac, session and finished-or-error in 15 s, once some phone wants the kind (the user hub's `turnPushAllowed`); the rest answer `{sent: 0, coalesced: true}`. The Mac reports only what a person can act on (`cmux-mobile-host` `notify.rs`): never a Chief's compactor (`cmux.chief.role` `compactor`, or an `optchat-compact-` name, preset or folder); a Chief turn session (`cmux.chief`) as `chief`, once per Chief; no finished turn of a sub-session or a Chief's child (their asks still push); and per session at most one finished turn and one error in 30 s, the newest held one sent when the window ends. `configured:false` when the Worker has no APNs key. Tokens APNs reports as gone are deleted (`dropped`). Rate limited per Mac (`429 rate_limited`) |
| `DELETE /v1/me` | → `{deleted:{devices:n}}` (0.7.0): purges everything the Worker stores for the caller (devices with their push tokens, team prefs) and evicts the caller's sockets: the caller's hub closes every socket with 4002 `removed` and forgets its devices and sessions. The app calls it first when the user deletes their account, then deletes the Stack account through cmux's account deletion (`DELETE <cmux API>/api/account`, as the main cmux app) |
| `POST /v1/me/bootstrap` | `{teamId, devices:[{deviceId,kind,name}]}` (at most 4) → `{devices:[{device}\|{error}], macs:{macs}\|{error}, myMacs:{macs}\|{error}, ice:{iceServers,ttl,turn}\|{error}}`: the phone's launch in one round trip (added in 0.8.0). Each part is the response of its own route (`POST /v1/devices` with `teamId`, `GET /v1/teams/:teamId/macs`, `GET /v1/me/macs`, `GET /v1/ice`), run at once; a part's error does not fail the others. A 404 means an older service: make the separate calls |
| `GET /v1/health` | → `{ok:true, version, stackProjects:[projectId], colo}` (accepted Stack projects, primary first; `colo` is the Cloudflare colo that received the request, added in 0.6.0) |
| `GET /v1/teams/:teamId/hub` | → `{ingressColo, hubColo, locationHint}`: diagnostics added in 0.6.0. Where this request entered Cloudflare, where the caller's hub runs (since 0.10.0 the hub is the caller's, whatever `teamId` names; the caller must still be a member of it), and the region a hub created by this request would get (`null` when unknown) |

Every response carries `Server-Timing` (0.8.0): the steps it waited on, for example
`auth;dur=1, member;dur=0, db_connect;dur=5, db;dur=82, hub;dur=12, total;dur=101`
(`auth` token check, `member` Stack membership, `db` the database, `hub` the caller's Durable
Object, `turn` Cloudflare TURN, `stack` the Stack API). A request slower than 250 ms is
also logged with them.

## Signaling WebSocket `GET /v1/teams/:teamId/signal?deviceId=<id>`

One hub per **user** (API 0.10.0; before, one per team): the `TeamHub`
Durable Object class (hibernating WebSockets) reached by
`idFromName("user:" + owner key)`, where the owner key is the caller's
verified token `sub` (`<projectId>:<sub>` outside the primary project, as in
stored rows). The name comes only from the verified token, never from the
path, query or body. A hub holds one user's devices: the phone and the Macs
signed in to the same account. It binds its owner on first use and refuses
any call for another owner, so no presence, introduction, signal,
`wg-endpoints` or device list can cross users, even teammates.

What the team still scopes (a view, not a trust boundary):

- The path's `teamId` is still checked: the caller must be a member, and
  the socket's device must be registered in that team (else `403
  wrong_team`). A Mac that re-registers into another team has its socket
  closed with 4001 `moved` and reconnects under its new team. A phone's open
  socket stays (as with team hubs), so its links keep signaling.
- A socket hears about the user's Macs registered in the socket's own team
  only: `hello.macs` and `presence` frames are filtered by team, as the team
  hub did. A Mac that moves team is announced `removed:true` to its old
  team's sockets and as present to its new team's.
- Admission is by user only: a phone may signal any Mac of its own user,
  whichever team either is registered in (`GET /v1/me/macs` finds them).
  Teammates never can, whatever team they share.

Migration from team hubs (0.10.0): the URL and frames are unchanged, so old
phone and Mac builds need no update. Hibernated sockets survive a deploy
(seen live: a Mac stayed connected to its team hub across it), so the
Worker retires the old team hubs, which close their sockets with 1012
`moved to the user hub` and delete their rows: a cron every minute walks
every team id in the database (devices and team prefs, named as each
project named its hubs), and requests retire lazily too, the first time an
isolate serves a team after a membership check (`GET /v1/teams/:teamId/macs`,
the signal socket, each team of `GET /v1/me/macs`). A retire that fails is
retried. After a deploy a Durable Object keeps running the previous class
until it is evicted, and traffic (these retries, a polling phone) can keep
it warm for minutes; such a hub answers "does not implement the method".
The Worker then calls the previous class's own `forgetMac` for each device
the database has in that team, which closes that device's socket with 4001
`moved` (clients reconnect, into their user hub), and retires the hub for
good once it runs the new class. A retired hub remembers it, so later
sweeps cost at most one wake per team. The fallback reaches the devices the
database has in that team now; a socket of a device registered elsewhere
since (a phone that switched team) stays until the hub runs the new class
and is retired. The sweep and the lazy path are temporary: remove them once
the sweep log shows every team retired across deploys. Clients reconnect as
after any drop (hostd in under a second) and land in their user's hub.
A user hub is never retired. A new hub is seeded once from the database
with the user's Macs (offline until they connect), so `hello` lists a
registered Mac that has not reconnected yet.

A hub stays where it is first created. Since 0.6.0 the Worker creates it
with a `locationHint` from the caller's own location (Cloudflare's
geolocation of the client: `wnam`, `enam`, `weur`, ...), not from the colo
that received the request. Free-plan traffic is sometimes received far from
the client (on 2026-10-13 a California client was served from Paris), and a
hub created then would stay across an ocean. JSON text
frames:

The socket is admitted only for a member of `teamId` whose `deviceId` is
registered to the caller in that team (else HTTP 403), in the caller's own
hub. The server selects
subprotocol `cmux-mobile.v1` when offered (never the bearer entry). One socket per
device: a newer connection closes the older with code 4000 `replaced` (no
offline presence in between); a Mac re-registered into another team is
closed with 4001 `moved`.

- server → client on connect: `{"type":"hello","you":deviceId,"macs":[{deviceId,name,online,lastSeenAt,ownerUserId}]}` (the user's own Macs in the socket's team)
- server → the user's sockets of the Mac's team: `{"type":"presence","mac":{deviceId,name,online,lastSeenAt,machineId}}` (`machineId` added 2026-10-21; also in `hello.macs`, and sent again when a registration gives an older build its machine id); a deleted Mac's last presence adds `"removed":true` (0.7.0), and clients drop it from their lists
- client → server → peer: `{"type":"signal","to":deviceId,"from":deviceId,"sessionId":uuid,"payload":P}`.
  A `from` other than the socket's own deviceId is refused with `bad_request`.
  On every forwarded signal the DO sets `"fromUserId": <sender's Stack userId>`,
  overwriting any client value. `cmux-mobile-host` admits a dial only when `fromUserId` equals the Mac's
  own user; a missing `fromUserId` is refused with `bye {reason:"not_admitted"}`.
  where `P.kind` is one of
  - `webrtc-offer` `{sdp, lanes?, mediaFor?}`, `webrtc-answer` `{sdp, lanes?}`, `webrtc-ice` `{candidate, sdpMid, sdpMLineIndex}`.
    An offer with `mediaFor` (added 2026-10-19) opens a media session for
    the WireGuard link with that session id, not a link of its own ("Media
    session" below).
  - `wg-init` `{publicKey, endpoints:[ "ip:port" ], overlayIP, lanes?, relayed?, relayedTls?, version?}`,
    `wg-resp` `{publicKey, endpoints, overlayIP, lanes?, relayed?, relayedTls?, version?}`.
    `relayed` (optional) lists which of the sender's endpoints are its TURN
    relayed addresses (the phone's; a Mac's only when its network blocks
    UDP). The peer sends plain UDP to them like any endpoint, and labels
    such a route `turn`, not `direct`; `relayedTls` lists which of them
    reach their TURN server over TCP or TLS (label `turn-tls`). `version`
    is the WireGuard protocol version: absent (0) from older peers, `2`
    from peers that never send relay frames and confirm routes with an
    in-tunnel `reach` message (below). A roam's endpoint announcement
    (`{"t":"endpoints", generation, endpoints, relayed?, relayedTls?}`)
    carries a new allocation's address the same way. Older peers omit all
    of these, and the label stays `direct`.
  - `wg-endpoints` `{generation, endpoints, relayed?, relayedTls?}` (API
    0.9.0): the same endpoint announcement a roaming side sends inside the
    tunnel (below), also sent through signaling, because the peer may not
    receive anything from the new address yet (a NAT that filters by
    address). The receiver applies the newer generation of either copy.
    Older peers ignore it (an unknown kind).
  - `bye` `{reason}`
- Relay frames (retired in API 0.9.0). Binary frames
  `[16 bytes sessionId][16 bytes to deviceId][wireguard datagram]` used to
  carry WireGuard when no UDP path worked. The DO no longer forwards them:
  every binary frame is dropped, and its sender gets
  `{"type":"error","code":"relay_retired","sessionId":...}` at most once
  per socket and session every 5 s. The error always names the frame's
  session, so an older client fails no other dial in progress (it fails a
  dial only on an error for that dial's session or one without
  `sessionId`). A frame shorter than 16 bytes is dropped silently. The
  hub keeps presence and signaling (introductions); it carries no
  data. A WireGuard path without UDP is TURN over TLS (below).
- WireGuard specifics: `publicKey` is base64 Curve25519; `endpoints` are
  `ip:port` strings (host and STUN-reflexive addresses of the tunnel's UDP
  socket); `overlayIP` is the sender's IPv4 address inside the tunnel (the
  dialer uses `10.77.0.2`, the answerer `10.77.0.1`).
- WireGuard paths, in order: plain UDP (direct, hole-punched), then TURN
  over UDP, then TURN over TLS on 443. When `/v1/ice` lists a TURN server
  the dialer allocates a TURN relay and adds the relayed address to its
  `endpoints`. It tries `turn:...?transport=udp` first; when that gets no
  allocation it uses `turns:...:443?transport=tcp` (any other `turns:` URL,
  else `turn:...?transport=tcp`, when the service lists no TLS on 443).
  The TLS attempt starts 500 ms after the UDP one (at once when UDP
  fails), so a network that answers UDP never opens a TLS connection; when
  TLS finishes first, UDP gets 250 ms more. Only the leg to the TURN
  server changes (RFC 5766 over TCP or TLS): the allocation still relays
  UDP, so the Mac sends plain UDP to the relayed address like to any
  endpoint. On the stream every STUN message and ChannelData message is
  framed by its own length, ChannelData padded to 4 bytes (RFC 5766
  §11.5). The TLS server name is the URL's host, checked against the
  public web PKI. The dialer sends through its allocation to the Mac's
  public endpoints and reports the path `turn`, or `turn-tls` when the
  allocation rides TCP or TLS. TURN servers sit on well-routed anycast
  addresses: on 2026-10-13 TURN over UDP measured 16 ms RTT against 240 to
  345 ms through the retired Worker relay. A Mac whose STUN servers never
  answer (its network drops UDP) takes its own TURN allocation the same
  way, lists it in `wg-resp` (`relayed`, `relayedTls`), and sends through
  it; so does a side with relay only or UDP blocked (debug). A TURN
  allocation whose TCP or TLS stream dies is replaced at once (then after
  1, 3, 10 and 30 s) and announced like a roam's.
  Datagrams queue toward a TURN allocation by class (no wire change):
  control (handshake messages, keepalives), then input (what the tunnel's
  pacer sends as interactive: keystrokes, ACKs, terminal output at a
  terminal's pace), then bulk (large transfers) and media (the media
  lane's video), which share the rest by bytes. A datagram the pacer did
  not class (packets held through a handshake, the watchdog's resends) is
  input up to 400 bytes, else bulk. Each class is bounded by bytes (16, 64,
  256 and 256 KiB) and drops its oldest datagram past it, and media older
  than 250 ms is dropped, so on a backed-up TLS stream media never delays
  control or input and memory stays bounded.
- WireGuard route confirmation. Reachability can be one-way, so a side that
  receives its peer's datagrams on a route does not yet know its own reach
  the peer. Until it does, it sends every datagram on that route and through
  its TURN allocation too (and to every candidate when it has no route; and
  every 100 ms to each of the peer's other endpoints, its relayed addresses
  among them). The confirmation is an overlay UDP datagram to port 7421 of
  the peer, JSON `{"t":"reach","from":"ip:port","via":"udp"|"turn"}` ("your
  datagrams reach me": they arrived from `from`, your address as seen here,
  on my plain UDP socket or my TURN allocation), sent by a version-2 side
  when an authenticated datagram from its peer arrives: at once on a new
  route, then 100, 300 and 1000 ms later while datagrams keep arriving, then
  at most every 3 s. `from` names the carrier that works (the receiver's
  TURN when it is its relayed address, else plain UDP) and `via` whether it
  reached the peer's relayed address. The current route is confirmed only
  when it is that pair. Otherwise the side switches to that pair when it is
  an upgrade (direct UDP instead of a relayed route), or when no `reach`
  confirmed the current route in the 4 s since it became the route (for
  example plain UDP to the peer's relayed address when its own UDP to the
  peer's LAN address is lost), and keeps it while `reach` keeps naming it,
  even though the peer's datagrams arrive on another route, and for 25 s
  after the last one (an idle link's keepalives every 10 s each draw one),
  or until the peer announces endpoints without that address. A relayed copy
  of a datagram never displaces a direct route that still delivers. A side
  that receives its peer's direct UDP while most of the peer's datagrams
  arrive relayed sends `reach` for that direct arrival at once (at most
  every 100 ms), so the peer upgrades; while the route is relayed (its own
  TURN, or the peer's relayed address) the direct candidates are tried every
  5 s. A confirmed route that is silent for 14 s, or that no `reach`
  confirmed for 25 s, is no longer trusted (every route again until a new
  `reach`). A bare `{"t":"reach"}` confirms the current route. An older peer
  (version 0) sends its confirmation through the retired relay, where it is
  lost, and never sends `reach`: with such a peer a side takes the peer's
  authenticated datagrams as the confirmation. An address the OS refuses to
  send to (macOS Local Network privacy answers `EHOSTUNREACH` for LAN peers)
  is never chosen as the route again.
- WireGuard roaming (no wire change for older peers, which simply never
  announce): a side whose network changed (the phone's `NWPathMonitor`, the
  Mac's routing socket) moves its tunnel onto a new UDP socket and at once
  sends an authenticated datagram from it (a keepalive on a session younger
  than 120 s, else a handshake initiation); the peer follows the new
  address (WireGuard endpoint roaming) and answers `reach` at once. Until
  the new route is confirmed every datagram also goes through TURN and to
  all of the peer's candidates, and for 3 s after a roam both sides also
  spray candidates every 100 ms. The roaming side learns its new reflexive
  address with STUN on the new socket and takes a fresh TURN allocation on
  the transport the new network allows (UDP, else TLS). New endpoints
  travel inside the tunnel: an overlay UDP datagram to port 7421 of the
  peer's overlay address, JSON
  `{"t":"endpoints","generation":N,"endpoints":["ip:port"]}` (at most 16,
  `generation` grows per announcement), answered with
  `{"t":"ack","generation":N}` and resent after 0.15, 0.4, 1, 2 and 4 s
  until acknowledged; and once through signaling (`wg-endpoints`, again
  after the side's signaling socket is replaced). An empty list means
  "same endpoints, my network changed". A side that receives an
  announcement replaces its candidates (unless empty) and resends the data
  messages it sent in the last 20 s (at most 128); so does a side whose
  route changes or that roams, as soon as it has a route to send them on.
  WireGuard's replay window drops the copies that already arrived, and TCP
  inside the tunnel never waits out its 1 s minimum retransmission
  timeout. The tunnel's UDP socket asks for 2 MB buffers, so such a burst
  is not dropped by the OS. While the confirmed route is TURN, plain UDP
  candidates are tried every 5 s, so a direct path wins again. A side
  whose signaling socket was replaced moves its sessions to the new socket
  (for `bye` and `wg-endpoints`).
- `{"type":"error","code","message","sessionId"?}` for refusals (`not_owner`,
  `offline`, `rate_limited`, `bad_request` for malformed frames or a `from`
  that is not the socket's device, `relay_retired` for a binary frame). A
  refused signal names its session once the frame has a valid `sessionId`
  (0.9.0). A client fails a dial only on an error for that dial's session
  or one without `sessionId`, never on an error naming another session. A
  WireGuard side that closes its tunnel sends `bye {reason:"closed"}` so
  the peer's tunnel stops too.
- Rate limits per socket: 20 text frames/s (burst 60). Binary frames
  (retired) are counted in their own bucket (12000/s, burst 24000), so a
  flood of an older client's frames costs at most a bounded number of
  `relay_retired` checks; excess ones are dropped silently.

Admission: the DO forwards `signal` only when `to` is a Mac owned by the
sender's user (same `sub` in the same Stack project), or the reply direction of an existing sessionId. A sessionId
is bound to the two devices of its first admitted signal. Since 0.10.0 the hub is the sender's own, so another
user's device is not in it at all: a signal to it is refused `not_owner` whether that device is online or not
(never `offline`, which would confirm it exists).

## Link (inside either transport)

A link is one reliable ordered byte stream, the main stream (WebRTC: data
channel `cmux-mobile-link`, ordered, reliable; WireGuard: one smoltcp TCP stream to
`overlayIP:7420`), plus the input lane when both sides support it (below).
Frames: `u32 BE length | u32 BE channel | u8 type | payload`, where `length`
counts the channel, type and payload bytes (5 + payload length). A payload is
at most 256 KiB. Since the input lane, writers split data into frames of at
most 16 KiB (readers still accept 256 KiB from older peers).

| type | meaning |
| --- | --- |
| 0 `open` | payload JSON `{"service": S, "args": {...}}` |
| 1 `data` | raw bytes |
| 2 `close` | payload JSON `{"code","reason"}` |
| 3 `ping` / 4 `pong` | channel 0, 8-byte nonce |

A channel whose owner does not read it may hold the link reader for at
most 3 s; then that channel is closed `overflow` on both sides and the rest
of the link keeps flowing (before 2026-10-14 one unread channel, say a
terminal screen that never attached, stopped every channel and the pongs,
and the peer's keepalive closed the link). A side sends `ping` and `pong`
ahead of queued channel data. The keepalive
pings every 15 s and closes the link (`keepalive timed out`) only when
nothing at all, not a pong and no other frame, arrived for 20 s after a
ping. (Before, a ping queued behind megabytes of data on a slow relay and a
healthy link closed during a 10 MiB transfer.)

### Lanes (added with the input lane; backward compatible)

All channels used to share the main stream in FIFO order, so a keystroke,
a ^C or a resize could wait behind megabytes of terminal output
(head-of-line blocking). Borrowed from WebRTC, which gives each data
channel its own SCTP stream:

- **Negotiation.** The phone's first signal (`webrtc-offer`, `wg-init`)
  and the Mac's answer (`webrtc-answer`, `wg-resp`) carry
  `lanes: ["input"]` when that side supports the input lane. The lane is
  used only when both list it. Older peers send no `lanes` and ignore the
  field; the backend forwards payloads unchanged.
- **The input lane's stream.** WebRTC: a second ordered, reliable data
  channel `cmux-mobile-input` (its own SCTP stream, so a lost bulk packet does not
  hold input back at the receiver). The phone creates it with `cmux-mobile-link`;
  it carries frames only once both sides agreed. WireGuard: a second TCP
  stream to the same `overlayIP:7420`, opened by the phone right after the
  main one (the Mac takes the second accepted connection as the lane, for
  10 s). Its own smoltcp socket buffers keep input out of the main
  stream's 256 KiB send buffer and its 512 KiB stream queue; one TCP byte
  stream cannot reorder bytes already in its buffer, so priority inside the
  smoltcp write path would not help. The input lane carries the same frame
  format; a channel lives on one stream for its whole life.
- **Opening on the lane.** An `open` payload may add `"lane":"input"`.
  The opener sends it on the input lane when the link has one, else on the
  main stream. The peer replies on the stream the `open` arrived on, at
  input priority. Older Macs ignore the field (the channel works, without
  priority).
- **Scheduling on each stream.** A writer sends control frames (ping, pong,
  refusals) first, then input-lane frames, then bulk data round robin
  across channels, one 16 KiB frame per turn. A channel may queue 256 KiB
  before its sender waits, so a flood cannot build a long backlog in front
  of the link.
- **Use.** The app sends terminal keystrokes (`send`) on a `daemon` channel
  opened on the input lane. `resize-surface` stays on the attach channel,
  because the daemon gives geometry authority to the attaching client.
  Output, attach streams, `acpmux` and `file` stay bulk.

### Media session (`webrtc-media`; added 2026-10-19, backward compatible)

WireGuard carries the link, and a WebRTC peer connection to the same Mac
carries browser video beside it (verify/hybrid-link.md). WebRTC is used only
where it is the better path for latency: a media stack with its own ICE
candidates (direct or TURN over UDP), SRTP and congestion feedback, and a
path chosen without waiting on the tunnel's.

- **Negotiation.** The phone lists `"webrtc-media"` in `wg-init` `lanes`
  next to `video`; a Mac that will answer media sessions for the link lists
  it back in `wg-resp`, and only when it also attached the tunnel's media
  lane (`video`), which stays the floor. Older peers leave it out and video
  rides RTP in the tunnel as before.
- **Opening.** The phone opens the session on demand: when a browser tab is
  shown, or ahead of it when the shown workspace has browser tabs (a
  warm-up that lasts a minute). The link and the terminal never wait for
  it. Its first signal is a `webrtc-offer` on a new session id with
  `lanes: ["video"]`, `mediaFor: <the WireGuard link's session id>` and one
  `recvonly` H.264 m-line (the media lane's codec, feedback and TWCC
  extension, below); there is no data channel. Candidates trickle through
  `webrtc-ice` as for a WebRTC link, with the same `GET /v1/ice` servers.
- **Admission (no new trust path).** The TeamHub forwards the offer like any
  first signal (the Mac's owner's own phone, `fromUserId` stamped by the
  hub). cmux-mobile-host answers only when `fromUserId` is its owner (as for a
  dial), `mediaFor` names a live WireGuard link that listed `webrtc-media`,
  the offer's `from` is that link's phone device, and, with pairing on, that
  link passed `auth`. Otherwise it answers `bye {reason}` with
  `unknown_link` or `unpaired`. Its answer has one `sendonly` track and
  `lanes: ["video"]`. A newer session for the same link replaces the older;
  every session ends with its link.
- **Video.** The session's track is a second route of the link's media lane
  (the same RTP stream format, NACK, PLI, FIR and TWCC as "Media lane"
  below). The Mac sends each frame on one route: the session's track while
  its peer connection is connected, else RTP in the tunnel. A route that is
  current, has packets out and hears no TWCC feedback for 500 ms counts as
  stalled: video leaves it and it is tried again after 1 s, doubling to
  16 s (back to 1 s after 10 s of feedback). Video changes route only at a
  keyframe (the Mac asks its encoder for one, at most every 250 ms); while
  the old route still works its frames keep going until then, and while it
  does not the frames in between are dropped, so the phone keeps showing
  the last frame. The phone takes frames from every route and passes a
  route's frames only after its keyframe, so a late frame from the old route
  never reaches the decoder. `video_tag` and the channel fallback are
  unchanged (with no lane at all, video rides the `browser` channel).
- **Liveness.** The session's ICE reports disconnected after 3 s without
  consent answers and failed after 8 s (1 s keepalives). The phone redials a
  failed or closed session after 1, 2, 4, 8, 16, then every 30 s while video
  is wanted (back to 1 s after a session that lasted 30 s), and closes it
  with `bye` 30 s after the last browser tab was hidden.
- **Input** stays on the WireGuard link's input lane: the session carries no
  data channel (verify/hybrid-link.md "Input path" has the measurements).
- **UDP blocked.** webrtc-rs cannot reach TURN over TCP or TLS, so on a
  network without UDP the session never connects and video stays in the
  tunnel (which rides TURN over TLS). The phone's Block UDP debug setting
  gives the session no candidates, so it fails the same way.
- **Labels.** The phone's link line adds the session: "Connected ·
  WireGuard direct · video WebRTC (TURN) · 14 ms" ("video in the tunnel"
  while a failed session waits for its retry). cmux-mobile-host reports
  `{"type":"phone_media","session_id":<the link's>,"media_path":"direct"|"turn"|"none"}`
  and the Mac's iPhone card adds "Video over WebRTC (TURN)".

### Media lane (`video`; added 2026-10-14, backward compatible)

Browser video as RTP beside the link's reliable streams
(verify/browser-video-track.md). One lane per link carries one H.264 stream
from the Mac to the phone; a `browser` channel claims it (below).

- **Negotiation.** The phone lists `"video"` in its first signal's `lanes`
  (`webrtc-offer` or `wg-init`); the Mac lists it back in its answer only
  when it attached a sender. Either side without it (an older phone, an older
  Mac, `CMUX_MOBILE_VIDEO_LANE=0`) leaves the lane out and browser video stays on the
  `browser` channel. No other negotiation happens, and a WireGuard roam
  changes nothing.
- **The stream.** H.264 (RFC 6184: STAP-A for the parameter sets, FU-A),
  payload type 102, 90 kHz clock, the host's capture time as the RTP
  timestamp. The transport-wide sequence number extension
  (`draft-holmer-rmcat-transport-wide-cc-extensions-01`) on every packet.
  RTCP back: generic NACK (resent at most 3 times, 40 ms apart), PLI and FIR
  (the Mac makes a keyframe at most every 250 ms), TWCC feedback every 25 ms,
  sender and receiver reports.
- **WebRTC carrier.** A video track on the link's own peer connection: the
  phone's offer has one `recvonly` H.264 m-line with `nack`, `nack pli`,
  `ccm fir` and `transport-cc`; the Mac adds a `sendonly` track before it
  applies the offer. SRTP as usual.
- **WireGuard carrier.** RTP and RTCP as plain UDP datagrams inside the
  tunnel, between overlay port 7422 on both sides (next to the link's TCP
  7420 and the roaming messages' UDP 7421), with no SRTP, ICE or DTLS
  (WireGuard authenticates and encrypts every datagram). RTCP is told from
  RTP by the second byte (192 to 223, RFC 5761). The SDP-less parameters are
  fixed: payload type 102, TWCC extension id 1, the Mac's SSRC `0x636e7876`.
  A datagram from another overlay address, or RTP from another SSRC, is
  dropped. The Mac binds its port before it answers, the phone before it
  opens the link stream. RTP payloads are at most 1196 bytes, so a packet
  with its header and room for three extensions stays within the 1232-byte
  datagram limit of the 1280-byte tunnel; nothing is fragmented. In cmux-wg's
  scheduler RTP is `Media` (dropped after 50 ms in the send queue) and RTCP
  `Interactive`.
- **Roaming.** After a network change on either side (its own roam, or an
  endpoint announcement on 7421 from the peer) the phone sends a PLI and the
  Mac's sender resets its congestion baseline; the lane's port, keys and
  parameters stay.

Phone opens odd channel ids, Mac even. Services exposed by `cmux-mobile-host`
(default deny; anything else is refused with `close {code:"unknown_service"}`):

- `daemon`: splice to the cmux-tui session socket (protocol v12 JSON lines),
  filtered per line by a command allowlist (read/watch, terminal attach/input/
  resize, workspace/tab list/create/close/select, conversation and question
  commands). Command-bearing params such as spawn argv are denied.
  `new-conversation-tab` is allowed only for an `agent_session` tab. The Mac
  sets its `host` to its own agent tab host, and refuses any other host,
  source or field.
- `acpmux`: splice to the acpmux loopback WebSocket. One WebSocket text
  message (a JSON value) is one write in each direction. A message above
  256 KiB arrives as several data frames, and the receiver joins frames until
  they parse as one JSON value (at most 32 MiB from the phone).
- `cloud-directory` (link protocol 2): no arguments; one JSON data frame
  `{"machines":[{"machine_id","team_id","name"}]}` followed by `eof`.
  Hostd obtains this list from the signed-in Mac app's authenticated owner
  CloudLinkSession objects. Carrier paths and ownership markers are never sent
  to the phone; conflicting duplicate machine/team entries are omitted.
- `cloud-acpmux` (link protocol 2): `{"machine_id","team_id"}`. Hostd
  resolves exactly one current owner link from the app. This socket is already
  the Cloud app server's daemon carrier; no second `link.dial` or service hello
  is sent. Rust hostd requires `identify.data.capabilities` to advertise
  `cloud-mobile-chat-v1` before marking its connection with that capability.
  A successful `set-client-info` reply alone is insufficient. It discovers the VM's stored
  agent tabs, and translates the phone's ACP requests to scoped native
  `agent-session-*` commands. ACP pages and records keep their original sequence
  numbers. Text prompts answer on durable acceptance; cancel and history paging
  are supported. Approval answers, mode changes and arbitrary daemon commands
  are refused. Every prompt first refreshes the session summary and requires
  Claude `default`/`plan` or Codex `ask`, plus enforcement policy `ask`; missing
  or unknown fields fail closed. This preflight supplements the required VM
  implementation: authenticated owner checks and an atomic asking-mode floor
  through dispatch, queued prompts and the active turn. It cannot replace that
  enforcement or prove the actual Codex bridge profile from a mode name.
- `file`: `{"path"}` read-only stream of a file inside a workspace root, for artifact preview.
  Any size: data frames until `eof`, up to the size the file had when it was opened. A host
  before 2026-10-28 refuses a file over 64 MiB with `too_large`.
- `file-preview`: `{"path"}` uses the same authorization and confinement as `file`.
  Its first data frame is JSON `{"size": <bytes>}`, from the same open descriptor
  used to stream the file. Subsequent data frames contain raw file bytes until `eof`,
  up to that initial size, with no file-size cap. A file truncated while streaming
  may end earlier; the phone treats a stream that ends short of the size, or runs past
  it, as a file that changed while downloading, removes the partial copy and asks the
  person to try again. Refusals before streaming send no metadata. The phone uses this
  size to check available storage before downloading and rechecks during the stream;
  insufficient space cancels the preview and removes the partial temporary file.
  Older hosts refuse this service with `unknown_service`; clients must not parse the
  legacy `file` service's raw bytes as metadata.
- `upload`: `{"name","size","cwd"?}` (`size` a number or a decimal string).
  The phone sends exactly `size` bytes as data frames. The Mac writes them to
  a new file and answers one data frame `{"path","size"}`, then `eof`. With
  `cwd`, which must be a folder of one of the Mac's tabs or inside a workspace
  root, the file goes to `<cwd>/.cmux/attachments/phone-<session>/`.
  Otherwise it goes to the host's uploads folder. Any size is accepted; the
  bytes stream to disk as they arrive. A refusal (`forbidden`, `not_found`,
  `bad_request`, `io`) is answered `{"error","message"}` before the channel
  closes with that code. The name is made safe, and an existing file is never
  replaced (`name 2.ext`, ...).
- `browser`: `{"tab", "url"?}` a streamed Mac browser tab
  (verify/browser-stream.md). The channel carries the `cmux.rd/1` stream
  carrier (`u8 kind | u32 LE len | payload`, kind 1 control JSON, 2 datagram)
  of a `cmux.rb/1` session with the Mac's browser host, unchanged in the
  host-to-phone direction. hostd sends the rd `hello` itself, with the host's
  per-launch secret. The phone sends only datagrams (input, feedback, clock
  probes), `stop`, and rd `service` messages for `rb/1` whose body `t` is a
  viewer message (`rb.open`, `rb.close`, `rb.visibility`, `rb.screen`,
  `rb.vsync`, `rb.history`, `rb.navigate` to an allowed address (below),
  `rb.menu.result`, `rb.dialog.result`, `rb.open_tab.result`, `rb.find`,
  `rb.find.stop`); hostd drops anything else. One host per `tab` outlives
  its channel; a new channel for the same tab closes the older with
  `replaced`. At most a host limit of hosts run (`CMUX_MOBILE_RB_MAX_TABS`, 4);
  opening another stops an idle host first, then a hidden tab's, then the
  least recently used, and that viewer's channel closes `evicted`
  (2026-10-20; before, `replaced`). The phone opens an evicted tab again when
  it is shown (at its current address), and on a new link it opens only the
  tab on screen, never every tab it holds (transport-verify-20261019.md
  defect 7). `url` must be an allowed address (below; otherwise the channel
  closes `forbidden`, `not_found` or `bad_request` with the sentence the phone
  shows as its reason), and a Mac with no browser host refuses with `unavailable`.
  **Addresses** (2026-10-21, `browser_policy.rs`):
  - A page one of the Mac's own browser tabs shows (the daemon's
    `list-workspaces`), and the address a tab was opened at after that check,
    always loads, whatever its scheme (`file:` anywhere, `chrome:` pages): the
    phone views what is already on the Mac's screen. `javascript:` and app
    schemes never load, even then.
  - Any other address, typed or followed inside the page: `http(s)`,
    `about:blank`, `data:`, `blob:`, `view-source:` of `http(s)`, and `file:`
    (`file:///p`, `file://localhost/p`, percent-decoded) inside the folders the
    Mac shares with the phone, which are the `file` service's roots (Chat
    Folders and the shareable workspace folders: never home, its parents or
    `~/.ssh`, `~/Library` and the other credential trees; symlinks resolved).
    `javascript:`, `chrome:`, `chrome-extension:`, `devtools:`, other `about:`
    pages, `file:` elsewhere and every other scheme are refused.
  - A shared file is loaded at its resolved path (hostd forwards
    `file://<canonical path>`), so a symlink swapped in after the check cannot
    redirect the load. A page the Mac shows is remembered for the tab; a
    shared file is checked again each time; its `?query` and `#fragment` are
    kept. Checks read the daemon once per 2 s at most, and only for `file:`
    and browser pages, so a page the Mac opened within the last 2 s can be
    refused once (it loads when asked again).
  - A refused `rb.navigate` never reaches the host: hostd answers the phone
    with the rb message `rb.navigate.refused {url, code, reason}`
    (`code`: `file_not_shared`, `file_missing`, `script`, `browser_page`,
    `app_scheme`, `malformed`; `reason` an English sentence such as "This file
    isn't in a folder this Mac shares with your iPhone."). The phone shows the
    reason over the page, in its own words for a known `code`, and the address
    bar goes back to the page.
  - **The host checks every `file:` load itself** (2026-10-22): hostd sends
    `rb.file_policy {roots, files}` right after its hello, and again when it
    changes. `roots` are the shared folders; `files` are the pages the Mac showed
    this tab (each page alone, never its folder). The host's request
    handler (`OnBeforeBrowse` for navigations and frames,
    `OnBeforeResourceLoad` for images, iframes, fetch and every other
    subresource) refuses a `file:` URL whose path, resolved at load time, is
    not one of `files` or inside one of `roots`. A host with no policy (the
    Mac app's own remote tabs) loads every file. Known limits: the policy is
    refreshed when hostd next checks an address (2 s cache), a link the host
    refuses shows no notice on the phone, and a page restored from the
    back-forward cache is not checked again by the host (hostd's take-back
    still applies); a policy is replaced, never
    removed, and a phone cannot send one (hostd's viewer allowlist). A new
    host of a `file:` page starts at `about:blank` and hostd navigates it
    after the policy.
  - hostd checks the host's `rb.page` too: a page the host went to by itself
    (a link, a redirect, script) that the rules refuse is not forwarded; hostd
    sends the host `rb.history back` (or `rb.navigate` to the last shown page
    when there is no history) and the phone gets `rb.navigate.refused`. After
    three take-backs with no phone navigation between (and no page that stayed
    1 s), hostd sends the host to `about:blank` instead (a page that bounces on
    load, or redirects on to one that does). The frames painted
    before the host goes back can still reach the phone.
  - An older hostd refuses every address but http, https and `about:blank`
    ("only http, https and about:blank load") and drops other `rb.navigate`
    without an answer. The phone's address bar sends `file:` URLs, Mac paths
    (`/Users/...` becomes a `file:` URL) and the other schemes as typed.
  **Keyboard** (2026-10-21): the phone types into the page with rb input events on
  the input lane: text as `ime_commit`, Return, Tab, Backspace, Escape and arrows
  as `key` down/up, and shortcuts as `key` with `modifiers` (Command = 8) and the
  Mac's `edit_commands` (`SelectAll`, `Copy`, `Cut`, `Undo`). Copy and Cut run
  on the Mac, so they put the text on the Mac's clipboard (the owner's own).
  Paste sends the phone's clipboard text as `ime_commit`. While the keyboard shows, the phone sends
  `rb.screen` with the page's visible height, so the page lays out above the
  keyboard. Hiding the keyboard sends nothing (the page keeps its focus). The host
  reports the focused field, `rb.text_input {input_type, composition_rects,
  caret}` (CSS pixels; `input_type` `none` when nothing takes text): the phone
  raises the keyboard when a field gains focus and lowers it when the page
  blurs a field it raised it for; Chromium keeps the focused field in view as
  the viewport shrinks. A hardware keyboard's arrows, Escape, Home/End,
  forward Delete and Command/Control shortcuts go to the page directly as
  `key` events (with the Mac's edit commands: Option-arrows by word,
  Command-arrows by line or document, Command-Z/Shift-Command-Z); Command-V
  pastes the phone's clipboard.
  **Page asks** (2026-10-26, remote-tab-protocol.md section 4, as the Mac's
  viewer answers them): a link that opens a new tab or window
  (`rb.open_tab {request, url, disposition}`: `target=_blank`, `window.open`)
  becomes a phone browser tab in the page's
  pane (daemon `new-browser-tab {url, pane}`, so only `http(s)` and
  `about:blank` open), shown unless `disposition` is `background_tab`, and the
  phone answers `rb.open_tab.result {request, tab}` or `{request, refused}`. A
  long press sends a secondary click at that spot (pointer `button` 2) and
  shows the host's `rb.menu.show` of kind `context` as the system menu; rows
  whose command acts on the Mac itself (Copy and Save rows, Paste, Print,
  Inspect, Look Up, Speech, Cast, Create QR Code) are left out, and so are the
  rows Chromium opens as a new tab through `OpenURLFromTab` (Open Link in New
  Tab or Window, Open Image in New Tab, Search for, View Page Source): the browser host forwards only the page's
  own popups (`OnBeforePopup`) as `rb.open_tab`, so those would open nothing
  a viewer sees until it forwards them too. The pick goes back as `rb.menu.result
  {token, choice: {choice: "command", id}}`, and a menu closed with no pick,
  or one that arrives with no long press waiting (after 1.5 s), as `{choice:
  "cancel"}`. A `<select>` (`rb.menu.show` of kind `select`) shows its options
  in a sheet and answers `{choice: "indices", indices}`. JavaScript dialogs
  (`rb.dialog.show`) show as a system alert (a prompt with a text field) and
  answer `rb.dialog.result {token, accept, text}`. `rb.menu.cancel` and
  `rb.dialog.cancel` close the sheet or alert with no answer; a new stream
  session drops whatever was open. Popup surfaces (`rb.surface.show`: date,
  color and datalist pickers) are not shown on the phone yet. The page menu's
  Hard Reload sends `rb.history reload_no_cache`. Under
  `CMUX_MOBILE_CONTROL=stdio` the app starts the hosts: hostd writes
  `{"type":"need_browser","request","tab","url"}` and the app answers
  `{"type":"browser","request","addr":"127.0.0.1:PORT","secret"}` or
  `{"type":"browser_failed","request","reason"}`. It reports
  `{"type":"browser_gone","tab"}` when a host exits, and hostd asks
  `{"type":"browser_stop","tab"}` to stop one.
  `"video":"track"` (with the media lane): the page's main video stream
  rides the link's media lane instead of the channel, on either carrier;
  rd control, input, clock probes and secondary surfaces stay on the
  channel. A newer `browser` channel that asks for the lane takes it, and the
  older tab's video returns to its channel with a keyframe. The phone sends
  `rb.visibility {visible}` when a tab is shown or hidden (hostd forwards it
  to the host); `visible: true` on a channel that asked for the lane and lost
  it takes the lane back, starting at a keyframe (2026-10-20). An older hostd
  forwards it without moving the lane. A hostd without
  the lane, or an older one, ignores the field and streams on the channel.
  `"video_tag": N` (u32, random per channel): hostd appends it to each of
  this tab's lane access units as an H.264 SEI NAL unit after the slices
  (user data unregistered, UUID `cmux-mobile-vid1` in ASCII (16 bytes), then N as 8
  lowercase hex digits, then the stop bit `0x80`; no byte is zero, so no
  emulation prevention). The phone keeps a lane frame only when it carries
  its own channel's tag, strips the SEI before decoding, and starts at its
  first keyframe; it never learns when the lane switched tabs otherwise.
- `echo`: test service.
- `version` (link protocol 2, added 2026-10-14): one data frame
  `{"hostd": "<version>", "link": 2}`, then `eof`. A host that refuses it
  with `unknown_service` speaks link protocol 1 (keepalive pings queued
  behind data, a reader that stalls on one full channel); the phone keeps
  the link and says "Update cmux on this Mac".
  Added 2026-10-14: `"capabilities": [...]`, what the host does that a
  phone may rely on. `removal-v1` (the Mac host of manaflow-ai/cmux#20414):
  after its owner removes it (signaling 4002 `removed`) the host stays off
  until the person allows iPhone connections again on the Mac, so the
  phone's removal copy can say so. Absent (older hosts): the Mac may add
  itself back.
  `file-preview-v1`: `file-preview` sends a size metadata frame before file bytes,
  allowing a phone to check available storage without a separate stat/open race.
  `browser-stream-v1`: the host streams browser tabs (`browser`); the Mac
  build bundles a browser host (Release builds ship none yet). A host that
  says `removal-v1` without it refuses `browser` with `no_browser_host`, and
  the phone hides New Browser Tab for that Mac.
  `browser-video-track-v1`: the host honors `browser {"video":"track"}`
  (the media lane above), on WebRTC and, since 2026-10-14, on WireGuard.
  `surface-stream-v1` (2026-10-22): the host streams the Mac's phone tabs
  (`surface`, below).
  `localhost-forward-v1` (2026-10-30): the host serves `localhost` (below).
  `cloud-directory-v1` and `cloud-acpmux-v1` (2026-11-01): the host can list
  and drive authenticated owner Cloud machines through the Mac carrier.
- `localhost` (2026-10-30): `{"port"}` (1 to 65535, a number or a decimal
  string) one TCP connection to that port on the Mac's loopback: `127.0.0.1`,
  then `[::1]`. Data frames are the connection's bytes in each direction;
  either side closing ends it. The phone opens one channel per connection a
  native browser tab makes to its own `127.0.0.1:<port>` / `[::1]:<port>`
  (Open on iPhone at `http(s)://localhost:<port>`), so the page keeps its
  origin. Nothing listening: `unavailable` "Nothing is listening on port N on
  this Mac."; a missing or bad port: `bad_request`; an older Mac:
  `unknown_service`, and the phone keeps that tab mirrored. The phone never
  names a host.
- `surface`: `{"tab", "video"?, "video_tag"?}` a Mac phone tab showing a
  booted iOS simulator, streamed like a browser tab
  (verify/simulator-surface.md). `tab` is the phone tab's key `s<surface>`;
  hostd opens it only when the daemon's `list-workspaces` lists that surface
  as a page tab with `conversation.page: "phone"` (else `forbidden`; not a
  tab key: `bad_request`; a Mac that streams no simulators: `no_surface_host`,
  an older Mac: `unknown_service`, and the phone says simulators are not
  available from that Mac). The channel is the `browser` channel's
  `cmux.rd/1` stream carrier of a `cmux.rb/1` session, and goes through the
  same splice: `video: "track"` and `video_tag` ride the link's one media
  lane, and the shown tab owns it among browser and simulator tabs alike
  (`rb.visibility`). The host answers `rb.open` and `rb.screen` with
  `rb.opened` and `rb.screen_applied` at the simulator's encoded size (its
  framebuffer scaled to at most 1920 px on the long side), sends a new
  `rb.screen_applied` (seq 0) when the simulator rotates, and sends no `rb.page`. The phone sends only rd datagrams, `stop` and
  `rb.open`, `rb.close`, `rb.visibility`, `rb.screen`, `rb.vsync`; hostd drops
  every other rb message. Input is `rb` input events in rd `service` input:
  `pointer` `down`/`move`/`up` at `x`, `y` in 0...1 of the simulator's screen
  (top-left origin, as shown; clamped), `ime_commit` text (at most 4 KiB, no
  control characters but newline and tab), `key` for `Backspace`, `Enter`,
  `Tab`, `Escape`, `Delete` and the arrows, and `{"e":"button","button":
  "home"|"lock"}`; anything else is dropped. A finger left down when the
  viewer goes is lifted. At most `CMUX_MOBILE_RB_MAX_TABS` surface hosts run,
  apart from browser hosts, with the same eviction. Under
  `CMUX_MOBILE_CONTROL=stdio` (and `CMUX_MOBILE_SURFACE_HOSTS=1`) hostd asks
  the app `{"type":"need_surface","request","tab"}`, the app answers
  `{"type":"surface","request","addr":"127.0.0.1:PORT","secret"}` or
  `{"type":"surface_failed","request","reason"}`, reports
  `{"type":"surface_gone","tab"}` and is asked `{"type":"surface_stop","tab"}`.
  hostd and the app's source speak `sf/1` on loopback (`surface.rs`
  `SourceFrame`): hostd's hello with the source's secret first, then `encode
  {idr,kbps}`, `visible`, `touch`, `text`, `key`, `button`; the source sends
  `size`, `damage`, `skip`, `error` and access units (flags, capture time on
  `CLOCK_UPTIME_RAW`, Annex B H.264). hostd runs the rd media engine (frame
  gate, congestion control, FEC, recovery keyframes) itself, so the source
  encodes only when asked.
  The phone declares `page-tabs-v1` on its `daemon` channel (2026-10-23), so
  page tabs read as `conversation` with their `page` instead of a blank
  browser tab: a phone tab shows as a simulator tab, and other page tabs
  (Settings, the App Store) are not shown on the phone.

A service that ends normally closes its channel with `{code:"eof"}`; a
refusal uses `unknown_service`, `forbidden`, `bad_request`, `not_found` or
`unavailable`. When the link itself drops, local channels see
`link_closed`.

## Pairing (`auth` service and the Mac app's control lines)

The `auth` handshake is in `verify/phone-approvals.md` ("Pairing on every
link"). The limits and close codes the phone sees:

| close code | meaning |
| --- | --- |
| `busy` | an `auth` is already running on this link (one at a time), or 32 channels already wait behind it |
| `rate_limited` | the Mac asked about this iPhone recently: 10 minutes after the person refused one of its keys, or after 3 new identity keys from that device id (6 from all phones) in 10 minutes; the reason names the wait |
| `unavailable` | the Mac app has not sent its approved list within 10 s (hostd never asks before it has it) |
| `timeout` | nobody answered the Mac's prompt within 120 s; opening `auth` again on the same link asks again |
| `denied` / `unpaired` | the person refused this key / the signature or pairing failed |

hostd → app, one JSON line on stdout (supervised mode, `control.rs`):

```json
{"type":"pair_request","phone_device_id":"<uuid>","name":"<phone>",
 "identity_key":"04…","approval_key":"04…","registered_at_ms":1791961929681}
```

`registered_at_ms` (integer, epoch milliseconds; added 2026-10-14) is when
that phone device id first registered with the service (`createdAt` of `GET
/v1/me/devices`), so the Mac's dialog can show how new the device is. It is
absent when the lookup failed or took over 3 s; the dialog then says the
date is unknown.

### Mac identity (trust on first use)

`auth` args may carry `macNonce` (16 to 128 letters or digits, the phone's
own). The Mac app keeps a long-lived P-256 identity key in its Keychain and
sends it to hostd once, on stdin:

```json
{"type":"mac_identity","private_key":"<32-byte scalar hex>","public_key":"04…"}
```

With both, the challenge frame adds `macKey` (the X9.63 point, hex) and
`macSignature` (raw `r || s`, hex) over
`cmux-mobile-mac-identity-v1 \0 mac \0 phone \0 macNonce \0 challenge`. The phone
pins `macKey` per Mac device id when pairing first passes, and from then on
refuses (`mac_identity_changed`, before it signs) a Mac that proves another key
or none. Removing the Mac forgets the pin.

### Chief question answers

On the `chief` channel, a supervised hostd forwards `conversation-op` with
`op.kind` `question.answer` only with
`approval: {approver, nonce, expiresAt, signature}` (see
`verify/phone-approvals.md`, "Chief question answers"); hostd strips it before
the Chief owner. `approval` on any other op is refused.

## Connection setup (phone)

Nothing here changes the wire; it is how a phone keeps a dial short.

- The phone keeps its link device's signaling socket open between dials
  (and opens it at launch and on foreground, before any Mac is asked for);
  a dial reuses it. Signaling sockets send a WebSocket ping every 15 s and
  close after 40 s without any inbound frame, so a kept socket is never a
  dead TCP connection. A reused socket that does not answer a ping within
  2.5 s while a dial runs is replaced and the dial redone.
- `GET /v1/ice` is cached for half its `ttl` (60 s when it lists no TURN
  server) by the phone and by `cmux-mobile-host`, which refreshes it in the
  background so an answer never waits on it.
- WebRTC nominates the first working candidate pair (host, srflx and prflx
  at once; relay after 300 ms unless relay only). WireGuard tries direct
  UDP, TURN over UDP and (only when UDP gets no TURN allocation) TURN over
  TLS on 443.
- A signaling socket lost after the answer does not fail a WebRTC dial or
  answer: ICE and DTLS finish without it. Lost before the answer, the dial
  fails at once and the app redials without showing an error; it shows a
  failure only after the second consecutive failure.
- `cmux-mobile-host` reconnects a socket that was up for 20 s or more 150 ms after
  it drops (a Worker deploy resets every socket), instead of 1 s.

## One link per Mac (phone)

Nothing here changes the wire. A phone holds one link per Mac at once, so the
workspaces, terminals, chats and Feed of two Macs on the account work side by
side (2026-10-21; before, one link served the account and choosing a second
Mac closed the first Mac's link).

- Every link rides the phone's one signaling socket (the link device's, in
  the team the phone registered in): the hub keeps one socket per device and
  routes each signal by `to` and `sessionId`, so links to several Macs never
  share a session. A dial that opens a new socket moves every live session of
  the device onto it at once (`bye`, `wg-endpoints`).
- Each link has its own state: its dial, retry and backoff, heartbeat, path
  (direct or TURN, its own TURN allocation and WireGuard keys), transport and
  pairing (`auth`). A refusal, a drop or a redial of one Mac's link does not
  touch another's. Each Mac's channels (`daemon`, `acpmux`, `file`, `upload`,
  the input lane) open only on that Mac's link; terminal tab ids (`s<surface>`)
  repeat across Macs, so a tab is always named with its Mac.
- Bounded: the phone targets the focused Mac (the one chosen last, else the
  first online one) and each other Mac whose data is on screen (the
  Workspaces list and the Feed show every Mac; a workspace page shows its
  Mac), or was within the last 5 minutes. A Mac nothing showed is not dialed
  (lazy); one left alone is closed after 5 minutes (its list stays, marked
  last-known). At most 4 Macs at once: the focused Mac, then those on screen,
  then the most recently used. A Mac presence calls offline is not dialed.
- Chief and the connection banner follow the focused Mac; each other Mac's
  link state shows in its own section header.

## Transport switch

The app exposes Settings → Connection → Transport: "WireGuard (recommended)"
or "WebRTC only" (2026-10-19). Both produce the same `Link`; switching tears
the link down and redials. WireGuard is the default for an install with no
saved choice (it was WebRTC); a saved choice stays. With WireGuard the link
rides the tunnel and browser video a WebRTC media session beside it ("Media
session"); "WebRTC only" is the earlier behavior unchanged: the link and
browser video share one peer connection.

Debug builds add Settings → Developer → "Relay only (simulate distant
network)" and "Block UDP". Both are phone-side dial policies with no wire
change, and changing either redials.

- Relay only: WebRTC gathers only TURN relay candidates (path `turn`), and
  WireGuard never sends plain UDP: it offers only its TURN relayed address
  and sends through TURN (path `turn`, or `turn-tls` when UDP to the TURN
  server fails). Without a TURN server the dial fails at once.
- Block UDP (WireGuard; WebRTC ignores it): no plain UDP in or out and no
  TURN over UDP, as on a network that passes only TCP. The link rides TURN
  over TLS on 443 (path `turn-tls`); without a `turns:` or TCP `turn:`
  server the dial fails at once. The media session gets no candidates and
  fails, so browser video stays in the tunnel. The rig sets it without the
  app's settings: simulator `SIMCTL_CHILD_CMUX_MOBILE_DEV_BLOCK_UDP=1`.
- No media session (measurement): simulator
  `SIMCTL_CHILD_CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA=1` leaves `webrtc-media` out of
  `wg-init`, so browser video rides RTP in the tunnel ("WireGuard only").
  cmux-mobile-host: `CMUX_MOBILE_WEBRTC_MEDIA=0`, or the test signals `SIGUSR1` (toggle a
  black hole under every media session's track) and `SIGUSR2` (close every
  media session).

The phone's link line names the path: "WireGuard direct", "WireGuard relay
(TURN)", "WireGuard relay (TURN over TLS)" (and the same for WebRTC's
TURN). There is no WebSocket relay any more. cmux-mobile-host reports the path as
`direct`, `turn`, `turn-tls` or `none` (`phone_up`, `phone_path`).

## Terminal size claims

When the phone shows a Mac terminal, the shared PTY is sized for the phone too
(cmux-tui shared sizing, docs/shared-terminal-sizing.md), and the Mac's pane
shows the phone's grid. The phone's size counts only while the person is
looking at that terminal; on every other path the claim ends and the Mac's
pane gets its own size back (2026-10-21).

Mechanisms, phone first, then the Mac:

- **Release / claim (phone).** A terminal page claims its size while it is on
  screen, settled and taking input (TabsKit `isInteractive`: not zoomed out to
  the grid, not mid-swipe, no page menu open), the app is in the foreground
  and none of its own sheets covers it (Files and Links, the photo picker, the
  file importer). Losing that sends `release-surface-size {surface}` on the
  attach channel after a 1 s debounce (`TerminalSizeClaimDebounce`), so a
  quick switch away and back sends nothing and never resizes the Mac twice.
  The app entering the background (or the lock screen) releases at once,
  with no debounce, before iOS suspends it. Coming back claims at once:
  `resize-surface` with the last measured grid. While released, layout passes
  are remembered and not sent, and a reattach attaches without a size.
- **Stop (phone).** A session that stops (its tab cooled out of the warm set
  of 4, closed, another account) sends `release-surface-size` and waits for the
  answer (at most 2 s) before it closes its channel. The daemon would read a
  bare close as a dropped link and hold the grid.
- **Size lease (phone and daemon, `size-lease-v1`).** The phone lists
  `size-lease-v1` in `set-client-info` `capabilities`; when `identify` lists
  it, the phone sends its claimed size again every 15 s while it claims (a
  same-size `resize-surface` renews the lease and never resizes the PTY). A
  size not refreshed for 45 s is released by the daemon; a connection that
  ended without releasing ends the departed-view hold its own departure set
  at that moment (a later departure's hold runs on). A suspended or dead phone can never pin the Mac's grid past it.
- **Departed-view hold (daemon).** A phone's connection that ends without a
  release (the link dropped) keeps the grid from growing for 30 s, so a link
  blip that reattaches finds the grid it left (termqa V2-5); capped by the
  lease as above, and ended at once by a phone back with a size.
- **Release on purpose (cmux-mobile-host).** The Mac releases a phone's sizes
  itself, sending `release-surface-size` for every terminal the channel
  attached to or sized and waiting up to 500 ms for the answers before it
  closes the daemon socket, when: the phone closed the `daemon` channel (a
  `close` frame); the owner removed the phone (link closed `removed`); hostd
  exits (stdin ends or SIGTERM: iPhone connections turned off, the app
  quitting). A link that timed out or failed keeps the hold.
- **Link keepalive.** A dead link closes 15-35 s after its last frame
  ("Link"); the daemon socket closes with it.

The Mac app's Swift phone splice (`DaemonLaneSplice`, the irx connection
server) has no release of its own: a phone on that path relies on its own
release and the daemon's size lease.

| Path | Mechanism | Mac pane restored within |
| --- | --- | --- |
| Back to the workspace list | page disappears → release after debounce | 1 s + one round trip |
| Another tab of the workspace | page not interactive → release | 1 s + RTT |
| Tab grid opened | page not interactive (zoomed out) → release | 1 s + RTT |
| Another workspace, another Mac | page disappears → release | 1 s + RTT |
| Quick switch away and back (< 1 s) | debounce: nothing sent | no change (no thrash) |
| Page menu open longer than 1 s | page not interactive → release; claimed again on close | 1 s + RTT |
| Files and Links, photo picker or file importer over the page | covered → release | 1 s + RTT |
| A sheet the page does not own (Connected Devices) | still claims (the terminal shows behind it) | n/a |
| App to the background, screen locked | `didEnterBackground` → release at once, inside a short background task | one round trip |
| Force quit, killed by iOS while foreground | no release; lease ends (or keepalive + hold, capped by the lease) | 45 s |
| Killed by iOS in the background | already released on entering it | one round trip |
| Link drop: network loss, roaming | keepalive closes the socket; hold capped by the lease | 45 s (a reattach inside it keeps the phone's grid) |
| Transport switch | link redialled; hold; reattach finds the grid | no change if it reattaches within 30 s; else 45 s |
| Mac host (hostd) restarts: SIGTERM | hostd releases before exit | 0.7 s |
| hostd crashes or is killed (SIGKILL) | socket closes; hold capped by the lease | 45 s |
| The Mac's cmux-tui daemon restarts | new daemon, no phone participant until it reattaches | at once |
| iPhone connections turned off on the Mac | hostd SIGTERM → release | 0.7 s |
| The owner removes the phone on the Mac | link closed `removed` → hostd releases | 0.5 s |
| Phone signs out, "Remove This iPhone from My Macs" | links close (sessions stop and release when the link still carries them); else hold capped by the lease | 45 s worst case |
| Tab cooled out of the warm set, tab closed | session stop → release, then close; else hostd releases on the close frame | one round trip |
| Grid card of a tab not started | `read-screen` only, never attaches | never claims |
| Grid card of a started tab | its page is not interactive → release | 1 s + RTT |
| Several phones | each claims and releases its own; the grid is the Mac's again once every claim ended | the slowest phone's bound |
| A phone and another remote client (a second Mac, the TUI) | the phone's release makes the grid follow the remaining views; a non-handheld view never holds | as the phone's path |
| Older phone without `size-lease-v1` | no lease: hostd releases on its close frame, the keepalive + 30 s hold on a drop | 65 s on a drop |

Measured on the rig: cmux-next-ios/verify/size-release-20261021.md.

## Push notifications (API 0.13.0)

Rich, interactive notifications (`verify/rich-push.md`). Every field below is
optional and additive: a host before 0.13.0 sends none of them and gets the
0.11 banner; an older phone ignores what it does not read.

### Mac → Worker: `POST /v1/devices/:macId/notify`

Adds to the 0.7.0 body (the Worker cleans every string: control and format
characters become spaces, then it cuts to the limit in code points):

| Field | Limit | Meaning |
| --- | --- | --- |
| `kind` | | adds `terminal` (an OSC 9, OSC 777 or OSC 99 desktop notification from a program in a cmux terminal) |
| `workspace` | 60 | the workspace's title (`place` stays the folder name) |
| `workspaceId`, `tabId` | 128 | the daemon's ids; `tabId` is `s<surface>` for a terminal |
| `permissionId` | 128 | the acpmux permission id of a question or permission |
| `conversationId` | 128 | a Chief's home id (`kind` `chief`) |
| `notificationId` | 64 | the daemon ledger id of a terminal notification |
| `title` | 200 | the question, the permission's command or tool title, a terminal notification's title |
| `body` | 400 | a terminal notification's body, an error's summary, a Chief reply's first lines |
| `options` | 6 × (`id` 64, `label` 60, `kind`) | a permission's acpmux options (`kind` `allow_once`, `allow_always`, `reject_once`, `reject_always`) |
| `questions` | 4 × (`question` 200, `header` 30, `multiSelect`, `allowsOther`, `options` 6 × (`label` 60, `description` 120)) | an AskUserQuestion-style ask |
| `tail` | 6 × 160 | the last lines of the chat (never a terminal's screen: it stays on the Mac until payloads are sealed) |
| `state` | | `waiting`, `finished`, `failed`, `notified` |
| `replyable` | | a terminal notification whose poster takes a typed reply (`notify --reply`, daemon `notification-reply-v1`) |

The answer adds `wants`: the kinds any phone of the owner that has not muted
this Mac still wants, so the host skips kinds nobody wants. It sends a
skipped kind again 15 s after the answer, so a phone that turns a kind on
gets it within about that.

Only `eventId` and `kind` are required. Any other field that is malformed
(an id outside its pattern, a value of the wrong type, an unknown `state`, an
option without a valid `id`) is dropped, not the push. A text cut to its
limit ends with "…". Combining marks past two on one character are dropped.
Terminal notifications have their own rate bucket (60 a minute), apart from
the Mac's asks and turns; the host also sends at most one per terminal tab in
10 s and ten a minute.

Content moved from minimized to granular in 0.13.0 by the person's decision
(rich notifications). A permission's `title` is the tool's own title, which
for a shell command is the whole command line, and `tail` and `body` are what
the agent printed: they can name paths and command arguments. The host
redacts credentials in every text field first (tokens such as `sk-`, `ghp_`,
`xoxb-`, `AKIA`, JWTs, `Bearer` and `Basic` values, `password=`-style
assignments, PEM blocks and long high-entropy runs become `[redacted]`). The
person's prompts and a terminal's screen are never sent. Until payload
encryption (PR B, `sealed`) every field is visible to the Worker and to
APNs.

### Worker → APNs

```json
{"aps": {"alert": {"title": "Claude asks", "subtitle": "cmux-next · Mac mini", "body": "Which branch?"},
         "sound": "default", "mutable-content": 1, "thread-id": "<mac>:<sessionId>",
         "category": "CMUX_MOBILE_QUESTION", "interruption-level": "time-sensitive",
         "target-content-id": "<mac>:<sessionId>"},
 "cmuxMobile": {"v": 2, "mac": "…", "macName": "Mac mini", "kind": "question", "eventId": "p-…",
                "agent": "Claude", "place": "cmux-next", "workspace": "cmux-next", "workspaceId": "…",
                "tabId": "…", "sessionId": "…", "permissionId": "…", "title": "Which branch?",
                "questions": [{"question": "Which branch?", "multiSelect": false, "allowsOther": true,
                               "options": [{"label": "main"}, {"label": "dev"}]}],
                "tail": ["…"], "state": "waiting", "previews": true}}
```

- `thread-id`: `<mac>:<sessionId>`, else `<mac>:<tabId>` (terminal), else
  `<mac>:chief:<conversationId>`, else `<mac>`. Collapse ids are unchanged
  (#23803); a terminal notification collapses per Mac and `notificationId`
  (`term-<fnv64(mac)>-<notificationId>`, hashed when longer than 64).
- `category`: `CMUX_MOBILE_QUESTION` (one question, one choice, at most 4
  options), `CMUX_MOBILE_QUESTION_FORM` (any other ask: multi-select, more
  options, several questions, or none listed), `CMUX_MOBILE_PERMISSION`,
  `CMUX_MOBILE_COMPLETED`, `CMUX_MOBILE_FAILED`, `CMUX_MOBILE_CHIEF`,
  `CMUX_MOBILE_TERMINAL`.
- The payload stays under 4096 bytes: the Worker drops option descriptions,
  then `tail` lines from the oldest, then shortens `title`, then drops
  `questions` (the category becomes `CMUX_MOBILE_QUESTION_FORM`), then
  shortens `body`. If it still does not fit (every field full of 4-byte
  characters), only the ids, `kind`, `state` and texts cut to 20 characters
  stay.
- Banner text: question "<Agent> asks" / the question; permission "<Agent>
  wants to act on <Mac>" / the title, as the Mac's approval prompt for a
  streaming device ("<device> wants to control this Mac"); completed
  "<Agent> finished" / the last `tail` line; failed "<Agent> stopped with an
  error" / `body` or the last line; chief "Chief" / `body`; terminal
  "Terminal · <workspace>" / "<title>: <body>" (a program never chooses the
  banner's title). Subtitle "<workspace or place> · <Mac>"; for a permission
  only "<workspace or place>" (the Mac is in the title). The phone writes the
  same text for a sealed push (`PushBanner`, `ApprovalBanner`).
- `previews: false` (the phone turned Show previews off): the 0.11 banner
  text ("Claude has a question", body the Mac's name) and no subtitle; the
  `cmuxMobile` fields stay, so the buttons still work after unlock.

### Phone → Worker: `PUT /v1/devices/:deviceId/push`

Adds `mutedMacs` (at most 64 Mac device ids: no push from them) and
`previews` (boolean, default true). `kinds` adds `terminal`. The answer echoes
both. The app's levels: Only when I'm needed = `question`, `permission`;
Needed and finished = those and `completed`, `chief`; Everything = all six
plus `failed` and `terminal`.

### Terminal agents' questions

A terminal-hosted agent's question (Claude Code AskUserQuestion, Codex
`request_user_input`) reaches the phone from its hook: the daemon's
`notification` event and that `list-notifications` row carry `question`
`{harness, tool_use_id?, questions: [{id?, question, header?, multiSelect,
isOther?, options: [{label, description?}]}]}` while the agent waits on it
(memory only; cmux-tui `agent_hook_question.rs`, `session.journal.append`
`live_question`). The Mac host pushes it as kind `question` with `questions`,
`tabId` (`s<surface>`), `notificationId` and no `permissionId`. The phone
answers it on that Mac by typing into the terminal (`send`) while
`read-screen` shows the question; see SECURITY.md "Answering a terminal
agent's question from the phone".

### Phone actions

| Identifier | Kind | Options | Delivery |
| --- | --- | --- | --- |
| `cmux.option.<i>` | question (one choice) | foreground, authenticationRequired | the app opens, Face ID, signed answer |
| `cmux.answer` ("Answer…") | question | foreground | the app opens on the question |
| `cmux.allow.once` | permission | foreground, authenticationRequired | the app opens, Face ID, signed allow. No Always allow beside it: as in the Feed (`phoneOptions`), acpmux refuses a lasting grant from a paired phone |
| `cmux.allow.always` | permission with no single-use Allow | foreground, authenticationRequired | as the Feed (`phoneOptions`): the agent's own options are offered, so the app opens, Face ID, signed allow, and acpmux refuses it (`remote.lasting_grant_refused`). Over the link the phone shows "Allow for this chat on the Mac"; through the mailbox the Mac's signed ack is only `refused`, so it shows "Your Mac didn't accept the reply." |
| `cmux.deny` | permission | destructive, authenticationRequired | background, unsigned reject |
| `cmux.reply` (text input) | completed, failed, chief | authenticationRequired | background: a prompt to the session, or a Chief message |
| `cmux.terminal.reply` (text input) | terminal (PR B) | authenticationRequired | background: input to the terminal |
| `cmux.retry` | the "Couldn't reach <Mac>" notification | foreground | the app opens and sends again |

The content extension replaces the buttons with the payload's own options
(`extensionContext.notificationActions`). Its option rows, Submit and its
composer write the request to the App Group outbox and open the app, which
sends it over that Mac's link and opens the chat.

A terminal agent's question push is named by what it asks: `q-` and the 64-bit
FNV-1a, in hex, of its prompts and option labels (`prompt \u{1} label \u{2}
label ...`, questions joined by `\u{0}`). It is pushed once per tab in 30 s,
though Claude Code fires two hooks for it in either order (PermissionRequest
carries no `tool_use_id`). The phone answers a notification only while that
very question is pending on its tab; any other push is answered from the Feed card.

## Sealed pushes and the reply mailbox (API 0.14.0, `feat-cmux-next-ios-push-fallback`)

Held for the #13742 decision (`verify/notifications-trust.md`). Every
addition is optional: a phone or Mac without it keeps PR A's behavior.

### Crypto (shared by hostd, the app and its service extension)

- **Seal** (ECIES, P-256): an ephemeral P-256 key `E`; `z = ECDH(E, R)` for the
  recipient key `R`; `k = HKDF-SHA256(ikm: z, salt: E_pub || R_pub, info:
  context, 32 bytes)`; AES-256-GCM with a random 12-byte nonce and the
  associated data `context`. Wire: base64url of
  `0x01 || E_pub (65 bytes, X9.63) || nonce (12) || ciphertext || tag (16)`.
- **Contexts**: a push `cmux-mobile-push-seal-v1 \0 mac \0 phone \0 eventId`; a
  reply `cmux-mobile-reply-seal-v1 \0 mac \0 phone \0 replyId`.
- **Mac box key**: hostd derives the P-256 scalar from its identity key:
  `HKDF-SHA256(ikm: identity scalar, salt: "", info:
  "cmux-mobile-mac-box-v1", 32 bytes)`, reduced into `[1, n-1]` (taken again
  with a counter byte appended to `info` while it is out of range).
- Signatures are ECDSA P-256 / SHA-256, raw `r || s`, lowercase hex, as
  elsewhere.

### Keys at pairing (`auth`)

- The phone adds `pushKey` (X9.63 hex, its push key) and `pushKeySignature`
  (identity key) over `cmux-mobile-push-key-v1 \0 mac \0 phone \0 pushKey` to
  `auth` args. hostd keeps it for the paired phone (0600 state file) once
  `auth` passes. A phone without it gets unsealed pushes.
- The challenge adds `macBoxKey` and `macBoxSignature` (Mac identity key)
  over `cmux-mobile-mac-box-v1 \0 mac \0 macBoxKey`. The phone verifies it with
  the pinned Mac identity key and keeps the box key with its signature; it
  checks the signature against the pin again before it seals each reply.
- A push key that does not verify is ignored (logged), never a pairing
  failure: that phone simply gets unsealed pushes.
- Once a Mac proved a box key after the phone gave it a push key, that Mac
  *seals*: the phone acts on no unsealed push that names it (generic banner,
  no buttons, a tap only opens the app).

### Sealed notify (Mac → Worker → APNs)

`POST /v1/devices/:macId/notify` adds `sealed: {"<phone device id>": {"box": "<sealed>", "sig": "<hex>"}}`,
where `box` seals the v2 `cmuxMobile` object (plus `decisionNonce` and
`personInstance` for an ask, so the phone can sign an answer offline) and
`sig` is the Mac identity signature (64 bytes, 128 hex digits) over `cmux-mobile-push-v1 \0 mac \0 phone \0
eventId \0 box`. The box also carries `postedAt` (Unix seconds). At most 20
phones; `box` is base64url of at most 3072 characters (hostd trims the content
to fit, and skips a phone whose box still would not). When every paired phone
has a push key the Mac sends no content fields, also when one box failed or
its identity key has not arrived (those phones get the generic banner from
the ids alone); a phone without a push key gets the v2 payload built from the
content the Mac then sends beside `sealed`. The Worker sends a phone listed
there `{"aps": {"alert": {"title": "cmux", "body": "New notification from
<Mac>"}, "mutable-content": 1, "category": "CMUX_MOBILE_SEALED" (no buttons),
"thread-id": FNV-1a of the v2 thread id, 16 hex digits}, "cmuxMobile": {"v": 3,
"mac", "macName", "kind", "eventId", "previews", "box", "sig"}}`. The service
extension checks `sig` against the pinned Mac key, opens `box` with the push
key, fills in the v2 content, category and thread, and keeps the v3 object
(`cmuxMobileSealed`) beside them; the app opens that box again before any
button acts. If it can't open it, the generic banner and no buttons stay. A
push older than 15 minutes (`postedAt`) shows its text with no buttons.

### Reply mailbox

- Phone → Worker: `POST /v1/devices/:macId/mailbox` `{id (uuid), from (the
  phone's link device id), sealed}` → `{queued: true, delivered}`. The caller
  must own `from` (a phone) and `:macId` (a Mac), else `403 not_owner`;
  `sealed` is base64url of at most 16384 characters (the phone refuses a
  larger reply itself); at most 32 pending per Mac
  (`429 rate_limited`) and 60 posts a minute per user. Kept in the user hub for
  10 minutes. The same `id` with the same blob is the same item (a retried
  request, answered `{queued: true, delivered: false}`); with another blob it
  is `409 conflict`.
- Worker → Mac socket: `{"type":"mailbox","items":[{id, from, sealed, at}]}` at
  once when the Mac's signaling socket is open, else right after its `hello`.
  The Mac answers `{"type":"mailbox_ack","results":[{id, applied, reason?, sig}]}`
  (at most 64; `reason` `[a-z_]{1,32}`, else `refused`) for each item it
  settled. `sig` is the Mac identity signature over `cmux-mobile-mailbox-ack-v1
  \0 mac \0 id \0 1|0 \0 reason` (empty reason when applied); the hub keeps it
  as sent (128 hex digits, else none). An item the Mac could not settle yet
  (its app has not sent the keys or paired list within 10 s, a service it
  applies through is not reachable, another copy is being applied) gets no
  result: it stays queued and the Mac tries it again every 30 s while its
  socket lives, and on the next delivery. The hub takes it only
  from a Mac socket (a phone gets `error bad_request`), settles only that Mac's
  own queued items, clears each blob, and keeps the outcome for 10 more
  minutes. Removing either device (`DELETE /v1/devices/:id`) deletes its items.
- Phone → Worker: `GET /v1/devices/:macId/mailbox/:id` → `{state: "queued" |
  "applied" | "rejected" | "expired", reason?, sig?}`; `404 not_found` for an
  id it never had or forgot. The phone takes `applied` or `rejected` only with
  a `sig` that verifies against the Mac's pinned key; otherwise it says "Not
  confirmed by <Mac>". It asks after 1, 2, 4 and 8 s. A retried `POST` of an
  id the hub holds with another blob (`409`) counts as queued.
- The sealed plaintext (canonical JSON, keys in byte order):
  `{v: 1, id, mac, phone, kind, target: {sessionId?, permissionId?,
  conversationId?, tabId?, notificationId?}, action: {type: "option" |
  "answers" | "allow" | "deny" | "text", optionId?, answers?, text?},
  approval?, nonce, issuedAt, expiresAt, sig}` where `approval` is the acpmux
  `_meta.acpmux` decision the phone signed after Face ID (Allow, answers) and
  `sig` is the phone identity signature over `cmux-mobile-reply-v1 \0 mac \0
  phone \0 sha256(canonical JSON without sig)`. The phone uses a 540 s window
  from when the person made the reply (a Retry keeps it, never starts a new
  one); the Mac takes `expiresAt` at most 600 s after `issuedAt` and at most
  660 s after its own clock (60 s for a phone clock ahead). `nonce` is 16 to
  128 letters or digits (the phone sends 32 lowercase hex digits); `text` at
  most 4096 bytes. A `deny` may leave out `optionId`: the Mac then picks the
  prompt's `reject_once`, else its first reject.
- hostd applies it only after the checks in `verify/notifications-trust.md`
  ("What the Mac checks"), and reports `applied` or the first failing check:
  `unsealed`, `not_paired`, `bad_signature`, `expired`, `replayed`,
  `not_pending`, `refused`. A repeat of a reply id the Mac already settled
  (over the link or the mailbox) answers that first outcome again, signed;
  `replayed` means another reply already used the nonce. hostd keeps each
  spent id's outcome on disk until it expires, and applies nothing while that
  file cannot be read.

### Terminal replies

The `daemon` policy allows `notification-reply {notification, text, reply_id?}`
(a ledger id, 1 to 4096 bytes of text and the reply's id, no other field).
The daemon has no such command: hostd answers it itself. It finds the
notification in the session's ledger (`list-notifications`; gone:
`not_found`) and applies the text only when:

- the row asked for replies (`reply: true`, `cmux notify --reply`);
- it is at most 15 minutes old;
- the program that posted it still holds its terminal: the daemon records
  the terminal's foreground process-group leader and its executable when the
  row is posted (`list-notifications` `notification`, `poster_pid`,
  `poster_executable`, memory only; `process-info` adds `foreground_pid`),
  and both must match now. A program that exited, another program, or a new
  process of the same name gets nothing (`not_found`); a daemon that records
  no poster gets no terminal reply.

Then it pastes the text and sends Return, each `send` with `expect_foreground`
naming that program. For an agent's notification (`source` `agent`, a hook on
a terminal tab) on a daemon with `send-expect-agent-v1` (manaflow-ai/cmux#24205)
it sends one `send` with `submit: true` and `expect_agent: {}` instead, so the
text and Return are written only while the agent waits at its prompt; a daemon
or host policy without it gets the two writes. The answer is a v12 line,
`{"id", "ok": true}` or an error. The phone's `cmux.terminal.reply` action
sends it over the link, or through the mailbox with `kind` `terminal`, whose
`target` also names the tab (`s<surface>`), which must be the notification's.

hostd keeps phones' push keys in `<state>/push-keys.json` and spent reply
ids and nonces in `<state>/mailbox-spent.json` (both mode 0600; public keys
and ids only).

## Terminal sizing policy (`host-size-policy-v1`; added 2026-10-23)

A shared terminal has one PTY grid. When several devices show it (this Mac,
one or more phones, another Mac), the **sizing policy** of the Mac decides
which device's size the grid takes. It is one setting per Mac, stored by that
Mac and applied by its cmux-tui daemon. The phone and the Mac's
Settings > Mobile both edit the same value; the phone only sends a
preference. The classic app's equivalent is the terminal size sheet of
docs/shared-terminal-sizing.md (PR #18866); cmux-next keeps its modes and
priority order but makes the policy per Mac instead of per terminal.

### Modes

| Setting value | Shown as | Engine policy the daemon applies |
| --- | --- | --- |
| `smallest` (default) | Fit the smallest viewer | `smallest`: every viewer sees the whole grid |
| `mac` | Prefer this Mac | `priority` with this Mac's own views first; when no view of this Mac counts (its pane hidden), the most recently active other viewer |
| `latest` | Prefer the active device | `latest`: the viewer that typed, pasted or focused last |
| `priority` | Priority order | `priority` over `order`, highest first; a viewer not in the list counts only when no listed viewer does (then the most recently active) |

Only viewers that **claim** a size count ("Terminal size claims" above): a
phone claims while its terminal page is on screen, so the policy only ever
chooses among the devices that are showing the terminal right now. A phone
that stops showing it releases its claim and the grid follows the remaining
claims under the same policy.

A per-terminal or per-workspace override (`set-size-policy {surface}` or
`{workspace}`, for example the Mac pane's Take Over) still wins over the
Mac's policy for that terminal, as before.

### Storage (the Mac)

Two keys of the Mac's settings file (`~/.config/cmux/cmux-next.json`,
owned by the daemon):

- `mobile.terminalSizing`: `"smallest"` | `"mac"` | `"latest"` | `"priority"`.
  Shown in Settings > Mobile as "Terminal Size When Shared".
- `mobile.terminalSizingOrder`: the priority order, a list of **device
  tokens**, highest first (at most 32): `"mac"` is this Mac's own views (its
  panes and its cmux-tui frontend); `"device:<id>"` is the viewer whose
  device id is `<id>` (1 to 128 of `[A-Za-z0-9_.:-]`). Hidden on the Mac's
  page; edited from the phone.

The daemon re-reads both on `settings-changed`, re-resolves every live
terminal without an override, and publishes `size-state` when a terminal's
policy changes. An unknown mode reads as the default.

### Who is "this Mac"

The daemon decides it from what it verified about each connection, failing
closed. A participant is one of this Mac's views only when its device kind is
a desktop kind (`mac`, `tui`, `linux`, `windows`) and its connection is the
in-process frontend or a local Unix connection that:

- has no `cmux link` peer record (a WebSocket, a remote-entry stream or a
  link peer is never this Mac, whatever it says it is);
- was not accepted from this build's bundled `cmux-mobile-host`. At accept
  the daemon reads the socket peer's executable and compares its real path
  with the `cmux-mobile-host` beside the daemon's own executable
  (`Contents/Resources/bin/`). On macOS it reads it by the peer's audit token
  (`proc_pidpath_audittoken`), which the kernel refuses once the pid carries
  another pid version (a process that reused the pid, or exec'd since it
  connected). On Linux it reads `/proc/<pid>/exe` and then checks the pid
  still has the start time of the peer key, which catches pid reuse but not
  an exec after connecting;
- is not marked `remote`. cmux-mobile-host (and the Mac app's Swift
  `DaemonLanePolicy` splice) rewrite every phone's `set-client-info` to carry
  `remote: true` and the link's own device id as `device_id`, so a phone can
  neither pose as this Mac nor as another phone in the order. The mark is
  sticky and never published in `size-state`.

A phone relays no other device, so a relay sub-view it opens
(`resize-attached-view {view, identity}`) names no user and no device: both
splices drop `identity.user_id` and `identity.device_id`, and the daemon drops
them again for a phone's lane (one accepted from hostd or marked `remote`).
Such a sub-view gets its own priority key and is never ranked by a `device:`
token. A sub-view relayed by one of this Mac's own connections keeps its
identity.

### Who may change it

`set-host-size-policy` is accepted only from the verified cmux app (origin
`user`, `client-hello` with its proof) and from a connection accepted from
the bundled `cmux-mobile-host` (a phone's lane; hostd lets only the Mac
owner's paired phones in). Every other connection (an agent or a script on
this Mac, the CLI, another machine) may read the policy but gets
`forbidden` when it writes. The write is stored as the app's own (both keys
are person-only settings).

The refusal is the daemon error `forbidden: ...`; the phone shows "This Mac's
cmux doesn't allow changing it from a phone." It also happens where no
bundled hostd sits beside the daemon (a development daemon started from
another folder, `CMUX_NEXT_TUI_BIN`, a `~/.local/bin/cmux-tui`), and on Linux
after an in-place upgrade replaced either binary while it ran: then no phone
lane may write the policy, and phones still never count as this Mac.

Residual risk: the hostd check trusts the executable path, so another
process of the same user that runs the bundled `cmux-mobile-host` binary
itself counts as a phone lane (on Linux also one that exec'd it after
connecting). That binary only forwards lines from an
authenticated phone link through its own allowlist, so such a process gains
nothing it could not already do with the same user's access to the settings
file. The Mac app's Swift phone splice (`DaemonLaneSplice`) connects from the
app process without `client-hello`, so a phone on that path can read the
policy but not change it. That splice has no size release of its own
("Terminal size claims"): under the default Fit the smallest viewer, a phone
on it that was killed keeps the Mac's pane at its size until the size lease
ends (45 s).

`get-host-size-policy` answers the policy in effect: before the daemon's
settings owner has read the settings file (only at startup, before it
serves connections) that is the engine default (`latest`), as the terminals
then use.

### Commands (cmux-tui daemon, `host-size-policy-v1` in `identify`)

- `get-host-size-policy {surface?}` →
  `{policy: {mode, order}, mac_participants: [participant id]}`.
  `mac_participants` lists the size-state participant ids of `surface` that
  are this Mac's views (empty without `surface`).
- `set-host-size-policy {policy: {mode, order?}}` → `{policy}`. Writes both
  settings keys (an omitted `order` keeps the stored one), then applies as
  above. Refused with `bad_request` for an unknown mode or a bad token.
- `get-size-state {surface}` → `{state, self_participant}` (existing).
- `note-size-activity {surface}` (existing) on the attach connection: the
  phone sends it when the person types, pastes or taps the terminal, at most
  once a second and only while it is not already an owner, so `latest` can
  pick the phone. Keystrokes travel on the input lane, a different
  connection, so they cannot count as the attach view's activity by
  themselves.

cmux-mobile-host (and the Mac app's Swift `DaemonLanePolicy` mirror) allow
these four from a phone. `set-size-policy` and `set-size-counts` stay closed
to a phone: it changes the Mac-wide preference only.

### Phone

- `set-client-info` `capabilities` add `shared-sizing-v1` (the attach stream
  then carries `size-state` events) and `host-grid-view-v1` (this phone
  renders a host grid larger than its own; see below). A daemon that caps a
  handheld's applied grid at its viewport stops doing so for a connection
  that lists `host-grid-view-v1`.
- **Settings > Terminal > Terminal Size When Shared** lists the phone's
  Macs; each Mac's page edits that Mac's mode and, in Priority order, a
  reorderable list of its devices (This Mac, this iPhone, other phones and
  Macs seen on it). The terminal's title menu opens **Connected Devices**
  for the terminal on screen: the grid, why it has that size, every
  connected viewer with the size it asks for (its claimed viewport, or "Not
  showing it" when it has released its claim) and which viewer sets the
  grid, and the same policy controls for that terminal's Mac.
- **A grid larger than the phone.** The phone renders the host's grid
  exactly at its own font size: wider than the phone, the terminal pans
  horizontally (it follows the cursor while typing); shorter than the
  phone, the grid is pinned to the top and the rest is letterboxed with the
  terminal background and a one-line note (`120×40 · set by <device>`).
  It never reflows the host's output to its own width.
