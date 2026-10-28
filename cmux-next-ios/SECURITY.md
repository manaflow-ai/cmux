# mobile phone link: relay authorization

This is the analysis that the repository's "Remote CLI relay" rule asks for
(`skills/cmux-socket-policy/references/remote-relay-authorization.md`). It
covers every path by which a phone reaches this Mac through `cmux-mobile-host`. Each
path goes through one link service: `daemon`, `chief`, `acpmux`, `file`,
`upload`, or `echo`, and, when the app supervises hostd, only after the
`auth` pairing service (below) accepted the phone.
Any other service is refused with `unknown_service`.

The daemon allowlist lives in one place:
`cmux-next-ios/rust/crates/cmux-mobile-host/src/policy.rs`. It mirrors
`Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift`,
and the test `mirrors_the_swift_allowlist` fails when the two lists drift.
Additions go into both lists together with a section here. Chief's
conversation commands are not on this list: they have their own service and
policy (see `chief` below).

## Who the peer is

- **Admission.** A link starts only from a dial whose `fromUserId` is the Mac's
  own Stack user, and only the backend sets that field (PROTOCOL.md
  "Admission"). The peer is therefore one of the account owner's own phones.
  It is never another user, and never an arbitrary remote host that holds a
  copied credential.
- **The phone acts for the person, but is not the app.** It cannot send
  `client-hello` or `origin.confirmation.issue` (both are refused by the
  policy). So the daemon gives the phone lane origin `agent`, and Gate A2's
  user-only operations (`apps.*`, the agent folder, history purges and
  imports) refuse it. The phone never proves the app's install key and never
  gets `user_origin_allowed`. This is deliberate: the phone is a scoped remote
  client, not the local owner.
- **The Mac is pinned.** The phone pins each paired Mac's identity key on
  first use (the Mac app's Keychain key, proved in every `auth` over the
  phone's own nonce; PROTOCOL.md "Mac identity"). A host registered with a
  stolen token under that Mac's device id cannot prove the key, so the phone
  refuses it before it signs or sends anything, and says the Mac's identity
  changed. A host under a new device id is a new Mac to the phone: it shows in
  the list as one more Mac, and the person pairs it only by choice.
- **Revoking.**
  - Turning off Settings > Mobile > Allow iPhone Connections stops hostd, so
    no link can start.
  - Remove in Settings > Mobile forgets the phone on the service
    (`DELETE /v1/devices/:id`, which closes its signaling socket). It also
    tells hostd (`drop_phone`), which closes that phone's live links at once.
  - Remove also forgets the phone's paired keys on this Mac; its next link
    asks the person again ("Allow … to connect to this Mac?").
  - A phone that is still signed in registers again. To keep a lost phone out,
    sign that session out of the account.

## `daemon`: a splice to the app's cmux-tui session socket

The phone writes v12 JSON lines, and every line is judged by
`DaemonPolicy::evaluate` before it reaches the daemon. Anything not on the
allowlist gets a local `forbidden` error line and never reaches the daemon.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | Yes, by design, and only in these bounded forms. `send` and `send-key` type into a terminal the person already sees in their own workspaces: the phone is a remote keyboard for the owner. `create-terminal`, `new-tab`, `new-pane`, `split`, `new-screen` and `new-workspace` start the person's default shell. Their parameters are limited to size and placement fields (`creation_fields`), so `argv`, `command`, `cwd`, `env` and any other field are refused. The browser commands (`new-browser-tab`, `browser-navigate`, `browser-key`, `browser-insert-text`, `browser-mouse`, ...) drive the Mac's cmux browser tabs. A URL the phone opens must be `http(s)://` or `about:blank` (test `browser_tabs_open_web_pages_only`), so `file:`, `javascript:` and app schemes are refused. This narrowing is in the Rust policy only; the Swift mirror keeps the same command list. There is no `run`, `respawn-*` or `eval` command. |
| Mutates or destroys objects the session does not own? | The phone's session is the owner's whole daemon, the same set of workspaces the person sees on the Mac, so close, rename, move and select act on the person's own objects. There is no per-object scoping beyond that, and none is needed while admission is same-user only. Frontend projections are the exception: reads and writes are limited to `scope: personal`, `subject_key: ios-device:<phone deviceId>`, so a phone cannot overwrite the Mac's own projection or another phone's. |
| Reads local state the remote should not see? | It reads what the owner's Mac shows: terminal screens and scrollback, process info, listening ports, machine usage. All of that is the owner's own data on the owner's own device. Settings, credentials, keychain, the control socket and other users' sessions cannot be reached. When the app supervises hostd, a phone that names a session gets only the app's own one (`forbidden` otherwise), so it never reaches another channel's or tag's daemon in the same socket folder. |

- **Rule 3 (command-bearing parameters):** refused on every creation command
  through the per-command field allowlist (test
  `refuses_unlisted_and_command_bearing_requests`).
- **Rule 4 (spawning terminals):** these terminals are meant to run on this
  Mac, where the person's shell lives. That is the product, not a fallback.
  No variant runs a program the phone picks.
- **Rule 5 (ID scoping):** IDs are the owner daemon's own. The only
  phone-specific object, the projection subject, is checked.
- **Rule 6 (tests):**
  - `allows_listed_commands` and `allows_the_phone_terminal_session` (the exact
    lines the iOS terminal tab sends) cover the allowed cases.
  - `refuses_unlisted_and_command_bearing_requests`,
    `projections_are_scoped_to_the_phone` and
    `the_phone_cannot_claim_the_app_identity` cover the refusals.

## `acpmux`: a splice to the app's acpmux WebSocket

- **How it connects.** The phone's frames go to the app's acpmux on loopback,
  with acpmux's dashboard bearer token. A listener that is not on loopback is
  refused.
  - acpmux treats the connection as remote-origin (`Web`). It never gets the
    LocalApp token, so the pane-only methods stay closed.
  - The endpoint comes from the app over hostd's stdin and is never written to
    disk.
  - **A phone's own credential.** When the app gives a paired phone its own
    acpmux credential (`phone_credentials` on stdin; acpmux pairing role `phone`,
    which only the person issues), that phone's channel presents it instead of
    the dashboard token. acpmux still serves it as `Web`, with every Web rule,
    but knows which phone it is. What hostd's phone filter refuses (a mode that
    does not ask, a chat in one) then goes on marked
    `_meta.acpmux.requireFullAccess`, and acpmux runs it only when that phone's
    Full-access setting is on (Settings > Devices on the Mac, off by default,
    off again at once when turned off or the phone is removed). Without a
    credential, or when acpmux refuses it, the dashboard token and hostd's own
    refusal apply as before.
- **Executing commands.** The phone can prompt agents, and agents run commands
  on the Mac. This is the product, and it runs under acpmux's permission
  policy: tool approvals reach the phone as questions, and the agent waits for
  the answer.
- **Unowned objects.** The phone sees only the owner's acpmux sessions.
- **Local state.** Transcripts belong to the owner.

## `file`: read-only previews

- **Path checks.** Only absolute paths inside `CMUX_MOBILE_FILE_ROOTS` or one of the
  Mac's workspace folders are served.
  - `CMUX_MOBILE_FILE_ROOTS` are the chat roots from Settings; there are none by default.
  - The workspace folders are the folders of the tabs the Mac's daemon lists
    at the time of the read (`list-workspaces`, canonicalized): the same
    folders the app already shares with phones for agent chats
    (`_acpmux/workspace_roots_set`, the agentcwd decision). As acpmux does, a
    folder that is `/`, the home folder or any ancestor of it is dropped, so a
    tab in `~` never opens `~/.ssh` or `~/Library`. They are read only when a
    path is outside `CMUX_MOBILE_FILE_ROOTS`; with no daemon answer the read is refused
    (full verify D9, 2026-10-19: the Files and Artifacts list showed files the
    phone's own chat edited in its workspace folder, and every preview was
    refused). This does not widen what a phone can reach: an agent chat the
    phone starts there can already read those folders.
  - A tab's folder is its shell's last reported cwd (OSC 7), which any
    terminal output can set. So a folder inside a credential or settings tree
    of home (`.ssh`, `.gnupg`, `.aws`, `.azure`, `.kube`, `.docker`,
    `.config`, `.password-store`, `Library`; `SENSITIVE_HOME_TREES` in
    `services.rs`) is never a workspace-folder root for previews (PR #22555
    review).
  - The path is canonicalized (symlinks resolved) before the open.
  - After the open, the descriptor's real path (`F_GETPATH`) is checked again,
    so a component swapped for a symlink in between cannot escape.
- **What it serves.** Regular files only (opened non-blocking, so a FIFO
  cannot hold the open), up to 64 MiB. It never writes, lists
  directories, or executes anything.

## `chief`: a splice to the Mac's Chief conversation owner

Chief does not go through `daemon`. The Chief's conversations live in their
own cmux-tui session: the Chief home's owner, `cmux-chief-<FNV-1a of
~/.cmux/chief/<account>>`, which every cmux-next build on the Mac shares
(`ChiefHome`, plans/cmux-next/home-state-ownership.md). The `chief` service
splices to that socket, and nothing else can reach it: `daemon` refuses any
`cmux-chief-*` session name. The app passes the session in
`CMUX_MOBILE_CHIEF_SESSION` (`MobileHostLaunch.chiefSession`); without it hostd derives
`~/.cmux/chief/default`.

hostd connects over the Unix socket, so the owner treats every line as the
Mac owner's trusted connection (principal `user_local`). The filter,
`ChiefPolicy` in `cmux-next-ios/rust/crates/cmux-mobile-host/src/chief_policy.rs`, is the
only narrowing. It applies the rules of the daemon's own remote relay gate
(`cmux-tui-core/src/server/remote_relay/gate.rs`) in both directions:

- **Phone to owner.** Default deny. A v12 command passes only by exact name,
  with exactly the parameters listed for it. Command-bearing parameters
  (`command`, `initial_command`, `tmux_start_command`, `pane_start_command`)
  are refused at every level. `conversation`, `message_id`, `thread_root`,
  `reply_to.message_id` and `root` must be plain owner-made ids (`conv_…`,
  `msg_…`). Op kinds and message parts are allowlisted.
- **Owner to phone.** Every event except `conversation-changed` and
  `conversation-typing` for an in-scope conversation is dropped (terminal,
  workspace and `cloud-*` events from the owner never reach the phone).
  `conversation-list` and `conversation-search` replies are narrowed to the
  scope.

**Scope (rule 5).** A conversation is in scope when its participants are the
owner (`user_local`, kind `human`) and agents only (`agent_*`, kind `agent`).
The phone learns ids only from the owner's narrowed list or an announcement
(`change.kind:"conversation"`) that passes the same test. A conversation that
gains another participant (a paired install `remote_*`, another human) leaves
the scope at once. Every request that names a conversation must name one in
scope. In practice: the Chief conversation (`user_local` and `agent_mux`) and
the owner's other agent conversations in Home.

| Allowed | Why |
| --- | --- |
| `identify`, `ping`, `subscribe` | Session. Events are filtered on the way back. |
| `conversation-list`, `-snapshot`, `-history`, `-thread`, `-search` | Read the owner's own agent conversations (narrowed). |
| `conversation-op`: `message.send` (`client_msg_id, parts, reply_to, thread_root`), `message.edit`, `message.retract`, `reaction.add/remove`, `read_cursor.set` | What the Mac's Home does in a conversation. |
| `conversation-op`: `title.set` | Rename, as the Mac's Chief settings. |
| `conversation-op`: `question.answer` with `approval` | Answer Chief's questions. Supervised, it counts only with the phone's Face ID signature over this Mac, conversation, question and answer (one use, at most 300 s; `chief_answers.rs`); hostd strips `approval`, and the owner stamps the respondent. An unsigned or forged answer is refused `forbidden`. |
| `conversation-typing` (`conversation, on`) | Typing as the owner. |
| `conversation-attachment-upload` (`begin` names an in-scope conversation; `chunk`, `commit`, `cancel` name the upload this connection began) and `-read` | Photos and files, under the owner's own limits (type allow list, 100 MB, hash checks). |
| `cmux.protocol/2` `chief.engine.get`, `chief.engine.set` (`harness, model, effort, speed, compactor_speed`, strings), `chief.stop` (`name`) with `machine`/`session` only `current`, and no `origin` | The Mac Chief settings' model, harness and effort pickers and Stop (`ChiefControlClient`). |

Parts: `text` (`type, text, runs` with `start, length, mention, link`) and
`attachment` (`type, hash, name, mime_type, byte_count, width, height,
duration_ms, poster, preview`). Refused by name: `work`, `question` and
`link_preview` parts, and the agent-only `answers`/`answers_pending` fields.

Refused (with a test each): `conversation-create` (the Mac creates Chief with
its own idempotent request), `conversation-import`, `conversation-bind` and
`conversation-agent-token` (either would let the phone speak as Chief or an
agent), `conversation-draft`, `chief-inspect` (the memory inspector stays on
the Mac), every `cloud-*` command, every terminal or workspace command,
`participants.add` (it would widen a conversation and the scope), an `actor`
parameter, and any v2 operation other than the three above.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | Indirectly, by design: a message to Chief asks the owner's Chief to act, and Chief runs agents on the Mac under its own permission policy, exactly as a message typed in the Mac's Home. The phone cannot run anything itself: no terminal or workspace command reaches this socket, command-bearing parameters are refused, and the phone cannot bind as an agent. `chief.stop` only stops a running turn; `chief.engine.set` only picks among the brain's harnesses, models and efforts (the brain validates them). |
| Mutates or destroys objects the session does not own? | Only in-scope conversations, which are the owner's own, and only through owner-level ops the owner's reducer validates (author-only edits and retractions, own read cursor). It cannot add participants, import history, or write as Chief. |
| Reads local state the remote should not see? | Only the owner's own agent conversations and their attachments. Conversations shared with a paired install or another person, the Chief's memory and traces, and all terminal and workspace state of the owner daemon are out of reach. |

Rule 6 tests: `chief_policy::tests` (`the_ios_chief_session_passes`, the exact
lines the iOS app sends; `conversations_outside_the_scope_are_refused`;
`unlisted_commands_ops_parts_and_command_params_are_refused`;
`events_reach_the_phone_only_in_scope`; `search_hits_are_narrowed`;
`scope_rule`), the end-to-end channel test in `tests/host.rs`
(`exercise_services`: list narrowed, out-of-scope snapshot refused, token mint
refused, only in-scope events delivered, and `daemon` refusing the owner
session), and `config::tests::chief_session_matches_the_mac_app`.

Why a separate service rather than entries in the `daemon` allowlist: the
`daemon` lane reaches the app's tagged daemon, where `conversation-*` would
also expose conversation tabs and anything else stored there, and its policy
is stateless. Chief needs a stateful, both-ways filter over a different socket.
The Swift lane (`DaemonLanePolicy`) offers no Chief, so its list stays
identical to `ALLOWED_COMMANDS`.

Production note: Release and RC builds of cmux-next do not start the Chief
brain (`HomeBrainHost.bundledChiefAllowed`); the owner keeps the conversation
and answers the phone, but Chief replies only while a brain runs in that home
(a DEV or NIGHTLY build that opened Home, `cmux chief`, or
`CMUX_NEXT_MUX_HOST`). The phone says so instead of pretending.

## `browser`: streamed browser tabs (the remote browser host)

A phone browser tab streams from a CEF remote browser host the Mac app runs,
`Contents/Helpers/cmux-remote-browser-host.app`. Release builds bundle it too
(arm64 only; on an Intel Mac the app never starts it and hostd advertises no
`browser-stream-v1`, so the phone hides New Browser Tab).

- **Who reaches it.** Only cmux-mobile-host, for a paired phone (`auth` passes first;
  the `browser` service is behind the same gate as every other). The app starts
  one host per phone tab when hostd asks (`need_browser`), with
  `--listen 127.0.0.1:0`: a loopback port, never another interface
  (`RemoteBrowserHostListening` refuses a non-loopback address). Each host has
  its own random secret (32 bytes, `SecRandomCopyBytes`), passed to hostd on
  stdin and never logged; the host admits only a hello that carries it. The
  host's stdin is its lifeline: it exits when the app quits or stops it.
- **What it loads** (`browser_policy.rs`, PROTOCOL.md `browser` "Addresses",
  2026-10-21). hostd checks the first page, every `rb.navigate` and every page
  the host reports (`rb.page`) against one policy, the same trust boundary as
  the `file` previews (#22555, full verify D9):
  - A page one of the Mac's own browser tabs shows, as the daemon lists it,
    loads whatever its scheme, `file:` anywhere included: the phone sees what
    is already on the owner's Mac screen. The check reads the daemon; the
    phone's claim alone is not enough. This rule is only as strong as what
    the phone can make the Mac's own browser show: the daemon's
    `new-browser-tab` and `browser-navigate` take only `http(s)` and
    `about:blank` from a phone, but `browser-key`, `browser-insert-text` and
    `browser-mouse` drive the Mac's page as the owner's remote keyboard and
    mouse, so a page there that links to a file can be followed from the phone.
  - Anything else must be `http(s)`, `about:blank`, `data:`, `blob:`,
    `view-source:` of `http(s)`, or a `file:` URL whose resolved path (symlinks
    followed) is inside the folders the `file` service shares: the Chat Folders
    and the open workspace folders, never home, its parents, or `~/.ssh`,
    `~/.gnupg`, `~/.aws`, `~/.azure`, `~/.kube`, `~/.docker`, `~/.config`,
    `~/.password-store`, `~/Library` (`SENSITIVE_HOME_TREES`). A missing file is
    reported as missing only inside a shared folder, so the answer is no
    existence oracle for the rest of the disk.
  - `javascript:` and app schemes (anything that would hand the address to
    another Mac app) never load, even when the daemon lists one. `chrome:`,
    `devtools:`, `chrome-extension:` and other internal pages load only when the
    Mac shows them.
  - A shared file loads at its resolved path, which narrows the window for
    a symlink swapped into a shared folder after the check: the final
    component and the path as checked are fixed, but a directory component
    swapped before Chromium opens the file can still redirect the load. The
    host's next `rb.page` is checked again and taken back, after frames may
    have reached the phone (the same gap as links, below).
  - A link clicked inside the page follows the phone's rules: hostd does not
    forward an `rb.page` the rules refuse and sends the host back. Chromium
    already refuses a web page's navigation to `file:`, so this matters for a
    `file:` page linking to another file. Limit: the host has committed the
    page when hostd sees it, so frames painted before the host goes back can
    reach the phone; a navigation check inside the host (CEF `OnBeforeBrowse`)
    would close that gap and needs a new pinned host binary.
  - **Subresources and the load itself** (closed 2026-10-22). The host checks
    every `file:` load before Chromium opens the file (`rb.file_policy`,
    `file_policy.rs`; `OnBeforeBrowse` and `OnBeforeResourceLoad` in
    `rb_shim.mm`): a `file:` page that the rules allow can no longer embed a
    file outside the shared folders and the pages the Mac showed (iframe,
    image, fetch), a link to a refused file never loads (no frames reach the
    phone), and the path is resolved at load time, so a symlink swapped in
    after hostd's check is refused too. Needs the pinned host built from this
    source (`remote-browser-host.pin.json`); an older host ignores the policy
    and the earlier after-the-fact take-back still applies.
  - The other `rb.*` messages are an allowlist (`browser.rs`). The daemon's
    `new-browser-tab` and `browser-navigate` (which drive the person's own Mac
    browser, with its profile) still take only `http(s)` and `about:blank`.
- **What it can touch.** Its CEF cache lives in a fresh work folder that is
  removed when it exits (`<state>/browser`), separate from the person's own
  cmux browser profiles. It runs as the person, like the app's own CEF.
  It never reads the login Keychain (`--use-mock-keychain`): its cookies in
  that fresh folder are not encrypted with the person's "Chromium Safe
  Storage" key, and it can neither use that key nor raise a Keychain prompt.
  Without the switch every http(s) load waited on that key and no page
  painted (2026-10-14, `feat-cnx-ios-rbfix`).
- **Signing.** The host app and its five helper apps are signed with the
  hardened runtime and a secure timestamp (`scripts/sign-cmux-bundle.sh`,
  `rbh_sign`); the GPU and Renderer helpers get `com.apple.security.cs.allow-jit`,
  the same entitlement the app's own CEF helpers get. Its CEF framework is a
  symlink to the app's own (`../../../../Frameworks/...`): `codesign --verify
  --deep --strict` passes on the app, but a strict verify of the host app alone
  rejects the symlink. Whether Apple's notarization accepts it is unproven
  (tracker cx-0y2y); if not, the host must load CEF from an explicit path.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | It renders pages in an isolated host, as the Mac's own browser would: web pages, and local files only inside the folders the Mac shares with the phone or a page the Mac's own browser already shows. No script URL or app scheme is opened. |
| Mutates or destroys objects the session does not own? | No: a fresh cache per host, removed on exit; the person's browser profiles are not used. |
| Reads local state the remote should not see? | Only what a web page sees in a fresh profile (no cookies, history or saved logins of the person), files in the shared folders (the same files the `file` previews read), and pages the Mac already shows. Never home itself, `~/.ssh`, `~/Library` or the other credential trees unless the Mac's own browser has that page open (that page, not its folder's other files); the host checks every file load, subresources included. |

## `surface`: streamed simulator tabs (2026-10-22)

A phone streams a Mac phone tab's iOS simulator (PROTOCOL.md `surface`,
verify/simulator-surface.md). This reuses the `browser` trust model; it adds
no new path for a peer and no new trust decision.

- **Who.** Only a paired phone of this Mac's owner opens the channel (the
  same gate as every service). It reaches only a tab the app's own daemon
  lists now as a phone page tab of an open workspace: hostd checks the
  `list-workspaces` answer, and the app checks its own store again before it
  starts a source (`PhoneSurfaceHosts`). No answer from the daemon streams
  nothing.
- **What it sees.** Only the simulator's own framebuffer: SimulatorKit's
  IOSurface of that device, the one the Mac's phone tab draws. No screen,
  window or other app is captured.
- **What it can do.** Touch the simulator, type text, press a short list of
  keys and Home or Lock: what a person at the Mac's phone tab can do. No
  install, launch, open-URL, location, appearance or recording reaches a
  phone; hostd drops any other input, and the source takes only those lines.
  One indirect effect: text a US keyboard cannot type (accents, emoji) is put
  on the simulator's pasteboard with `simctl pbcopy` and pasted, as the Mac's
  own phone tab does, so it also lands on that simulator's pasteboard (which
  Simulator.app may sync to the Mac's while it is open). The source applies
  input one event at a time from a bounded queue (256), so a flood cannot
  start more than one `simctl` at once.
- **Lifetime.** The source stops when its tab closes or shows another phone
  (checked at the start, on every input, frame and encode), and hostd hears
  `surface_gone`.
- **Loopback.** The app's source listens on `127.0.0.1` (accept local only),
  with a per-launch secret it gives hostd over stdin, compared in constant
  time. hostd's own host for each tab is on loopback with its own secret, as
  for a browser host.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | No command or content: touches, text, keys and Home / Lock on the simulator the person already shows in a phone tab. |
| Mutates or destroys objects the session does not own? | Only the simulator's UI state, as the owner at the Mac's phone tab could change it. Nothing else on the Mac. |
| Reads local state the remote should not see? | The pictures of that simulator's screen, which the Mac shows in its phone tab. Nothing else. |

## Link transport: TURN over TLS, and no backend relay (`feat-cnx-ios-turntls`)

The WireGuard link's paths are plain UDP, TURN over UDP and, where UDP is
blocked, TURN over TLS on 443 (PROTOCOL.md "WireGuard paths"). The backend's
WebSocket relay of WireGuard datagrams is retired. None of this adds a way
into the Mac: every path carries the same WireGuard tunnel, whose keys came
from the admitted `wg-init` / `wg-resp` exchange.

- **Confidentiality and integrity stay end to end.** WireGuard authenticates
  and encrypts every datagram between the phone and the Mac. TLS to the TURN
  server only hides from the local network that the datagrams are WireGuard;
  the TURN operator sees the same ciphertext it sees over UDP. The TLS server
  name is the `turns:` URL's host, verified against the public web PKI
  (webpki roots, ring); a certificate that does not verify fails the
  allocation, and the dial goes on without that path.
- **TURN credentials** come only from `/v1/ice` (short-lived Cloudflare TURN
  credentials, 1 h), never stored, and are the same ones WebRTC uses.
- **The TeamHub carries no data.** It drops every binary frame and answers
  `relay_retired` at most once per socket and session every 5 s, naming the
  session. It still admits and forwards signals only between the two
  devices of a session (or to a Mac of the sender's own user), now including
  `wg-endpoints` (a roaming side's new addresses). An endpoint the peer
  learns this way is only a place to send ciphertext to: the tunnel accepts
  a datagram only if it authenticates under the session's keys.
- **Route confirmation** (`reach`) travels inside the tunnel, so only the
  peer can confirm a route; the retired relay marker was authenticated only
  by the backend. An older peer that never sends `reach` makes this side
  trust its authenticated datagrams instead, as before the marker existed.
- **A Mac takes a TURN allocation** only when its STUN servers never answer
  (its network drops UDP) or a debug option asks for one. The allocation
  relays only to the addresses the Mac sends to (TURN permissions), and the
  Mac's tunnel accepts nothing that does not authenticate.
- **Debug "Block UDP"** (`block_udp`, simulator `CMUX_MOBILE_DEV_BLOCK_UDP`) only
  narrows the phone's own paths. A Release build ignores the setting; the
  environment variable is read by the shared Rust core, so it is a test
  hook for whoever launches the app with it, never a way to reach a Mac.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | No. It changes how the tunnel's ciphertext travels, not what the link may do. |
| Mutates or destroys objects the session does not own? | No. A `wg-endpoints` signal is admitted only within its session and changes only that session's candidate addresses. |
| Reads local state the remote should not see? | No. The TURN server and the backend see ciphertext and addresses, as with TURN over UDP and the retired relay. |

## Media lane: browser video as RTP (WebRTC track or WireGuard UDP)

The media lane (PROTOCOL.md "Media lane") adds a way for bytes to travel, not
a way into the Mac. It is not a service and it opens nothing on the Mac.

- **Who reaches it.** Only the link's own peer. On WebRTC the lane is a track
  on the link's peer connection (the same DTLS keys). On WireGuard it is
  overlay UDP port 7422 inside the session's tunnel: the tunnel's keys came
  from the same admitted signaling exchange as the link (`wg-init` /
  `wg-resp`), the tunnel routes only the peer's overlay address, and the
  carrier also drops any datagram from another address or SSRC. No SRTP is
  added there because WireGuard already authenticates and encrypts each
  datagram; nothing listens on a real network interface.
- **What it sends.** Nothing until a `browser` channel claims it, and that
  channel is behind pairing like every other service (`auth` first). The
  lane carries only the claimed tab's encoded frames: the pictures the same
  channel would carry without the lane.
- **What the phone can send on it.** RTCP only: NACK, PLI, FIR, TWCC and
  receiver reports. A NACK makes the Mac resend a packet it sent to that same
  phone (at most 3 times); PLI and FIR make the claimed tab's encoder produce
  a keyframe (at most every 250 ms); TWCC lowers or raises that tab's bitrate.
  RTP from the phone is dropped. None of it reaches the browser host as input,
  and none of it names a tab, a file or a command.
- **Roaming** reuses the tunnel; the lane is never negotiated again, so a
  network change cannot attach it to anyone else.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | No. It moves the encoded frames of a tab the paired phone already opened; its RTCP only paces and repairs that stream. |
| Mutates or destroys objects the session does not own? | No. A keyframe request or a bitrate change affects only the claiming tab's encoder. |
| Reads local state the remote should not see? | No. Only frames of the phone's own tab, which the `browser` channel would carry anyway. |

## `daemon`: agent tabs and tab create, close and select

Added by `feat-cnx-ios-dataflow` so tabs made on the phone are real tabs of
the Mac.

- **Terminal and browser tabs** use commands already on the allowlist:
  `new-tab {pane, cols, rows}` (size and placement only, as above),
  `new-browser-tab {url, pane}`, and `close-surface {surface}`. The phone still
  never names a folder: hostd adds the Mac's own choice to a phone's `new-tab`,
  the folder of that pane's active tab (else another tab of the pane, else of
  its workspace), from the daemon's own `list-workspaces`, canonicalized, never
  `/`, the home folder or above (`pane_folder`). The terminal opens where the
  person's other terminals in that workspace already are, as one made on the
  Mac does; it gains no folder the phone's terminals in that pane lack. Selecting a
  tab stays on the phone (it remembers the last tab per workspace). The phone
  never sends `select-tab` or `report-focus` for its own navigation, because
  both move the Mac's view for the person sitting at it.
- **Agent chat tabs:** `new-conversation-tab` is new on the allowlist, and
  `DaemonPolicy::agent_tab_verdict` narrows it to one shape. Rule 2 answers:

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | It creates one tab that shows an acpmux session of this Mac. The tab itself runs nothing. The session behind it is created over the phone's `acpmux` lane with `session/new`, under acpmux's remote guard: an existing folder, an asking policy, no MCP servers, and folder trust held for the person to answer. opencode and the codex-acp adapter are refused families there; Codex on the `codex app-server` bridge starts in its asking mode (round 2, below). The phone may set only `pane`, `workspace`, `cols`, `rows`, `origin`, `mutation_id`, `transaction` and `agent_session {harness, session, host_name}`. `harness` and `session` must be short identifiers (`[A-Za-z0-9._:-]`, at most 64 and 128 bytes). `host_name` is a display name of at most 256 bytes with no control characters. `conversation`/`owner` (another conversation owner), `page`/`route` (the app's own pages) and any other field are refused. |
| Mutates or destroys objects the session does not own? | `agent_session.host` is never the phone's choice. hostd sets it to this Mac's own `install:<id>` (`CMUX_MOBILE_AGENT_TAB_HOST`, supplied by the app's `AgentTabStore.localHost`). A phone that names any other host, such as a `registry:` host or another Mac's install, is refused. The tab therefore always belongs to this Mac's acpmux and shows in the Mac app as its own chat. Without `CMUX_MOBILE_AGENT_TAB_HOST` (an older app), every `new-conversation-tab` is refused with `unavailable`. The Swift mirror refuses it always, because the irx lane has no such host. |
| Reads local state the remote should not see? | No new read. A session id the phone names is one it can already attach to over `acpmux`. |

- **Rule 3:** no field carries a command, argv, environment or folder. The
  agent's folder is the `session/new` cwd, which acpmux checks.
- **Rule 6 (tests):** `agent_tabs_get_this_macs_host` and
  `agent_tabs_refuse_other_sources_and_hosts` (policy), and the
  `new-conversation-tab` rewrite in `tests/host.rs`.

## `daemon`: terminal agents in the Feed

The Feed shows events of agents that run in terminal tabs (Codex, Claude Code)
from the daemon's notification ledger, as the Mac's notifications panel does.
It uses only commands that were already on the allowlist, and adds none:
`subscribe` (the `notification` event), `list-notifications {limit}` (read
the ledger) and `ack-tab-notifications {surface}` (mark a tab's notifications
read when the person reads them on the phone). Rule 2 answers:

- Executes commands or opens content: no. An ask from a terminal agent (an
  approval or a question in its TUI) is not answered from the Feed; the item
  opens the terminal tab. (A finished turn takes a typed reply: below.)
- Mutates objects the session does not own: the read mark is the person's
  own, on their own tab, the same mark the Mac's panel sets.
- Reads local state: the notification titles and bodies the Mac already shows
  for the person's own tabs. Agent hooks redact prompt text before the
  journal accepts it, so the body is at most the tool an approval waits on.
- Rule 6: `allows_the_terminal_feed` (policy) covers these exact lines and
  refuses the activity stream, the session journal and replies into a terminal.

### Terminal agents' texts and the Feed reply to a terminal agent (`feat-cmux-next-terminal-agent-feed`)

A terminal agent's Feed card now shows what a GUI chat's shows. Its prompt,
its whole last answer, or a failed tool's error text ride on the daemon's
live `notification` event (`id`, `prompt`, `message`). They are kept in the
daemon's memory only, as the banner's `preview` already was: not in the
ledger, the journal, a log or any daemon file. The behavior test
`a_finished_turn_notification_carries_the_whole_prompt_and_answer_for_the_feed`
checks the daemon's folders after a checkpoint. The texts are up to 4000
characters each. The phone keeps them in its own Feed archive, as it keeps a
GUI chat's preview. That includes a failed tool's error text, which, like the
Mac's own banner, is not redacted: error output can name a path or a value
the agent printed. They never go into a push. The phone reads the texts
through the `subscribe` it already had. No command was added.

**Feed reply to a terminal agent.** A finished turn's card or an error's card
takes a typed reply. The phone types it into that terminal's agent and
submits it, as the Mac's `notify --reply` banner does (paste, then Return as
its own key). It uses only lines the phone's terminal keyboard already sends:
`identify` (for the daemon's capabilities), `process-info {surface}`, then
one `send {surface, text, paste: true, submit: true, expect_foreground,
expect_agent: {session}}`. `notification-reply` stays refused. Policy test:
`allows_the_terminal_feed_reply`.

Who may reply:
- **Owner only.** The paired owner's phone can reply, over its own approved
  link (device key, owner-only admission, "Who the peer is"). The reply goes
  to the item's own Mac, never another linked Mac
  (`LiveCoordinator.terminalFeed(macID:)`), over that Mac's current daemon
  connection. A write is refused if the connection changed while the reply
  was on its way (`connectionSerial`). After a reconnect, the phone reads the
  ledger again before it allows a reply.

When a reply goes in: the phone checks first (`TerminalFeed.reply`), then
the daemon checks again right before the write. The phone's view can be a
moment old, so the daemon checks are the guarantee.
- **The daemon.** `send-expect-agent-v1` (`cmd_terminal_io.rs`), checked
  just before the write, in one command with no gap between the text and
  Return (`submit`):
  - **Foreground program.** It must still be the foreground program
    (`expect_foreground`, its full path). So text never lands in a shell
    that took the terminal back, or in another program.
  - **At its prompt.** The terminal's agent must be `idle` or `done`
    (`expect_agent`). Typed text, or the Return, would otherwise answer
    something else: refused while it works, or while it is blocked on an
    approval or a question. Those are answered in the terminal.
  - **Same session.** The agent must be in the harness session that
    posted the event (`expect_agent.session`, the event's `session`). A
    new session in the same terminal, after a restart or `/clear`, is
    refused.
  - **Older Macs.** A Mac whose daemon lacks `send-expect-agent-v1` takes
    no reply from the Feed. The phone asks `identify` first.
- **The phone**, before it sends:
  - The event must still be its terminal's newest. A later event means the
    agent moved on.
  - The terminal must still run an agent of the same harness.
  - The foreground program must not be a shell.
  - The reply's control characters are dropped, except line breaks and
    tabs. An escape inside a paste would end the paste early and send the
    rest as keys.
  - One reply at a time per card.
  - A link that drops after the send went out says the reply may have
    arrived, so it is not typed twice.

Rule 2 answers:
- **Executes commands?** It types text into a program's input, which the
  phone's terminal view already allows on any of the person's terminals. The
  reply narrows that: one terminal, one waiting agent, a program that is not a
  shell.
- **Mutates objects the session does not own?** No. The terminal is the
  person's own.
- **Reads local state?** The agent's own prompt and answer, which the person
  sees on the Mac's screen and in its banner.

This is not a trust-policy change. A paired phone could already type into
these terminals. The lock-screen notification reply (`cmux.terminal.reply`,
`notification-reply`) is a different path. It stays held behind #13742 in
the push-fallback branch, and this branch adds no notification action.

### Answering a terminal agent's question from the phone (`rich-push-termq`)

A terminal-hosted Claude Code AskUserQuestion is answered from the Feed card or
its notification by typing the answer into that terminal. No command is added
to the allowlist: the phone uses `read-screen {surface}` and `send {surface,
bytes}`, which its own keyboard already uses on the person's terminals.

- Where the question comes from: the agent hook reads the tool input before
  redaction and sends it beside the journal event (`live_question`); the daemon
  keeps it in memory only while the agent waits (never the journal, the ledger,
  the database or a log; `an_agent_question_reaches_the_notification_and_its_row_in_memory_only`
  checks the state folder). A program's OSC notification never carries a
  question; a program that runs the agent hook helper itself can post one, which still
  only lets the person's chosen option numbers and printable text reach that terminal (`a_terminal_agent_question_pushes_as_a_question`).
- What is typed: only keys that select the person's chosen options
  (`TerminalQuestionKeys`): option numbers, Tab, arrow-down, Return, Escape,
  and "Other" text limited to printable characters, so a free-text answer can
  never press Return, an arrow or Escape it was not meant to.
- Where it is typed: only while `read-screen` shows this question with each of
  its options at its own number. A terminal that moved on (a shell, another
  prompt, another question) gets nothing, and the card says so.
- Which question: a notification answers only the question it was sent for (its push is
  named by a hash of the question and its options; the phone types only while that question is pending), never a
  newer one on the same tab.
- When: a notification's answer is a foreground action (the app is open and
  unlocked); nothing is typed from the lock screen. Lock-screen terminal input
  is PR B's held policy (`verify/notifications-trust.md`).
- Residual: the screen check reads text, so an agent that draws a lookalike
  question screen in the same terminal could receive the keys; they are still
  only the person's chosen option numbers and printable text, into a terminal
  the person already types into from the phone.

## `acpmux`: agent chats in the person's workspaces (`feat-cnx-ios-agentcwd`, in `feat-cnx-ios-parity`)

Implemented on `feat-cnx-ios-parity` (2026-10-14) after the person asked that
the phone do everything the Mac app does; the trust call is recorded for
review in `verify/13742-recommendation.md` ("Agent chats in workspace folders")
and stays listed under "Decisions for the person" until they confirm it. A
phone's New Claude Chat in a workspace failed with "cwd is refused:
a remote WebSocket connection may use only a known project or a configured
webRoots folder". acpmux's remote guard (`acpmux/src/server/remote_guard.rs`,
`web_roots`) lets a `Web` connection start a session only below `webRoots`
(config.json) or a known project, which is the folder of a session acpmux
already has. A new workspace folder is neither.

The change: the Mac app also hands acpmux, on its person connection, the
folders of the tabs its daemon lists now (`_acpmux/workspace_roots_set`, kept in
memory only, the same connection and person proof as the phone approvers). It
sends none while iPhone connections are off or nobody is signed in, and an
empty list when they turn off. acpmux adds them to the Web roots under the
existing guards: `/`, the home folder and every folder above it are dropped,
and paths are canonicalized (symlinks, `..`) before the check. This is the
same set of folders as `file`'s tab-folder rule (`feat-cnx-ios-fileroots`).

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | The phone could already prompt agents in known projects. This lets it start one in a folder where the person already has a tab open. The agent still runs under the Web rules: asking policy only, no MCP servers from the phone, an asking mode, each tool approval answered by the person (on the Mac, or with the phone's Face ID signature). |
| Mutates or destroys objects the session does not own? | No new methods. Only the folder a session may start in widens, to folders the person has open in their own daemon. |
| Reads local state the remote should not see? | An agent in that folder reads what its approved tools read there, as today in known projects. Folders with no open tab, `/` and `~` (and above) stay refused, and so does a folder that is only reachable through a symlink. The folder list itself never reaches the phone. |
| Whose objects? | The Mac owner's own daemon session (the app's), set only by a connection that proved the app's person key; neither an agent, a page nor the phone can set it (`person_required`). |

- **Tests:** acpmux `tests/workspace_roots.rs` (refused before; only the
  person sets the list; `/` and home dropped; the folder and a folder below it
  pass; elsewhere, a symlink out and `..` out are refused; cleared refuses
  again). acpmux `person_allow`, `remote_guard` and the lib tests still pass.
- **Who steers the list:** it is the folders of the tabs open now, and a phone
  can change a tab's folder by typing `cd` in its terminal, so in practice a
  phone can start a chat in any folder below home that it can `cd` to (never
  home itself, `/` or above). That adds no new reach: the same phone can already
  type any command in that terminal, and every agent tool still asks. The list is
  held by acpmux for every Web connection with the listener token (cmux-mobile-host's
  splice is the only one the app opens), not per phone.
- **Turning it off:** the Mac app sends an empty list when iPhone connections
  turn off or the account signs out, reconnecting once to deliver it
  (`MobileHostApproverSync.rootsClearPending`); the list is memory only and goes with
  acpmux.
- **What stays refused:** the phone still sends no `cwd` to the daemon, no
  command, argv, env, mode or permission policy other than `ask`; opencode and the
  codex-acp adapter stay refused families (`web_modes.rs`; Codex on the app-server
  bridge starts in its asking mode, round 2); MCP servers stay empty. The
  phone's own guard says why before it asks: a workspace whose folder is the
  home folder (or above) gets "Agent chats start in a project folder" instead of
  acpmux's refusal (`LiveWorkspaceCreationBackend.isHomeOrAbove`).

## Parity with the Mac app's tab and workspace actions (`feat-cnx-ios-parity`)

`verify/parity-mac.md` lists every Mac action and the phone's state. The
actions added there use only commands already on the daemon allowlist; none
were added to `policy.rs` or `DaemonLanePolicy.swift`:

| Phone action | Line it sends | Rule 2 notes |
| --- | --- | --- |
| New Agent Chat, New Agent Chat With… | acpmux `_acpmux/harnesses`, `_acpmux/models` (reads), `session/new` (harness, `policy: ask`, workspace folder), `session/set_model` on the phone's own new session; daemon `new-conversation-tab` (host set by hostd) | The catalog read is the one the handoff sheet already made. A model choice is a free config (`FREE_CONFIG_IDS`), never a mode. A Mac-started Claude session stays unchanged from the phone (D13). |
| Rename Tab… | `rename-surface {surface, name}` | The person's own tab; the name is text the daemon shows. |
| Duplicate Tab | `new-tab {pane}` (folder chosen by hostd, `with_pane_folder`), `new-browser-tab {url, pane}` (http/https only) | Same as New Terminal and New Browser Tab. Agent chats have no duplicate. |
| Drag to reorder tabs | `move-tab {surface, pane, index}` | Position only, within the person's workspaces. |
| New Workspace in a recent folder | `new-workspace {name}`, then `send {surface, text: "cd '<folder>' && clear\n"}` into the new terminal | The same input the person can type into any phone terminal; no `cwd` reaches the daemon. The folder is single-quoted, and a folder with any control or format character (DEL, ^U, ESC, line separators), a backslash or `!` is never typed, since a shell's line editor acts on those inside quotes (`foldersThatCouldEditTheLineAreNeverTyped`). |

Tests: CmuxMobileKit `WorkspaceTabsSourceTests` (`agentChatsAreOneModelAgnosticEntry`,
`newAgentChatWithOpensTheChooser`, `aKindTheMacCantOpenStaysWithItsReason`,
`renameDuplicateAndMoveTabs`), `AgentCatalogTests`, `WorkspaceFolderTests`,
`TabNoticeTests`; hostd `policy::tests` (unchanged allowlist, `mirrors_the_swift_allowlist`).

## Workspace pins, order and Clear All Notifications (`feat-cnx-ios-parity2`)

Parity round 2 added the Mac's workspace pin, color, order, bulk close, read
marks and Clear All Notifications to the phone. Color, the legacy pin flag,
read marks and closing use commands that were already allowed
(`set-workspace-metadata {color | pinned | marked_unread}`,
`ack-tab-notifications`, `close-workspace`, `move-workspace`). Four entries are
new, in both `policy.rs` and `DaemonLanePolicy.swift` (deny by default; the
mirror test checks the commands, the resource operations and their params):

| New entry | What the phone sends | Why |
| --- | --- | --- |
| `list-personal` (command, read) | `{"cmd":"list-personal"}` | The person's own sidebar order, so the phone lists workspaces in the Mac's order. |
| `set-personal-workspace` (command) | `{session_id, workspace_key, index}` only, and hostd forwards it only when the Mac's own `list-workspaces` (read on a separate connection) has that `registry_id` and that workspace `key` | Move Workspace Up / Down on a Mac with personal order (the Mac's `movePersonalWorkspace`). |
| `notification.clear` (resource op) | `params {machine: current, session: current}`, an idempotency key | Clear All Notifications (the Mac's `clearAllNotifications`). |
| `sidebar_layout.get` (resource op, read) | `params {machine: current, session: current}` | Which workspaces the person pinned (tiles in the Mac's pinned section). |
| `sidebar_layout.update` (resource op) | `params.op = {"kind":"item.remove","id":"itm_<16 base32>"}`, an idempotency key, and hostd forwards it only when a fresh `sidebar_layout.get` it reads itself has that item in `sec_pinned` with a `workspace` ref | Unpin Workspace: removes the pinned tile, as the Mac's `unpinOp`. |

A `cmux.protocol/2` line was refused outright before (no `cmd`). Now hostd
checks it member by member and sends on the object it checked, serialized
again (`Verdict::Rewrite`), so a duplicate key cannot mean one thing to the
filter and another to the daemon. Envelope members other than `protocol`,
`type`, `id`, `operation`, `params` and `idempotency_key` are refused, so a
phone never sends an `origin` claim or a launch `credential`. A refusal is a
v2 failure response (`origin.forbidden`, reason `phone_policy`).

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | No. None of the five carries a program, a path, a URL, an environment or text that is run. `set-personal-workspace` refuses every field but the three above (never `group`, `browser_profile_id`, `theme`, or `remote_localhost`, which would open the Mac's loopback to a remote workspace's browser). |
| Mutates or destroys objects the session does not own? | Only the person's own state, and only objects the Mac itself confirms (`services::owned_check`, on a separate daemon connection, before the line is sent; a Mac that cannot answer refuses): `set-personal-workspace` only for a live workspace of this session, so a phone cannot create personal rows for made-up sessions or keys; `item.remove` only of a pinned workspace tile, never a custom section's item or an app or link tile. Personal order and the sidebar layout are the signed-in person's own (`profiles-v1`, `sidebar-layout-v1`, home session). `notification.clear` takes no `terminal_id` and only `machine`/`session` = `current`, so it clears this session's ledger exactly as the Mac's Clear All Notifications does; it deletes no terminal, tab or file. `sidebar_layout.update` is limited to removing an item whose id the Mac app minted (`itm_` + 16 characters of `a-z2-7`), so the built-in items (`itm_home`, `itm_account`) and sections can never be removed, and no item, section or reset can be added. A removed pin is the same as Unpin on the Mac and can be pinned again. |
| Reads local state the remote should not see? | `list-personal` and `sidebar_layout.get` return the person's own sidebar organization (order, groups, pins, room names, per-workspace themes). The phone already reads every workspace, group and tab name through `list-workspaces` and `list-workspace-groups`; no secret, path outside the workspaces, or credential is in them. |
| Origin | The daemon gives the phone's lane origin `agent` (it cannot prove the install key). None of these operations is user-only (`USER_ONLY_OPERATIONS`), and a phone's line can carry no origin claim. |

- **Swift lane:** `DaemonLanePolicy` has no ownership check, so it refuses
  `set-personal-workspace` and `sidebar_layout.update` (its allowlist text
  still mirrors hostd's). Its `index` must be a non-negative integer, as
  Rust's `is_u64` (never 3.0, a Bool, or past `Int.max`).
- **Rule 6 (tests):** hostd `policy::tests::ownership_is_checked_against_the_macs_state`
  (another session's row, an unknown key, another section's item, a link
  tile, an unknown item refused), `duplicate_keys_are_sent_as_checked`,
  `allows_the_workspace_resource_ops`,
  `refuses_other_resource_ops_and_params` (other operations, another
  machine or session, `terminal_id`, no idempotency key, a reset, a built-in
  item, an extra op member, an add, an origin claim, a credential,
  protocol/1), `personal_order_is_a_place_only` (allowed with an owned
  workspace; `remote_localhost`, `group`, `theme`, browser profile, a
  negative index, a missing session refused), `mirrors_the_swift_allowlist`;
  Swift `DaemonLanePolicyResourceTests` (`ownershipLinesAreRefusedOnThisLane`,
  `duplicateKeysAreSentAsChecked`, `indexIsAnIntegerPlace`).
- **Pin from the phone** sends the legacy flag (`set-workspace-metadata
  {pinned: true}`), already allowed. A Mac whose sidebar has pinned tiles
  turns a flagged workspace into its tile and clears the flag
  (`SidebarLayoutService.migrateLegacyPins`), so the phone never adds layout
  items itself.

## Workspace groups (`feat-cnx-ios-parity3`)

Parity round 3 shows the Mac's workspace groups in the phone's Workspaces list
and adds the Mac's group actions that fit a phone. On a Mac with personal order
the Mac's sidebar keeps groups as the person's own rows in the home session and
changes them with `cmux.protocol/2` state operations
(`StateResourceClient+Groups.swift`); the phone sends the same ones. The legacy
commands (`create-personal-group`, `set-personal-workspace {group}`) are not
used, and `set-personal-workspace` still refuses `group`. The shared-group
commands already on the list (`create-workspace-group` …
`move-workspace-to-group`) are for a Mac without personal order; the phone does
not send them. Four resource operations are new, in both `policy.rs` and
`DaemonLanePolicy.swift` (deny by default; the mirror test checks them and their
params):

| New entry | What the phone sends | Why |
| --- | --- | --- |
| `workspace_group.create` | `params {machine: current, session: current, name, color, room}`, an idempotency key. `name`: 1-256 characters, not blank, no control characters. `color`: one of the Mac's nine group colors. `room`: 1-64 of `[A-Za-z0-9_.:-]` | Move Workspace to New Group (the Mac's `workspace.moveToNewGroup`), in the room of the Mac window that shows the workspace. |
| `workspace_group.update` | `params {…, workspace_group, name?, color?, collapsed?}` (at least one), and hostd forwards it only when the Mac's own `list-personal` has that group and every row in it is a workspace of this session (`registry_id` from `list-workspaces`) | Rename Group…, Set Workspace Group Color…, Collapse / Expand Workspace Group. |
| `workspace_group.delete` | `params {…, workspace_group}`, same ownership check | Ungroup Workspaces and Delete Group (both keep the workspaces open; the Mac records the group in its closed history, so Reopen Closed brings it back). |
| `workspace.place` | `params {…, workspace: "ws_…", group: "<id>" or null}`, and hostd forwards it only when `list-workspaces` lists that `resource_id`, and, for a group, that group passes the same check | Move Workspace to Group… and Remove Workspace from Group (and the second step of Move Workspace to New Group). |

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | No. None of the four carries a program, a path, a URL, an environment or text that is run. Only the params above pass; `command`, `argv`, `cwd`, `env`, `index`, `icon`, `pinned`, `top_index` and anything else are refused. A group name is stored and drawn as text in the Mac's sidebar (the same field the Mac's own rename writes). |
| Mutates or destroys objects the session does not own? | Only the person's own sidebar organization, and only objects the Mac itself confirms (`services::owned_check`, on a separate daemon connection, before the line is sent; a Mac that cannot answer refuses). `workspace.place` resolves `workspace` in this session's own state (`machine`/`session` must be `current`), and hostd also requires that `list-workspaces` lists it. Update, delete and place-into-a-group take only a group whose rows are all this session's workspaces (or an empty one), so a phone never renames, recolors, folds or deletes a group that holds another machine's workspaces, and never moves a workspace into one (the Mac's own rule: a group holds one machine's workspaces, `SidebarEdits.canMove`). No workspace is closed: delete removes the group record and leaves its workspaces open and ungrouped. `update` never takes `room`, which would move the group and pin every member to another room. A new group can only go into one of the person's existing rooms (the daemon refuses an unknown room). |
| Reads local state the remote should not see? | Nothing new: the phone reads groups, rooms and room pins from `list-personal`, already allowed in round 2. The ownership checks read `list-personal` and `list-workspaces` on hostd's own connection; their replies never reach the phone. |
| Origin | The phone's lane has origin `agent`; none of the four is a user-only operation (`USER_ONLY_OPERATIONS`), and a phone's line carries no origin claim. |

- **Swift lane:** `DaemonLanePolicy` checks the same values (`groupRefusal`),
  sends `workspace_group.create` on as checked, and refuses update, delete and
  place (it has no ownership check), as it does Unpin.
- **Rule 6 (tests):** hostd `policy::tests::allows_the_workspace_group_ops`
  (the eight lines the phone sends), `refuses_other_workspace_group_shapes`
  (`workspace_group.list` / `.move`, room operations, `index`, `collapsed` on
  create, `room` / `top_index` / `pinned` / `icon` on update, `cwd`,
  `command`, `argv`, `env`, a blank, long or multi-line name, a hex or unknown
  color, a bad room or group id, a non-`ws_` workspace, a non-Bool
  `collapsed`, another machine or session, no idempotency key),
  `group_ownership_is_checked_against_the_macs_state` (a group with another
  machine's workspace, another machine's group, an unknown group, an unlisted
  workspace refused; an empty group of the person's allowed),
  `mirrors_the_swift_allowlist`; Swift `DaemonLanePolicyGroupTests`
  (`allowedShapesPass`, `otherShapesAreRefused`).
- **Not on the phone:** Move Workspace Group Up / Down (`workspace_group.move`
  with `top_index`), group icon and Pin/Unpin Group, New Workspace in Group,
  Close All Workspaces in Group, Group Selected Workspaces, and moving a group
  to another room or window. They stay refused until reviewed.


Round 3 review notes (accepted, said here):

- **An empty group** passes the ownership check whoever made it (no member to tell), and
  between the check and the forward the person's other Mac could move one of its workspaces
  into a group. Either way the effect is limited to the person's own sidebar grouping (a
  rename, a color, a delete that keeps every workspace open); no program, folder or content
  is reachable.
- **On the Swift lane** (a Mac without cmux-mobile-host's ownership reads) `workspace_group.create`
  passes and `workspace.place` is refused, so Move Workspace to New Group fails there; the
  phone then deletes the group it just made, so no empty group stays.
- Live (round 3, rig `cmux-mobile-p3-153f3482`): every group action read back from the Mac's
  `list-personal` (`verify/parity-mac.md`, `groups`).

## `acpmux`: messages larger than one link frame

The link splits a write above 256 KiB into several data frames. hostd now
joins the frames of one phone message until they parse as one JSON value
(`MessageAssembler`, at most 32 MiB) before it sends one WebSocket message,
so a prompt carrying an image reaches acpmux whole. A frame sequence that is
not JSON closes the channel with `bad_request`. This adds no new method and
does not change acpmux's own guard.

## `upload`: phone attachments into this Mac

`upload {name, size, cwd?}` writes the bytes that follow into one new file
and answers `{"path","size"}`. A refusal is answered with
`{"error","message"}` and the channel closes with that code. The phone uses
it for terminal attachments, where the real path is inserted into the
composer and Return is never pressed, and for agent chat files, which are
sent as an ACP `resource_link` to that path.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | No. It creates one regular file. Nothing is executed, opened or indexed. The file mode follows the umask, without the executable bit. |
| Mutates or destroys objects the session does not own? | It never overwrites. The bytes go to a hidden `.<uuid>.part` file created with `O_EXCL`. That file is hard-linked to `<name>`, or to `<name> 2`, `<name> 3` and so on when the name is taken, and only then removed. A short, long or oversized upload removes the part and leaves nothing. The name is reduced to its last path component. Separators, `:` and control characters are replaced, leading dots and spaces are trimmed, and the name is cut at 120 bytes (`safe_file_name`). The size is declared first and capped at `CMUX_MOBILE_UPLOAD_MAX_BYTES` (100 MiB by default). Receiving more than the declared size is refused. |
| Where can it write? | With `cwd`, the folder must exist and be either the folder of a tab the daemon lists right now (`list-workspaces`, canonicalized) or inside `CMUX_MOBILE_FILE_ROOTS`. The file goes to `<cwd>/.cmux/attachments/phone-<link session>/`, next to acpmux's own attachments, so the workspace's agent can read it without leaving its folder. hostd canonicalizes that folder again after creating it, so a `.cmux` or `attachments` symlink that points out of the workspace is refused. Without `cwd`, the file goes to `<CMUX_MOBILE_STATE_DIR>/uploads/<link session>/` (mode 0700). The phone never picks any other part of the path. |
| Reads local state the remote should not see? | No. The reply contains only the path of the file the phone just wrote. |

- **Rule 6 (tests):** `upload_names_are_safe`, `publish_never_replaces`, and
  the `upload` cases in `tests/host.rs`: a plain upload, a workspace folder, a
  folder that is no tab's and outside the roots (`forbidden`), and an
  oversized upload (`too_large`).
- **Open:** there is no total quota per phone, and old uploads are not
  cleaned up. Both are bounded only by the per-file cap and the person's
  disk.

## `auth`: pairing a phone with this Mac

When the app supervises hostd, every link starts with `auth`. A channel the
phone opens after `auth` waits for its outcome (at most the signature and
approval waits) and is refused with `unpaired` unless it pairs; a channel with
no `auth` before it (`echo` included) is refused at once. The design is in
`verify/phone-approvals.md`.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | No. Its arguments are two P-256 public keys, a display name and `pair` or `unpair`. It runs nothing and reads no file. |
| Mutates or destroys objects the session does not own? | It can only ask the person to approve this link's own device id (stamped by the backend, never taken from the arguments), or, with `unpair` and a signature by the approved identity key, ask the app to forget that same device. |
| Reads local state the remote should not see? | It answers only a fresh 32-byte challenge and the Mac's own device id. The paired list stays in the app (a 0600 file per signed-in user). |

- **Prompt limits.** A token holder can bring any number of fresh key pairs,
  so the deny list (keyed on the key) alone does not stop it re-asking. hostd
  runs one `auth` at a time per link (`busy`), lets at most 32 channels wait
  behind it (`busy`), and asks at most 3 new identity keys per device id and
  6 in all per 10 minutes. After the person refuses a key, that device id
  asks nothing for 10 minutes whatever key it brings (`rate_limited`). hostd
  asks nothing until the app sent its approved list, so an approved phone is
  never asked again after a hostd restart.
- **Prompt content.** `pair_request` carries `registered_at_ms` (PROTOCOL.md
  "Pairing"): when the backend first saw that device id. The phone sets the
  `name` it shows, so a spoofed "Aziz's iPhone" from a device registered
  minutes ago is visible as new.
- **Rule 6 (tests):** `pairing::tests` and the pairing cases in
  `tests/host.rs` (a token alone reaches no service, a forged signature asks
  nobody, approval opens the link, a new approval key asks again, unpair
  reaches the app, a refused key is closed `denied`, channels opened
  behind `auth` wait for it, one `auth` per link, a refusal silences new keys
  from that device id, and nothing is asked before the app's list arrives).

## Parity round 2: Codex, model proxies, Restart Shell, the Mac's last pick (`feat-cnx-ios-parity2`)

### `acpmux`: Codex from a phone, always asking

- **What changed.** acpmux bridges Codex through `codex app-server`
  (`codex_app_server.rs`) and already let an authenticated remote (Web)
  connection pick any bridge mode (`any_mode_for_web`, Lawrence 2026-10-13). A
  session such a connection *starts* now begins in the bridge's `ask` mode
  (`web_modes::BRIDGE_ASKING_MODES`; cmux-codex-acp c30e6489: approval policy
  `untrusted`, workspace-write sandbox), also as a new handoff target. The
  codex-acp adapter and opencode stay refused.
- **The phone's narrowing.** cmux-mobile-host's `acpmux` service refuses any
  `session/set_mode` or `session/set_config_option {configId: "mode"}` whose
  mode is not `default`, `plan` or `ask` (`acpmux_policy.rs`), answering the
  phone with a JSON-RPC error. So a phone keeps every agent it drives in a mode
  that asks; each tool approval reaches the person and an Allow needs the phone's
  Face ID signature. Tests: acpmux `a_remote_device_starts_the_codex_bridge_in_its_asking_mode`,
  hostd `acpmux_policy::tests`.
- **Rule 2.** No new method. It narrows what a phone could already send, and the
  start mode moves from one that does not ask to one that asks.

### `acpmux`: a remote chain reaches its own model proxy (and nothing else)

- The remote-chain Seatbelt profile opened the port of the `ANTHROPIC_BASE_URL`
  in the profile's env, but Claude Code applies its user settings `env` over its
  process env, so it used another endpoint (EPERM or a hang). Now the endpoint is
  the one Claude uses (profile or route, else the user settings env, else the
  login env); only its port opens (loopback only when the endpoint is loopback);
  the inline `--settings` pins it (no project file can move it); and a profile's
  own route skips the user settings source (`--setting-sources project,local`),
  whose env would replace the route's key. No new hole: one port, as before.
- `sr claude proxy` (`claude-sr`) would start a loopback listener, which the
  sandbox forbids; a remote chain runs Claude Code itself to the subrouter server
  (`SUBROUTER_URL` or sr's default server), with the same placeholder token the
  launcher fallback uses (the server ignores it). Refused when no server is set
  or the profile carries other `sr` options.
- Tests: `endpoint_tests` (order, pin, setting sources, one loopback port, sr)
  and, on macOS, `a_remote_chain_reaches_its_own_loopback_model_proxy_and_nothing_else`.

### `daemon`: Restart Shell Here (`restart-tab`)

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | It starts the dead terminal tab's own recorded launch again (the person's shell, or the program the Mac started there), on this Mac, under the same terminal id. The phone names only the tab (`surface`); `tab` (the alias), `command`, `argv`, `cwd`, `env` and every other field are refused (`creation_fields`). The daemon refuses a live tab (`tab-not-dead`) and a non-terminal (`tab-not-terminal`). |
| Mutates or destroys objects the session does not own? | Only the person's own tab, as the Mac's button does. |
| Reads local state the remote should not see? | No. |

- **Rule 4 (live verification), 2026-10-15.** Rig Mac `cmux-mobile-p2-1585ab34` (a real
  build of this branch on mini-cmux11s). The tab's terminal host was killed until
  the Mac stopped respawning it (the tab dead, `restart_exhausted`); the phone's
  Restart Shell Here sent `restart-tab {surface}`; the Mac listed the same tab live
  with a new shell, pid 55788, whose parent was the rig app's own
  `cmux-tui __terminal-host --owner com.cmuxterm.app.debug.cmuxMobile.p2.1585ab34`, i.e. it ran
  on the Mac under the person's daemon, and a command typed from the phone ran
  there (`verify/parity-mac.md` Round 2, `restart-shell.mp4`). The phone cannot pick
  what runs: only the tab's own recorded launch restarts.
- Tests: hostd `restart_shell_takes_only_the_tab`, Swift `DaemonLanePolicyRestartTests`.

### `acpmux`: the Mac's last New Tab pick (`_acpmux/new_chat_picks_set`)

- Set only by the person's app on its proven person connection (memory only),
  while iPhone connections are allowed for a signed-in account; shown in
  `_acpmux/harnesses` as `lastPicks`. Short identifiers and absolute folders only.
- Cleared (an empty set, sent once) when iPhone connections turn off, the account
  signs out, or nothing is picked.
- Rule 2: it runs nothing and changes no session; a phone reads agent and model
  ids and the folders the person picked them in on this Mac (up to 50, any folder
  a New Tab chat was started in, not only open workspace folders). Tests: acpmux `the_apps_last_new_chat_picks_reach_a_remote_device`,
  CmuxNext `NewChatPicksTests`.

## Parity round 3 (`feat-cnx-ios-parity3`)

### `daemon`: Reopen Saved Tab Group (`reopen-saved-tab-group`, `delete-saved-tab-group`)

Both commands were already on the allowlist with any params. They now take only
what the Mac's own palette rows send, in `policy.rs` (`creation_fields`,
`saved_group_refusal`) and `DaemonLanePolicy.swift` (`creationFields`,
`savedGroupRefusal`), kept identical:

- `reopen-saved-tab-group {saved, pane, transaction?}`
- `delete-saved-tab-group {saved}`

`saved` must be a short identifier (`[A-Za-z0-9._:-]`, at most 128 bytes; the
daemon mints `saved_<hex>`), `pane` a non-negative pane number or a short public
pane id, `transaction` 1-128 printable ASCII characters (the daemon's own rule).
Every other field is refused: `command`, `argv`, `cwd`, `env`, `members`,
`origin`, a terminal host and any field the daemon adds later.
`list-saved-tab-groups` takes nothing and is unchanged.

What the daemon does (cmux-tui `mux/tab_groups/reopen_saved.rs`,
`reopen_saved_tab_group_as`):

- It looks the record up by id in this daemon's own presentation state
  (`presentation_snapshot().saved_tab_groups`). The saved groups are personal
  state of this Mac's home session (`SavedTabGroupRecord`, one room each); a
  phone cannot name a record of another Mac or person, and an unknown id is
  `not found`. A group that is already open is returned unchanged (no spawn).
- A terminal member whose saved terminal still runs is reattached (a new view of
  the same terminal). Otherwise it calls `new_tab_as(actor, pane, cwd, None)`:
  the person's login shell, no command and no environment, in the folder the
  record holds, on this Mac's terminal host, as New Terminal does. The record
  holds only `terminal_id`, `cwd` and `title` for a terminal
  (`SavedTabMember::Terminal`); it has no command field, so nothing but a shell
  can start.
- A browser member reopens its saved page (`new_browser_tab_as` or the frontend
  browser record with its saved engine and profile).
- Records are written only from a live group by `save-tab-group`
  (`saved_record_for`: the members' presented folder and page). The phone can
  pin a group of its own tabs; the folder of a terminal it reopens is a folder that
  terminal was in, which the phone could already reach by typing `cd`.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | It starts the person's login shell (no command, no env) in each saved terminal's folder, and reopens saved pages, on this Mac. The phone names only the record and a pane. |
| Mutates or destroys objects the session does not own? | Only this daemon's saved records and panes, the person's own. Delete removes the record; an open group stays, unlinked, as on the Mac. |
| Reads local state the remote should not see? | `list-saved-tab-groups` returns the saved groups' names, colors, folders and page URLs: the same folders and pages the phone already reads for the open tabs (`list-workspaces`). |

- A browser member may be a page that is not http or https (a page the person had
  open on the Mac). The phone never sends such a URL itself (`new-browser-tab`
  stays http/https only); a reopen restores the page the person saved.
- Tests: hostd `saved_tab_groups_take_only_the_saved_id_and_a_pane`, Swift
  `DaemonLanePolicySavedGroupTests`; phone CmuxMobileLive `SavedTabGroupTests`, CmuxMobileWorkspaces
  `savedTabGroupsFromThePageMenu`.
- **Live check: passed (round 3, 2026-10-15, rig `cmux-mobile-p3-153f3482` on mini-cmux11s).** A
  saved red group of two terminals (one `cd`'d to `/tmp/p3saved-check`) was closed with
  `end_terminals` (old shells 25525, 25558). From the phone, page menu > Reopen Saved Tab
  Group… > P3SAVED: the Mac listed both tabs again in 0.2 s, each a NEW `/bin/zsh` (28056,
  28066) whose parent is the rig app's own `cmux-tui __terminal-host --owner
  com.cmuxterm.app.debug.cmuxMobile.p3.153f3482`, with working folders
  `~/cmux-next-ios-e2e/p3/proj` and `/private/tmp/p3saved-check` (the saved ones, `lsof`). Delete
  Saved Tab Group… removed the record in 0.2 s; the open group stayed. Refusal of
  `command`/`argv`/`cwd`/`env` on the line: the hostd and Swift policy tests above (the
  phone never builds such a line). Video `~/cmux-next-ios-e2e/p3-raw/reopen-saved-group.mp4`.

### `daemon`: Duplicate Workspace (no allowlist change)

The Mac duplicates a workspace in the app (`WorkspaceBlueprintBuilder`: `new-tab {cwd}`
per terminal). No daemon command does it, and `apply-layout` takes a `command` per pane,
so neither is on the lane. The phone composes the copy from lines that are already allowed:
`new-workspace {name}`, `new-tab {pane}` (hostd adds the pane's folder, as for New
Terminal), `new-browser-tab {url, pane}` (http/https only) and `send` of
`cd '<folder>' && clear` into each new shell. A folder that the line editor could act on
is never typed (`WorkspaceFolderPath.isTypable`). The phone can already type that same
line into any terminal, so this adds no reach. Tests: CmuxMobileLive `duplicatePlanFollowsTheTabs`,
CmuxMobileWorkspaces `duplicateWorkspace`.

### `acpmux`: opencode stays refused (round 3 re-check)

opencode v1.19.0 cannot be forced to ask from outside. Its own config sources (global, org,
managed, MDM, agent files) merge after anything a launcher sets, or are appended after it,
and rules match last-wins. Custom tools, plugins, MCP tools and command templates run
outside the edit/bash/webfetch asks (details and source paths in `verify/parity-mac.md`
round 3 and `web_modes::REFUSED_FAMILIES`). The remote row's reason now says this:
"opencode's own settings on this Mac can let it edit and run commands without asking".

## Test-only pairing seed (DEBUG builds)

A hidden rig app cannot press the person-only "Allow … to connect?" prompt.
For tagged test instances only, a DEBUG build reads `CMUX_NEXT_IPHONE_PAIRING_SEED`
once at launch: the path of a JSON file `{"devices": [{"id"?, "name"?,
"identityKey"?, "approvalKey"?}]}`. When a phone asks, the app reads that file;
an entry whose given fields all match the request (at least an `id` or a `name`)
pairs it without the prompt, exactly as Allow would (`IPhonePairingSeed`). A
Release build compiles none of it and ignores the variable, so it is no path
for anyone but a developer who launches their own DEBUG build with it. The e2e
rig sets it in the rig app's `LSEnvironment` (`e2e/mac.py`) and names its
simulator; it never clicks Allow and never writes `paired-devices.json`.

## Notification replies: the mailbox, sealed pushes and terminal input (`feat-cmux-next-ios-push-fallback`)

Held for #13742 (`verify/notifications-trust.md`). Wire format: PROTOCOL.md
"Sealed pushes and the reply mailbox".

| Threat | What stops it | What's left |
| --- | --- | --- |
| The Worker (or someone holding a stolen Stack token) forges a reply | the Mac opens only what is sealed to its box key and signed by a paired phone's identity key (Secure Enclave); the Worker-stamped sender must be that phone | none: a token alone signs nothing |
| A replayed, late or re-issued reply | one-time id and nonce, kept on disk with each id's outcome until expiry (an unreadable store applies nothing); `expiresAt` at most 600 s after `issuedAt` and 660 s after the Mac's clock; the phone's window is 540 s from when the person made it and a Retry keeps it; an Allow also spends acpmux's own decision nonce | none beyond the window |
| A reply applied twice (link and mailbox, or a lost ack) | the link's `reply_id` and the mailbox id share one spent store; a repeat answers the first outcome; a text prompt carries one `promptId` with `resend: true` on both paths, which acpmux runs once, also across a restart | none |
| A reply applied to something else | it names one session, permission, conversation or terminal notification, and hostd checks it is still pending; an Allow is bound by the acpmux approval signature to that prompt, option and daemon run; a Deny with no option takes only a reject | none |
| The Worker claims a reply was applied | every outcome is signed by the Mac identity key; the phone takes it only with a signature that checks against its pin, else says "Not confirmed" | none |
| A removed or refused phone | the Mac checks its current paired list and denied list on every reply | a removal not yet on the Mac (the Mac app was off) applies when it next starts |
| The Worker or APNs reads notification content | sealed pushes (ECIES to the phone's push key, signed by the Mac identity key); the generic banner names only the Mac; when every paired phone has a key the content never leaves in clear, also when one box failed | phones without a push key (older apps) get plain content; kinds, ids, sizes, timing and the target Mac stay visible |
| A forged push steers an answer (fake question, swapped labels, fake terminal Reply) | the phone acts on no unsealed push from a Mac that seals to it; a sealed push is opened again from its box before a button acts; answers are bound to the live option's label | before the first pairing with that Mac (trust on first use) |
| A genuine sealed push replayed under the service's own banner and category (no `mutable-content`, so the service extension never ran) | a sealed box acts only when the banner, subtitle, body and category shown are what the phone writes from that box (`PushTrustGate.Shown`); otherwise a tap only opens the app | none |
| A replayed old push | `postedAt` in the box; past 15 minutes its buttons stop acting | none |
| A changed box key in the shared keychain | the box key's signature is checked against the app's own pin before each reply is sealed | none |
| Lock-screen input into a terminal | the Reply action is `authenticationRequired` (device unlock) and offered only when the poster asked for replies; the long-press view has no terminal composer and the outbox refuses terminal text; the Mac requires `reply: true`, a row at most 15 minutes old, and that the posting process (pid and executable, recorded at post time) still holds the terminal; on a terminal where an agent runs, one write bound to that agent's session, made only while it waits at its prompt (`send-expect-agent-v1`), and no reply without it | a program's notification can invite a harmful reply: the person reads what they send |
| Queue flooding | 32 pending per Mac, 60 posts a minute per user, 10-minute expiry | a token holder can delay real replies for up to 10 minutes |
| A lost, unlocked phone | the same as the app itself; removing the phone from the Mac (or the account) ends its replies | none new |

Policy: the `daemon` lane adds `notification-reply` with only `notification`,
`text` and `reply_id` (`policy.rs` tests refuse every other field and
over-long text); hostd's mailbox applies a reply through the same policy as a
link request.

## Decisions for the person

- Agent chats from the phone in the person's workspaces: acpmux lets a phone
  start a session in the folder of a tab the Mac's daemon lists
  (`feat-cnx-ios-agentcwd`; the same folders as `file`'s tab-folder rule).
  Implemented on `feat-cnx-ios-parity` at the person's request for full Mac
  parity; confirm or revert in `verify/13742-recommendation.md`.

- Phone pairing and Face ID signed approvals (`verify/phone-approvals.md`),
  a trust-policy change recommended on issue #13742.
- Notification replies without the live link and terminal input from a
  notification (`verify/notifications-trust.md`), recommended on #13742; held
  until approved.
- None for the service: production builds use the production Worker
  (`https://mobile-api.cmux.dev`), and development builds use the dev Worker.
