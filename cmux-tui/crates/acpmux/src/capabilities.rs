//! The protocol surfaces this acpmux build serves, by stable id, as
//! cmux-tui's `identify` lists its capabilities. The web agent pane updates
//! apart from the app (web OTA), so a newer pane checks these before it
//! relies on a surface instead of reading the daemon's version.
//!
//! [`CAPABILITIES`] is the one source: `initialize` sends its ids in
//! `_meta.acpmux.capabilities`, `_acpmux/status` in `capabilities`, and
//! `acpmux capabilities [--json]` prints them with no daemon running, which
//! the app bundle records in `Contents/Resources/bin/daemon-capabilities.json`
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
    Capability { id: "machine.join.stdin.v1", wire: &[] },
    Capability {
        id: "machine-consent-v1",
        wire: &[method::MUX_MACHINE_CONSENT_SET, method::MUX_MACHINE_CONSENT_GET],
    },
    Capability { id: SESSION_MESSAGES, wire: &[method::MUX_MESSAGE] },
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
    // Owner-VM Codex app-server bridge: access-only external tokens are read
    // from the private broker file and never exposed through ACP frames.
    Capability {
        id: "codex-external-access-v1",
        wire: &[method::SESSION_NEW, method::SESSION_PROMPT],
    },
    // Metadata-only paths for a focused chat's config and state files. The
    // daemon serves this surface on its local Unix socket only.
    Capability { id: "session-files-v1", wire: &[method::MUX_SESSION_FILES] },
    // Who has a shared chat open and who types in it (`hub/presence.rs`); the attach reply's
    // `presence` comes with it.
    Capability { id: "chat-presence-v1", wire: &[method::MUX_TYPING, method::MUX_PRESENCE] },
    // Edit or remove a queued prompt, and send a steer now (`hub/queue_edit.rs`).
    Capability { id: "queue-edit-v1", wire: &[method::MUX_QUEUE_EDIT, method::MUX_QUEUE_REMOVE] },
    // A person's prompt waits for the owner, who approves or declines it (`hub/queue_approve.rs`).
    Capability {
        id: "queue-approval-v1",
        wire: &[method::MUX_QUEUE_APPROVE, method::MUX_QUEUE_DECLINE],
    },
    // One queued prompt's whole text, read on demand (`hub/queue_text.rs`).
    Capability { id: "queue-text-v1", wire: &[method::MUX_QUEUE_TEXT] },
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
    // Agent CLI health (`hub/health_view.rs`).
    Capability { id: "harness-health-v1", wire: &[method::MUX_HARNESS_HEALTH] },
    // The mode a new chat starts in, and its changes (`hub/start_mode.rs`).
    Capability {
        id: "start-mode-v1",
        wire: &[method::MUX_START_MODE, method::MUX_START_MODE_CHANGED],
    },
    // A peer link's state, pushed on each change (`protocol/peer_state.rs`).
    Capability { id: "peer-state-events-v1", wire: &[method::MUX_PEER_STATE_CHANGED] },
    // Folder trust (`trust.rs`).
    Capability { id: "folder-trust-v1", wire: &[method::ACP_TRUST_GET, method::ACP_TRUST_SET] },
    // Resume agent message pairs the runaway guard paused (`hub/agent_pairs.rs`).
    Capability { id: "agent-pairs-v1", wire: &[method::MUX_AGENT_PAIR_RESUME] },
    // Retry a chat's failed last turn now: the Retry button (`hub/auto_resume/retry_turn.rs`).
    Capability { id: "turn-retry-v1", wire: &[method::MUX_RETRY] },
    // `_acpmux/retry` with `subagentId`: resume a failed subagent now
    // (`hub/subagent_retry_manual.rs`). A daemon without this id does not
    // retry a subagent, so the pane shows a subagent's Retry button only
    // under it.
    Capability { id: "subagent-retry-v1", wire: &[method::MUX_RETRY] },
    // A subagent's entry carries `retryInFlight` (`hub/subagent_retry.rs`): an attempt fired
    // and the subagent not running again yet, so the pane shows it retrying, not a Retry.
    Capability { id: "subagent-retry-v2", wire: &[method::MUX_RETRY, method::SESSION_UPDATE] },
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
    // A chat adopted or watched from Claude Code pages its older turns in from the transcript,
    // past the newest page its log was seeded with (`hub/native_history.rs`).
    Capability { id: "native-history-v1", wire: &[method::MUX_NATIVE_HISTORY] },
    Capability {
        id: "durable-watches-v1",
        wire: &[method::MUX_WATCH_ADD, method::MUX_WATCH_LS, method::MUX_WATCH_RM],
    },
    // Every Claude workflow of this daemon's chats, duplicates marked (`hub/workflow_index.rs`).
    Capability { id: "workflows-index-v1", wire: &[method::MUX_WORKFLOWS] },
    // Answer an agent's offer to start a session (`offer_mcp.rs`).
    Capability { id: "session-offers-v1", wire: &[method::MUX_OFFER_RESPOND] },
    // Reconnect a Claude Code chat's MCP server (`hub/tools.rs`).
    Capability { id: "mcp-reconnect-v1", wire: &[method::MUX_MCP_RECONNECT] },
    // Labs team-scoped agent messaging over the mesh relay. The daemon keeps
    // this capability visible even when the flag is off so clients can explain
    // the opt-in instead of treating it as an unknown method.
    Capability {
        id: "team-messaging-v1",
        wire: &[
            method::MUX_TEAM_SEND,
            method::MUX_TEAM_INBOX,
            method::MUX_TEAM_READ,
            method::MUX_TEAM_ACK,
        ],
    },
    // A chat's sign-in before a send, by session or target (`hub/session_auth.rs`).
    Capability { id: "session-auth-v1", wire: &[method::MUX_SESSION_AUTH] },
    // Owner-captured Cloud turns: prepare reserves a stable id before the native bridge mints
    // its one-use execution capability. The app exposes the rewind action only for configured
    // new Cloud workspace sessions; local and legacy sessions never send this envelope.
    Capability {
        id: "agent-session-turn-rewind-v1",
        wire: &[method::AGENT_SESSION_TURN_PREPARE, method::AGENT_SESSION_TURN_ABANDON],
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
];

/// The ids of [`CAPABILITIES`], in its order.
pub fn ids() -> Vec<&'static str> {
    CAPABILITIES
        .iter()
        .filter(|capability| {
            capability.id != "agent-session-turn-rewind-v1"
                || [
                    "CMUX_PLATFORM_ORIGIN",
                    "CMUX_PLATFORM_WORKSPACE_ID",
                    "CMUX_PLATFORM_MACHINE_ID",
                ]
                .iter()
                .all(|name| std::env::var(name).is_ok_and(|value| !value.is_empty()))
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

    /// `initialize` and `_acpmux/status` carry the list, and `acpmux
    /// capabilities --json` prints the same one without a daemon.
    #[tokio::test]
    async fn initialize_status_and_the_cli_name_the_same_capabilities() {
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = crate::hub::Hub::new(cfg, store);
        let dir = cmux_unix_socket::short_test_dir("acpmux-caps");
        let path = dir.path().join("d.sock");
        let listener = crate::server::bind_unix(&path).await.unwrap();
        tokio::spawn(crate::server::serve_unix(hub, listener));
        let client = Client::connect(&path).await.unwrap();

        let expected = json!(ids());
        let status = client.request(method::MUX_STATUS, json!({})).await.unwrap();
        assert_eq!(status["capabilities"], expected, "{status}");
        let hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "caps-test"}});
        let init = client.request(method::INITIALIZE, hello).await.unwrap();
        assert_eq!(init.pointer("/_meta/acpmux/capabilities"), Some(&expected), "{init}");

        let printed: Value = serde_json::from_str(&render(true)).unwrap();
        assert_eq!(printed, json!({"capabilities": expected}));
        assert_eq!(render(false), ids().iter().map(|id| format!("{id}\n")).collect::<String>());
    }
}
