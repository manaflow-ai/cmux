//! Claude Code's cross-session messaging, as the daemon names it (`hub/native_messaging.rs`).

/// Claude Code's switch for its cross-session messaging (`0`: off, both ways).
pub const SWITCH_ENV: &str = "CLAUDE_CODE_HARBOR_KITE";

/// The ACP `sessionUpdate` the Claude Code backend sends for a `system/peer_message_hold` line.
pub const HOLD_UPDATE: &str = "peer_message_hold";
