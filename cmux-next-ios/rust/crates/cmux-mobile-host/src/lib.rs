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
pub mod activity;
pub mod appearance;
pub mod auth;
pub mod browser;
pub mod browser_policy;
pub mod browser_track;
pub mod bundle;
pub mod catch_up;
pub mod chief_answers;
pub mod chief_policy;
pub(crate) mod cloud_acp;
pub mod config;
pub mod control;
pub mod dial_mailbox;
pub mod host;
pub mod lan;
pub mod link_deflate;
pub mod link_socket;
pub mod live_code;
pub mod local_link;
pub mod localhost;
pub mod machine;
pub mod mailbox;
pub mod mailbox_apply;
pub mod media_session;
pub mod needs_you;
pub mod netwatch;
pub mod notify;
pub mod notify_content;
pub mod notify_redact;
#[cfg(test)]
mod notify_secfix_tests;
pub mod notify_terminal;
mod notify_waiting;
pub mod output_paint;
pub mod paint_latency;
pub mod pair_requests;
pub mod pairing;
pub mod path_probe;
pub mod peer;
pub mod phone_frames;
pub mod phone_page;
pub mod policy;
pub mod portmap;
pub mod presence;
pub mod push_keys;
pub mod relay_feed;
pub mod relay_publish;
pub mod seal;
pub mod sealed_notify;
pub mod services;
pub mod site_data;
pub mod size_release;
pub mod surface;
pub mod tab_snapshots;
pub mod traffic;
pub mod try_pr;
pub mod viewport_link;
pub mod viewport_sync;

mod side_completion;
mod workspace_cache;
