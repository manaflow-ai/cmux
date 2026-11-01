//! cmux-mobile-host: the Mac side of cmux-next-ios links (cmux-next-ios/PROTOCOL.md).
//!
//! Registers the Mac with the backend, holds the signaling socket, admits
//! dials from the owner's own phones, answers WebRTC offers and WireGuard
//! handshakes, and serves link channels: `echo`, `daemon` (the cmux-tui
//! session socket through an allowlist), `chief` (the Chief's conversation
//! owner, scoped to the owner's agent conversations), `acpmux`, `file` and
//! `browser` (a streamed Mac browser tab, `browser.rs`) and `localhost` (a
//! phone's native browser tab reaching a port on this Mac's loopback). Beside a WireGuard
//! link the phone may open a WebRTC media session for browser video
//! (`media_session.rs`).

pub mod acpmux_policy;
pub mod auth;
pub mod browser;
pub mod browser_policy;
pub mod browser_track;
pub mod chief_answers;
pub mod chief_policy;
pub(crate) mod cloud_acp;
pub mod config;
pub mod control;
pub mod host;
pub mod localhost;
pub mod mailbox;
pub mod mailbox_apply;
pub mod media_session;
pub mod netwatch;
pub mod notify;
pub mod notify_content;
pub mod notify_redact;
#[cfg(test)]
mod notify_secfix_tests;
pub mod notify_terminal;
mod notify_waiting;
pub mod pairing;
pub mod policy;
pub mod push_keys;
pub mod seal;
pub mod sealed_notify;
pub mod services;
pub mod size_release;
pub mod surface;

mod workspace_cache;
mod side_completion;
