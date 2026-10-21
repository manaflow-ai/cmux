//! cmux-next-ios link core (cmux-next-ios/PROTOCOL.md).
//!
//! - [`link`]: the transport-agnostic [`Link`]: framing, channel mux, ping,
//!   open and close.
//! - [`signaling`]: the backend signaling WebSocket client.
//! - [`api`]: the backend HTTP API.
//! - [`dial`]: the WebRTC and WireGuard dialers behind one [`dial::Dialer`]
//!   trait, selected by [`TransportKind`].
//! - [`hybrid`]: the phone's WebRTC media session beside a WireGuard link.

pub mod api;
pub mod class_queue;
pub mod dial;
pub mod frame;
pub mod hybrid;
pub mod link;
pub mod media;
mod send_queue;
pub mod signaling;
#[cfg(feature = "testing")]
pub mod testing;
pub mod timing;

pub use dial::{Connected, DialError, DialOptions, LinkPath, TransportKind};
pub use link::{
    Channel, ChannelEvent, CloseInfo, IncomingChannel, Lane, LaneState, Link, LinkConfig, LinkError, Role,
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
