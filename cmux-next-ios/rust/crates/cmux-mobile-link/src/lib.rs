//! cmux-next-ios link core (cmux-next-ios/PROTOCOL.md).
//!
//! - [`link`]: the transport-agnostic [`Link`]: framing, channel mux, ping,
//!   open and close.
//! - [`signaling`]: the backend signaling WebSocket client.
//! - [`api`]: the backend HTTP API.
//! - [`build_space`]: a dev build's `x-cmux-build-space` header.
//! - [`dial`]: the WebRTC and WireGuard dialers behind one [`dial::Dialer`]
//!   trait, selected by [`TransportKind`].
//! - [`hybrid`]: the phone's WebRTC media session beside a WireGuard link.
//! - [`keepalive`]: the phone's one keepalive clock (Align Keepalives).
//! - [`link_stat`]: the phone's path report (`link_stat` on the signaling socket).
//! - [`path_report`]: one log line per path change and per 10 s (path, srtt).
//! - [`names`]: the link's capability names, declared once (PROTOCOL.md "Capabilities").
//! - [`reconnect`]: the reconnect decision as one pure step (a port of `LinkMachine.swift`).

pub mod api;
pub mod build_space;
pub mod class_queue;
pub mod dial;
pub mod frame;
pub mod hybrid;
pub mod keepalive;
pub mod link;
pub mod link_stat;
pub mod media;
pub mod path_report;
pub mod names;
pub mod reconnect;
mod send_queue;
pub mod signaling;
#[cfg(feature = "testing")]
pub mod testing;
pub mod timing;

pub use build_space::BuildSpace;
pub use dial::{Connected, DialError, DialOptions, LinkPath, TransportKind, UltraSetting};
pub use link::{
    Channel, ChannelEvent, CloseInfo, IncomingChannel, KEEPALIVE_TIMEOUT, Lane, LaneState, Link, LinkConfig,
    LinkError, Role,
};
pub use signaling::SignalingClient;
pub use timing::Timeline;

/// Install rustls's ring provider once (HTTP and WebSocket TLS).
pub fn install_crypto_provider() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}
