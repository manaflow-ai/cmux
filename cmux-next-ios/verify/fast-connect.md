# Fast and honest phone→Mac connections (2026-10-14)

Branch `feat-cnx-ios-fastconn`. The user asked why WebRTC takes about 3 s to
connect on a real iPhone. While it connected, the screen showed "No
workspaces", which was false.

## Setup

- **Phone:** the cmux-next-ios DEBUG app on the headless simulator `cmux-mobile-fc-ios26`
  (iOS 26.5) on Aziz's MacBook. The account is the DEBUG dev credential in
  the personal space.
- **Mac:** real cmux-next app builds from the fleet, each running its own
  bundled `cmux-mobile-host`. They ran on `mini-cmuxs-mac-mini-2` under
  `~/cmux-next-ios-e2e/fastconn`, in the logged-in GUI session.
  - Settings came from a private `CMUX_NEXT_CONFIG_FILE`
    (`mobile.allowIPhoneConnections: true`).
  - Auto-login used `CMUX_UITEST_STACK_EMAIL`/`PASSWORD`.
  - The builds:
    - `cmux DEV cnxfc2`: this branch at `fe8685ef`, job `6d52675a…`.
    - `cmux DEV cnxold`: `85437c23`, the hostd the user's real Mac runs. Job `186fd7b0…`.
    - `cmux DEV cnxfc`: `d1f3f9ac`, used for the early runs.
- **Before:** the app built from `094f3cd9`, the branch base.
- **Pinning:** every run pinned the Mac with
  `-cmuxMobile.live.mac.<team> <device id>`, because other agents' apps on the
  same mini use the same account.
- **Launches:**
  - "Cold" is a fresh install: no snapshot, but the tokens stay in the
    Keychain.
  - "Warm" is a relaunch.
- **Usable:** the first live workspace row on screen (`workspace_row_live`),
  measured from process start. The old app has no such mark, so it is
  measured at `link connected` (an upper bound for usable is later still).
- **Step marks:**
  - The app logs `timing <attempt> <step> +ms` under subsystem
    `dev.cmux.mobile`, category `timing`.
  - The Rust steps come from `LinkHandle.timings()`.
  - `cmux-mobile-host` logs `timings=` on `link up`.
- **Network:** the dev Worker was slow and uneven during these runs. Bare
  `GET /v1/health` took 0.17 to 1.8 s. The ingress is PDX and the hub is
  SJC (see `connectivity.md`, finding 1).

## Results (ms from process start)

Runs were interleaved. Logs are in
`verify/evidence/2026-10-14/fast-connect/logs/`.

| Phone build | Mac host | Launch | Runs | First live row (usable) | Cached rows on screen |
| --- | --- | --- | --- | --- | --- |
| before (`094f3cd`) | new | cold | 10025, 7934, 12400 (link connected) | median ≥ 10.0 s | none; "No workspaces" while connecting |
| before | new | warm | 9361, 12537, 3485 (link connected) | median ≥ 9.4 s | none |
| after | new (`cnxfc2`) | cold | 4079, 3364, 3289 | **median 3.4 s** | skeleton until then |
| after | new | warm | 8857, 4927, 2559 | median 4.9 s | **1.27 to 1.43 s** (dimmed, "Connecting…") |
| after | old (`cnxold`, 85437c23) | cold | 4887, 7090, 3811 | median 4.9 s | skeleton |
| after | old | warm | 4582, 4678, 5863 | median 4.7 s | 1.31 to 2.45 s |
| after | new | foreground after 8 s in the background (link still up) | 20, 22, 16 ms to `link_alive` | **< 25 ms** | live rows stay |
| after | new | the Mac's host restarted (link dropped) | redial: 1.1, 2.0, 1.6 s to `link connected`, with no error banner | | rows stay, dimmed |

Earlier interleaved runs against `cnxfc` (4 each) showed the same pattern.
Before: cold link 6.5 to 13.4 s, warm 6.1 to 9.3 s. After: cold usable 5.8
to 9.1 s, warm usable 4.3 to 6.4 s, cached rows at 0.78 to 1.1 s.

### Where the time goes now (after, `cnxfc2`, per run)

| Step | Cold | Warm | Owner |
| --- | --- | --- | --- |
| Launch to `dial_start` | 1.9 to 3.7 s | 0.63 to 0.71 s | Cold: Stack auth, the team list, two registrations (now in parallel). Warm: the snapshot dials before any of these. |
| `dial_start` to `token_ready` | 0.04 to 0.17 s | 0.55 to 1.4 s | Stack access-token refresh at launch |
| Signaling socket (`signaling_open` or `joined`) | 0 to 1.2 s | 0.4 to 2.1 s | Worker: TLS, WebSocket upgrade, JWT check, Durable Object |
| `offer_sent` to `answer_received` | 0.25 to 2.1 s | 0.24 to 6.9 s | Worker forwarding through the SJC hub both ways. hostd answers in about 1 ms (ICE cached). |
| Answer to data channel open (ICE, DTLS, SCTP) | 9 to 134 ms | 6 to 136 ms | webrtc-rs (was 1.0 to 1.3 s) |
| Data channel open to first daemon reply | 30 to 70 ms | 47 to 92 ms | one batched round trip (was 5) |
| Reply to row on screen | about 30 to 100 ms | about 10 to 100 ms | SwiftUI |

### Core-level baseline (cmux-mobile-dial, 2026-10-14 02:24 to 02:25 UTC, healthy Worker)

`cmux-mobile-dial` from this branch talked to `cmux-mobile-host` from this branch. Both
were built from the same source. This isolates the link from the app.
`--stock-ice-waits` together with `CMUX_MOBILE_BASELINE=1` restores the old
behavior: webrtc-rs's nomination waits, and `/v1/ice` fetched once for
every answer.

| Step | Before (6 runs) | After (6 runs) |
| --- | --- | --- |
| `GET /v1/ice` (phone) | 282 to 862 ms, before signaling | in parallel with signaling, then cached (0 ms) |
| Signaling open | 729 to 1651 ms, after ICE | in parallel with ICE; 0 ms when warm |
| hostd `GET /v1/ice` before answering | 277 to 759 ms | 0 ms (cached and refreshed in the background) |
| `offer_sent` to `answer_received` | 557 to 1040 ms | 190 to 350 ms |
| ICE checking to connected | 1.0 to 1.3 s (`host-prflx` pair held by the 1 s prflx wait); 0.2 s for `host-host` | 3 to 340 ms |
| Connect total (cmux-mobile-dial, fresh socket) | **1.69 to 3.74 s** | **0.94 to 1.33 s** |

## Root causes and fixes

1. **Serial ICE fetch, then a new signaling socket for every dial.** These
   cost 1 to 2.5 s. The FFI now keeps the link device's socket warm
   between dials. The app opens it at launch, when the team becomes known,
   and on foreground (`prewarm`). Each dial reuses it, and a dial that
   starts while a prewarm is still opening the socket joins it.
   - `/v1/ice` is fetched in parallel and cached for half its TTL.
   - One HTTP pool keeps TLS warm.
   - Sockets send a ping every 15 s and close after 40 s of silence.
   - A reused socket that does not answer within 2.5 s is replaced during
     the dial.
2. **hostd fetched `/v1/ice` before every answer,** 0.3 to 0.8 s. It now
   uses a cache that it refreshes itself.
3. **webrtc-rs nomination waits:** srflx 0.5 s, prflx 1 s, relay 2 s. The
   phone usually sees the Mac as prflx, so this cost about 1 s. The first
   working pair is now nominated. Relay keeps a 300 ms head start.
4. **App startup was serial.** It waited on auth, then teams, two serial
   registrations, the Mac list, the dial, and five serial daemon requests.
   - A per-account snapshot now dials the last Mac before teams are known.
   - Registrations run in parallel, and setup goes out in one write.
   - All of this starts at sign-in or launch, whichever tab is open.
5. **Foreground probe:** 2 s instead of 8 s before a dead link is redialed.
6. **Not fixable in the app:** Worker latency. The Worker is on the
   `workers.dev` free plan, the ingress was PDX and the hub SJC, and
   requests took 0.2 to 7 s during these runs. It now accounts for 70 to
   95% of each connect. Fixing it needs the infrastructure item from the
   audit (a paid plan or custom domain), or the Mac's address cached for a
   LAN fast path. Neither is in this branch.

## Honest states

`MacDataMachine` in CmuxMobileModel tracks each Mac's workspace data. Its phases
are loading, cached, live, empty, failed, offline and idle.

- "No workspaces" (or "No workspaces yet") appears only after the Mac
  answered with an empty list.
- While connecting with no cache, the list shows a skeleton
  (`cold-skeleton-connecting.png`).
- With a cache, it shows the last-known rows dimmed, under "Connecting over
  WebRTC…" (`warm-cached-connecting.png`). Live rows look like
  `warm-live.png`.
- A Mac that sends nothing within 10 s, or a daemon channel that fails,
  shows "Can't connect to <Mac>" with the reason and Retry. Retry reloads
  the list on a live link.
- The Feed says "Connecting to your Mac…" until the acpmux watch is live,
  instead of "Nothing yet".
- The Mac status line (chips, Settings → Paired Macs):
  - It reads "Online" only while this phone is connected. Otherwise it reads
    "Online · Connecting…" or "Online · Can't connect".
  - Paired Macs shows real presence, the last-seen time and the link line.
  - It was hardcoded as "Online · X direct" and "Last seen 3h ago".
- Failures:
  - The first failed dial retries at once without a banner.
  - A dropped link redials at once.
  - An offline Mac is not shown as "Can't reach".
- A failed chat channel and an outdated Mac host show in the status line.
  An outdated host (one that refuses the new `version` service) reads
  "Update cmux on this Mac".
- Macs that belong to another team member are listed but never dialed.

## Interop and the user's drops

- **The real-device report.** A newer phone with the old 85437c23 hostd
  logged `keepalive timed out` 50 s to 6 min after connecting while a
  terminal was attaching. The cause was the link reader. It awaited a full
  channel queue (1024 frames), so one channel nobody read stopped every
  other channel and the pongs, and the old hostd's 20 s ping timeout closed
  the link.
  - The reader now waits at most 3 s, then closes only that channel as
    `overflow`.
  - Test `an_unread_channel_does_not_stall_the_link`: red without the
    change (hung, killed at 120 s), green with it.
  - A newer phone helps an old Mac as well, because the phone keeps reading
    and answering pings.
- **Signaling resets mid-handshake.** A signaling socket lost after the
  answer no longer fails a WebRTC dial or answer. Lost before the answer,
  the dial fails at once and redials silently. hostd reconnects a
  long-lived socket after 150 ms instead of 1 s.
- **Phone new ↔ hostd old (`cnxold`).**
  - Connects, and shows "Update cmux on this Mac".
  - Stayed up for 240 s with no drop (idle Workspaces, daemon and acpmux
    channels).
  - That hostd answers the first daemon request about 5 s after the phone's
    channel opens, which is why the old-host rows above are later.
- **Phone new ↔ hostd new (`cnxfc2`).** Connects, reconnects after a hostd
  restart in 1.1 to 2.0 s, and stays up.
- **Not verified:**
  - A long terminal attach over an old host.
  - Cellular.
  - A real iPhone (not authorized for this task).

## Tests

- **Rust:** `cargo test -j 4` and `cargo clippy --all-targets -D warnings`
  are green. They include:
  - the new `prewarm_and_redial_reuse_the_socket_and_ice_servers`;
  - `a_dial_during_prewarm_joins_its_socket`;
  - `a_closed_warm_socket_is_replaced`;
  - `ice_cache_lifetime_follows_the_ttl`;
  - `a_signaling_outage_does_not_fail_the_handshake`;
  - `an_unread_channel_does_not_stall_the_link`;
  - the `version` service in `services_over_*`.
- **Swift:** CmuxMobileModelTests, CmuxMobileLiveTests and CmuxMobileTransportTests are green
  (Swift Testing, 92 tests) at `9f0ba747`, before the merge of
  `origin/feat-cnx-ios`. The run after the merge stopped at a compile error
  that the merge brought into CmuxTabsKit (`Toolbar.swift:372`, "ambiguous
  use of operator '-'"). It shows only on the mini's Xcode 26.3; the app
  builds with this Mac's Xcode. The merge commit's Retry, timeout and
  Paired Macs changes have no unit tests yet. They include `MacDataMachineTests`,
  `MacStatusLineTests`, `LiveSnapshotStoreTests`,
  `batchSendsOneWriteAndKeepsOrder` and the updated `LinkMachine` retry
  tests.
  - They ran on the cmux mini through `xcodebuild test` on its own simulator,
    because `nx-remote`'s host `cmux-lawrence-2` does not resolve from this
    Mac. They did not run locally.
- **Build:** the app builds for the simulator (`xcodebuild build -jobs 4`).

## Rerun

```bash
cmux-mobile-dial --base-url https://cmux-mobile-api-dev.debussy.workers.dev --token-file <token> \
  --team personal-<sub> --mac <mac id> --exclude-cgnat --daemon --transport webrtc [--stock-ice-waits]
# app: launch, then read the steps
xcrun simctl spawn <udid> log stream --predicate 'subsystem == "dev.cmux.mobile" AND category == "timing"'
```

## Worker 0.8.0 (2026-10-14, later): profiled and cut

`Server-Timing` is now on every response (PROTOCOL.md). With it, the dev
Worker was profiled. It runs in colo SJC, its hub in SJC, and PlanetScale in
us-east-1 behind Hyperdrive. These were the costs:

| Cost | Before | Fix |
| --- | --- | --- |
| A fresh isolate fetching Stack's JWKS before checking a token. Most signal upgrades landed on one. | `auth` 116 to 151 ms | JWKS shared across isolates through the Cache API (10 min) |
| Signal upgrade device lookup | `db` about 80 ms (us-east-1 round trip) | Team hubs keep their registered devices; the database is only a fallback |
| `/me/macs` asking Stack for the caller's teams on every request | a Stack round trip | cached 60 s, one fetch in flight |
| `/v1/ice` calling Cloudflare TURN on every request | `turn` about 50 ms | TURN answer cached for a tenth of its TTL |
| Phone launch: 2 registrations, `/macs`, `/me/macs` | 3 to 4 requests | `POST /v1/me/bootstrap`: one round trip |
| Database queries for `/macs` and `POST /devices` | `db` 80 to 170 ms | **not fixed.** The database is in us-east-1 and the Worker in SJC. Smart Placement would move the Worker away from the hub and the clients. Hyperdrive caching was turned off on purpose (stale `/macs`). |

Route timings from this Mac, 10 samples each. "Client" is curl time after
TLS; "Worker" is the Server-Timing `total`.

| Route | Before: client median / p90 | After: client median / p90 | After: Worker median |
| --- | --- | --- | --- |
| WebSocket `signal` upgrade | 397 / 452 ms | **130 / 274 ms** | 29 ms |
| `GET /v1/ice` | 85 / 105 ms | 63 / 132 ms | 12 ms |
| `GET /v1/teams/:id/macs` | 162 / 177 ms | 155 / 173 ms | 86 ms (database) |
| `GET /v1/me/macs` | 169 / 203 ms | 173 / 208 ms | 109 ms (database) |
| `POST /v1/devices` | 214 / 278 ms | 259 / 423 ms | 176 ms (2 queries) |

### Live, 20 samples each

The phone app is this branch on `cmux-mobile-fc-ios26`. The Mac is the real
`cmux DEV cnxfc2` cmux-next build on the mini. The ACCEPTANCE.md targets
are in brackets.

| Metric | Before (Worker 0.7.0, 3 runs) | After (Worker 0.8.0, 20 runs) |
| --- | --- | --- |
| Cold launch to workspaces live [≤ 1.5 s median / ≤ 2.5 s p95] | 3.3 to 4.1 s (median 3.4 s) | **median 2.45 s, p95 3.1 s** (one outlier at 9.7 s, the first launch after the deploy) |
| Warm relaunch to workspaces live | median 4.9 s | **median 1.39 s, p95 2.1 s**; cached rows at 0.82 s |
| Warm reconnect, foreground with the link still up [≤ 1.0 s / ≤ 1.5 s] | 16 to 22 ms | **median 15 ms, p95 19 ms** |
| `offer_sent` to `answer_received` | 0.24 to 6.9 s | 58 to 111 ms |

**What is left on the launch path (warm):**
- A Stack access-token refresh: 380 to 450 ms after `dial_start`. This is
  Stack, not the Worker.
- The signaling socket: 170 to 260 ms.

**What is left on the launch path (cold):**
- Stack sign-in state, the Stack team list, and the bootstrap call: 1.4 to
  2.3 s to `dial_start`.

**What is still missing:**
- Cold launch misses its target by about 1 s.
- Both remaining gaps are the Stack calls made before the first dial. The
  next step would be to dial with a cached, still-valid access token, and
  to fetch the team list after the dial.
- Foreground with a dead link (an iPhone suspended long enough for the
  link to drop) was not measured. The simulator keeps links alive in the
  background.

**Deploys:**
- `cmux-mobile-api-dev`, `cmux-mobile-api-prod` (`mobile-api.cmux.dev`), and the
  renamed `cmux-next-ios-api-dev` and `cmux-next-ios-api`
  (`cmux-next-ios-api.cmux.dev`) all report 0.8.0.
- The renamed ones were deployed from this config with the names and route
  swapped, because the renaming branch has not been pushed.
- All changes are backward compatible: old phones and Macs keep working,
  and the app falls back to the separate calls on a 404.
