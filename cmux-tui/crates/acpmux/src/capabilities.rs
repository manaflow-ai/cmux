//! The protocol surfaces this acpmux build serves, by stable id, as
//! cmux-tui's `identify` lists its capabilities. The web agent pane updates
//! apart from the app (web OTA), so a newer pane checks these before it
//! relies on a surface instead of reading the daemon's version.
//!
//! [`CAPABILITIES`] declares the wire names across builds. `initialize` sends the ids for its
//! transport in `_meta.acpmux.capabilities`. `_acpmux/status` and `acpmux capabilities [--json]`
//! report the build's ids, which the app records in `Contents/Resources/bin/daemon-capabilities.json`
//! (scripts/cmux-next/write-daemon-capabilities.sh).
//!
//! An id names a wire contract. Never rename one or drop it while the daemon
//! still serves its surface; a changed contract gets a new id (`-v2`). A new
//! surface the pane depends on gets its own id here in the change that adds it.

use crate::rpc::method;

/// One capability: its id and the wire names (methods and notifications) the
/// web pane uses under it. Every name is in the protocol registry
/// (`protocol::registry`); the tests check that.
/// Session-to-session message events; a daemon with it names, in each prompt acceptance, the
/// message its journal kept (`hub/message_events.rs` `name_message`).
pub const SESSION_MESSAGES: &str = "session-messages-v1";
/// Cloud trigger chat: a short-lived trigger principal may bootstrap one scoped chat and
/// submit idempotent ensure/send/status operations over fd0.
pub const TRIGGER_CHAT: &str = "trigger-chat-v1";
/// `_acpmux/attach` with `settled: true` answers the chat's settled view first, then the records
/// logged since (`hub/settled_view.rs`, `server/requests/settled_attach.rs`, cmuxterm-hq#9655).
pub const SETTLED_ATTACH: &str = "settled-attach-v1";
/// `_acpmux/attach {hold:true}` keeps a chat attached while reading no log records.
pub const HOLD_ATTACH: &str = "attach-hold-v1";

/// `_acpmux/paused_files`: a paused machine's file tree and search answered from its replica and
/// write journal with no wake (`server/paused_files.rs`, RFD 0144). The same id as the cmux
/// protocol's `RemoteCapability::PausedReadsV1`.
pub const PAUSED_READS: &str = "paused-reads-v1";

/// `_acpmux/presence` and `_acpmux/typing` (`hub/presence.rs`).
pub const CHAT_PRESENCE: &str = "chat-presence-v1";

/// `_acpmux/connections.changed`, pushed to a local watcher when a model connection changes
/// (`server/connections.rs`).
pub const CONNECTIONS_EVENTS: &str = "connections-events-v1";
/// The machine's fill on an attached chat (`_acpmux/fill`, `server/fill.rs`): only to a client
/// that listed it, so nothing changes for any other.
pub const AUTOCLOUD_FILL: &str = "autocloud-fill-v1";

/// `_acpmux/info` with `sessionIds` answers the list's rows by key, and `_acpmux/status` says
/// `closedListed` (`server/requests/info.rs` `rows`).
pub const INFO_ROWS: &str = "info-rows-v1";

/// The hub carrier can list and probe machine routes.
pub const MACHINE_ROUTES: &str = "machine-routes-v1";
/// A fresh local stream accepts a remote pipe request on its first line.
pub const REMOTE_PIPE: &str = "remote-pipe-v1";

/// A client that sends `initialize` with `_meta.acpmux.peerRowBatches: true` hears a burst of one
/// peer's rows (more than 32, a peer's list) as one `_acpmux/peer_rows_changed`, and follows the
/// list for them (`hub/list_guard.rs` `send_remote_batch`). Every other client hears each row's
/// `_acpmux/session_changed`, as before.
pub const PEER_ROW_BATCHES: &str = "peer-row-batches-v1";

/// A client that sends `initialize` with `_meta.acpmux.chunkDeltas: true` hears a text chunk on
/// its event stream as `_acpmux/chunk`, a delta of the chat's last chunk event, which carries
/// `chunkRef` (`server/chunk_deltas.rs`). Every other client hears each chunk's `_acpmux/event`,
/// as before.
pub const CHUNK_DELTAS: &str = "chunk-deltas-v1";

/// Session summaries carry `hasDraft` and `workingBelow` (absent means false only with this id).
pub const SESSION_IDLE_FACTS: &str = "session-idle-facts-v1";

/// `_acpmux/process/census` answers the census `acpmux ps --json` prints (`server/processes.rs`).
pub const PROCESS_CENSUS: &str = "process-census-v1";

/// Pre-copy for a chat move (`hub/transfer_precopy.rs`).
pub const TRANSFER_PRECOPY: &str = "transfer-precopy-v1";

/// Live migration of a chat move (`hub/transfer_live.rs`): compressed pages, resumable stages,
/// the source's digest of a prefix, and the client's progress reports.
pub const TRANSFER_LIVE: &str = "transfer-live-v1";

/// A chat move whose history follows the chat as a session pack (`hub/transfer_history.rs`).
pub const TRANSFER_HISTORY_LATER: &str = "transfer-history-later-v1";

/// A move's receive here takes `composers.json`, each surface's unsent text and the queue's
/// labels (`hub/composers.rs`), a guarded one too (`hub/transfer_guard.rs` `bundle_path_kind`).
pub const TRANSFER_COMPOSERS: &str = "transfer-composers-v1";

/// A move's receive here takes `attachments/<sha256>`, the images the chat's prompts sent
/// (`hub/prompt_images.rs`), a guarded one too.
pub const TRANSFER_IMAGES: &str = "transfer-images-v1";

/// The bundle files a chat runs without: each a capability and the first path component of the
/// files it covers. A source makes them whatever its target is (it cannot know); the move's
/// client, which reads the target's capabilities, leaves out each one the target does not list
/// ([`leave_out_untaken`]). A guarded receive from before the file refuses the whole move for it
/// (2026-11-24, a Move to Cloud onto an older machine image: `transfer.path: "composers.json" is
/// not a file a guarded move takes`). A new optional bundle file gets its row here and its id in
/// [`CAPABILITIES`] in the change that adds it; every other file stays required.
pub const OPTIONAL_BUNDLE_FILES: &[(&str, &str)] =
    &[(TRANSFER_COMPOSERS, "composers.json"), (TRANSFER_IMAGES, "attachments")];

/// The capability a target lists when it takes the bundle file `path`, for an optional one
/// ([`OPTIONAL_BUNDLE_FILES`]); `None` for a file every move carries.
pub fn optional_bundle_file(path: &str) -> Option<&'static str> {
    let first = path.split('/').next().unwrap_or(path);
    OPTIONAL_BUNDLE_FILES.iter().find(|(_, f)| *f == first).map(|(capability, _)| *capability)
}

/// Removes from a move's `manifest.files` each optional bundle file whose capability `lists`
/// says the target does not list, so that a target older than the file takes the chat without
/// it; answers the paths it removed. Only the client that hands the manifest to the target calls
/// it, with that target's own capabilities; then it pages only the files still listed.
pub fn leave_out_untaken(
    manifest: &mut serde_json::Value,
    lists: impl Fn(&str) -> bool,
) -> Vec<String> {
    let Some(files) = manifest.get_mut("files").and_then(serde_json::Value::as_array_mut) else {
        return Vec::new();
    };
    let mut left = Vec::new();
    files.retain(|f| {
        let path = f.get("path").and_then(serde_json::Value::as_str).unwrap_or("");
        let keep = optional_bundle_file(path).is_none_or(&lists);
        if !keep {
            left.push(path.to_owned());
        }
        keep
    });
    left
}

/// The one line a move says when it left optional files out ([`leave_out_untaken`]).
pub fn left_out_line(left: &[String]) -> Option<String> {
    if left.is_empty() {
        return None;
    }
    let what: Vec<&str> = OPTIONAL_BUNDLE_FILES
        .iter()
        .filter(|(c, _)| left.iter().any(|p| optional_bundle_file(p) == Some(*c)))
        .map(|(c, _)| match *c {
            TRANSFER_COMPOSERS => "unsent composer text",
            TRANSFER_IMAGES => "prompt images",
            other => other,
        })
        .collect();
    Some(format!(
        "the target's acpmux is older and does not take {} ({} file(s)); the chat moves without it",
        what.join(" or "),
        left.len()
    ))
}

pub struct Capability {
    pub id: &'static str,
    pub wire: &'static [&'static str],
}

pub const CAPABILITIES: &[Capability] = &[
    // The base the pane needs to show and drive a chat: ACP sessions, the
    // session list and its events, attach and view, harnesses and models,
    // drafts, bookmarks, prompts, permissions and the other per-chat actions.
    Capability {
        id: "acpmux-v1",
        wire: &[
            method::INITIALIZE,
            method::SESSION_NEW,
            method::SESSION_PROMPT,
            method::SESSION_CANCEL,
            method::SESSION_SET_MODE,
            method::SESSION_SET_MODEL,
            method::SESSION_SET_CONFIG_OPTION,
            method::SESSION_UPDATE,
            method::MUX_STATUS,
            method::MUX_INFO,
            method::MUX_SESSIONS,
            method::MUX_ATTACH,
            method::MUX_DETACH,
            method::MUX_VIEW,
            method::MUX_WATCH,
            method::MUX_EVENTS,
            method::MUX_EVENT,
            "_acpmux/lagged",
            method::MUX_SESSION_CHANGED,
            method::MUX_PROMPT_ACCEPTED,
            method::MUX_HARNESSES,
            method::MUX_HARNESSES_CHANGED,
            method::MUX_HARNESS_ENABLE,
            "_acpmux/models",
            method::MUX_ROUTE_LIST,
            method::MUX_KILL,
            method::MUX_ARCHIVE,
            method::MUX_SIDE,
            method::MUX_MARK_UNREAD,
            method::MUX_ATTACHMENT,
            method::MUX_DRAFT_GET,
            method::MUX_DRAFT_SET,
            method::MUX_BOOKMARK_GET,
            method::MUX_BOOKMARK_SET,
            method::MUX_ASK,
            method::MUX_WARM,
            method::MUX_PREWARM,
            method::MUX_PERMISSION_RESPOND,
            method::MUX_PERMISSION_PENDING,
            method::MUX_SECRET_SUBMIT,
        ],
    },
    // Server-side local/non-closed session-list filters used by native quit
    // census callers. Older daemons keep serving the unfiltered list.
    Capability { id: "session-list-filters-v1", wire: &[method::MUX_SESSIONS] },
    // One seen cursor per chat per person (`hub/seen.rs` `read_through`): `_acpmux/seen` moves it,
    // `_acpmux/attach` answers it as `readThrough`. The pane's Jump up goes only to rows after it.
    Capability { id: "read-through-v1", wire: &[method::MUX_SEEN] },
    // The MCP connect card (plans/cmux-next/mcp-connect-DESIGN.md): an agent asks, only the
    // person answers. Older daemons answer neither method.
    Capability {
        id: "mcp-connect-v1",
        wire: &[method::MUX_MCP_CONNECT_REQUEST, method::MUX_MCP_CONNECT_ANSWER],
    },
    // `_acpmux/sessions {pendingOnly: true}`: only the chats with a pending ask, without the
    // list's pace (the app's dialog list). Older daemons would answer the whole list.
    Capability { id: "session-list-pending-v1", wire: &[method::MUX_SESSIONS] },
    // `_acpmux/sessions {topLevelOnly: true}`: no side chat and no session another chat's agent
    // started, filtered before the page is cut (the phone's chat lists). Older daemons ignore it
    // and list every chat.
    Capability { id: "session-list-top-level-v1", wire: &[method::MUX_SESSIONS] },
    // `_acpmux/usage`: every listed chat's `usageStats` and nothing else, `unchanged` while the
    // digest the client holds is current (Session Info's Usage). Older daemons: the client reads
    // the list's pages with `usage: true`.
    Capability { id: "session-usage-v1", wire: &[method::MUX_USAGE] },
    // Each local session summary says `hasDraft` and `workingBelow`, omitted when false
    // (`protocol/session.rs`, `Hub::holds_work_below_read`). Only from a daemon that lists this
    // id does a missing field mean false; the app's Update When Idle holds on any other (absent
    // is unknown).
    Capability { id: SESSION_IDLE_FACTS, wire: &[method::MUX_SESSIONS] },
    // `_acpmux/info {sessionIds, row: true}`: the session list's rows of up to 100 chats by key,
    // the bytes `_acpmux/sessions` lists, and `_acpmux/status`'s `closedListed`. A list caller
    // that reads the v2 list's keys asks for the rows it prints (agent service v2, row 7b); a
    // daemon without this id gets its v1 list read.
    Capability { id: INFO_ROWS, wire: &[method::MUX_INFO, method::MUX_STATUS] },
    // `_acpmux/markRead`: mark a chat read without showing it (cmux's `chat.mark_read`).
    Capability { id: "mark-read-v1", wire: &[method::MUX_MARK_READ] },
    // `_acpmux/archive` and `_acpmux/rename` take an optional `opId` and run once per id
    // (`hub/op_once.rs`): a resend after a lost reply answers the first result. An older
    // daemon ignores `opId` and runs each resend, as before.
    Capability {
        id: crate::hub::op_once::CAPABILITY,
        wire: &[method::MUX_ARCHIVE, method::MUX_RENAME],
    },
    // The session list as a row log (`hub/row_log.rs`): `session_changed` and a watch's list
    // carry `listSeq`/`listEpoch`, and `_acpmux/watch {afterSeq, listEpoch}` answers the rows
    // changed since, not the list. Older daemons ignore `afterSeq` and send the list.
    Capability {
        id: crate::hub::row_log::CAPABILITY,
        wire: &[method::MUX_WATCH, method::MUX_SESSION_CHANGED],
    },
    // `session/new` with `_meta.acpmux.placeRedirect: 1`: a create this lane host has no room
    // for starts on the peer the placement engine picks, answered with that peer's session and
    // `_meta.acpmux.placedOn` (`hub/admission_redirect.rs`). Older daemons ignore the opt-in and
    // start it here, warned; a client that sends none gets that from this one too.
    Capability { id: crate::hub::admission_redirect::CAPABILITY, wire: &[method::SESSION_NEW] },
    Capability {
        id: PEER_ROW_BATCHES,
        wire: &[method::INITIALIZE, method::MUX_WATCH, method::MUX_PEER_ROWS_CHANGED],
    },
    Capability {
        id: CHUNK_DELTAS,
        wire: &[method::INITIALIZE, method::MUX_ATTACH, method::MUX_EVENT, method::MUX_CHUNK],
    },
    // A client that sends `initialize` with `_meta.acpmux.sessionChangedDelta: true` hears each
    // chat's row change after the first as `_acpmux/session_patch`, only what changed
    // (`server/session_patch.rs`); every other client hears the whole row in `session_changed`.
    Capability {
        id: crate::server::session_patch::CAPABILITY,
        wire: &[method::INITIALIZE, method::MUX_SESSION_CHANGED, method::MUX_SESSION_PATCH],
    },
    // `sessionChangedDelta: 2`: patches to a masked connection (a peer's link) too, and
    // `_acpmux/session_resync` for a client that missed a row.
    Capability {
        id: crate::server::session_patch::CAPABILITY_V2,
        wire: &[method::INITIALIZE, method::MUX_SESSION_PATCH, method::MUX_SESSION_RESYNC],
    },
    Capability {
        id: MACHINE_ROUTES,
        wire: &[method::MUX_MACHINE_ROUTES, method::MUX_MACHINE_ROUTE_PROBE],
    },
    Capability { id: REMOTE_PIPE, wire: &[method::MUX_REMOTE_PIPE] },
    Capability { id: "machine.join.stdin.v1", wire: &[] },
    // `acpmux machine vault pull|status|forget` (crate::vault): the CLI, which
    // asks the daemon to pull or forget when the values live only in its memory.
    Capability {
        id: crate::vault::CAPABILITY,
        wire: &[method::MUX_VAULT_PULL, method::MUX_VAULT_FORGET, method::MUX_VAULT_STATUS],
    },
    // Proxy-delivered vault entries reach agents as `cmux-secret://NAME`,
    // filled in by the daemon's egress proxy for their allowed hosts only;
    // `machine vault status` names each entry's delivery and hosts.
    Capability { id: crate::vault::EGRESS_CAPABILITY, wire: &[method::MUX_VAULT_STATUS] },
    Capability {
        id: "machine-consent-v1",
        wire: &[method::MUX_MACHINE_CONSENT_SET, method::MUX_MACHINE_CONSENT_GET],
    },
    // Signing in enrolls this machine on the hub; signing out leaves only that join
    // (`server/machine_enroll.rs`). A literal id, which the app's reference check reads.
    Capability {
        id: "machine-enroll-v1",
        wire: &[method::MUX_MACHINE_ENROLL, method::MUX_MACHINE_LEAVE_IF_AUTO],
    },
    // Door A: a machine this computer reaches by ssh joins through the hub in one call, and the
    // ones it reaches but has not added are listed (`server/machine_join_ssh.rs`).
    Capability {
        id: crate::cli::ssh_join::CAPABILITY,
        wire: &[method::MUX_MACHINE_JOIN_SSH, method::MUX_MACHINE_CANDIDATES],
    },
    // The app reports only who is signed in; acpmux decides the enroll, its retry and the leave
    // (`server/sign_in_follow.rs`). A literal id, which the app's reference check reads.
    Capability { id: "machine-signed-in-v1", wire: &[method::MUX_MACHINE_SIGNED_IN] },
    Capability { id: SESSION_MESSAGES, wire: &[method::MUX_MESSAGE] },
    // Agent byte channels (`server/channels.rs`): a peer daemon opens one only on a peer that
    // lists this id, so an older peer is never sent a `connect` it would drop.
    Capability {
        id: crate::server::channels::CAPABILITY,
        wire: &[
            method::MUX_CHANNEL_LISTEN,
            method::MUX_CHANNEL_UNLISTEN,
            method::MUX_CHANNEL_OPEN,
            method::MUX_CHANNEL_SEND,
            method::MUX_CHANNEL_CLOSE,
            method::MUX_CHANNEL_CONNECT,
            method::MUX_CHANNEL_OPENED,
            method::MUX_CHANNEL_DATA,
            method::MUX_CHANNEL_CLOSED,
        ],
    },
    Capability { id: SETTLED_ATTACH, wire: &[method::MUX_ATTACH] },
    Capability { id: HOLD_ATTACH, wire: &[method::MUX_ATTACH] },
    Capability {
        id: TRIGGER_CHAT,
        wire: &[
            method::TRIGGER_CHAT_ENSURE,
            method::TRIGGER_CHAT_SEND,
            method::TRIGGER_CHAT_STATUS,
        ],
    },
    // Inline `/btw` answers: the pane may send `inline: true` and receive `{text}`;
    // older daemons treat that field as legacy side-session input, so this id gates the shape.
    Capability { id: "btw-inline-v1", wire: &[method::MUX_BTW] },
    // A guest from another harness: `_acpmux/btw` with `targetHarness` answers from that
    // harness, gated on its own folder trust. Older daemons ignore the field and ask the chat's own.
    Capability { id: "btw-guest-v1", wire: &[method::MUX_BTW] },
    // Owner-VM Codex app-server bridge: access-only external tokens are read
    // from the private broker file and never exposed through ACP frames.
    Capability {
        id: "codex-external-access-v1",
        wire: &[method::SESSION_NEW, method::SESSION_PROMPT],
    },
    // Metadata-only paths for a focused chat's config and state files. The
    // daemon serves this surface on its local Unix socket only.
    Capability { id: "session-files-v1", wire: &[method::MUX_SESSION_FILES] },
    // A paused machine's file tree and search with no wake; the reply says when it did not
    // answer (setting off, machine running, replica stale), and the client asks the machine.
    Capability { id: PAUSED_READS, wire: &[method::MUX_PAUSED_FILES] },
    // Who else works on these files, topic, branch or folder, here and on peers
    // (`hub/touched.rs`).
    Capability { id: "who-else-v1", wire: &[method::MUX_WHO_ELSE] },
    // One caller's same prompt to many sessions in a minute, noted per send
    // (`send_fanout.rs`).
    Capability { id: "send-fanout-v1", wire: &[method::MUX_SEND_FANOUT] },
    // What turns cost, indexed by day and session (`hub/ledger`).
    Capability { id: "cost-ledger-v1", wire: &[method::MUX_LEDGER] },
    // The team's agent spend from cmux-platform (`server/chats/team_audit.rs`).
    Capability { id: "team-audit-v1", wire: &[method::MUX_TEAM_AUDIT] },
    // Who has a shared chat open and who types in it (`hub/presence.rs`); the attach reply's
    // `presence` comes with it.
    Capability { id: CHAT_PRESENCE, wire: &[method::MUX_TYPING, method::MUX_PRESENCE] },
    // Who is on this machine now, people across devices and agents in a turn (`hub/here.rs`).
    Capability { id: "here-v1", wire: &[method::MUX_HERE_BEAT, method::MUX_HERE] },
    // Chat titles and read marks through the sync engine, pulled and pushed by version vector
    // (`hub/synced.rs`).
    Capability { id: "state-sync-v1", wire: &[method::MUX_SYNC_PULL, method::MUX_SYNC_PUSH] },
    // A chat pinned or unpinned, kept in its record and synced as `pin/<id>` (`hub/synced.rs`).
    Capability { id: "chat-pin-v1", wire: &[method::MUX_PIN] },
    // Edit or remove a queued prompt, and send a steer now (`hub/queue_edit.rs`).
    Capability { id: "queue-edit-v1", wire: &[method::MUX_QUEUE_EDIT, method::MUX_QUEUE_REMOVE] },
    // A person's prompt waits for the owner, who approves or declines it (`hub/queue_approve.rs`).
    Capability {
        id: "queue-approval-v1",
        wire: &[method::MUX_QUEUE_APPROVE, method::MUX_QUEUE_DECLINE],
    },
    // One queued prompt's whole text, read on demand (`hub/queue_text.rs`).
    Capability { id: "queue-text-v1", wire: &[method::MUX_QUEUE_TEXT] },
    // A chat's transcript as rows folded in the daemon, paged and patched (`rows/`, hq#9655).
    Capability {
        id: "transcript-rows-v1",
        wire: &[method::MUX_ROWS, method::MUX_ROWS_PATCH, method::MUX_ROWS_LAGGED],
    },
    // The owner reads a queued prompt whole, its blocks and revision (`hub/queue_approve.rs`).
    Capability { id: "queue-get-v1", wire: &[method::MUX_QUEUE_GET] },
    // One answer for a group of permission asks, and revoking a chat's grants.
    Capability {
        id: "permission-groups-v1",
        wire: &[
            method::MUX_PERMISSION_GROUPS,
            method::MUX_PERMISSION_GROUP_RESPOND,
            method::MUX_PERMISSION_CHAT_REVOKE,
        ],
    },
    // Continue a chat on another harness (`acpmux continue`, `cli/handoff.rs`).
    Capability {
        id: "session-handoff-v1",
        wire: &[
            method::MUX_HANDOFF_PREPARE,
            method::MUX_HANDOFF_GET,
            method::MUX_HANDOFF_DRAFT,
            method::MUX_HANDOFF_START,
            method::MUX_HANDOFF_DISCARD,
        ],
    },
    // A chat's background processes.
    Capability {
        id: "processes-v1",
        wire: &[
            method::MUX_PROCESS_LIST,
            method::MUX_PROCESS_TAIL,
            method::MUX_PROCESS_KILL,
            method::MUX_PROCESS_BACKGROUND,
            method::MUX_PROCESS_UPDATE,
        ],
    },
    // Every process and lock acpmux owns on this machine, with acpmux's own judgment of each
    // (`_acpmux/process/census`, what `acpmux ps --json` prints). Read-only; this machine's
    // clients only. Without it, a client asks `acpmux ps --json`, never guesses from argv.
    Capability { id: PROCESS_CENSUS, wire: &[method::MUX_PROCESS_CENSUS] },
    // Agent CLI health (`hub/health_view.rs`).
    Capability { id: "harness-health-v1", wire: &[method::MUX_HARNESS_HEALTH] },
    // The mode a new chat starts in, and its changes (`hub/start_mode.rs`).
    Capability {
        id: "start-mode-v1",
        wire: &[method::MUX_START_MODE, method::MUX_START_MODE_CHANGED],
    },
    // A model connection's change, pushed to a local watcher (`server/connections.rs`).
    Capability { id: CONNECTIONS_EVENTS, wire: &[method::MUX_CONNECTIONS_CHANGED] },
    // How full a Cloud seed's checkout is, pushed on an attached chat (`server/fill.rs`).
    Capability { id: AUTOCLOUD_FILL, wire: &[method::MUX_FILL] },
    // A peer link's state, pushed on each change (`protocol/peer_state.rs`).
    Capability { id: "peer-state-events-v1", wire: &[method::MUX_PEER_STATE_CHANGED] },
    // Folder trust (`trust.rs`).
    Capability { id: "folder-trust-v1", wire: &[method::ACP_TRUST_GET, method::ACP_TRUST_SET] },
    // Resume agent message pairs the runaway guard paused (`hub/agent_pairs.rs`).
    Capability { id: "agent-pairs-v1", wire: &[method::MUX_AGENT_PAIR_RESUME] },
    // The person takes a managed chat over and hands it back (`hub/agent_hold.rs`).
    Capability { id: "agent-hold-v1", wire: &[method::MUX_AGENT_HOLD] },
    // Retry a chat's failed last turn now: the Retry button (`hub/auto_resume/retry_turn.rs`).
    Capability { id: "turn-retry-v1", wire: &[method::MUX_RETRY] },
    // The sudo card (`hub/elevation.rs`): `elevation_request` / `elevation_decision` records, and
    // an approver-signed `secret_submit` that answers one. A phone asks for those kinds only
    // under this id, since an older peer refuses an attach with more than 8 kinds.
    Capability {
        id: "elevation-cards-v1",
        wire: &[method::MUX_ELEVATION_REQUEST, method::MUX_SECRET_SUBMIT],
    },
    // `_acpmux/retry` with `subagentId`: resume a failed subagent now
    // (`hub/subagent_retry_manual.rs`). A daemon without this id does not
    // retry a subagent, so the pane shows a subagent's Retry button only
    // under it.
    Capability { id: "subagent-retry-v1", wire: &[method::MUX_RETRY] },
    // A subagent's entry carries `retryInFlight` (`hub/subagent_retry.rs`): an attempt fired
    // and the subagent not running again yet, so the pane shows it retrying, not a Retry.
    Capability { id: "subagent-retry-v2", wire: &[method::MUX_RETRY, method::SESSION_UPDATE] },
    // `_acpmux/retry` with `subagentId` also resumes a stopped Claude subagent, or one lost with
    // its harness, from its transcript and brief; its entry carries `resumable`, `resumes` and
    // `resumedBy` (`hub/subagent_resume.rs`). The pane shows Resume only under it.
    Capability { id: "subagent-resume-v1", wire: &[method::MUX_RETRY, method::SESSION_UPDATE] },
    // `_acpmux/retry {sessionId}` on a sub-session whose last turn was stopped continues it in
    // the same chat (`hub/subsession_resume.rs`): its row offers Resume only under it.
    Capability { id: "subsession-resume-v1", wire: &[method::MUX_RETRY] },
    // Stop one of a chat's background subagents. acpmux takes the method for
    // every harness, but only the Claude stdio adapter acts on it
    // (`claude_stdio/outbound.rs`); others pass it on to the agent.
    Capability { id: "subagent-stop-v1", wire: &[method::MUX_SUBAGENT_STOP] },
    // A Claude workflow's progress names its phases and agents (`phases`,
    // `workflowAgents`, `subagents.rs`), not only how many returned. The id
    // speaks for this daemon's own chats; a peer's chat comes from the peer's
    // daemon, so a pane draws rows from the payload, never from the id.
    Capability { id: "workflow-agents-v1", wire: &[method::SESSION_UPDATE] },
    // Read one subagent's transcript, a page at a time: a Claude workflow
    // agent's or background agent's, from the files Claude Code writes
    // (`claude_stdio/agent_transcript.rs`).
    Capability { id: "subagent-transcript-v1", wire: &[method::MUX_SUBAGENT_TRANSCRIPT] },
    // Every running subagent of a chat and its latest ended ones, whatever a page of the chat
    // holds (`hub/subagent_list.rs`): the Background tasks panel's list.
    Capability { id: "subagent-list-v1", wire: &[method::MUX_SUBAGENT_LIST] },
    // A chat adopted or watched from Claude Code pages its older turns in from the transcript,
    // past the newest page its log was seeded with (`hub/native_history.rs`).
    Capability { id: "native-history-v1", wire: &[method::MUX_NATIVE_HISTORY] },
    Capability {
        id: "durable-watches-v1",
        wire: &[method::MUX_WATCH_ADD, method::MUX_WATCH_LS, method::MUX_WATCH_RM],
    },
    // Every Claude workflow of this daemon's chats, duplicates marked (`hub/workflow_index.rs`).
    Capability { id: "workflows-index-v1", wire: &[method::MUX_WORKFLOWS] },
    // `$/cancel_request` is honored (`request_cancel.rs`): the request is answered with -32800
    // (RequestCancelled) at once, its slot freed, and the cancel goes on to the agent or peer
    // it waited on; the late answer is dropped. A daemon without it accepts the notification
    // and does nothing, so a client waits for the answer or its own deadline there.
    Capability { id: "cancel-request-v1", wire: &[method::CANCEL_REQUEST] },
    // Answer an agent's offer to start a session (`offer_mcp.rs`).
    Capability { id: "session-offers-v1", wire: &[method::MUX_OFFER_RESPOND] },
    // Reconnect a Claude Code chat's MCP server (`hub/tools.rs`).
    Capability { id: "mcp-reconnect-v1", wire: &[method::MUX_MCP_RECONNECT] },
    // Team-scoped agent messaging over the mesh relay, on wherever a hub is
    // configured. The daemon keeps this capability visible even when it is off
    // so clients can explain why instead of treating it as an unknown method.
    Capability {
        id: "team-messaging-v1",
        wire: &[
            method::MUX_TEAM_SEND,
            method::MUX_TEAM_INBOX,
            method::MUX_TEAM_READ,
            method::MUX_TEAM_ACK,
        ],
    },
    // A listen on another member's agent address: open, list, close, and read what it receives
    // (`server/team.rs` `listen`), under the same team-messaging gate.
    Capability { id: "team-listen-v1", wire: &[method::MUX_TEAM_LISTEN] },
    // A chat's sign-in before a send, by session or target (`hub/session_auth.rs`).
    Capability { id: "session-auth-v1", wire: &[method::MUX_SESSION_AUTH] },
    // Owner-captured Cloud turns: prepare reserves a stable id before the native bridge mints
    // its one-use execution capability. The app exposes the rewind action only for configured
    // new Cloud workspace sessions; local and legacy sessions never send this envelope.
    Capability {
        id: "agent-session-turn-rewind-v1",
        wire: &[method::AGENT_SESSION_TURN_PREPARE, method::AGENT_SESSION_TURN_ABANDON],
    },
    // The person's saved prompts, with the read-only ones the settings file names (`prompts.rs`).
    Capability {
        id: "prompt-library-v1",
        wire: &[method::MUX_PROMPTS_LIST, method::MUX_PROMPTS_SAVE, method::MUX_PROMPTS_DELETE],
    },
    // The composer's stashed drafts, kept here so they outlive the pane's page (`stash.rs`).
    Capability {
        id: "draft-stash-v1",
        wire: &[
            method::MUX_STASH_LIST,
            method::MUX_STASH_PUSH,
            method::MUX_STASH_GET,
            method::MUX_STASH_DROP,
            method::MUX_STASH_MOVE,
        ],
    },
    // The person's Accept or Dismiss on what a chat learned (`server/memory_inbox.rs`).
    Capability { id: "memory-inbox-v1", wire: &[method::MUX_MEMORY_RESOLVE] },
    Capability {
        id: "agent-home-v1",
        wire: &[method::MUX_AGENT_HOME, method::MUX_AGENT_HOME_RESOLVE],
    },
    // The rewrite a chat that took several corrections offers (`server/prompt_coach.rs`).
    Capability { id: "prompt-coach-v1", wire: &[method::MUX_PROMPT_COACH] },
    // Pre-copy for a chat move (`hub/transfer_precopy.rs`): `transfer_prepare` exports the log
    // without a freeze, a target stages it (`transfer_stage`, `transfer_stage_finish`), and
    // `transfer_begin {prepareId, afterSeq}` freezes the chat for only what followed. A client
    // pre-copies only between two daemons that both list it; `transfer_base` names the copy a
    // target still holds from the chat's last move, for a prepare of only what came after.
    Capability {
        id: TRANSFER_PRECOPY,
        wire: &[
            "_acpmux/transfer_base",
            "_acpmux/transfer_prepare",
            "_acpmux/transfer_stage",
            "_acpmux/transfer_stage_finish",
            "_acpmux/transfer_begin",
            "_acpmux/transfer_receive",
        ],
    },
    // Live migration of a chat move (`hub/transfer_live.rs`): `transfer_write {encoding:
    // "zstd"}` takes a compressed page, `transfer_stage {resume: true}` takes up the chat's
    // unfinished stage and says what it holds, `transfer_digest` answers the source's digest of
    // the same bytes, `transfer_progress` is the client's report `session info` shows, and
    // `transfer_end_stale` ends a move whose client is gone now, as its watch would.
    Capability {
        id: TRANSFER_LIVE,
        wire: &[
            "_acpmux/transfer_digest",
            "_acpmux/transfer_end_stale",
            "_acpmux/transfer_progress",
            "_acpmux/transfer_stage",
            "_acpmux/transfer_write",
        ],
    },
    // A move whose history follows the chat (`hub/transfer_history.rs`): `transfer_prepare
    // {historyLater}` prepares only the chat's last turns, the chat runs on the target at once,
    // and its earlier history is exported as a session pack (`transfer_history_export`, less the
    // chunks the target says it has, `transfer_history_have`), staged, and taken into the live
    // chat (`transfer_history`). A client asks for it only between two daemons that both list it.
    Capability {
        id: TRANSFER_HISTORY_LATER,
        wire: &[
            "_acpmux/transfer_history",
            "_acpmux/transfer_history_export",
            "_acpmux/transfer_history_have",
            "_acpmux/transfer_prepare",
            "_acpmux/transfer_stage_finish",
        ],
    },
    // The optional bundle files a move's receive (and a guarded one's writes) take here
    // ([`OPTIONAL_BUNDLE_FILES`]); a client leaves out of a move each one its target does not list.
    Capability {
        id: TRANSFER_COMPOSERS,
        wire: &["_acpmux/transfer_receive", "_acpmux/transfer_write"],
    },
    Capability {
        id: TRANSFER_IMAGES,
        wire: &["_acpmux/transfer_receive", "_acpmux/transfer_write"],
    },
    // An agent CLI's own sign-in on this machine, for a chat's sign-in card (`agent_login.rs`).
    Capability {
        id: "agent-login-v1",
        wire: &[
            method::MUX_AGENT_LOGIN_START,
            method::MUX_AGENT_LOGIN_FINISH,
            method::MUX_AGENT_LOGIN_CANCEL,
            method::MUX_AGENT_LOGIN_API_KEY,
        ],
    },
    // A turn's before and after picture of the chat's page, for its edited-files card
    // (`hub/turn_shots.rs`).
    Capability { id: "turn-shots-v1", wire: &[method::MUX_TURN_SHOTS] },
    // A turn's frames of the chat's page as it formed, for the frames strip and the live preview
    // window (`hub/turn_frames.rs`, RFD 0151).
    Capability { id: "turn-frames-v1", wire: &[method::MUX_TURN_FRAMES] },
    // A wrap-up card's Try it on, Keep and Revert (`customize_run.rs`).
    Capability { id: "customize-run-v1", wire: &[method::MUX_CUSTOMIZE_RUN] },
    // `acp.session.fork` with `subagentId` (a subagent's own conversation as a chat of its own),
    // `mode`, and `model` without `harness` (`hub/fork_subagent.rs`).
    Capability { id: crate::hub::fork_subagent::CAPABILITY, wire: &[method::ACP_SESSION_FORK] },
];

/// The capabilities of this build, including the local stream listener.
pub fn ids() -> Vec<&'static str> {
    ids_for_connection(true)
}

/// `initialize` lists only the surfaces available over its transport. Debug builds only:
/// `ACPMUX_TEST_HIDE_CAPABILITIES=ID,ID` leaves those ids out, so a test daemon lists what a
/// daemon one version older lists (`tests/transfer_cli/session_move_history.rs`). Release builds
/// have no seam.
pub(crate) fn ids_for_connection(local_stream: bool) -> Vec<&'static str> {
    #[cfg(debug_assertions)]
    let hidden = std::env::var("ACPMUX_TEST_HIDE_CAPABILITIES").unwrap_or_default();
    #[cfg(not(debug_assertions))]
    let hidden = String::new();
    let hidden: Vec<&str> = hidden.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
    CAPABILITIES
        .iter()
        .filter(|capability| !hidden.contains(&capability.id))
        .filter(|capability| match capability.id {
            MACHINE_ROUTES => cfg!(feature = "hub-carrier"),
            REMOTE_PIPE => local_stream && cfg!(feature = "hub-carrier"),
            "agent-session-turn-rewind-v1" => {
                ["CMUX_PLATFORM_ORIGIN", "CMUX_PLATFORM_WORKSPACE_ID", "CMUX_PLATFORM_MACHINE_ID"]
                    .iter()
                    .all(|name| std::env::var(name).is_ok_and(|value| !value.is_empty()))
            }
            _ => true,
        })
        .map(|capability| capability.id)
        .collect()
}

/// `acpmux capabilities`: one id per line, or with `--json`
/// `{"capabilities": [...]}`.
pub fn render(json: bool) -> String {
    if json {
        format!("{}\n", serde_json::json!({ "capabilities": ids() }))
    } else {
        ids().iter().map(|id| format!("{id}\n")).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::Client;
    use crate::config::{Config, StoreMode};
    use serde_json::{Value, json};
    use std::collections::BTreeSet;

    #[test]
    fn every_id_is_stable_shaped_and_listed_once() {
        let mut seen = BTreeSet::new();
        for id in ids() {
            let (name, version) = id
                .rsplit_once("-v")
                .or_else(|| id.rsplit_once(".v"))
                .unwrap_or_else(|| panic!("{id} has no version suffix"));
            assert!(
                !name.is_empty()
                    && name.bytes().all(|b| b.is_ascii_lowercase()
                        || b.is_ascii_digit()
                        || b == b'-'
                        || b == b'.')
                    && !version.is_empty()
                    && version.bytes().all(|b| b.is_ascii_digit()),
                "{id} is not a lowercase-kebab id ending in -vN"
            );
            assert!(seen.insert(id), "{id} is listed twice");
        }
        assert_eq!(ids().first(), Some(&"acpmux-v1"), "the base comes first");
    }

    fn begin_manifest() -> Value {
        json!({"files": [
            {"path": "session.json", "size": 10},
            {"path": "events/000001.ndjson", "size": 20},
            {"path": "composers.json", "size": 2},
            {"path": format!("attachments/{}", "ab".repeat(32)), "size": 3},
            {"path": "native/claude-project/.claude/projects/p/s.jsonl", "size": 4},
        ]})
    }

    fn paths(manifest: &Value) -> Vec<&str> {
        manifest["files"].as_array().unwrap().iter().map(|f| f["path"].as_str().unwrap()).collect()
    }

    /// A target from before the optional files (it lists neither id) gets the chat without
    /// them, every required file still listed, and the move says so in one line.
    #[test]
    fn an_older_target_gets_the_move_without_its_optional_files() {
        let mut manifest = begin_manifest();
        let left = leave_out_untaken(&mut manifest, |_| false);
        assert_eq!(
            left,
            vec!["composers.json".to_owned(), format!("attachments/{}", "ab".repeat(32))]
        );
        assert_eq!(
            paths(&manifest),
            [
                "session.json",
                "events/000001.ndjson",
                "native/claude-project/.claude/projects/p/s.jsonl"
            ]
        );
        let line = left_out_line(&left).unwrap();
        assert!(line.contains("unsent composer text") && line.contains("prompt images"), "{line}");
    }

    /// A current target lists both ids (this build does): the move carries every file.
    #[test]
    fn a_current_target_gets_every_file() {
        let mut manifest = begin_manifest();
        let here = ids();
        let left = leave_out_untaken(&mut manifest, |c| here.contains(&c));
        assert!(left.is_empty());
        assert_eq!(left_out_line(&left), None);
        assert_eq!(paths(&manifest), paths(&begin_manifest()));
        for (capability, _) in OPTIONAL_BUNDLE_FILES {
            assert!(here.contains(capability), "{capability} is not listed");
        }
    }

    /// A target that lists only one id loses only the other's files.
    #[test]
    fn a_target_is_sent_each_optional_file_it_lists() {
        let mut manifest = begin_manifest();
        let left = leave_out_untaken(&mut manifest, |c| c == TRANSFER_COMPOSERS);
        assert_eq!(left.len(), 1);
        assert!(left[0].starts_with("attachments/"));
        assert!(paths(&manifest).contains(&"composers.json"));
    }

    /// Only the listed optional files are ever left out: an unknown file stays in the manifest,
    /// so a guarded target still refuses it (`hub/transfer_guard.rs`).
    #[test]
    fn an_unknown_file_is_never_left_out() {
        assert_eq!(optional_bundle_file("harness/owner.sqlite"), None);
        assert_eq!(optional_bundle_file("composers.json.bak"), None);
        assert_eq!(optional_bundle_file("x/composers.json"), None);
        let mut manifest = json!({"files": [{"path": "harness/owner.sqlite", "size": 1}]});
        assert!(leave_out_untaken(&mut manifest, |_| false).is_empty());
        assert_eq!(paths(&manifest), ["harness/owner.sqlite"]);
    }

    /// An id covers names the daemon has: a renamed or removed method breaks
    /// this test, not the pane that relied on the id.
    #[test]
    fn every_covered_name_is_in_the_protocol_registry() {
        let registry: BTreeSet<&str> =
            crate::protocol::registry().iter().map(|decl| decl.name).collect();
        for capability in CAPABILITIES {
            // Machine onboarding is CLI-only and has no daemon wire method.
            if capability.id == "machine.join.stdin.v1" {
                assert!(capability.wire.is_empty());
                continue;
            }
            assert!(!capability.wire.is_empty(), "{} covers nothing", capability.id);
            for name in capability.wire {
                assert!(
                    registry.contains(name),
                    "{} covers {name}, which acpmux does not serve",
                    capability.id
                );
            }
        }
    }

    #[test]
    fn base_info_and_carrier_methods_have_wire_declarations_in_every_build() {
        let wire = |id| CAPABILITIES.iter().find(|cap| cap.id == id).unwrap().wire;
        assert!(wire("acpmux-v1").contains(&method::MUX_INFO));
        assert!(wire(INFO_ROWS).contains(&method::MUX_INFO));
        assert_eq!(
            wire(MACHINE_ROUTES),
            &[method::MUX_MACHINE_ROUTES, method::MUX_MACHINE_ROUTE_PROBE]
        );
        assert_eq!(wire(REMOTE_PIPE), &[method::MUX_REMOTE_PIPE]);
    }

    fn memory_hub() -> std::sync::Arc<crate::hub::Hub> {
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        crate::hub::Hub::new(cfg, store)
    }

    #[tokio::test]
    async fn declared_agent_passthroughs_require_a_session() {
        let client = Client::in_process(memory_hub()).await.unwrap();
        for m in [method::MUX_SUBAGENT_STOP, method::MUX_STEER_WITHDRAW, method::MUX_STEP_NOW] {
            let error = client.request(m, json!({})).await.unwrap_err();
            let rpc = &error.downcast_ref::<crate::client::DaemonError>().unwrap().0;
            assert_eq!((rpc.code, rpc.message.as_str()), (-32602, "sessionId is required"), "{m}");
        }
        let unknown = client.request("_acpmux/unknown", json!({})).await.unwrap_err();
        assert_eq!(unknown.downcast_ref::<crate::client::DaemonError>().unwrap().0.code, -32601);
    }

    /// `initialize` and `_acpmux/status` carry the list, and `acpmux
    /// capabilities --json` prints the same one without a daemon.
    #[tokio::test]
    async fn initialize_status_and_the_cli_name_the_same_capabilities() {
        let hub = memory_hub();
        let dir = cmux_unix_socket::short_test_dir("acpmux-caps");
        let path = dir.path().join("d.sock");
        let listener = crate::server::bind_unix(&path).await.unwrap();
        let channel = Client::in_process(hub.clone()).await.unwrap();
        tokio::spawn(crate::server::serve_unix(hub, listener));
        let client = Client::connect(&path).await.unwrap();

        let carrier = cfg!(feature = "hub-carrier");
        assert_eq!(client.daemon_lists(MACHINE_ROUTES), carrier);
        assert_eq!(channel.daemon_lists(MACHINE_ROUTES), carrier);
        assert_eq!(client.daemon_lists(REMOTE_PIPE), carrier);
        assert!(!channel.daemon_lists(REMOTE_PIPE));

        let expected = json!(ids());
        let status = client.request(method::MUX_STATUS, json!({})).await.unwrap();
        assert_eq!(status["capabilities"], expected, "{status}");
        let hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "caps-test"}});
        let init = client.request(method::INITIALIZE, hello).await.unwrap();
        assert_eq!(init.pointer("/_meta/acpmux/capabilities"), Some(&expected), "{init}");
        assert!(
            client.daemon_lists(TRIGGER_CHAT),
            "trigger chat capability must gate its CLI helper"
        );

        let printed: Value = serde_json::from_str(&render(true)).unwrap();
        assert_eq!(printed, json!({"capabilities": expected}));
        assert_eq!(render(false), ids().iter().map(|id| format!("{id}\n")).collect::<String>());
    }
}
