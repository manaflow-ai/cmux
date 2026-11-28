//! cmux-next-ios link core (cmux-next-ios/PROTOCOL.md).
//!
//! - [`link`]: the transport-agnostic [`Link`]: framing, channel mux, ping,
//!   open and close.
//! - [`signaling`]: the backend signaling WebSocket client.
//! - [`api`]: the backend HTTP API.
//! - [`build_space`]: a dev build's `x-cmux-build-space` header.
//! - [`egress`]: how the link's own TCP connections leave this device: the
//!   system's proxy (PAC included) and the OS trust store.
//! - [`dial`]: the WebRTC and WireGuard dialers behind one [`dial::Dialer`]
//!   trait, selected by [`TransportKind`].
//! - [`hybrid`]: the phone's WebRTC media session beside a WireGuard link.
//! - [`keepalive`]: the phone's one keepalive clock (Align Keepalives).
//! - [`link_stat`]: the phone's path report (`link_stat` on the signaling socket).
//! - [`path_report`]: one log line per path change and per 10 s (path, srtt).
//! - [`names`]: the link's capability names, declared once (PROTOCOL.md "Capabilities").
//! - [`local`], [`local_hub`]: nearby links with no internet (mDNS ad policy, the Mac's local hub).
//! - [`route_literals`]: the IP literals each dialed host last resolved to (a dial needs no DNS).
//! - [`zstd_stream`]: `zstd-stream-v1`, one zstd stream per acpmux channel on the link.
//! - [`reconnect`]: the reconnect decision as one pure step (a port of `LinkMachine.swift`).
//! - [`viewport`]: viewport state sync's VT rendering and the phone's datagram receiver.

// A test function that lost its `#[test]` in a merge is dead code: fail the
// test build on it instead of skipping the test with a warning nobody reads.
#![cfg_attr(test, deny(dead_code))]

pub mod api;
pub mod build_space;
pub mod bundle_link;
pub mod chat_open;
pub mod class_queue;
pub mod classes;
pub mod dial;
pub mod egress;
pub mod frame;
pub mod hold_route;
pub mod hub;
pub mod hybrid;
pub mod keepalive;
pub mod key_echo;
pub mod key_paint;
pub mod lan;
pub mod link;
pub mod link_stat;
mod liveness;
pub mod local;
pub mod local_dns;
pub mod local_hub;
pub mod mailbox_client;
pub mod media;
pub mod names;
pub mod net_return;
pub mod path_report;
pub mod reconnect;
pub mod relay_cache;
pub mod relay_hold;
pub mod reliable;
pub mod route_literals;
mod send_queue;
pub mod signal_dial;
pub mod signaling;
#[cfg(feature = "testing")]
pub mod testing;
pub mod timing;
pub mod viewport;
pub mod zstd_stream;

pub use build_space::BuildSpace;
pub use dial::{Connected, DialError, DialOptions, LinkPath, Overlay, TransportKind, UltraSetting};
pub use link::{
    Accepted, Channel, ChannelEvent, ChannelResume, CloseInfo, IncomingChannel, KEEPALIVE_TIMEOUT, Lane,
    LaneState, Link, LinkConfig, LinkError, ResumeReport, Role,
};
pub use reliable::{Carrier, RELIABLE_LANE, ReliableConfig, ReliableStats, ResumeRegistry};
pub use signaling::SignalingClient;
pub use timing::Timeline;

/// Install rustls's ring provider once (HTTP and WebSocket TLS).
pub fn install_crypto_provider() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}
