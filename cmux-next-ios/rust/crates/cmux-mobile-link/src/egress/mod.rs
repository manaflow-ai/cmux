//! How the link's own TCP connections leave this device (PROTOCOL.md
//! "Corporate networks"): the signaling WebSocket, the HTTP API (`/v1/ice`
//! and the rest) and TURN over TLS or TCP, on the phone and on the Mac.
//!
//! The proxy lookup, the `CONNECT` and SOCKS5 tunnels, the OS trust store and
//! the path telemetry ([`PathKind`], [`note`], [`seen`]) live in `cmux-proxy`
//! (cmux-tui/crates/cmux-proxy), shared with `cmux-remote`'s way to a cmux
//! Cloud machine; this module re-exports it under the paths the link has
//! always used, and adds the link's WebSocket and its gated HTTP client.

pub use cmux_proxy::*;

use tokio::net::TcpStream;

/// A WebSocket from [`connect_websocket`].
pub type WebSocket = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

/// Why [`connect_websocket`] failed: before the upgrade (the way out) or in
/// it (TLS, HTTP), so each caller can say which.
#[derive(Debug)]
pub enum WebSocketError {
    BadUrl(String),
    Egress(EgressError),
    Tls(String),
    Upgrade(tokio_tungstenite::tungstenite::Error),
}

impl std::fmt::Display for WebSocketError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadUrl(url) => write!(f, "not a WebSocket URL: {url}"),
            Self::Egress(error) => error.fmt(f),
            Self::Tls(error) => write!(f, "TLS: {error}"),
            Self::Upgrade(error) => error.fmt(f),
        }
    }
}

/// A WebSocket upgrade of `request` on a TCP stream that left the way `egress`
/// says (the system's proxy with `CONNECT`, PAC included), with TLS verified
/// against its trust: the signaling socket and the relay share it, so a network
/// whose only way out is its proxy, or that inspects TLS, reaches both.
pub async fn connect_websocket(
    request: tokio_tungstenite::tungstenite::handshake::client::Request,
    egress: &Egress,
) -> Result<(WebSocket, Via), WebSocketError> {
    if let Some(captured) = capture_stream(&request).await {
        let (tcp, connector) = captured.map_err(WebSocketError::Egress)?;
        let (socket, _) =
            tokio_tungstenite::client_async_tls_with_config(request, tcp, None, Some(connector))
                .await
                .map_err(WebSocketError::Upgrade)?;
        return Ok((socket, Via::Direct));
    }
    let uri = request.uri().clone();
    let secure = uri.scheme_str() == Some("wss");
    let host = uri.host().ok_or_else(|| WebSocketError::BadUrl(uri.to_string()))?;
    let host = host.trim_start_matches('[').trim_end_matches(']').to_owned();
    let port = uri.port_u16().unwrap_or(if secure { 443 } else { 80 });
    let (tcp, via) = connect_tcp(&host, port, secure, egress).await.map_err(WebSocketError::Egress)?;
    let connector = if secure {
        tokio_tungstenite::Connector::Rustls(tls::client_config(&egress.trust).map_err(WebSocketError::Tls)?)
    } else {
        tokio_tungstenite::Connector::Plain
    };
    let (socket, _) = tokio_tungstenite::client_async_tls_with_config(request, tcp, None, Some(connector))
        .await
        .map_err(WebSocketError::Upgrade)?;
    note(PathKind::of(&via, &host));
    Ok((socket, via))
}

/// With the seeded-secret capture on (`cmux_egress` feature `capture`, tests
/// only), the stream and TLS a `wss://` upgrade of `request` takes instead of
/// its own way out: the capture server, trusting its CA, as the gate's own
/// WebSocket connects do. Every upgrade this crate dials itself after
/// `cmux_egress::ws::checked` (the relay's, the signaling socket's) asks here
/// first; `None` in every other build and for every other host.
pub(crate) async fn capture_stream(
    request: &tokio_tungstenite::tungstenite::handshake::client::Request,
) -> Option<Result<(TcpStream, tokio_tungstenite::Connector), EgressError>> {
    let (addr, tls) = cmux_egress::ws::capture_route(request)?;
    Some(
        TcpStream::connect(addr)
            .await
            .map(|tcp| (tcp, tokio_tungstenite::Connector::Rustls(tls)))
            .map_err(|error| EgressError::Io(error.to_string())),
    )
}

/// The HTTP client of the link's API calls: the OS trust store, and the
/// system's proxy for each request (the cached answer; [`proxy::warm`]
/// asks ahead of time). Every connection passes the egress gate
/// (`cmux_egress`, docs/privacy.md) as `site`; with a proxy set, the proxy's
/// host is the one checked.
pub fn http_client_builder(site: &'static str) -> reqwest::ClientBuilder {
    with_system_proxy_and_trust(cmux_egress::client_builder(site))
}

/// [`http_client_builder`] looking names up with `resolver` behind the gate.
/// Call this, never `.dns_resolver(..)` on the builder: reqwest keeps one
/// resolver, so a later one replaces the gate's and the client goes ungated.
pub fn http_client_builder_with(
    site: &'static str,
    resolver: impl reqwest::dns::Resolve + 'static,
) -> reqwest::ClientBuilder {
    with_system_proxy_and_trust(cmux_egress::client_builder_with(site, resolver))
}

fn with_system_proxy_and_trust(builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    let builder = builder.proxy(reqwest::Proxy::custom(proxy::http_proxy_url));
    // The seeded-secret capture trusts its own CA (set by the gate's builder);
    // the OS store would replace it.
    if cmux_egress::capturing() {
        return builder;
    }
    match tls::client_config(&TlsTrust::System) {
        Ok(config) => builder.use_preconfigured_tls((*config).clone()),
        Err(error) => {
            tracing::warn!(%error, "no TLS configuration from the OS trust store; the HTTP client uses its own roots");
            builder
        }
    }
}
