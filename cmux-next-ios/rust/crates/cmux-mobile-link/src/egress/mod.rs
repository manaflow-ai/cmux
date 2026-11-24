//! How the link's own TCP connections leave this device (PROTOCOL.md
//! "Corporate networks"): the signaling WebSocket, the HTTP API (`/v1/ice`
//! and the rest) and TURN over TLS or TCP, on the phone and on the Mac.
//!
//! The proxy lookup, the `CONNECT` and SOCKS5 tunnels and the OS trust store
//! live in `cmux-proxy` (cmux-tui/crates/cmux-proxy), shared with
//! `cmux-remote`'s way to a cmux Cloud machine; this module re-exports it
//! under the paths the link has always used, and adds the link's HTTP client.

pub use cmux_proxy::*;

/// The HTTP client of the link's API calls: the OS trust store, and the
/// system's proxy for each request (the cached answer; [`proxy::warm`]
/// asks ahead of time).
pub fn http_client_builder() -> reqwest::ClientBuilder {
    let builder = reqwest::Client::builder().proxy(reqwest::Proxy::custom(proxy::http_proxy_url));
    match tls::client_config(&TlsTrust::System) {
        Ok(config) => builder.use_preconfigured_tls((*config).clone()),
        Err(error) => {
            tracing::warn!(%error, "no TLS configuration from the OS trust store; the HTTP client uses its own roots");
            builder
        }
    }
}
