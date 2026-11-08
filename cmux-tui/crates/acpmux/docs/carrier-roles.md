# Connections through the Cloud carrier: owner and teammate rules

Status: S2 of "Cloud carries acpmux". The carrier service and its bridge (S1) are the Cloud
backend lane's; this page is the contract between the bridge and acpmux. The Cloud backend
lane reviews the matrix below; the acpmux owner owns the code (`src/server/carrier.rs`).

## The path

A chat on a Cloud VM reaches acpmux through the carrier (CMXR v5, `Service::Acpmux`). On the
VM, the session host bridges each carrier stream of that service to acpmux's **carrier
socket**:

- Path: `ACPMUX_HOME/run/carrier.sock` (`~/.acpmux/run/carrier.sock` by default), mode 0600
  in a 0700 directory.
- Served only on a Cloud VM (the creation marker `/etc/cmux/vm-kind` exists, owner or team),
  or with `ACPMUX_CARRIER_SOCKET=1` (tests, a dev VM). The daemon's ready line and the
  normal socket are unchanged.
- Who connects: the VM's session host only. acpmux checks that the peer is the daemon's own
  user (the file mode, and the peer uid at accept).
- Protocol: a WebSocket over the unix socket. The upgrade request carries exactly one header,
  written by the session host from the carrier grant the platform signed:

  ```
  x-acpmux-carrier: {"vmk":"owner"|"team","sub":"<subject id>","team":"<team id>"|null,
                     "chats":["<session id>", ...]}
  ```

  `vmk` is `owner` when the VM is the person's own, `team` when the person is a teammate of
  the VM's team. `sub`, `team` and each chat are one line of printable ASCII without spaces,
  1 to 256 bytes. For `vmk: team`, `team` is required and `chats` is required: a list of 1 to
  64 exact session ids, the chats the grant gives the teammate. For `vmk: owner`, `chats` is
  ignored (absent or not, whatever it holds): the owner reaches every chat, as a peer daemon
  does. Any other field, a missing or repeated header, a value over 16 KiB, a teammate header
  with no, an empty or a malformed `chats`, or one that is not this JSON object is refused
  with HTTP 403 and a reason (`carrier.header_missing`, `carrier.header_repeated`,
  `carrier.header_malformed`) before any session or data. After the upgrade, frames are
  acpmux's JSON-RPC, as on the WebSocket listener.

The header is read on the carrier socket and nowhere else:

- The daemon's own unix socket speaks JSON-RPC lines. A first line that is an HTTP request
  (an upgrade, with or without the header) ends the connection with
  `carrier.wrong_socket`; nothing it sent reaches the server.
- The WebSocket listener refuses an upgrade that carries the header (403,
  `carrier.wrong_socket`), whatever token it presents.
- No request field names a carrier person. A teammate's author is stamped by acpmux from the
  header, replacing any the request named.

### Why same-user is enough

Any process of the VM's user already reaches acpmux's own unix socket, where it is served as
`Origin::Local` with every right. A header it writes on the carrier socket gives it less than
that (an owner is a peer, a teammate far less), so the carrier socket opens no new door on the
VM. The trust in `vmk` and `sub` is the carrier grant's: the platform signs it, the carrier
checks it, and the session host copies it. acpmux never holds a Cloud token and cannot see the
signed grant: it trusts the header because only the daemon's user can open the socket.

**Requirement on the session host (S1):** it MUST copy `vmk`, `sub`, `team` and `chats` from
the verified, signed carrier grant, and never from anything the client sends (a query, a
frame, a header of its own). A teammate's `chats` is exactly what the grant names.

## What a carrier connection never does

A carrier connection is never a local client, whatever its role: it never makes the VM spawn a
process or set a spawn environment, never reads or writes a path of its choice, never names
`mcpServers`, and never changes the policy or the rules beyond what the Peer origin may
(`src/server/remote_guard.rs`). These are the remote guard's rules, which both roles go
through.

## Owner

`vmk: owner` is served as `Origin::Peer` with the proof `ConnAuth::CarrierOwner`, which has
every rule of `ConnAuth::PeerToken`, the owner's own acpmux daemon on another machine
(`ConnAuth::peer_daemon`): the Mac's acpmux dials the VM through the carrier (S3) as it dials
a peer over ssh today. A test checks the remote guard answers both the same for every method
in `rpc::method`, with params that ask for a spawn, a path, an environment or a policy.

Refused to the owner as to any peer (examples, not the full list): `mcpServers` in any
request, `_acpmux/process/*`, `_acpmux/peer_add` and `_acpmux/peer_remove`,
`_acpmux/export` with a `dest`, `_acpmux/import` outside the bundle directory,
`_acpmux/web_modes`, `_acpmux/web_token_rotate`, `_acpmux/btw`, a session env, a session
route, a prompt's provenance, a cwd outside the web roots.

## Teammate

`vmk: team` is served as `Origin::Web` with the proof `ConnAuth::CarrierTeam`, so every Web
rule applies (asking modes only, the folder-trust gate holds its prompts, no Full access).
Before any of that, its request must be one of the teammate's verbs. The verbs are one list,
`cmux_agent_pane_policy::share_roles::TEAMMATE_VERBS`, which cmux-tui's agent-session proxy
also checks its teammates against. acpmux maps each verb to its own methods:

| Teammate verb | acpmux methods | Notes |
| --- | --- | --- |
| (handshake) | `initialize` | Always. |
| `agent-session-attach` | `_acpmux/attach` | Always hidden (`visible: false`): a teammate never changes the owner's unread or seen state. |
| `agent-session-observe` | `_acpmux/attach`, `_acpmux/info` | The same hidden attach, and the chat's detail. |
| `agent-session-events` | `_acpmux/events`, `_acpmux/attachment` | Page through the log, and the images its prompts sent. |
| `agent-session-prompt` | `session/prompt` | Carries the author acpmux stamps from the header (below); a prompt naming any other author has it replaced. |
| `agent-session-cancel` | `session/cancel` (request or notification) | The Web's cancel rules apply; it stops the owner's turn too (below). |
| `agent-session-detach` | `_acpmux/detach` | |

**Scope.** Every allowed method but `initialize` must name one chat by `sessionId`, and that id
must be in the grant's `chats`, exactly. A request that names no chat (`_acpmux/info` with no
session, which would describe the VM's chats), names it by `session`, `name` or `host`, names
an id outside `chats`, or names an id in `chats` that resolves here to another session (by
name, prefix or `HOST/NAME`: an id no session has) is refused with `carrier.team_refused`.
A chat's forks, side chats and subagent children are other chats: the teammate reaches one
only when the grant names it. The hidden attach subscribes the connection to that chat only,
so it hears that chat's `session/update` and records and nothing of any other chat on the VM.
There is no listing: `session/list`, `_acpmux/sessions` and `_acpmux/watch` are refused.

**Cancel.** A teammate's `session/cancel` stops the running turn of a chat it was given,
including a turn the owner started. That is the teammate verb `agent-session-cancel` as
cmux-tui's proxy has it; whether a teammate should be able to stop the owner's turn is a
product call, and narrowing it is a change to the shared verb list.

Every other method is refused with code -32003 and `data.reason: "carrier.team_refused"`,
including every method added later. That covers, among others: `session/new`,
`session/fork`, `session/load`, `session/resume`, `session/list`, `_acpmux/sessions`,
`_acpmux/watch`, every permission answer (`_acpmux/permission_respond`,
`_acpmux/permission_group_respond`), every policy, mode, model, rule and tool change, kills,
renames, queue edits, typing and view, mail, processes, uploads and media, peers and pairing.
A teammate's notifications other than a `session/cancel` of a chat it was given are dropped,
and so are its answers to requests the daemon sends a client.

A teammate's `session/new` is refused whatever it carries (`mcpServers`, a `cwd`, a policy):
it never starts a session on the VM. The test `the_owner_and_team_matrix_covers_every_method`
(`src/server/carrier_tests.rs`) reads every method from `rpc.rs` and checks each against this
table; `every_teammate_verb_has_a_row_and_every_row_is_a_teammate_verb` fails when a verb is
added to the shared list without a row here.

### Open for review

- `sub` becomes the author id `user_<sub>` (kept as is when it already starts with `user_`) and
  the display name, since the header carries no name. A `name` field in the header would let
  the transcript show the person's name.

## Audit

- Each carrier connection, prompt, cancel, permission answer and refusal is logged at info
  with target `acpmux::carrier_audit`: the connection, the method, `vmk`, `sub`, `team`, the
  session, prompt, permission and option ids it names, and for a refusal its reason
  (`carrier.team_refused`).
- A carrier prompt that carries a provenance records `transport: "carrier"`
  (`prompt_provenance::TRANSPORT`).
- A teammate's prompt is recorded as a person's prompt from `user_<sub>`
  (`_meta.provenance.kind: "person_message"`, `author.rs`), in the chat's log.
- `initialize` answers `_meta.acpmux.auth` as `carrierOwner` or `carrierTeam`.

## The resume cursor

One cursor: a chat resumes from **acpmux's per-session `seq`** (`afterSeq` on `_acpmux/attach`
and `_acpmux/events`), on every route. The carrier's lanes (interactive, control, bulk,
tunnel) and their replay positions are transport only: they schedule and replay frames within
one dial, are never persisted and are never a cursor a client sees or sends. After any break
(a relay drop, a switch to the ssh route, a new dial), the client attaches again with
`afterSeq` = the last `seq` it holds and drops duplicates by `seq`. See "Persistence and
portability" in the README.
