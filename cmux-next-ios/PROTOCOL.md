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
  paired phones), so a Mac running Stable and NIGHTLY, or a dev build, is on the
  account more than once. A Mac registers `machineId`, the same for every build
  of one account on that computer: HMAC-SHA256 under the key
  `cmux-mobile machine-id v1` of `<owner sub> NUL <16-byte host UUID>`
  (`gethostuuid`, the IOPlatformUUID), first 16 bytes in lowercase hex. The
  hardware id never leaves the Mac, and two accounts on one Mac get unrelated
  ids. Builds stay separate devices on purpose: one shared device id would make
  two running builds replace each other's signaling socket (4000 `replaced`),
  and would make a debug build hold the identity key phones pin for the
  release build.
- Every build is its own Mac on the phone (changed 2026-11-12; from 2026-10-21
  the phone listed one Mac per (owner, machine id) and marked the rest "Another
  cmux build on this Mac"). The phone lists, links and removes each build on
  its own. Each build names itself apart: the Mac registers `name` as the
  computer's name for the Stable lane (`com.cmuxterm.app`, cmux NEXT Stable
  `com.cmuxterm.app.nightly.cmux-next-stable`) and `<computer name> (<lane>)`
  for any other build (`NIGHTLY`, `DEV <tag>`, `RC`, `STAGING <tag>`;
  CmuxNextCompat `BuildIdentity.instanceLabel`). The phone names itself the
  same way: the App Store build by the phone's name, every other build with its
  label (`INTERNAL`, `BETA`, `PROD`, `DEV`, `DEMO`; Info.plist
  `CmuxMobileInstanceLabel`). A name is never an identity: Macs that share a
  name stay separate (with the name tag).
- A Mac's device id is per account (changed 2026-11-12): each account signed in
  to one build keeps its own id (`<state>/device-id.<owner sub>`) and its own
  paired-phone list, so account B never registers the id account A owns (which
  the service refuses with `403 not_owner`). An older build's single
  `device-id` is adopted by the account its paired list names. If registration
  still answers `not_owner`, hostd emits `{"type":"device_not_owned"}` and exits
  with status 79; the app forgets that account's id and starts hostd with a new
  one (at most twice per launch). Each id records the machine id it was made on
  (`device-id.<owner sub>.machine`): a state folder that Migration Assistant or
  a restore copied to another Mac carries the old Mac's value, so the new Mac
  makes its own id instead of registering as the old one.

## Build spaces (API 0.16.0)

Two dev builds of the app and Mac host (say tags `a` and `b`), signed in as the
same person, never see or touch each other's data on the service, and never see
nightly or stable data. Each build is in a **build space**:

- A dev build sends `X-Cmux-Build-Space: dev:<slug>` on every HTTP request and
  on the signaling WebSocket upgrade. `<slug>` is the dev tag's slug
  (`scripts/lib/mobile-attach.sh`: lowercase letters, digits and inner dashes,
  at most 64), so the value matches
  `^dev:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$`. `dev:default` is refused:
  `default` is the stable instance's reserved tag.
- Stable and nightly builds send nothing: the stable space `""`, where every
  row and hub that predates build spaces stays.
- A malformed value is refused with `400 build_space.invalid` before anything
  else; it never falls back to the stable space.
- Only the dev, test and local Workers (`ENVIRONMENT` `dev`, `test`, `local`)
  serve dev spaces. Every other Worker, production included, and one whose
  environment is missing or misspelled, refuses them with
  `403 build_space.not_allowed`: production holds only stable data, so a dev
  build pointed at it fails on its first request instead of reading or writing
  a person's real devices. Dev builds use the dev Worker or a local one.

What a space scopes: the device registry (`/v1/devices`, `/v1/me/devices`,
`/v1/me/macs`, `/v1/teams/:teamId/macs`, bootstrap), push registrations and
notify targets, team prefs, the reply mailbox, and the user hub. A device id
held by another space is never found (404). Each build keeps its own id, and a
device id is one install of one build, so `POST /v1/devices` of an id the
caller holds in another space moves that device, with its push registration,
into the caller's space: the other space's hub drops it (presence `removed`,
its socket closed with 4002) and it is listed only in the new space. This is
how a dev build that registered before build spaces (its row is in stable) or
whose dev tag changed keeps working. An id another user holds in another space
is refused with `409 build_space.device_conflict` and left alone. A
dev space's hub is named `dev:<slug>|user:<owner key>`; the stable hub keeps
`user:<owner key>`, so presence, `hello`, signaling admission and turn push
coalescing never cross spaces. `DELETE /v1/me` from a dev build purges only its
space; from a stable build it purges every space (the account is deleted).
Cloud attention pushes go only to stable phones. Wire shapes do not change:
no response carries the space.

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
`conflict` (409, 0.14.0: a mailbox item id reused with another blob),
`build_space.invalid` (400), `build_space.not_allowed` (403) and
`build_space.device_conflict` (409) ("Build spaces", 0.16.0), `store.schema_outdated` (503, 0.16.0: the
Worker was deployed before its database migration; the message names it), `membership_unavailable` / `invite_failed` / `hub_unavailable` (502; `hub_unavailable` since 0.10.0 when the caller's hub refuses a signaling socket for an internal reason).

| Method + path | Body / result |
| --- | --- |
| `POST /v1/devices` | `{deviceId, kind, name, teamId, wgPublicKey?, machineId?, siblingDeviceIds?}` → `{device:{deviceId,ownerUserId,teamId,kind,name,wgPublicKey,machineId?,createdAt,updatedAt,lastSeenAt}}` (upsert; caller must be a team member; a deviceId owned by another user is `403 not_owner`). `machineId` (added 2026-10-21, "Machine id" above; every Mac list, `hello` and `presence` carries it, and omits the key for a Mac that has none) is a Mac's only: 32 lowercase hex digits, else `400`; omitted keeps the stored one. `siblingDeviceIds` (with `machineId`, at most 16 UUIDs) are the device ids of other cmux builds found on the same Mac (their `device-id` files): each that is a Mac of the caller with no machine id yet gets this one, so a deleted build's record is listed as that computer's; another owner's device, a phone or a Mac that reported its own machine id is never changed |
| `GET /v1/teams/:teamId/macs` | → `{macs:[{deviceId,name,online,lastSeenAt,ownerUserId,machineId,quietMs?}]}` (`quietMs` added 2026-11-21: "Mac freshness"): the caller's own Macs registered in `teamId` (caller must be a member). Changed in 0.10.0: a teammate's Macs are never listed (before, every Mac of the team was), so `ownerUserId` is always the caller |
| `GET /v1/me/macs` | → `{macs:[{deviceId,name,teamId,online,lastSeenAt,ownerUserId,machineId,quietMs?}]}` (`quietMs` added 2026-11-21: "Mac freshness"): the caller's own Macs (registered by the caller, the only Macs v1 lets it dial) in every team the caller still belongs to and in its personal space, with presence from the caller's hub. Added in 0.5.0 so a phone finds its Mac whichever team either side has selected; the app polls it (every 4 s while its active team has no online Mac, else every 30 s) and moves to the team of an online Mac. `502 membership_unavailable` when Stack cannot list the caller's teams |
| `GET /v1/teams/:teamId/prefs` | → `{color, emoji, transparent}` for the caller (per user per team; `transparent` added in 0.12.0, always `false` without an icon) |
| `PUT /v1/teams/:teamId/prefs` | `{color?: "#RRGGBB", emoji?: string\|null, transparent?: boolean}`. `emoji` is the avatar glyph: `null` = automatic (team initial), `""` = none (color only), otherwise exactly one grapheme (letter, digit, symbol or emoji; not whitespace). `transparent` (0.12.0) draws that grapheme with no background; `true` needs one (`400` otherwise; `false` is always accepted), `color` stays stored as the fallback for clients that predate it, an `emoji` change to `null` or `""` turns it off, and a PUT that sets `color` without `transparent` (any older build) turns it off. Answers the stored `{color, emoji, transparent}` |
| `POST /v1/teams` | `{name}` (1 to 64 characters, trimmed, no control characters; 3 a minute per user) → `{team:{id,name}}`: creates a Stack team with the caller as creator and first member, using the project's server key (Stack refuses client-side team creation), then grants the caller `team_admin` so the web team settings treat them as its admin. If that grant fails, the team is deleted again and the route answers `502 team_create_failed`. `503 team_creation_unavailable` when the Worker has no server key for the caller's project; `403`/`502 team_create_failed` when Stack refuses. New clients list, create, rename and delete teams through the web team API (`/api/teams`, docs/team-settings-and-invites.md); this route stays for older builds. |
| `POST /v1/teams/:teamId/invites` | `{email}` → `{url, sent:true}`: Stack emails a team invitation whose link opens `url` (the configured callback) with the code. Changed from a bare link: without a Stack server key the API can only send the invitation email, not mint a shareable link. Needs the caller's `$invite_members` team permission. |
| `GET /v1/ice` | → `{iceServers:[{urls:[...],username?,credential?}], ttl, turn}` from the Cloudflare TURN key (generate-ice-servers), STUN `stun:stun.cloudflare.com:3478` always included (STUN only if TURN is unavailable). `turn` (0.7.0) is `false` when no TURN server could be included: clients must say so (off-LAN WebRTC may then fail) instead of failing silently. `ttl` is 1 h (was 4 h) |
| `GET /v1/me/devices` | → `{devices:[{deviceId,kind,name,teamId,createdAt,updatedAt,lastSeenAt,online,machineId,push}]}` (0.7.0): every Mac and phone the caller registered, in any team or personal space. `online` is live presence for Macs and `null` for phones; `push` is whether the phone has an APNs token |
| `DELETE /v1/devices/:deviceId` | → `{deleted:true, deviceId}` (0.7.0). Owner only (`403 not_owner`, `404 not_found`). Deletes the row and its push token; the owner's hub drops the Mac from presence (broadcasting `presence` with `removed:true`), closes the device's signaling socket with code 4002 `removed`, and ends its signaling sessions. A removed device that registers again is a new registration: removal tidies stale devices, it does not ban an id. Used by the phone (Settings → Connection → Macs / Phones) and by the Mac app ("Unpair this Mac") |
| `PUT /v1/devices/:deviceId/push` | `{token, environment, topic, kinds?}` → `{push:{environment,topic,kinds,updatedAt}}` (0.7.0). Phone only, owner only. `token` is the APNs device token in hex (64 to 200 hex digits), `environment` `sandbox` or `production` (the app's `aps-environment`), `topic` its bundle id, which must be one of the Worker's `APNS_TOPICS`. `kinds` is which events to push (default all): `question`, `permission`, `completed`, `failed`, `chief` |
| `DELETE /v1/devices/:deviceId/push` | → `{deleted:true}` (0.7.0): stop pushing to this phone (sign-out, notifications turned off) |
| `POST /v1/devices/:deviceId/notify` | `{eventId, kind, agent?, place?, workspaceId?, tabId?, sessionId?}` → `{configured, sent, failed, dropped, skipped?, coalesced?, failures?}` (0.7.0; `failures` below). `:deviceId` is a Mac the caller owns. Pushes one event to every phone of the same owner that registered a token and wants that `kind`. Content minimization: the Mac sends only a kind, a short agent name (≤ 40 characters) and a short place such as the workspace title (≤ 60); the Worker writes the text itself ("Claude has a question", "Claude needs permission", "Claude finished", "Claude stopped with an error", "Chief replied") with the place as the body, and never forwards agent output, prompts, tool arguments or paths. The payload's `mobile` object carries `{mac, kind, eventId, workspaceId, tabId, sessionId}` so a tap opens that tab. APNs `thread-id` is the `sessionId`, so a phone groups a session's notifications (0.13.0: `<mac>:<sessionId>` and the other fields of "Push notifications" below, which also add the answer's `wants`). The collapse id is `eventId` (≤ 64) for a question or permission; for a finished turn, an error or a Chief reply it is one id per session (`turn-<sessionId>`, hashed when longer than 64), so a newer one replaces the older. The Worker passes at most one turn-ending event per Mac, session and finished-or-error in 15 s, once some phone wants the kind (the user hub's `turnPushAllowed`); the rest answer `{sent: 0, coalesced: true}`. The Mac reports only what a person can act on (`cmux-mobile-host` `notify.rs`): never a Chief's compactor (`cmux.chief.role` `compactor`, or an `optchat-compact-` name, preset or folder); a Chief turn session (`cmux.chief`) as `chief`, once per Chief; no finished turn of a sub-session or a Chief's child (their asks still push); and per session at most one finished turn and one error in 30 s, the newest held one sent when the window ends. `configured:false` when the Worker has no APNs key. Tokens APNs reports as gone are deleted (`dropped`). Rate limited per Mac (`429 rate_limited`) |
| `DELETE /v1/me` | → `{deleted:{devices:n}}` (0.7.0): purges everything the Worker stores for the caller (devices with their push tokens, team prefs) and evicts the caller's sockets: the caller's hub closes every socket with 4002 `removed` and forgets its devices and sessions. The app calls it first when the user deletes their account, then deletes the Stack account through cmux's account deletion (`DELETE <cmux API>/api/account`, as the main cmux app) |
| `POST /v1/me/bootstrap` | `{teamId, devices:[{deviceId,kind,name}]}` (at most 4) → `{devices:[{device}\|{error}], macs:{macs}\|{error}, myMacs:{macs}\|{error}, ice:{iceServers,ttl,turn}\|{error}}`: the phone's launch in one round trip (added in 0.8.0). Each part is the response of its own route (`POST /v1/devices` with `teamId`, `GET /v1/teams/:teamId/macs`, `GET /v1/me/macs`, `GET /v1/ice`), run at once; a part's error does not fail the others. A 404 means an older service: make the separate calls |
| `POST /v1/diagnostics/connectivity-incidents` | One state of a major connectivity incident (0.15.0; "Connectivity incidents" below) → `202 {accepted:true, route:"team"\|"test", note?:"duplicate"\|"rate_limited"}`; `403 not_team` / `email_unverified` for anyone whose verified Stack email is not on a cmux team domain; `409 conflict` for an incident id another account used; `502 user_unavailable` when Stack cannot be asked (retry) |
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

- server → client on connect: `{"type":"hello","you":deviceId,"macs":[{deviceId,name,online,lastSeenAt,ownerUserId,quietMs?}]}` (the user's own Macs in the socket's team; `quietMs`: "Mac freshness" below)
- server → the user's sockets of the Mac's team: `{"type":"presence","mac":{deviceId,name,online,lastSeenAt,machineId,quietMs?}}` (`machineId` added 2026-10-21; `quietMs` added 2026-11-21, "Mac freshness" below; also in `hello.macs`, and sent again when a registration gives an older build its machine id); a deleted Mac's last presence adds `"removed":true` (0.7.0), and clients drop it from their lists
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
    in-tunnel `reach` message (below). `relay` (0.17.0, optional) says the
    sender can join the session's WebSocket relay ("WebSocket relay"
    below): `"ready"` (when nothing else reaches the peer) or `"now"` (it
    has no other path: no plain UDP and no TURN allocation, so the peer
    joins at once too); absent from older peers, which never join, and
    then neither does this side. A roam's endpoint announcement
    (`{"t":"endpoints", generation, endpoints, relayed?, relayedTls?, mapped?, mappedBy?}`)
    carries a new allocation's address the same way. Older peers omit all
    of these, and the label stays `direct`.
  - `wg-endpoints` `{generation, endpoints, relayed?, relayedTls?, mapped?, mappedBy?}` (API
    0.9.0; `mapped`, `mappedBy`: "Mapped endpoints" below): the same endpoint announcement a roaming side sends inside the
    tunnel (below), also sent through signaling, because the peer may not
    receive anything from the new address yet (a NAT that filters by
    address). The receiver applies the newer generation of either copy.
    Older peers ignore it (an unknown kind).
  - `wg-relay` `{}` (0.17.0): the sender joined the session's WebSocket
    relay because nothing it sent reached the peer otherwise; the peer
    joins too. Sent only to a peer whose `wg-init` / `wg-resp` carried
    `relay`.
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
  data. A WireGuard path without UDP is TURN over TLS (below), and past
  that the session's own WebSocket relay (0.17.0, "WebSocket relay"), a
  separate object per session reached on its own route, never this socket.
- WireGuard specifics: `publicKey` is base64 Curve25519; `endpoints` are
  `ip:port` strings (host and STUN-reflexive addresses of the tunnel's UDP
  socket); `overlayIP` is the sender's IPv4 address inside the tunnel (the
  dialer uses `10.77.0.2`, the answerer `10.77.0.1`).
- WireGuard paths, in order: plain UDP (direct, hole-punched), then TURN
  over UDP, then TURN over TLS on 443, then (0.17.0) cmux's WebSocket
  relay on the service's own host ("WebSocket relay"). When `/v1/ice` lists a TURN server
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
  §11.5). The TLS server name is the URL's host, checked against the OS
  trust store, and the TCP leg goes through the system's proxy for it
  ("Corporate networks" below). The dialer sends through its allocation to the Mac's
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

### Mac freshness (added 2026-11-21, backward compatible)

`online` says the Mac's signaling socket is open. A Mac that sleeps keeps it
half open, so `online` can stay true for minutes. Every Mac listing (`hello`,
`presence`, `GET /v1/teams/:teamId/macs`, `GET /v1/me/macs`, and so
`POST /v1/me/bootstrap`) now also carries `quietMs` for an online Mac: how
many ms ago the hub last heard that socket, from its connect or its last
application `ping` ("Connection setup"). The hub keeps the ping's time
without waking, so this costs nothing per ping.

- `quietMs` is relative to the hub's clock when it answered, so the phone's
  clock does not matter. Absent when the Mac is offline, and from a hub that
  predates it. Clients that do not know it ignore it.
- The Mac host pings every 15 s. A Mac with `quietMs` under 18000 (the
  link's `FRESH_WITHIN`, the hub's `FRESH_MS`) is awake: dial it now. One
  past it is online but probably asleep.
- A `presence` frame is sent only when a Mac connects, disconnects, or
  changes its registration, never per ping. So `quietMs` in a frame is its
  age at send time; it says nothing about later silence. The phone reads a
  fresh listing (the next `hello` or Mac route) to learn it again.
- The hub's `online` and its rules for closing sockets do not change.

### Link stats (`link_stat`; added 2026-11-21, backward compatible)

The phone reports which path its link to a Mac takes and how it performs,
on its signaling socket, so production can see path, RTT, loss and setup
time (`cmux-mobile-link/src/link_stat.rs`). Phone to service only; nothing
is forwarded, and the service never answers it.

```json
{"type":"link_stat","v":1,"transport":"wireguard","path":"turn-tls","reason":"first",
 "setupMs":812,"marks":{"signaling_open":120,"dial_start":130,"link_ready":700,"first_pong":812},
 "rtt":{"n":3,"p50":41,"p95":77,"max":80},"pings":3,"lost":0,"switches":1,
 "net":"cellular","upS":2,"lib":"0.1.0"}
```

- `transport`: `wireguard` or `webrtc`. `path`: `direct`, `turn`, `turn-tls`
  (WireGuard over TURN on TCP/TLS) or `none` (no working route right now).
- `reason`: `first` (once the link's first ping is answered, or 5 s after it
  came up), `periodic` (every 60 s while up), `path` (the path changed; at
  most one per 10 s, a change inside that only counts in `switches`), `end`
  (the link closed; `end` is then `app`, `keepalive`, `transport` or `other`).
- `setupMs` and `marks` (first stat only): ms from the app's `connect` to the
  first pong (else `link_ready`), and the dial's step marks from a fixed list.
- `rtt`: the link's ping round trips since the last stat (nearest-rank p50 and
  p95, max; absent with no sample). `pings`: pings sent since the last stat;
  `lost`: pings neither answered nor waiting, counted once (a pong that comes
  after its ping was counted lost does not take it back). `switches`: path
  changes since the link came up. `net`: `cellular` or `other` (the app's last
  `set_cellular_path`). `upS`: seconds up. `lib`: the link library version.
  `egress` (optional): `proxy` or `inspected` when this network's link
  connections left through a proxy, or one that inspects TLS ("Corporate
  networks"); absent when direct.
- `echo`, `ack`, `spikeCount`, `spikes` (added 2026-11-24; absent when no key
  was typed): the keystroke round trips since the last stat, from the key's tap
  (`cmux-mobile-link/src/key_echo.rs`). `echo` (n, p50, p95, p99, max): tap to
  the first terminal output after it. `ack`: tap to the Mac's reply to its
  `send` on the input lane. With `rtt` (a datagram, outside both streams) they
  name the slow hop: `rtt` slow too is the network; `ack` slow with `rtt` fast
  is the input stream or the Mac daemon; `echo` slow with `ack` fast is the
  Mac's echo or the attach stream queued behind other output. `spikeCount`:
  keys whose echo took over 150 ms; `spikes`: the six slowest, each
  `[upS at the key, ack ms or -1 when the reply had not come, echo ms]`, so a
  periodic stall shows its period.
- Bounded: every stat is under 768 bytes; ms values are clamped to 600000.
  It names no user, device, session or address.
- `portmap` (optional, added 2026-11-24): `{"by":"pcp"|"nat-pmp"|"upnp"|"unknown","used":bool}`,
  present when the Mac offered a NAT-mapped endpoint ("Mapped endpoints"): which
  protocol mapped it, and whether the link's direct route goes to it. The
  service logs it as `portmapBy` and `portmapUsed`; `link-stats.py` counts a
  direct link with `portmapUsed` as path `direct-mapped`. An older service
  drops the field.

The service (`TeamHub.linkStat`) takes it only from a phone socket, under the
socket's text rate limit, and drops silently (no error frame: a session-less
error fails every dial in flight) a frame over 2048 bytes, a malformed one, or
one within 5 s of the socket's last (an `end` stat excepted). It writes one
Workers Logs line, `{"event":"link_stat",...}`: the frame's fields checked
against fixed words or clamped (`rtt` flattened to `rttN`, `rttP50`, `rttP95`,
`rttMax`; `echo` and `ack` the same with `P99`; `spikes` at most six clamped
triples), plus `kind`, `ingressColo`, `country` and `continent` (where the
socket's upgrade entered Cloudflare, `req.cf`) and `hubColo` (where the user's
hub runs). No user or device id is logged. `scripts/cmux-next/link-stats.py`
reads them back.

A Worker older than the frame answers it `{"type":"error","code":"bad_request",
"message":"unknown frame type"}` without `sessionId`. The phone takes that
answer, within 30 s of a stat it sent, as the refusal of the stat: it never
reaches a dial, and that socket sends no more stats.

### Mapped endpoints (`mapped`; added 2026-11-24, backward compatible)

The Mac asks its home router for a public UDP port that forwards to the
session's WireGuard socket, with PCP (RFC 6887), else NAT-PMP (RFC 6886),
else UPnP-IGD (`cmux-mobile-host/src/portmap.rs`), and offers the mapped
address to the phone. A phone behind a NAT that maps per destination
(symmetric NAT, a carrier's CGNAT) reaches a mapped port directly, where
hole punching alone ends on TURN.

- It never holds up a link: the Mac asks after `wg-resp`, in the
  background, and announces the address when (if) the router grants it,
  with the roaming announcement (`{"t":"endpoints",...}` in the tunnel and
  `wg-endpoints` through signaling), as one more entry of `endpoints`.
- `mapped` lists which of `endpoints` are mapped (at most 2; an entry not
  among `endpoints` is ignored); `mappedBy` names the protocol: `pcp`,
  `nat-pmp` or `upnp` (another word reads as unknown). Both are absent when
  nothing is mapped.
- Backward compatible both ways: an older phone ignores the two fields and
  dials the address as any endpoint; a newer phone with an older Mac sees
  neither and has nothing mapped. The phone sends neither (it maps
  nothing).
- The Mac renews a mapping at half its lifetime (asking for 3600 s), and
  deletes it when the session closes or roams (a roam maps the new socket
  and announces it), and every live one when hostd stops. A mapped address
  that is not public (private, CGNAT 100.64/10: another NAT beyond the
  router) is deleted and not offered. The protocol a router answered is
  remembered per (gateway, local address), and a router that maps nothing
  is not asked again until either changes.
- `CMUX_MOBILE_PORTMAP=0` in hostd's environment turns it off.

## WebSocket relay (API 0.17.0)

The last way a WireGuard link reaches its peer, for a network that lets out
only cmux's own hosts (an allowlist without the TURN host), or only real
HTTP inside TLS (an inspecting proxy that drops TURN's stream): WireGuard
datagrams in WebSocket binary messages, `wss://` on 443, on the host the
app already signs in and signals through. Design, cost and why the old
relay was retired: [docs/cmux-next/phone-link-https-relay.md](../docs/cmux-next/phone-link-https-relay.md).

- **Join:** `GET /v1/relay/:sessionId?deviceId=<id>`, a plain HTTP/1.1
  `Upgrade: websocket` with `Authorization: Bearer <Stack token>` (or the
  `bearer.` subprotocol entry, as for signaling), `x-cmux-relay-ticket:
  <ticket>`, and the build space header of a dev build. The Worker selects
  `cmux-relay.v1` when offered. It admits only a device the caller's own hub
  bound to that session at its first admitted signal (the session's
  initiator or responder, while the session lives: 24 h, or until `bye` or
  the device's removal), in the caller's build space, presenting that
  device's own ticket: anyone else gets `403 not_in_session`, a session no
  signal opened, a missing or wrong ticket, or another device's ticket too.
  `503 relay_off` when the Worker's `LINK_RELAY_MODE` is `off` (the kill
  switch); an older Worker answers `404`. A malformed `%` escape in the path
  is `400`.
- **Tickets:** when a session opens the hub makes a random ticket (32 bytes,
  base64url) for each of its two devices, and stamps `relayTicket` on every
  `wg-*` signal it forwards, the recipient's own ticket, replacing any value
  a client wrote. A device learns its ticket only from its own signaling
  socket, so a join proves which of the user's devices it is as far as the
  service can tell (the user's token plus that device's socket).
- **Where:** one `LinkRelay` Durable Object per session, named by the owner
  key, build space and session id (never a client value), created in the
  region that makes the two ends' round trips through it least ("Relay
  placement" below); the joiner's `locationHint` when the peer's location is
  unknown. Hibernating sockets, no storage, one
  socket per device (a newer join closes the older with 4000 `replaced`).
- **Frames:** the overlay relay frame of `cmux_transport::relay_frame`
  (`[u8 1][u8 kind][16-byte peer][payload ≤ 16 KiB]`, the shared golden
  vectors), kind `datagrams` only: one or more `[u16 length][datagram]`
  records, as many ready datagrams as fit in one message. The relay sends
  each frame to the other party's socket with `peer` set to the sender's
  device id (the UUID's 16 bytes) and never reads the payload. Kind 4
  `tagged-datagrams` (same frame version 1) carries hop/1 DATA records
  (`docs/cmux-next/relay-pop-hop.md`: `[u8 class][u8 flags][u32 key, u32
  key_seq if flags&1][u16 len > 0][bytes]`, tiling the payload exactly; golden
  vectors `relay-tagged-frames.json`) so one record means the same on the UDP
  PoP and here. The relay forwards it like `datagrams`, coalescing the tagged
  records that reach one target socket in the same event-loop turn into
  fewer frames and dropping a class-1 record when a newer one of the same key
  is queued with it; it never drops or reorders other classes, and sends a
  plain `datagrams` frame only after the records queued before it. Workers'
  WebSocket has no `bufferedAmount` or drain signal, so it cannot see a send
  backlog: this is coalescing of what it already holds, not backpressure.
  An older relay answers kind 4 with `bad_frame:kind` and a sender then
  falls back to `datagrams` (`RelaySender`). A client's text `stats`
  is answered `{"type":"stats","leg":{...},"peer":{...}|null}` with in-memory
  per-leg counters (frames, bytes, records, superseded, refused, notices).
  The Rust client of this WebSocket relay is not built yet (the dial the app
  uses today has none on `feat-cmux-next`), so `RelaySender` is not wired into
  any sender and nothing sends kind 4 yet. Malformed
  frames, other kinds and frames past the per-socket limit (1500 frames and
  8 MiB a second) are dropped; the sender hears `{"type":"error","code":...}`
  at most every 5 s. What a socket relays is first granted by the user's
  hub (64 KiB, doubling up to 1 MiB per grant while the socket keeps
  relaying), one budget per user and build space across all sessions
  (`LINK_RELAY_USER_MIB_PER_MIN`, default 480: 8 MiB/s, kept in the hub's
  storage so a wake grants no fresh minute); past it frames are dropped and
  the sender hears `{"type":"error","code":"rate_limited"}`. A session asks
  the hub one grant at a time (at most 256 frames wait for it); a refusal
  holds for the hub's retry-after, and a hub that fails grants nothing for
  1 s (fail closed), so frames past the budget cost no hub call each.
- **Tail replay** (RFD 0142 R3): the relay keeps, in memory only, the frames
  of the last 1 s it sent (or found no socket for) toward each device, at
  most 256 KiB a session. When a device joins, after `joined`, those frames
  go out on its new socket at once, oldest first, and leave the tail: what
  went into a socket whose network had just gone (Wi-Fi to cell), or arrived
  between two sockets, reaches the receiver one relay leg after it is back
  instead of after the sender's retransmit timer. A client sees the same
  WireGuard datagrams again; the ones it already had die in WireGuard's
  replay window. A held frame spends the budget when it goes.
  `LINK_RELAY_TAIL=off` turns it off.
- **Closes:** the service closes a relay socket with 4000 `replaced` (the
  same device joined again), 4001 `ended` (the session's `bye`, also when the
  peer's signaling socket is closed, or the session passed its 24 h), 4002
  `removed` (a device of the session, or the account, was removed) and 4003
  `relay_off` (the kill switch, at the socket's next frame). A client does
  not rejoin after 4001 to 4003 (the join would be refused).
- **Text frames, relay → client:** `{"type":"joined","peer":bool}` (the
  other party's socket is joined), then `{"type":"peer","online":bool}` when
  it joins or leaves, or at most every 5 s while frames find it absent. A
  client's `ping` is answered `pong` without waking the object.
- **When a side joins** (`cmux-mobile-link` `relay.rs`, `wireguard_roam.rs`):
  only when both sides offered `relay`. At once when either has no other
  path (`relay: "now"`); else when nothing from the peer authenticated 3 s
  after its tunnel started or after it roamed (TURN over TLS is already
  open by then: the dial races it from the start), when the phone's link
  heard nothing for 16 s in the foreground, when its relay socket dies while
  the session needs it, or when the peer asks (`wg-relay`). A side that
  joins on its own asks the peer; one that heard the peer while its join
  ran drops the unused socket (an asked one too, once another route is
  confirmed both ways, and an ask that arrives then is ignored). A dead
  socket is joined again at once only while nothing else reaches the peer,
  and only a side that left the relay on its own (another route carried the
  session) keeps it after joining again within 5 minutes. On joining, the phone sends its handshake
  through the relay at once and the Mac 300 to 900 ms later (at random, and
  only if nothing arrived meanwhile): two initiations that cross in step each
  overwrite the other side's pending one. A failed join is retried after 1, 3, 10 and
  30 s; `403`, `404` and `503` are not.
- **On the tunnel:** the relay is one more carrier, a path of the path
  selector like each TURN route, ranked below every direct path and, by
  round trip, below a TURN path that answers. Until the peer confirms a
  route, datagrams also go through the relay; route confirmation stays the
  in-tunnel `reach` (`via: "relay"`, `from` the relay's placeholder
  `0.0.0.0:443`), so the relay can never confirm a route itself. The path
  is `https-relay` (`link_stat`, `phone_up`, `phone_path`).
- **Leaving:** a side lets its relay socket go once another route has been
  its confirmed one for 60 s. Plain UDP and TURN keep being probed while the
  session rides the relay, so a roam to a network that allows them moves the
  link off it. A side that still needs the relay (its route is the relay, or
  nothing came from the peer for 5 s) and hears the peer left it
  (`{"type":"peer","online":false}`) asks it back with `wg-relay` after 5 s,
  then at most every 10 s. A session that joins again within 5 minutes of
  leaving keeps the relay from then on.
- Debug "Relay via cmux (HTTPS) only" (and simulator
  `SIMCTL_CHILD_CMUX_MOBILE_DEV_FORCE_RELAY=1`): no plain UDP, no TURN
  allocation, the relay at once, never left; without the relay the dial
  fails at once. `CMUX_MOBILE_DEV_NO_RELAY=1` dials without it, and
  `CMUX_MOBILE_RELAY=0` turns it off for `cmux-mobile-host`.

### Early relay ticket

A dialer whose gather left it no path but the relay (`relay: "now"`) used to
learn its ticket only from the Mac's `wg-resp`, so its join (TCP, TLS and the
upgrade, about three round trips to the edge) waited behind the Mac's gather
and answer. Now it asks for the ticket at once:

- **Ask:** the dialer's `wg-init` carries `ticketEarly: true`, only when it
  sends `relay: "now"`. Absent means false; an older Mac ignores the field.
- **Answer:** a hub that forwarded that `wg-init` sends the dialer, on its
  own signaling socket, `{"type":"signal","to":<dialer>,"from":<mac>,
  "sessionId":...,"payload":{"kind":"wg-ticket"},"relayTicket":<the
  dialer's ticket>}`. Only the service sends `wg-ticket`: it is not in the
  kinds a client may send, so a client's is refused `unknown payload kind`.
- **Join:** the dialer starts its relay join when `wg-ticket` arrives
  (timeline `relay_early_join`) and keeps waiting for `wg-resp`; the relay
  watch's first join takes that carrier instead of starting its own. A plan
  that ends with no relay (the Mac offered none) aborts it.
- **Old and new:** an older dialer never asks and never gets `wg-ticket`; a
  new dialer with an older hub gets no `wg-ticket` and joins after `wg-resp`
  as before. The ticket is the one `wg-resp` carries too.

### Relay placement

A Durable Object stays where it is first created, so the first reach of it
(the hub's prewarm below, else the first join) decides where a session's
relay lives for good (`backend/src/placement.ts`). The Worker picks the region r that makes cost(joiner, r) + cost(r, peer) least.
The peer is the other party of the session, located by its live signal
socket. Each end's cost to r is either:

- its own measured round trip to r, from its netcheck; or
- an estimate from Cloudflare's geolocation of its request (lat/lon rounded
  to 0.1°): the great-circle distance to the region's assumed centre at
  100 km per ms of round trip.

When an end has neither, the relay takes the joiner's `locationHint`, as
before. Regions within 2 ms of the least sum count as a tie; the more even
split wins.

- **Netcheck targets:** `GET /v1/netcheck/:region` (`wnam`, `enam`, `sam`,
  `weur`, `eeur`, `apac`, `oc`, `afr`, `me`), a WebSocket upgrade with the
  same bearer as signaling. It reaches one object per region and build
  space, created with that region's hint. The object answers `ping` with
  `pong` without waking; any other frame closes the socket with 1008. An
  unknown region gets `404 unknown_region`, and `503 relay_off` comes with
  the relay's kill switch.
- **Reporting it:** a client that has measured adds
  `netcheck=<region>:<ms>,...` to its signal socket's URL (and may add it to
  a relay join). Entries that fail to parse are dropped. The hub keeps the
  value with the socket and never stores it.
- **Prewarm (added 2026-11-24, server-only, no version change):** when the
  hub forwards a session's first `wg-init`, it creates the session's relay
  object (the same name the relay route uses) without waiting for it, placed
  from both ends' signal sockets (each one's ingress and netcheck), else at
  the sender's `locationHint`. A later join finds the object made and placed,
  so a fallback to the relay no longer pays for creation and a cold start.
  Since the object stays where it is first created, this placement is the
  session's; the join's own placement applies only when the prewarm did not
  happen (the kill switch, a `webrtc-*` session, a failed prewarm). Nothing on
  the wire changes: no frame, header or status is new, old and new clients
  join and talk exactly as before, and an older Worker's relay object that
  answers the prewarm with `426` is created all the same. A prewarmed object
  holds no socket and no storage, so it is evicted soon after if nobody joins.

### When no path works

A WireGuard dial records what each way did: plain UDP (`blocked`: no STUN
answer; `off`: a debug mode), TURN (`none_offered`, `no_allocation`, with
the TURN host) and the relay (`unavailable`, `peer_cannot`, `refused` with
the HTTP status, `off`, `proxy_refused` with the proxy's reason,
`tls_rejected` with the TLS error, `unreachable`,
`timeout`, `no_token`, `peer_absent`). When nothing from the Mac ever
authenticated and the relay failed too (or the Mac's build has none), the
dial ends with that record instead of waiting out its timeout: at once when
the relay was the only way, else 8 s after the tunnel started at the latest.
The FFI error is `Refused { code: "network_blocked", message: <the record
as JSON> }`. The app shows one sentence the person can act on (another
network, the Mac's update, or what IT must allow) with the hosts named, and
retries on its own; it never shows "connecting" without a bound for it
(`scripts/cmux-next/check-connection-notices.py`). What IT must allow:
[network requirements](../web/data/next-docs/pages.ts) (cmux.com
`/docs/nightly/next/network-requirements`).

## Three-way hub (RFD 0142 R6, added 2026-11-24, backward compatible)

One room per agent session where both sources of the session's events, the
Mac and the AutoCloud VM, upload, and every viewer (the phone, another Mac)
downloads each event once: whichever source is ahead carries the stream, and
the other is a warm standby. When the Mac sleeps mid-turn, the VM's copies
are already the newest and keep flowing with no reconnect.

- **Join:** `GET /v1/hub/:sessionId?deviceId=<id>&role=mac|vm|viewer`, a
  plain HTTP/1.1 `Upgrade: websocket` with the Stack token, as for the
  relay. The Worker admits only a device registered to the caller (its own
  hub, then the database; anyone else gets `403 not_owner`) and a source
  role only from a Mac-kind device (the VM's daemon registers as one; a
  phone gets `403 not_a_source`). `400` for a session id or device id that
  is not a UUID or an unknown role, `503 hub_off` when the Worker's
  `HUB_RELAY_MODE` is `off`. An older Worker answers `404`.
- **Capability:** a hub client offers the `cmux-hub.v1` subprotocol and the
  hub echoes it. A client falls back to its other paths (one link per Mac,
  the WebSocket relay) on `404`/`405` (no route), `503` (off), any other
  refusal, a `101` without the subprotocol, or the error `bad_frame:kind`,
  which is what the two-party `LinkRelay`, and so every pre-hub relay,
  answers a kind-5 frame with (`cmux_transport::hub::hub_join_outcome`,
  `relay_error_means_no_hub`). Old clients never ask for the hub, and the
  relay they use is unchanged.
- **Where:** one `HubRelay` Durable Object (wrangler migration `v4`) per
  session, named by the owner key, build space and session id
  (`hubRoomName`), never a client value. Hibernating sockets, no storage
  write per frame. One socket per source role and per viewer device (a
  newer join closes the older with 4000 `replaced`). On join the socket
  gets `{"type":"joined","hub":1,"sources":{"mac":bool,"vm":bool}}`; every
  socket hears `{"type":"source","role","online"}` when a source comes or
  goes (not when a newer socket of the same role replaced it).
- **Frames:** relay frame kind `5` (`hub`; kind `4` is the
  `LinkRelay`'s tagged datagrams, cmux#54189), golden vectors in
  `cmux-tui/crates/cmux-transport/tests/vectors/relay-hub-frames.json`,
  checked by the Rust crate and the backend tests. The payload is a 35-byte
  clear header and a sealed body:
  `[u8 1][16-byte session][u64 BE epoch][u64 BE seq][u8 source: 1 mac, 2 vm][u8 to: 0 viewers, 1 mac, 2 vm]`.
  The header is all the relay reads; a bad one is `bad_frame:bad_hub`.
- **Seal (end to end, source to viewer):** XChaCha20-Poly1305 under
  `BLAKE3 derive_key("cmux relay hub v1 session key", secret || session)`,
  nonce `[source][to][epoch BE][seq BE][6 zero bytes]`, associated data the
  clear header, plaintext `[session][epoch BE][seq BE][source][event]`. The
  relay holds no key that decrypts or authenticates session content; an
  edit to any header byte, or a header moved onto another body, fails to
  open (`cmux_transport::hub::{seal, open}`).
- **Relay rule** (`cmux_transport::hub::HubRelayRule`, the same in
  `src/hub-relay.ts`): a frame `to` viewers whose `(epoch, seq)` is newer
  than the highest the room forwarded goes to every viewer once, with
  `peer` set to the sender's device; an older or equal one is dropped and
  counted. A frame `to` a source (Mac-to-VM sync when the two have no direct
  path) goes to that source as is, or the sender hears
  `{"type":"source","role","online":false}`. A viewer may not send
  (`bad_hub:viewer`); a source speaks only as its own role
  (`bad_hub:role`) and for the room's session (`bad_hub:session`); other
  kinds are `bad_frame:kind`. The high-water mark lives in memory: a wake
  forgets it, which lets at most one more copy through. `{"type":"stats"}`
  answers `{"type":"stats","forwarded","dropped"}`.
- **Viewer** (`cmux_transport::hub_truth::TruthTracker`, sans-io): checks
  that the clear header equals the sealed triple, delivers events in log
  order with no duplicates, reports a hole inside an epoch as a `Gap` to
  fill from the source with the higher head, and flags a `StalePick` when
  the relay's copy trails the other source's known head by more than the
  tolerance (4).

## Relay-held sends (RFD 0142 R8, added 2026-11-25, off by default)

A send the phone makes while the Mac is not joined to the session's WebSocket relay (asleep, offline,
mid-redial) can ride the phone's relay socket and be held by the relay until the Mac joins. The backend turns it
on with `LINK_RELAY_HOLD=on`; off, the relay answers every hold with `hold_refused` `off` and the phone routes the
send as before (the store-and-forward mailbox, else it fails). Code: `backend/src/relay-hold.ts`,
`cmux_mobile_link::relay_hold`.

Text frames on the relay socket (JSON; binary relay frames are unchanged):

- Phone to relay: `{"type":"hold","id","sealed"}`. `id` is a UUID (the composer's client message id, also inside
  the signature); `sealed` is the store-and-forward item (`mailbox-send-v1`: signed by the phone's identity key,
  sealed to the Mac's box key), base64url, at most 16384 characters.
- Relay to phone: `{"type":"held","id","depth","expiresAt"}` at once (one relay RTT: the send is done as far as
  the user sees), or `{"type":"hold_refused","id","code"}` with `off`, `bad` or `full` (64 items or 524288
  sealed characters per session). The same id again answers its first `held` and holds nothing new; an id the
  Mac already acked answers `held` with `"delivered":true`.
- Relay to Mac: `{"type":"held_item","id","from","sealed","at","expiresAt"}`, oldest first, on every join and at
  once for a hold made while it is joined. Delivery is at least once.
- Mac to relay: `{"type":"held_ack","id"}` after the send is applied; the relay deletes it and tells the phone
  `{"type":"delivered","id"}`.

The Mac applies an id at most once (`HeldInbox`): it records the id in the same durable write as the send's
effect, before its ack, so a redelivery, a lost ack or a killed process never applies it twice. Items expire
10 minutes after the hold, with the P8 mailbox's default hold. The relay reads the id, the sender's device id,
the sealed length and times; never the text (it holds no key). Nothing is written per keystroke: one storage
write per send, one per ack.

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
| 5 `deflated data` | parked writes only, negotiated below. Original payload length (u32 BE) and one raw DEFLATE stream |

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

Align Keepalives (phone Settings → Transport, off by default; no wire
change): the phone sends every keepalive on the beats of one grid
(multiples of the period since the Unix epoch, `cmux-mobile-link`
`keepalive.rs`), so the radio wakes once for all of them. The link pings on
every 10 s beat whether or not the last pong came, and its WireGuard tunnel
sends no persistent keepalive (the ping is a tunnel datagram as often, on the
same routes); the 20 s timeout above is unchanged. The signaling and presence
sockets ping on every 10 s beat, the Cloud Chief socket on every 20 s beat,
and the app's heartbeat probes a link with no traffic (only pings and pongs)
on its 2.5 s foreground or 10 s background beat. No interval is longer than
before.

### Parked link (added 2026-11-16; backward compatible)

When the app leaves the screen with a live WireGuard link, the phone asks
the Mac to hold the link while iOS suspends it, so returning skips the
full dial. It opens the service `_link.park` with `{"hold_ms": N}`. A Mac
that knows parking answers `close` with code `parked` (a control frame) and
holds for N ms, at most 10 minutes. An older Mac answers `unknown_service`,
and the phone redials on return as before. While parked:

- Neither side sends a link keepalive or closes the link for silence.
- The tunnel is held (`cmux-wg` `WgNet::hold`): no TCP keepalive probe,
  each link connection waits for the hold plus 30 s instead of its user
  timeout, and no WireGuard keepalive (persistent or passive) goes out. The
  Mac sends a suspended phone nothing at all.
- The Mac writes only control frames. Channel data waits in each channel's
  queue (up to its 256 KiB, then its writer waits, as on a slow link).
- The app's heartbeat, foreground and presence probes are suspended: a
  ping ends the park.

A phone that can read type 5 adds `"encoding":"deflate-v1"` to its
park request. For that park the Mac can encode each held data frame
independently if it shrinks. Its original length (at most 16 KiB) counts
towards the same queue limit. The phone restores each frame in channel
order, including its original boundary. Other frames use their usual
encoding. A Mac that predates the encoding ignores the argument, and a
phone that omits it receives ordinary data.

The park ends on the Mac at the phone's first ping, channel data or new
channel (other than `_link.park`): a phone that sends a request (a
notification action run in the background) is awake and waits for the
answer. The phone parks no link a call is using, and a request it runs in
the background resumes its link for the request, then parks it again. On
the phone the park ends at the first frame from the Mac after `resume`. On return within the hold
(less a 30 s margin, on the clock that runs while the device sleeps), the
phone moves the tunnel onto a fresh socket, as for a network change, and
probes once with a 1.5 s timeout. The first explicit probe starts on the
ordered stream even when liveness datagrams are available, so its ping
follows the park request and releases queued output on the Mac. The Mac
queues its pong before releasing the writers. If the probe fails, the phone redials. If
the hold passes with nothing heard, the Mac closes the link (`park
expired`). A WebRTC link is never parked: ICE consent ends a silent data
channel after 30 s whatever the link does.

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
  A phone that opens it with `{"compression":"deflate"}` (CMUX-563) gets each
  message of 16 KiB or more from the Mac as one envelope instead of text:
  `0x00`, the text length (u32 big-endian), the deflate length (u32 big-endian),
  then the raw deflate (RFC 1951) of the JSON text; smaller messages stay text.
  JSON never starts with `0x00`, and the lengths say where the envelope ends
  among the frames and bound its inflate (hostd `link_deflate.rs`, phone
  `DeflatedMessage.swift`). An older Mac ignores the argument and sends text.
  The phone watches its chats in pages: `_acpmux/watch {limit: 100}` is the
  newest page, and the phone is ready with it; the rest comes from
  `_acpmux/sessions {limit, cursor}` after (`AcpmuxHub+SessionPages.swift`).
- `cloud-directory` (link protocol 2): no arguments; one JSON data frame
  `{"paid","desktops","machines":[{"machine_id","team_id","name","status","ran","linked"}]}`
  followed by `eof`. `paid` says the account pays for cmux Cloud; `desktops` is the
  Mac's `phone.cloudDesktop` setting; `status` is the machine's Cloud status
  (`running`, `paused`, `starting`, ...); `ran` says it has run at least once;
  `linked` says the Mac holds its live carrier, so a Cloud chat can open on it.
  A machine that is asleep (no live carrier, `linked` false) is listed too, for the
  Chief's Computer card only; the Cloud chats list leaves it out. An older Mac sends
  none of these fields: the phone reads `paid`, `desktops` and `ran` as false,
  `status` as unknown and `linked` as true (it listed only linked machines).
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
  `session/new` starts a chat on the machine: hostd reads `list-workspaces`,
  takes the active ordinary workspace (`kind` `normal`; else the first; it sends
  `create-workspace` when there is none), creates a `registry:<registry_id>`
  agent tab there with `new-conversation-tab`, then sends `agent-session-start
  {surface, harness:"claude", vm_kind:"owner"}` with a 90 s deadline. The
  phone's params may hold only `cwd` (ignored: the machine makes the chat's
  folder), an empty `mcpServers`, and `_meta.acpmux` with only `harness`
  `claude` and `policy` `ask`; anything else is refused with -32602. On success the phone
  gets `_acpmux/session_changed` (`kind: "created"`) and then `{sessionId}`; a
  refused or timed-out start closes the empty tab. The Mac shows the same tab, since it lives
  in the machine's own store.
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
- `bundle` (`bundle-v1`; added 2026-11-24, backward compatible): an attachment
  upload or a file open as sealed, content-defined chunks (cmux-tui
  `cmux-bundle`, RFD 0142 R7), so a file the far end already holds costs one
  round trip and its manifest (36 bytes per ~64 KiB chunk) instead of its bytes.
  Every message is `u32 BE length | bytes`; one that starts with `{` is JSON,
  any other a `cmux-bundle` sync message (offer, want, chunks). A length past
  4 MiB is refused. The Mac's first message is `{"v":1,"key":"<64 hex>"}`, the
  pair's bundle secret: `blake3::derive_key("cmux-bundle v1 pair secret", the
  Mac's box key (derived from its identity key) || phone device id)`, so the
  same phone always gets the same key; chunk ids and seals derive from it, and
  a relay cache never sees it. The phone keeps it per Mac and may offer before
  reading it; the Mac takes one offer under a stale key and the next.
  - `{"op":"put","name","size","cwd"?}` (as `upload`, needs what `upload`
    needs): the phone offers; the Mac answers a want (the chunks it lacks); the
    phone sends those chunks without waiting; the Mac publishes the file as
    `upload` does and answers `{"path","size"}`, then `eof`.
  - `{"op":"get","path"}` (as `file`: the same roots and open checks): the Mac
    offers; the phone answers a want, or closes when it holds every chunk; the
    Mac sends the chunks, then an empty message.
  Files past 256 MiB are refused `too_large` (the phone uses `upload` or
  `file`); a chunk that does not open to its id, an offer under another key, or
  chunks the offer does not name are refused `bad_request`, and nothing is
  published. Refusals are `{"error","message"}` before the close. The Mac keeps
  chunks (ciphertext) under `<uploads>/bundle-chunks`, at most 2 GiB, least
  recently used out first; the phone keeps its own per Mac in its Caches. An
  older Mac closes `bundle` with `unknown_service`; the phone then uses
  `upload` / `file` for the rest of the link.
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
  Inspect, Look Up, Speech, Cast, Create QR Code) are left out. Rows that open
  a tab stay (2026-11-01): the browser host forwards the tabs Chromium opens
  through `OpenURLFromTab` (Open Link in New Tab or Window, Open Image in New
  Tab, Search for, Cmd-click) as `rb.open_tab`, like the page's own popups
  (`OnBeforePopup`). View Page Source stays off the phone's menu: the host
  answers it with an `rb.open_tab` of the page's `view-source:` address, which
  the Mac's viewer opens but `new-browser-tab` refuses from a phone (http and
  https only). The pick goes back as `rb.menu.result
  {token, choice: {choice: "command", id}}`, and a menu closed with no pick,
  or one that arrives with no long press waiting (after 1.5 s), as `{choice:
  "cancel"}`. A `<select>` (`rb.menu.show` of kind `select`) shows its options
  in a sheet and answers `{choice: "indices", indices}`. JavaScript dialogs
  (`rb.dialog.show`) show as a system alert (a prompt with a text field) and
  answer `rb.dialog.result {token, accept, text}`. `rb.menu.cancel` and
  `rb.dialog.cancel` close the sheet or alert with no answer (the host sends
  `rb.dialog.cancel` when Chromium resets its dialogs, when the frame that
  asked goes away, as when the page removes the iframe whose alert shows, and
  when the tab closes); a new stream
  session drops whatever was open. Popup surfaces (`rb.surface.show`: date,
  color and datalist pickers) are not shown on the phone yet. The page menu's
  Hard Reload sends `rb.history reload_no_cache`. Find… (page menu, Cmd-F;
  Cmd-G and Shift-Cmd-G step) shows the system find bar: each query sends
  `rb.find {query, forward: true, match_case: false, next: false}`, Next and
  Previous `{next: true, forward}`, and the host's `rb.find.result {matches,
  active}` sets the bar's count; Done sends `rb.find.stop {keep_selection:
  true}`. Under
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
- `appearance` (`appearance-v1`, 2026-11-12): the Mac's theme and wallpaper. Since
  2026-11-22 the phone's chrome (backgrounds, surfaces, text, fills, accent) follows it again
  and the wallpaper shows behind the sidebar and Home, while Match Mac theme is on (the
  default); off, the phone's stock look (2026-11-13 to 11-22 the chrome stayed stock). Since 2026-11-17 its agent chat takes `chat` (below). One JSON frame now and on every change, nothing before the
  Mac app sent its first one: `{"theme": {"background", "foreground", "palette": [8 or
  16 "#rrggbb"], "selection_background"?, "selection_foreground"?, "cursor"?, "accent",
  "accent_color"?, "background_opacity", "background_blur"?}, "wallpaper": {"id", "bytes", "tint_opacity"} |
  null}`. Since 2026-11-22 `wallpaper` is what the Mac shows behind its windows' content: the
  background chosen in cmux, else the Ghostty `background-image`, else, in a see-through window
  (`background_opacity` < 1), the desktop picture under the window's tint; null only for an opaque
  window with no picture. The phone draws it under the terminals too, which are then see-through
  (`background-opacity = 0` on the phone's surfaces, as on the Mac), and blurs it by
  `background_blur` (Ghostty's encoding: a radius in points, -1 regular and -2 clear Liquid Glass;
  omitted for 0). `id` is the SHA-256 of the picture (hex). The phone derives the
  palette itself (`ThemeTokens.derive`, the Mac's own code) and keeps the last frame, so
  the accent is the same at launch and offline. Since 2026-11-13 a
  frame may also carry `"terminal": ["key = value", ...]`: the Mac's terminal theme, its
  applied Ghostty config's value for each terminal theme key
  (`appearance.rs` `TERMINAL_KEYS`: background, foreground, every palette entry, cursor,
  selection, bold, contrast, faint and cursor opacity, palette generation, blending,
  colorspace, search colors). hostd drops any other key and any value that is not a plain
  color, number, flag, enum or palette entry. The phone's terminals of that Mac reset each
  of those keys and load these lines, live, whatever Mac the phone focuses, while its
  Match Mac theme switch is on (the default; off, terminals show the phone's stock black,
  since 2026-11-22); a frame without `terminal` (an
  older Mac) stands in with `theme`'s colors. Since 2026-11-14 a frame may also carry
  `"look"`, the rest of what the Mac's windows show, every field optional (absent: the
  phone's own default): `{"chrome_style"?: appearance.chromeStyle (`default`, `card`,
  `card-outlined`, `flat`, `flat-sidebar-line`, `bare`, `panes`, `two-tone`, `floating`,
  `blocks`), "hue"?: appearance.hue (0...1, 0.5 keeps the theme's), "saturation"?:
  appearance.saturation (0...2, 1 keeps it), "glass_transparency"?:
  appearance.glassTransparency (0...1), "sidebar_surface"?: appearance.sidebarSurface
  (`same` | `separate`), "terminal_font"?: {"family"?, "size"?} (the face and points the
  terminals draw in: terminal.fontFamily and terminal.fontSize over the Ghostty config's;
  size 4...96), "chat"?: {"sent"?, "sent_text"?, "received"?, "received_text"?}
  (home.bubbleColors.*, `#rrggbb`), "groups"?: {"palette"?: sidebar.groupPalette (`glass`,
  `theme`, `wallpaper`, `grayscale`, `vibrant`, `gradient`, `pictorial`), "gradient"?:
  sidebar.groupGradient (`sunset`, `aurora`, `lagoon`, `twoTone`)}}`. The Mac app sends the
  same object on its stdin line (`MobileHostAppearance.Look`); hostd (`appearance.rs`
  `sanitize_look`) checks each field on its own and drops a bad one (an unknown value, a
  number out of range, not `#rrggbb`, a family with a control character, `#`, `=` or `"`, or
  over 120 characters) while the rest and the theme still serve; a nested object with
  nothing valid is left out, and with nothing valid at all the frame has no `look`, the same
  bytes an older Mac sends. The phone does not draw these yet. Since 2026-11-17 a frame
  may also carry `"chat"`, what the phone's agent chat shows, resolved by hostd
  (`appearance.rs` `chat_look`): `{"background", "foreground", "background_opacity",
  "wallpaper"?: the `wallpaper` id, "bubbles"?: look's `chat` colors}`. `background_opacity`
  is how much of `background` covers the picture: the window's tint with a picture (the
  Mac's `ThemeScope.shownWindowOpacity`), 1 without. A Mac at its defaults (Ghostty's
  colors `#282c34`/`#ffffff`, no picture, no bubble colors) sends no `chat`, and the phone
  keeps its stock chat. The phone draws it in the agent chat only while Match Mac theme is
  on.
- `appearance-wallpaper` (`appearance-v1`): `{"id"}` streams that picture's bytes (a JPEG
  or PNG, at most 8 MB), then `eof`; `stale` when the Mac shows another one now,
  `not_found` when it shows none. Machines need the View grant for both. The phone
  stopped reading this service on 2026-11-13 and reads it again since 2026-11-17 (the picture a frame's `chat` names) and since 2026-11-22
  for any frame's `wallpaper` while Match Mac theme is on, once per id (size and SHA-256
  checked, one kept).
- `phone-frames` (`phone-frames-v1`, 2026-11-22): how smoothly the phone drew each terminal
  scroll. The phone times every display frame of one pan of a terminal (the drag and its
  fling) and, when the pan ends, sends one data frame per pan, then `eof`:
  `{"v": 1, "kind": "tui" | "scrollback", "program"?, "app"?, "expected_ms", "intervals_ms":
  [...], "rows"?, "bytes_in"?, "rtt_ms"?}` (`expected_ms` the display's nominal frame,
  `intervals_ms` each frame interval, at most 1800; the load the pan ran under: `rows` the page
  held when it began, `bytes_in` terminal output that arrived during it, `rtt_ms` the link's
  last round trip). hostd (`phone_frames.rs`) summarizes it (frames, p50/p95/max ms, hitches:
  intervals over 1.5 frames, frames dropped, hitch ms per second, and the load: `rows`,
  `bytes_in`, `bytes_per_s`, `rtt_ms`) and appends one JSON line to
  `phone-frames.jsonl` in its state folder (`~/Library/Application
  Support/cmux-mobile-host/`, rotated at 1 MB with one previous file) and to its log. At most
  16 pans of 64 KiB per channel; a line that does not parse is dropped. The phone sends
  nothing to a Mac without the capability. Phones only.
  Each record also carries `path`, the link's route when it came, which hostd reads from the
  link and the phone never sends: `direct-lan` (a direct path to a private, link-local or
  unique-local peer address), `direct-wan` (direct, but routed: a public, CGNAT or tailnet
  address), `direct` (direct, address unknown), `relay` (a TURN server) or `none`.
  Mac redraw to iPhone paint (added 2026-11-22, same capability): hostd adds `"pseq": N` to
  each terminal redraw line it splices to the phone (`output`, `agent-cli-frame`,
  `agent-cli-lean`; an older phone ignores the field) and keeps, for the last 8192 of them,
  when it read the line and when the link flushed the line's last byte to the socket. The
  phone notes when each stamped line arrived and when the first frame that showed its bytes
  was presented, and sends, on the same channel:
  `{"kind": "clock", "t0"}` probes, each answered at once with `{"kind": "clock", "t0", "t1",
  "t2"}` (Mac epoch ms; at most 32 per channel), then
  `{"v": 1, "kind": "paint", "samples": [[seq, received, painted], ...], "clock": [[t0, t1,
  t2, t3], ...], "program"?, "app"?, "load"?, "rtt_ms"?}` (phone epoch ms, at most 256
  samples; the phone sends 200). hostd takes the clock offset from the probe with the
  shortest round trip (NTP midpoint, error at most half that round trip), joins each sample
  with its stamps and appends `{"kind": "paint", "samples", "joined", "offset_ms",
  "clock_rtt_ms", "path", "mac", "wire", "phone_paint", "total"}`, each part
  `{"n", "p50_ms", "p95_ms", "max_ms"}`: (a) `mac` read to socket, (b) `wire` socket to
  the phone's receive, (c) `phone_paint` receive to present, and `total`.
- `tabs` (`tab-snapshots-v1`, 2026-11-22): the tab overview's cards for every tab of this
  Mac (title, kind, favicon, thumbnail or terminal screen text), with deltas and
  content-addressed blobs. No open args; machines need the View grant. Both ways the
  channel carries frames, each behind its 4-byte big-endian length; a frame is a 1-byte
  kind, then a body (`cmux-tab-snapshots` `wire.rs`). Phone to Mac (JSON, camelCase):
  `0x01 viewport {cardPixelWidth, cardAspect, displayScale, screenPixelW, screenPixelH}`,
  `0x02 want [hash]` (priority order, replaces the last; each named blob is sent even if
  sent before), `0x03 have [hash]` (once on link-up), `0x04 resume {epoch?, rev}` (first on
  reconnect; an empty epoch asks for a manifest). Mac to phone: `0x11 manifest {epoch,
  rev, rows}`, `0x12 delta {epoch, rev, baseRev, changed: [partial row], removed: [tabId],
  order?}` and `0x13 blob` (binary: 32 raw SHA-256 bytes, 1 mime byte: 0 octet-stream, 1
  JPEG, 2 PNG, 3 screen text, then the bytes; the phone checks the hash). A row is
  `{tabId, title, kind ("browser", "terminal", "agent", or a kind the phone shows as
  other), faviconHash?, thumbHash?, thumbW, thumbH, thumbMime, screenHash?, screenCols,
  screenRows, frameHash?, capturedAtMs}`; in a partial row an absent field is unchanged
  and a `null` hash is cleared. `tabId` is the tab's daemon surface id as a decimal
  string, so it lasts one daemon run. Revs of different epochs are unrelated. `epoch` names
  the host process and the daemon run its tab ids came from: it is new at each hostd start
  and each time hostd reconnects to the daemon (taken as a new run), and a new one drops
  every row, order and held picture of the old, so a phone gets a manifest. A tab naming
  an agent session the phone's chat exposure blocks is hidden, and every tab is while the
  exposure is unavailable. Browser favicons and thumbnails come from the Mac app on its
  stdin line `{"type":"tab_picture","surface": <daemon surface u64>, "part": "thumb" |
  "favicon", "path", "w"?, "h"?, "captured_at_ms"?}`: `path` is an absolute regular file
  (not a link) in the app's caches (`phone-tab-pictures`) of 1 byte to 2 MiB, JPEG or PNG
  by its magic bytes (any `mime` is ignored); others are logged and dropped. The app sends
  one when a page's leave picture is taken (576 px wide at most, JPEG) or its favicon
  changes (PNG), only for its own daemon's tabs that are not incognito, while a phone is
  paired; it skips bytes it sent last for that tab and part, and resends the newest of each
  to a new hostd.
- `echo`: test service.
- `version` (link protocol 2, added 2026-10-14): one data frame
  `{"hostd": "<version>", "link": 2}`, then `eof`. A host that refuses it
  with `unknown_service` speaks link protocol 1 (keepalive pings queued
  behind data, a reader that stalls on one full channel); the phone keeps
  the link and says "Update cmux on this Mac".
  Added 2026-10-14: `"capabilities": [...]`, what the host does that a
  phone may rely on, each named in "Capabilities" below. `removal-v1` came
  with the Mac host of manaflow-ai/cmux#20414, so the phone's removal copy
  can say the Mac stays off. `browser-stream-v1` needs a browser host in the
  Mac build (Release builds ship none yet); a host that says `removal-v1`
  without it refuses `browser` with `no_browser_host`, and the phone hides
  New Browser Tab for that Mac.
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
  (verify/simulator-surface.md). With `cloud-desktop-v1`, `tab` may instead be
  `c~<machine_id>~<team_id>`: the desktop of a Cloud machine the account owns
  (exactly one owner link from the app, else `forbidden`; not running: `asleep`),
  view only: hostd sends the source no input from the phone.
  With `mac-display-v1` (2026-11-23), `tab` may be `d~<display>`: this Mac's own
  display (a CGDirectDisplayID in decimal, no leading zero; `d~0` the main display),
  the Mac screen as rd/1 on this link with its video on the media lane, view only like
  a Cloud desktop. hostd lists `mac-display-v1` only when the app's source captures
  displays (`CMUX_MOBILE_MAC_DISPLAY=1`, else `no_surface_host`); the app starts a
  capture only while Share This Mac is on (else the open fails `unavailable`) and
  stops it when sharing turns off or the viewer goes.
  `tab` is the phone tab's key `s<surface>`;
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

### Capabilities

Every capability name the link speaks: what hostd lists in `version`, and the
cmux-tui daemon's names hostd itself declares or checks. Printed from
`rust/crates/cmux-mobile-link/src/names.rs`; edit it there, not here.

<!-- link-names:capabilities:begin (printed from cmux-mobile-link src/names.rs; CMUX_UPDATE_LINK_NAMES=1 cargo test -p cmux-mobile-link names rewrites it) -->
| Name | Said by | Meaning |
|---|---|---|
| `removal-v1` | hostd `version` | After its owner removes it (signaling 4002 `removed`) the Mac stays off until iPhone connections are allowed again on the Mac; without it the Mac may add itself back. |
| `file-preview-v1` | hostd `version` | `file-preview` sends a size metadata frame before the file bytes, so the phone can check free storage first. |
| `localhost-forward-v1` | hostd `version` | (2026-10-30) The host serves `localhost`: a phone browser tab reaches a port on the Mac's loopback. |
| `cloud-directory-v1` | hostd `version` | (2026-11-01) The host lists the owner's authenticated Cloud machines through the Mac carrier (`cloud-directory`). |
| `cloud-acpmux-v1` | hostd `version` | (2026-11-01) The host drives an owned Cloud machine's agents through the Mac carrier (`cloud-acpmux`). |
| `needs-you-v1` | hostd `version` | The host serves `needs-you`: the Mac app's own open Feed requests. |
| `appearance-v1` | hostd `version` | (2026-11-12) The host serves `appearance` and `appearance-wallpaper`: the Mac's theme and wallpaper. |
| `pair-requests-v1` | hostd `version` | The host serves `pair-requests`: a paired device answers a pairing request waiting on this Mac. |
| `phone-frames-v1` | hostd `version` | The host serves `phone-frames`: the phone's terminal scroll frame times, logged to `phone-frames.jsonl` on the Mac. |
| `tab-snapshots-v1` | hostd `version` | (2026-11-22) The host serves `tabs`: every tab's title, favicon, thumbnail or terminal screen text, each picture sent once by hash and then only changes. |
| `mailbox-send-v1` | hostd `version` | (2026-11-24) The Mac's mailbox takes `send` (a chat message) and `compose` (a queue action) items, held up to 24 hours and applied once, in each phone's order: a phone routes a send to the mailbox only to a Mac that listed it on its last link. |
| `bundle-v1` | hostd `version` | (2026-11-24) The host serves `bundle`: an attachment upload (`put`) or file open (`get`) as sealed content-defined chunks, so a file the far end already holds costs one round trip and its manifest. |
| `browser-stream-v1` | hostd `version` | The host streams browser tabs (`browser`); listed only when the Mac has a browser host. |
| `browser-video-track-v1` | hostd `version` | With `browser-stream-v1`: `browser {"video":"track"}` carries the page's video on the media lane (WebRTC, and WireGuard since 2026-10-14). |
| `surface-stream-v1` | hostd `version` | (2026-10-22) The host streams the Mac's phone tabs' simulators (`surface`); listed only when the Mac app streams simulators. |
| `cloud-desktop-v1` | hostd `version` | (2026-11-02) `surface` also streams an owned Cloud machine's desktop, view only, on the key `c~<machine_id>~<team_id>`. |
| `mac-display-v1` | hostd `version` | (2026-11-23) `surface` also streams this Mac's own display as rd/1 on the link, view only, on the key `d~<display>` (CGDirectDisplayID, 0 the main display); served while Share This Mac is on. |
| `cloud-mobile-chat-v1` | cmux-tui daemon | On a `cloud-acpmux` carrier hostd requires the Cloud daemon's `identify` to list it before declaring it (phone prompt restrictions). |
| `conversation-tabs-v1` | cmux-tui daemon | Declared in `set-client-info`: conversation tabs read as `conversation` with their record, not `browser`. |
| `page-tabs-v1` | cmux-tui daemon | Declared in `set-client-info`: page tabs read as `conversation` with their `page` (a phone tab is a simulator tab). |
| `agent-session-tabs-v1` | cmux-tui daemon | Declared in `set-client-info` on a `cloud-acpmux` carrier: agent session tabs read with their session source. |
| `send-expect-agent-v1` | cmux-tui daemon | In `identify`: a notification reply to an agent types text and Return only while that agent waits at its prompt (#24205). |
| `agent-cli-hybrid-v1` | cmux-tui daemon | Declared by the phone's terminal in `set-client-info` (the lean stream): an agent CLI's terminal as `agent-cli-frame` cell deltas. |
| `agent-cli-hybrid-v2` | cmux-tui daemon | With `agent-cli-hybrid-v1`: the same deltas packed as `agent-cli-lean`. |
| `terminal-shell-lines-v1` | cmux-tui daemon | With the hybrid pair: a plain shell's terminal as lean frames too, PTY bytes while it runs a full-screen program. |
| `attach-output-coalesce-v1` | cmux-tui daemon | `output` at most once per display frame for a terminal that stays on PTY bytes (#43373). |
| `terminal-full-screen-frames-v1` | cmux-tui daemon | With `terminal-shell-lines-v1`: a full-screen program as lean frames as well (its modes as bytes), one display frame apart, instead of its PTY repaints (#51565). |
<!-- link-names:capabilities:end -->

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

`bundle_id` (string; added 2026-11-17) is the phone app's bundle id as the
phone states it in its `auth` args (`bundleId`, 1 to 155 ASCII letters,
digits, `.` and `-`; the phone app sends `Bundle.main.bundleIdentifier`). hostd
forwards it for phones only and drops a malformed one without refusing the
link. It is a claim, not a proof: the app reads it only to auto-approve its own
tag's dev iPhone app in a DEBUG tagged dev build (`dev.cmux.mobile.<tag>`) and
to keep another build's dev iPhone app from prompting (SECURITY.md "Dev
auto-approve"). An older phone sends none, an older hostd forwards none, and
the app then asks as before.

`auth` args may also carry `appBuild` (added 2026-11-22; the phone app's
CFBundleVersion, 1 to 32 ASCII letters, digits, `.` and `-`). hostd keeps the
phone's `bundleId` and `appBuild` in memory per device and logs one `phone app`
line at each `auth` open (device, variant `appstore`/`testflight`/`dev`/`other`/
`unknown`, bundle, build, link path). It refuses nothing on them; an older phone
sends none.

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

#### Tunnel keys in the proofs (`proofVersion` 2)

On a WireGuard link, both identity proofs also cover the tunnel's two static
public keys, as each side's own tunnel handshook with them: `dialer` (the
phone's, or a dialing Mac's) and `answerer` (the Mac's), base64 as in `wg-init`
and `wg-resp`.

- The phone's `auth` args add `proofVersion: "2"` on a WireGuard link.
- A Mac that supports it answers on a WireGuard link with `proofVersion: "2"` in
  the challenge, `macSignature` over
  `cmux-mobile-mac-identity-v2 \0 mac \0 phone \0 macNonce \0 challenge \0 dialer \0 answerer`,
  and checks the phone's signature over
  `cmux-mobile-link-auth-v2 \0 mac \0 phone \0 nonce \0 identityKey \0 approvalKey \0 action \0 dialer \0 answerer`
  (refused `unpaired` otherwise).
- The phone checks the proof over its own tunnel's keys (refused
  `mac_identity_changed`, before it signs). Once a Mac proved v2, the phone
  remembers it beside the pin and refuses a v1 challenge from it on a WireGuard
  link; a v2 challenge on a link with no tunnel keys is refused too.
- A peer that sends no `proofVersion` (an older phone, or a WebRTC link) gets
  the v1 proofs above; an older Mac ignores it and answers v1.

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
  dead TCP connection. Since 0.15.0 each keepalive also sends the text frame
  `ping`, which the hub answers with `pong` without waking (a hibernation
  auto-response) and whose time it keeps: it tells a Mac that is awake from
  one that slept with its socket half open ("Connectivity incidents"). An
  older Worker answers `ping` with a session-less `bad_request` error frame:
  the reader counts the pings it sent and swallows one such answer per ping,
  so it never fails a dial in flight; `pong` is dropped the same way. A reused socket that does not answer a ping within
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
network)", "Block UDP" and "Relay via cmux (HTTPS) only" ("WebSocket
relay"). Each is a phone-side dial policy with no wire change, and changing
one redials.

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
- Proxy only and Drop WireGuard (WireGuard; WebRTC ignores them; they apply
  at the next dial): the corporate networks below ("Corporate networks").
- No media session (measurement): simulator
  `SIMCTL_CHILD_CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA=1` leaves `webrtc-media` out of
  `wg-init`, so browser video rides RTP in the tunnel ("WireGuard only").
  cmux-mobile-host: `CMUX_MOBILE_WEBRTC_MEDIA=0`, or the test signals `SIGUSR1` (toggle a
  black hole under every media session's track) and `SIGUSR2` (close every
  media session).

The phone's link line names the path: "WireGuard direct", "WireGuard relay
(TURN)", "WireGuard relay (TURN over TLS)", "WireGuard relay (cmux, HTTPS)"
(and the same for WebRTC's TURN). cmux-mobile-host reports the path as
`direct`, `turn`, `turn-tls`, `https-relay` or `none` (`phone_up`, `phone_path`).

## Corporate networks

The link's own connections (the signaling WebSocket, the HTTP API, TURN
over TLS or TCP, and the WebSocket relay's join, on the phone and on the
Mac's hostd) leave the device the way URLSession's do. No wire change; `cmux-mobile-link` `egress/`.

- **TLS inspection.** A company network that inspects TLS re-signs every
  server's certificate with its own root, which an MDM profile (or Settings
  → General → About → Certificate Trust Settings) made the OS trust. The
  link verifies every server against the OS trust store
  (`rustls-platform-verifier`: the Security framework on iOS and macOS, the
  system bundle elsewhere), so it trusts that root as Safari does. A
  certificate the OS does not trust still fails. This is safe for the link
  because WireGuard authenticates and encrypts every byte end to end inside
  that TLS (SECURITY.md "Link transport").
  A chain the OS trusts but the public web PKI bundled in the app does not
  marks its host **inspected** (`egress::tls::inspected`); the connection
  goes on unchanged. The link's `link_stat` carries `egress: "inspected"`
  (or `"proxy"` for a proxy that does not inspect; absent when every link
  connection went direct), cleared at each network change.
- **Proxy only.** A network whose only way out is its HTTP proxy. Each
  connection asks the system for the proxies of its destination
  (`CFNetworkCopyProxiesForURL` for `https://host:port/` on iOS and macOS: a
  manual HTTP, HTTPS or SOCKS proxy, a PAC file or script, run by CFNetwork
  itself, WPAD, an MDM global proxy; the `https_proxy`, `http_proxy`,
  `all_proxy` and `no_proxy` variables elsewhere) and tries them in order. An
  HTTP proxy carries the connection with `CONNECT host:port` (the TURN
  server's name, unresolved: the proxy resolves it), a SOCKS proxy with SOCKS5.
  Credentials the system's settings hold go along: HTTP Basic
  (`Proxy-Authorization`) and SOCKS5 user name and password (RFC 1929). The
  answer is cached for 30 s per destination and forgotten at a network change,
  and a PAC file gets 4 s to answer (then direct, as CFNetwork does).
  Loopback is never proxied. A destination name with a space or a control
  character is refused before it reaches the proxy.
  - A proxy that asks for **NTLM or Kerberos (Negotiate)** fails the dial at
    once, before `wg-init`, with a sentence that names the proxy, the server
    and the schemes it asked for. The link does not do those: Apple exposes no
    API that hands an app a proxy-authenticated byte stream it can run TURN
    on. `URLSessionStreamTask` (and `URLSessionWebSocketTask`) do follow the
    system proxy and answer its challenges from the keychain, but only from
    Swift, not the Rust core, and a stream task carries TCP for one host only,
    so moving TURN's socket there means a Swift transport the language
    boundary rules out; Network.framework's `ProxyConfiguration` (iOS 17)
    takes a user name and password only (`applyCredential`), and
    `NWConnection` does not follow the system proxy on its own. A Basic proxy
    with no password in the settings, or one that refuses it, fails the same
    way with its own sentence.
  - A dial whose STUN never answered (or never resolved) and whose TURN over
    TLS the proxy refused fails with that sentence instead of a timeout.
- **A firewall that drops WireGuard.** Packet inspection that lets STUN and
  TURN's own requests through (so UDP looks open and TURN over UDP grants an
  allocation) but drops every datagram carrying a WireGuard message, bare or
  inside TURN over UDP. A tunnel that has no route (nothing from its peer
  authenticated) for 3 s on the dialing phone, 6 s on the answering Mac, from
  its start or after a roam, takes a TURN allocation over TCP or TLS
  (timeline mark `wg_silent_turn_tls`) and announces it as a roam does,
  through signaling too (`wg-endpoints`), so the peer sends there. Until its
  next roam that side takes TURN over TCP or TLS only. A side already on TURN
  over TLS, or with no `turns:` or TCP `turn:` server, does nothing. Both
  sides then send a handshake initiation at once (the escalating side on its
  new allocation, the peer on the announcement); after answering the peer's,
  a side with data queued waits for the peer's first data before it starts
  another (cmux-wg `wait_for_handshake_until`), so the two crossing
  handshakes complete instead of replacing each other.
- **Then the WebSocket relay.** The relay's "nothing reached the peer" join
  (WebSocket relay, above) waits while this fallback may still take TURN over
  TLS: from the moment the tunnel has no route until a route comes, or the TLS
  allocation came up and had 3 s (`RELAY_AFTER`) to carry a handshake
  (`RelayClock::turn_window`). So a network that drops WireGuard links over
  TURN over TLS, and joins the relay only when that fails too (TLS to TURN
  blocked, or the proxy refuses it).

Debug builds add Settings → Transport → Developer → "Proxy only" and "Drop
WireGuard" (`DeveloperOptions.proxyOnlyKey`, `dropWireGuardKey`;
`ConnectOptions.proxyOnly`, `dropWireguard`), read at each dial:

- Proxy only: Block UDP, and TURN over TLS must leave through a proxy the
  system's settings name for the TURN server; with none the dial fails at once
  and says so.
- Drop WireGuard: every UDP datagram carrying WireGuard is dropped on this
  side, both ways, on the tunnel's socket and its TURN over UDP; STUN and TURN
  requests pass. The link should come up on `turn-tls` within about 4 s.

The rig sets them without the app's settings: simulator
`SIMCTL_CHILD_CMUX_MOBILE_DEV_PROXY_ONLY=1`,
`SIMCTL_CHILD_CMUX_MOBILE_DEV_DROP_WIREGUARD=1`, and
`SIMCTL_CHILD_CMUX_MOBILE_DEV_PROXY=http://user:pass@host:port` (or
`socks5://...`, or `direct`) in place of the system's proxy settings. hostd
reads the same three variables; `cmux-mobile-dial` takes `--proxy-only` and
`--drop-wireguard`.

## Terminal size claims

**Projection (2026-11-12, the default).** The phone keeps a VT model of the
Mac terminal at the Mac's grid, fed the attach stream's bytes
(`cmux-terminal-projection`, `TerminalProjectingSession`), and re-wraps its
primary screen (a shell, an inline TUI such as Claude Code) at the phone's
own width. On the primary screen the phone claims no size: it attaches
without one and never sends `resize-surface`, so attach, an app switch, a
lock, the keyboard and a rotation never resize the Mac's PTY, and a rotation
re-wraps on the phone in the same frame. On the alternate screen (vim, htop)
it claims as below, only while the page claims, and releases when the
program leaves the alternate screen.

With Settings → Terminal → Zoom Full-Screen Apps on (off by default,
`cmuxMobile.settings.terminalZoomFullScreenApps`, read when the page opens),
the alternate screen claims no size either: the page shows the Mac's exact
grid, zoomed (pinch snaps to fit width and to the reader's font size, double
tap toggles them, one finger pans and is never sent to the program). The one
exception (2026-11-17, `fit_policy`): the phone claims its grid as below once the person types text (3 printable characters; keys, mouse
reports and replies never count) into a TUI: the alternate screen, or a
named program that is not a shell drawing on the primary screen with its
cursor hidden (Claude Code, Codex). The program's name (the terminal title,
else the tab's) is remembered on the phone, so the next time it is in the
foreground the phone claims at once and holds the program's frames at the
Mac's grid until the `resized` replay arrives (1.5 s at most). The claim is
released when the program leaves the foreground (the alternate screen ends,
the cursor shows again, another program is named) or when the page stops
claiming. The terminal's title menu toggles it by hand (Fit to Phone, Keep
the Mac's Size); undoing forgets the program. On the primary screen, cursor position
(`CSI 6n`) and text area (`CSI 18t`) reports are answered by the projection
in the Mac's cells; on the alternate screen the phone's terminal gets the
program's bytes unchanged and answers them itself (once). A rotation
re-wraps the Mac's screen and two phone screens of scrollback above it
(plus the lines being read); older lines are re-wrapped as the reader
scrolls up to them.
Settings → Terminal → Fit to Phone turns projection off: the rest of this
section then applies to every screen.

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
  with no debounce, before iOS suspends it (2026-11-12, Leo: "if I do
  completely switch away, I want to be gone. I want to leave it. And if I
  come back, I don't want to see the stretched out version"), so the Mac's
  pane gets its own size back. Coming back (`willEnterForeground`) claims
  at once, and the page as it was when the app left stays on screen until
  the reclaim's mirror reset is replayed, so the Mac's wider grid is never
  painted. The claim:
  `resize-surface` with the last measured grid. While released, layout passes
  are remembered and not sent, and a reattach attaches without a size.
  The release goes out at once on the attach channel, never behind a request
  of the session's still waiting for its answer (that answer comes back
  behind the terminal's output, and iOS may suspend the app first); the
  daemon runs one connection's requests in order, so it still lands after
  any size sent before it (2026-11-12).
- **Reclaim hold (phone, `TerminalReclaimHold`).** Any release (a page left
  for another tab, the grid or a sheet, or the app going to the background)
  makes the Mac replay its own grid to the hidden page, and the claim makes it
  replay the phone's again. The page draws neither round trip: while it is released, a
  grid other than its claimed one, and every byte after it, is held. When the
  claim brings the phone's grid back, the held events are dropped (the replay
  after a grid change is whole) and the screen gets a reset and the replay's
  alternate screen state. When the Mac is already at the phone's grid, the
  stream ends, more than 8 MB is held, or the claim is not answered with the
  phone's grid within 1.5 s of being attached (the Mac's policy keeps its own
  grid), the held events show in order. The page keeps its last frame at its
  own grid meanwhile (Leo, 2026-11-12: "i swipe up into another app and it
  resize back... then i go to it again and it resize again").
  On screen too, the page never draws a grid it did not ask for while its
  claim may still bring its own back (Aziz, 2026-11-12: "ensure that the
  phone never sees a terminal size that it doesn't want to see even if it
  receives it"): a grid other than its claimed one (its lease ended over a
  slow link, a reattach replayed the Mac's grid) starts the same hold, the
  phone sends its size again at once, and the hold shows what it has only
  when the Mac keeps its grid past 1.5 s (its policy keeps that grid). The
  Mac's later grid changes then show as they come, until the phone's grid is
  back or the page claims again.
- **Stop (phone).** A session that stops (its tab cooled out of the warm set
  of 4, closed, another account) sends `release-surface-size` and waits for the
  answer (at most 2 s) before it closes its channel. The daemon would read a
  bare close as a dropped link and hold the grid.
- **Size lease (phone and daemon, `size-lease-v2`, `size-lease-v1`).** The
  phone lists both in `set-client-info` `capabilities`. When `identify` lists
  `size-lease-v2`, the phone sends its claimed size again every 2 s while it
  claims and the daemon releases a size not refreshed for 8 s; with only
  `size-lease-v1`, every 15 s and 45 s. A same-size `resize-surface` renews
  the lease and never resizes the PTY, and a refresh goes out at once, never
  behind an unanswered request, so a slow link does not let the lease run
  out while the phone is on screen. With the short lease, a phone that went
  away without a release (suspended before it left, a dead link, a crash)
  gives the Mac its grid back within 8 s; a connection that
  ended without releasing ends the departed-view hold its own departure set
  at that moment (a later departure's hold runs on). A suspended or dead phone can never pin the Mac's grid past it.
- **Departed-view hold (daemon).** A phone's connection that ends without a
  release (the link dropped) keeps the grid from growing for 30 s, so a link
  blip that reattaches finds the grid it left (termqa V2-5); capped by the
  lease as above (8 s under `size-lease-v2`), and ended at once by a phone
  back with a size.
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
release and the daemon's size lease (8 s under `size-lease-v2`).

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
| App to the background, screen locked | `didEnterBackground` → release at once (never behind an unanswered request), inside a short background task; coming back holds the page from before until the reclaim's replay | one round trip; 8 s if the release never leaves the phone |
| Force quit, killed by iOS while foreground | no release; lease ends (or keepalive + hold, capped by the lease) | 8 s (45 s under `size-lease-v1`) |
| Killed by iOS in the background | already released on entering it | one round trip |
| Link drop: network loss, roaming | keepalive closes the socket; hold capped by the lease | 8 s (45 s under `size-lease-v1`); a reattach inside it keeps the phone's grid, and a later one never draws the Mac's grid first |
| Transport switch | link redialled; hold; reattach finds the grid | no change if it reattaches within 8 s (30 s under `size-lease-v1`); else the Mac's grid until it does |
| Mac host (hostd) restarts: SIGTERM | hostd releases before exit | 0.7 s |
| hostd crashes or is killed (SIGKILL) | socket closes; hold capped by the lease | 8 s (45 s under `size-lease-v1`) |
| The Mac's cmux-tui daemon restarts | new daemon, no phone participant until it reattaches | at once |
| iPhone connections turned off on the Mac | hostd SIGTERM → release | 0.7 s |
| The owner removes the phone on the Mac | link closed `removed` → hostd releases | 0.5 s |
| Phone signs out, "Remove This iPhone from My Macs" | links close (sessions stop and release when the link still carries them); else hold capped by the lease | 8 s worst case (45 s under `size-lease-v1`) |
| Tab cooled out of the warm set, tab closed | session stop → release, then close; else hostd releases on the close frame | one round trip |
| Grid card of a tab not started | `read-screen` only, never attaches | never claims |
| Grid card of a started tab | its page is not interactive → release | 1 s + RTT |
| Several phones | each claims and releases its own; the grid is the Mac's again once every claim ended | the slowest phone's bound |
| A phone and another remote client (a second Mac, the TUI) | the phone's release makes the grid follow the remaining views; a non-handheld view never holds | as the phone's path |
| Older phone without `size-lease-v1` | no lease: hostd releases on its close frame, the keepalive + 30 s hold on a drop | 65 s on a drop |

Measured on the rig: cmux-next-ios/verify/size-release-20261021.md.

## Terminal history window (`attach-replay-history-window-v1`; added 2026-11-14)

The Mac keeps a terminal's scrollback; the phone's mirror holds the screen and
a bounded part of it (cmux-tui `spec/commands.md`, `attach-surface`).

- Attach: the screen alone (`replay_history_rows: 0`,
  `attach-replay-history-rows-v1`, as before).
- Scrolling up to the oldest row held: an attach with 2,000 more of the
  newest rows, up to 10,000. Past them, an attach with a 4,000-row window
  (`replay_history_rows: 4000, replay_history_start: S`): the Mac sends rows
  `[S, S+4000)` and the screen, and says how many rows it left out above
  (`history_rows_omitted`) and between the window and the screen
  (`history_rows_skipped`). Each step moves the window 1,500 rows up, down to
  row 0, the oldest row the Mac keeps. The phone never holds more than 10,000
  history rows, however long the Mac's history is.
- Scrolling down to the window's last row: the window moves 1,500 rows down.
  Within 4,000 rows of the screen the Mac sends the rows from `S` down to the
  screen (no `history_rows_skipped`), and the phone holds the newest rows
  again. Scrolling up from the screen to the window brings the newest 10,000
  rows at once.
- Each such attach replaces the last one; the screen puts the reader back on
  their rows by text (`TerminalReadingMark`), which a step of 1,500 rows keeps
  within the 2,000-row search.
- Resize: the phone declares the capability in `set-client-info`, so each
  `resized` replay holds the screen and the newest `replay_history_rows` rows
  of the reflowed terminal (a window becomes the newest 4,000 rows), with
  `history_rows_omitted`, instead of the whole history.

Compatibility: a daemon without the capability gets no
`replay_history_start` (the newest rows grow as before, then the whole
history); a Mac app whose lane refuses the field gets the same attach without
it; a phone that does not declare the capability keeps getting whole
`resized` replays.

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

When some send failed, the answer also carries `failures`: one
`{environment, status, reason}` per failed send, where `environment` is the
phone's registered `sandbox` or `production`, `status` is APNs' HTTP status
(0 when no answer came) and `reason` is APNs' reason word
(`BadEnvironmentKeyInToken`, `TopicDisallowed`, `InvalidProviderToken`, ...),
`network` when no answer came, or `unknown` for any other body. It never
carries the device token, the topic or an error's text. Without a failure the
field is absent, so the rest of the answer is unchanged. Sends APNs reports as
gone count in `dropped`, not here: only a token-level answer (`BadDeviceToken`,
`Unregistered`, `DeviceTokenNotForTopic`, or 410) drops a registration.

A key- or topic-level answer (`TopicDisallowed`, `BadEnvironmentKeyInToken`,
`InvalidProviderToken`, `ExpiredProviderToken`, `MissingTopic`, `BadTopic`)
would be the same for every phone on that environment and topic, so the
Worker does not send that event to the rest of them: they count in
`skipped` (absent when 0), not in `failed` or `failures`, and keep their
registrations. The Worker keeps at most 6 APNs sends in flight per event,
each environment and topic's first send in the first six.

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

A Claude Code terminal's approval (its PermissionRequest hook, for any tool but
AskUserQuestion and ExitPlanMode) rides the same way: the `list-notifications`
row carries `approval` `{harness: "claude", tool, command?, target?,
description?}` while the agent waits on it (memory only; cmux-tui
`agent_hook_live_approval`, `session.journal.append` `live_approval`). The
Feed shows it as a permission card with Allow once (types `1`) and Deny
(Escape), sent only after its own `list-notifications` request still carries
it and `read-screen` shows its dialog at the bottom of the screen; see SECURITY.md "Answering a terminal agent's
approval from the phone".

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
eventId \0 box`. The box also carries `postedAt` (Unix seconds). One request
carries at most 20 boxes (a bound on its body, not on phones); `box` is
base64url of at most 3072 characters (hostd trims the content to fit, and
skips a phone whose box still would not). When every paired phone
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

#### More than 20 phones: a lead and batches (API 0.16.0)

There is no cap on how many phones get a push. The Worker sends a notify to
every push registration of the Mac's owner that wants the kind and has not
muted the Mac. A Mac with more than 20 boxes splits one event:

- The **lead** is the notify as above with the first 20 boxes, plus
  `batchedPhones: ["<phone device id>", ...]` (at most 10000), the phones
  whose boxes come in batches. The Worker sends the lead to every target but
  those phones. A Worker that takes batches answers with `batches: true`.
- Each **batch** carries the routing ids, the next at most 20 boxes and
  `batch: n` (1, 2, ...; at most 500). The Worker sends it only to the targets
  it has a box for, never checks the turn-end window again (the lead did),
  and counts it in its own rate bucket (`<mac>:batch:<n>`), so a phone past
  the first 20 gets pushes at the same rate as the rest.
- hostd posts the batches after the lead, and only when the lead's answer
  has `batches: true` and no `coalesced: true`: an older Worker ignores
  `batch` and would push a batch to every phone again. A malformed `batch`
  or `batchedPhones` is refused (400), never dropped.

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

### Store and forward (`mailbox-send-v1`, API 0.18.0)

A chat send or a composer queue action the phone makes while its Mac sleeps
or is offline goes through the same mailbox, sealed and signed the same way,
held for hours, and applied once, in order, when the Mac's signaling socket
comes back. Every field below is optional on the wire: an older phone, hub or
Mac keeps the reply mailbox above as it is.

**Hub (Worker user hub).**

- `POST /v1/devices/:macId/mailbox` takes `hold` (seconds, an integer from 1
  to 86400; absent, 600). The answer adds `seq` and `expiresAt` (ms): a phone
  that gets no `seq` talks to an older hub, which holds every item 10 minutes.
- `seq` is per (Mac, phone): 1, 2, 3, ... in post order, never reused, also
  after items expire or are settled. A retried post of the same item answers
  its first `seq`.
- Bounds: items with `hold` of at most 600 count against the 32 pending per
  Mac as before. Longer holds count per (Mac, phone): at most 64 queued and
  at most 524288 sealed characters (`429 rate_limited`, the phone's
  `full`). An outcome stays readable 10 minutes past its item's expiry.
- Delivery: `mailbox` items add `seq` (absent from an older hub). The hub
  sends a Mac's queued items ordered by phone, then `seq`, at most 32 in one
  frame, each once per socket; after each `mailbox_ack` it sends the next
  page. An item posted while the socket is open goes at once unless 32 sent
  items still wait for their ack on it. Items not acked are sent again on the
  next socket.
- `GET /v1/devices/:macId/mailbox/:id` adds `seq` and `expiresAt` for an item
  that has them; `expired` is reported once `expiresAt` passed unsettled.

**Mac (hostd).**

- hostd keeps the highest settled `seq` per phone in
  `<state>/mailbox-cursor.json` (0600), written after the item's outcome is
  in `mailbox-spent.json` and before its ack is sent. An item whose `seq` is
  at or under its phone's cursor is never applied: hostd answers its first
  outcome from the spent file (signed), else `replayed`. With the spent file
  claimed before applying, a redelivery, an ack lost on the way, a hub retry
  or a hostd crash mid-apply never applies an item twice.
- Order: a phone's items are applied in `seq` order. An item that cannot be
  settled yet (`unavailable`) holds that phone's later items back, unacked,
  until it settles; other phones' items go on.
- An item with no `seq` (an older hub) is handled as before, by id alone.
  Within a frame those go first, in frame order, then each phone's items by
  `seq`; hostd handles one frame at a time. A held item's phone sends its
  higher `seq`s to `later` until it settles; a hold not retried in 90 s
  (its socket died) lapses.
- The cursor moves only for an item that passed the seal, pairing, signature
  and expiry checks: `seq` is the hub's and not signed, so a forged item
  cannot move it. Gaps (an expired or unreadable item) are allowed.
- An unreadable cursor file holds every item `unavailable`. An item under the
  cursor whose spent record is still applying, or with an unreadable spent
  file, is `unavailable`, not `replayed`. A failed cursor write is logged:
  the spent file still stops a second apply.
- Crash windows: after the spent claim and before its settle, a redelivery
  answers `replayed` (as today); after the settle and before the cursor
  write, it answers the first outcome signed and then moves the cursor.
- hostd lists `mailbox-send-v1` in `version` when it takes the kinds below.
  A phone routes a send to the mailbox only to a Mac that listed it on its
  last link.

**New kinds** (the sealed plaintext of "Reply mailbox"; `target.sessionId`
required for both):

- `send`: a chat message to an agent session. `action: {type: "text", text,
  steer?}` (`steer` defaults to true, as Send in the chat). The mailbox item's
  `id` is the composer's client message id, used as the acpmux `promptId`
  (`resend: true`), so the same message sent over the link and through the
  mailbox runs once whichever comes first.
- `compose`: a composer queue action, keyed by its item id. `action: {type:
  "queue", op: "update" | "remove" | "send_now" | "move", promptId, text?,
  index?}` (`text` for `update`, `index` from 0 for `move`), applied as
  `_acpmux/queue_edit` (`queue_remove` for `remove`). `text` (1 to 4096
  bytes, not blank) is read only for `update` and `index` only for `move`. A
  queued prompt that is gone (`_acpmux/info` fails, or the answer is
  `{ok:false}` or `{removed:false}`) is `not_pending`. A `send` whose `steer`
  is not a bool is refused; absent or null is true.
- Their lifetime is up to 24 hours: `expiresAt` at most 86400 s after
  `issuedAt` and at most 86460 s after the Mac's clock. Every other kind keeps
  600 s. The phone posts them with `hold` equal to its time left.

**Phone (`cmux-mobile-link`, Rust).** One router decides each send: the link
up and the Mac present goes the link; the link down or the Mac offline, with
`mailbox-send-v1` from the Mac, goes the mailbox; neither, it fails as
before. Both paths carry the same id, so a send that went the link and then
the mailbox (or the reverse, after a link drop) runs once. Each item's state
is `queued`, `applied`, `rejected` (with its reason) or `expired`; `applied`
and `rejected` count only with the Mac's signed ack, else "Not confirmed by
<Mac>".

Phone details: it reads an item's state after 1, 2, 4 and 8 s, then every
30 s until `expiresAt`. A `409` on a retried post counts as queued; its `seq`
comes from the next read. A post answered with no `seq` came from an older
hub: the phone takes `expiresAt` as its post time plus 600 s and never asks
for a longer `hold` there. A `404` read before `expiresAt` (the hub lost the
item) shows "Not confirmed by <Mac>", never a failure: the Mac may have
applied it.

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

## Relay snapshot seal (`cmux-relay-snapshot-v1`; RFD 0142 R2, relay serve behind `LINK_RELAY_CACHE`)

The envelope a relay's Durable Object will store so a cold-opening phone gets first content from the edge
while its live link dials. The relay holds ciphertext only. The one implementation is the Rust crate
`cmux-tui/crates/cmux-relay-snapshot` (Mac, relay tooling and the phone's FFI all use it; Swift is a shim).
The Durable Object store and serve are in the backend (`relay-cache.ts`, `/v1/relay-cache/...` below), off
unless the Worker's `LINK_RELAY_CACHE=on`; the host publish path and the phone's open are the next PRs, each
versioned and updated both sides at once.

- Seal: the ECIES of "Sealed pushes" (P-256 ECDH, HKDF-SHA256 salted with `E_pub || R_pub`, AES-256-GCM) with
  HKDF info and AAD `cmux-relay-snapshot-v1 \0 sourceKeyId \0 viewerKeyId \0 stream` (key ids are lowercase hex
  SHA-256 of the X9.63 point), and the 130-byte header in the AAD.
- Envelope: `version(1) epoch(u64) seq(u64) sourceKeyId(32) E_pub(65) nonce(12) ctLen(u32) ct||tag sig(64)`,
  big endian. `sig` is the source identity key's ECDSA P-256 / SHA-256 (fixed 64 bytes) over
  `cmux-relay-snapshot-sig-v1 \0 context \0 every byte before sig`.
- Order: `(epoch, seq)` compared epoch first. The Durable Object keeps only the newest envelope per viewer and
  stream; the viewer keeps the highest position it accepted and refuses an older one (`stale`), so a replay or
  a rolled-back source never replaces newer state. Equal is a harmless replay.

### Host replica sealed state (RFD 0163 row 7, off by default)

The host replica (`cmux-tui-cloud-conversations::host_replica`) can seal every session and chief snapshot it
publishes, and every answer to `snapshot.request`, before the relay stores it. Off by default: nothing sets a
seal yet, so frames are unchanged. With a seal, a frame's `state` is replaced by

```json
{"sealed":"cmux-relay-snapshot-v1","source":"<hex source key id>","to":{"<hex viewer key id>":"<base64 envelope>"}}
```

- One `cmux-relay-snapshot-v1` envelope per viewer, at position `(0, seq)` where `seq` is the frame's seq, on the
  frame's stream. The relay stores the object opaquely and sees only key ids, sizes and positions.
- Viewers: every device in the Mac's pairing store, the set that already authorizes readers, by the key
  agreement key it proved at pairing (its `pushKey`, "Keys at pairing", counted only while the store still
  pairs it with the identity key that signed it); the app refreshes the set on pair and unpair. A device that
  gave no push key gets no envelope. 1 to 16 keys, duplicates collapse. Source: the Mac identity key.
- A seal that fails to build refuses the lease; a frame that fails to seal is not sent (the replica stays
  online and says why). `require_seal` (default off) refuses any lease without a seal, so the host never
  publishes state in the clear. A renewal cannot add or drop the seal.

### Relay delta catch-up (RFD 0142 R9, relay serve behind `LINK_RELAY_CACHE`)

A viewer that resumes after sleep asks the relay for the deltas it missed, so it catches up from the edge
without waking the Mac. `cmux-relay-snapshot::delta` is the one implementation (Rust); the relay's
`relay-cache.ts` mirrors its rules over Durable Object storage (Worker and Durable Object code is TypeScript,
and the relay only reads clear headers, so it needs no crypto). Off unless `LINK_RELAY_CACHE=on`.

- Each delta is a `cmux-relay-snapshot-v1` envelope on the stream `<stream>/delta`, so a snapshot never opens
  as a delta and a delta never opens as a snapshot. Deltas count `seq` up by one within an epoch.
- The relay keeps per session at most 512 deltas and 1 MiB, oldest evicted first; each expires 10 minutes
  after it arrived (the P8 mailbox's expiry), and the log drains through what every viewer acknowledged. A
  hole or a new epoch restarts the log; a retry of a held or older position changes nothing.
- A catch-up request is one position, "after `(epoch, seq)`". The relay answers every delta after it, in
  order, or `gap` (not covered: expired, evicted, another epoch, empty); it never serves a partial run. On
  `gap` the viewer takes the snapshot or the live link, as before.
- The viewer applies a delta only if it is exactly the next position after its floor and it opens; it stops
  at the first that is not. With no floor it takes the snapshot first.
- The relay sees the envelopes' sizes and positions and which position a viewer resumes after; nothing else.

### Relay cache routes (`/v1/relay-cache/<sourceDeviceId>/...`, off unless `LINK_RELAY_CACHE=on`)

One LinkRelay Durable Object per source device (`relayCacheRoomName(owner, space, source)`), not per link
session, so a cold open reads it before any session exists and with the Mac asleep. Every call carries the
caller's `?deviceId=`; both devices must be the caller's own, and the source a Mac or VM. Off, or with
`LINK_RELAY_MODE=off`, every route answers 503 (`relay_cache_off`, `relay_off`) and clients keep the live link.

- `PUT .../snapshot?deviceId=<source>&viewer=<id>&stream=<s>` (body: one envelope, at most 256 KiB plus
  framing): the source only. `{ok, outcome: stored|stale}`; 400 `malformed`, 413 `too_large`, 507 `full`
  (32 viewer-stream slots per source). Snapshots expire 24 hours after they were put.
- `GET .../snapshot?deviceId=<viewer>&stream=<s>`: the viewer's own newest envelope, or 404.
- `POST .../delta?deviceId=<source>&viewer=<id>&stream=<s>/delta` (body: one envelope): the source only.
  `{ok, outcome: added|restarted|duplicate, evicted}`; 409 `wrong_source` for another source key.
- `POST .../catch-up?deviceId=<viewer>` with `{surfaces: [{surface, after: {epoch, seq}}], budgetBytes}` (at
  most 64 surfaces; budget default 64 KiB, at most 256 KiB) answers
  `{fromRelay: true, surfaces: [{surface, sealed: [base64url envelope], head: {epoch, seq}}], cut: [surface]}`.
  A gap or a surface the relay holds nothing for is in `cut`; the budget cuts whole surfaces in the order asked.
  Positions are JSON numbers, or decimal strings past 2^53.
- `POST .../ack?deviceId=<viewer>&stream=<s>` with `{through: {epoch, seq}}` drains the viewer's held deltas
  through that position: `{drained}`.

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
| `smallest` (default) | Fit the smallest viewer | `smallest`: every viewer sees the whole grid, except that while a phone or tablet shows the terminal the grid is never narrower than it (a narrower Mac pane clips at the right; rows stay the minimum). An agent's split does not shrink it until the person uses that Mac pane (docs/shared-terminal-sizing.md, "Agent layout changes") |
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
ends (8 s under `size-lease-v2`, 45 s under `size-lease-v1`).

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
  This applies to the alternate screen, and to every screen with Fit to
  Phone on; with projection (the default, "Terminal size claims" above)
  the primary screen is re-wrapped to the phone's width instead. With
  Zoom Full-Screen Apps on, the alternate screen's grid also takes a zoom: it opens at fit width (the
  whole width on the page), pinch and double tap reach the reader's font
  size, and one finger pans in both directions; the letterbox and its note
  follow the zoomed grid's height.

## Connectivity incidents (API 0.15.0)

A cmux team member's phone tells the team's Slack when it suffers a major connectivity incident. The
phone decides what is major; the service decides who is heard.

### What the phone reports (`ConnectivityIncidentDetector`, CmuxMobileLive)

Only when the signed-in account's connectivity audience is the team (`ConnectivityAudience`: an email on
`manaflow.ai`, `manaflow.com` or `cmux.com`, or a subdomain). Everyone else's phone never checks or sends.

- `mac_unreachable`: a Mac the service says is online has not connected for 30 s of qualifying time (the
  app in front, the phone on a network, no network change since). Before it reports, the phone fetches
  `https://captive.apple.com/hotspot-detect.html` and `GET /v1/health` at once: if the internet does not
  answer, the phone itself is offline, nothing is sent, and the 30 s start again from that check.
  `serviceReachable` says whether the cmux service answered.
- `link_unstable`: three drops of a live link (its stream ended or a probe went unanswered) in five minutes,
  each back within 20 s while the Mac stayed online, not counting drops in the 10 s after the app came to
  the front or the network changed. A drop where the Mac itself went away (presence offline), or that
  turned into an unreachable stretch, is not instability. The same reachability check gates it, and it is
  reported only once the link is up again (the Mac is then awake; one that went to sleep never
  reconnects). The service holds it (`mac_restarted`) when one of the Mac's last signaling connects falls
  inside its window: a host that crashed and came back within a second never shows the Mac offline; the
  phone then forgets it and its cooldown. At most one per Mac per 30 minutes. If the Mac stops answering
  for 30 s while it is open, it ends (`became_unreachable`) and an unreachable incident takes over.
- Not reported: a Mac presence calls offline, a link no longer used, a slow connect that succeeds, time in
  the background or without a network, sign-out.
- A Mac that goes offline in the middle of an incident (or while drops are being counted) gets 60 s to come
  back (a host restarting): back and connected, the incident resolves; still offline, it ends as
  `mac_offline` at the moment the Mac left. Drops counted before the blink still count.

Each incident is reported `open`, then exactly once more: `resolved` (the Mac reconnected, or the link
stayed up 10 minutes) or `ended` with `endReason` (`app_backgrounded`, `network_lost`, `mac_offline`,
`link_closed`, `signed_out`, `app_relaunched`). Reports wait in a file in Application Support and are sent
in order, each retried (5 s, 30 s, 2 min, 10 min, then every 30 min) until the service accepts it or
refuses it with a 400, 403, 409 or 413 (a 404, a service that predates the route, is retried); a report older than a week is dropped. Only a team account checks; the end of an incident already reported is always sent, even after the audience changed, and sign-out sends the ends (as `signed_out`) before the token goes. A launch ends what the last one left open
as `app_relaunched`, at the time it was last seen.

### The report

```json
{"id":"<uuid>","kind":"mac_unreachable","state":"open","startedAt":"<iso>","observedAt":"<iso>",
 "durationMs":31000,"mac":{"id":"<device id>","name":"Studio"},"attempts":6,"lastError":"…",
 "transport":"wireguard","serviceReachable":true,"network":"wifi",
 "app":{"version":"1.2.0","build":"450","config":"TestFlight","simulator":false},
 "device":{"model":"iPhone17,4","os":"27.2"},"simulations":["block_udp"],"drops":3,"endReason":"…"}
```

### What the service does (`src/connectivity-alerts.ts`)

- Looks up the caller's primary email in Stack (never from the body). Unverified or not on a team domain:
  `403`. Agent and service accounts (`cmux-agent-*@…`, `CONNECTIVITY_ALERT_EXCLUDED_EMAILS`), simulator
  builds, Debug builds and reports with a developer network simulation on go to the test channel
  (`CONNECTIVITY_ALERT_TEST_CHANNEL`; dropped when unset); real team phones on shipping builds to
  `CONNECTIVITY_ALERT_CHANNEL`.
- For `mac_unreachable`, asks the caller's own hub whether the Mac was awake when the phone saw the incident
  (`observedAt`, never later than now; `TeamHub.macLiveness`): it sent an application `ping` after the link
  stopped working (`startedAt`) and within 45 s of that moment. An awake host pings every 15 s through the
  30 s stretch; one that froze or slept as the link stopped cannot. (`link_unstable` is not judged by
  pings: the phone reports it only while its link to the Mac is up; it is held only for a host restart,
  above.) The hub
  keeps each Mac socket's last ping, and the last one of a socket that closed or was replaced, so a report
  delivered late is judged as it was (a Mac that woke and reconnected since does not count as awake then).
  A Mac that sleeps keeps its socket half open, so presence still says online, but its pings stop: such an
  incident (`mac_asleep`), one whose Mac is not connected and did not ping then (`mac_offline`), and one
  whose Mac never pinged (a dark wake's connect, or a host that predates the pings:
  `mac_liveness_unknown`) are kept but never posted, start or end. A phone that could not reach the cmux
  service (`serviceReachable:false`) is always posted. Rollout: until a Mac runs a build with the pings,
  its incidents are held.
- One Durable Object (`ConnectivityAlertDesk`) stores each incident under its own key for a week (at most 100
  per reporter) before answering, and keeps an ordered outbox of Slack calls sent after the answer. A start
  posts one message; its end edits that message and replies in its thread. A resend of a state already seen
  is a no-op. The same reporter's next incident for the same Mac (either kind) within 30 minutes goes in the
  first one's thread as its own "Again:" reply, which its end edits in place.
- An incident whose end never comes (the app was closed for good or removed) is closed after 3 hours: its
  message is edited to say no end arrived from the phone. An end that comes later still edits it.
- Slack calls that fail for a reason that can pass (network, `ratelimited`, a 5xx) are retried by alarm
  (5 s, 30 s, 2 min, 10 min, then every 30 min) for as long as the incident is kept. Any other Slack error
  drops that call (logged), so one bad call never holds up the alerts behind it.
- At most 5 new incidents per reporter and 20 overall per hour (both routes share one channel, so they share
  the limits), thread replies included. Each
  held-back incident is counted once; the next post (whatever its state) says how many were held back
  since the last post, and if none comes within the hour the desk posts that count (and whose) on its own.
  An end whose start was held back is posted whole later. One open incident per Mac at a time.
- The verdict uses the phone's own `observedAt - startedAt` with the server's clock, so a phone clock that
  runs fast or slow does not change it. A Mac outage that two or more
  teammates hit within 10 minutes is flagged as likely service-side; a phone that could not reach the
  service is flagged as a likely service outage.
- 10 reports a minute per user (`INCIDENT_LIMIT`).
