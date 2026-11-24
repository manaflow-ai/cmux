//! How the link's own TCP connections leave this device (PROTOCOL.md
//! "Corporate networks"): the signaling WebSocket, the HTTP API (`/v1/ice`
//! and the rest) and TURN over TLS or TCP, on the phone and on the Mac.
//!
//! - [`proxy`]: each connection goes through the system's proxy for its
//!   destination (manual, PAC or WPAD on iOS and macOS, as URLSession; the
//!   environment elsewhere), with `CONNECT` or SOCKS5, so a network whose only
//!   way out is its proxy still links.
//! - [`tls`]: TLS verifies against the OS trust store, so a network that
//!   inspects TLS with a company root an MDM profile installed still links.

#[cfg(target_vendor = "apple")]
mod apple;
pub mod proxy;
pub mod tls;

use std::time::Duration;

use tokio::net::TcpStream;

pub use proxy::{Credentials, Hop, ProxyConfig, ProxyServer};
pub use tls::TlsTrust;

/// How one connection leaves this device.
#[derive(Debug, Clone, Default)]
pub struct Egress {
    pub proxy: ProxyConfig,
    /// Only through a proxy: a destination the settings send direct fails
    /// with [`EgressError::ProxyRequired`] (the debug "Proxy only" network,
    /// whose only way out is its proxy).
    pub require_proxy: bool,
    pub trust: TlsTrust,
}

/// Why a connection could not be made, said for a person (the dial's error).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum EgressError {
    #[error("{0}")]
    Io(String),
    #[error(
        "the proxy {proxy} asks for {schemes} sign-in before it lets {target} through, and the cmux link can \
         sign in to a proxy only with a user name and password (Basic); ask your IT team to let {target} through \
         without sign-in"
    )]
    ProxyAuthUnsupported { proxy: String, target: String, schemes: String },
    #[error(
        "the proxy {proxy} asks for a user name and password, and the system's proxy settings give none (or a user name without its password)"
    )]
    ProxyAuthMissing { proxy: String },
    #[error("the proxy {proxy} refused the user name and password in the system's proxy settings")]
    ProxyAuthRefused { proxy: String },
    #[error("the proxy {proxy} refused to connect to {target}: {status}")]
    ProxyRefused { proxy: String, target: String, status: String },
    #[error("the system has no proxy for {target}, and Proxy only allows nothing else")]
    ProxyRequired { target: String },
}

impl EgressError {
    /// A proxy's refusal (sign-in or policy), not a network failure: trying
    /// again soon gives the same answer.
    pub fn is_proxy_refusal(&self) -> bool {
        !matches!(self, Self::Io(_))
    }

    /// The more telling of two failures (a proxy's refusal over a network
    /// error).
    fn rank(&self) -> u8 {
        match self {
            Self::Io(_) => 0,
            Self::ProxyRefused { .. } | Self::ProxyRequired { .. } => 1,
            Self::ProxyAuthMissing { .. }
            | Self::ProxyAuthRefused { .. }
            | Self::ProxyAuthUnsupported { .. } => 2,
        }
    }
}

/// The network changed: the next connection asks the system for its proxy
/// again (not the 30 s cached answer of the old network), and what was
/// learned about TLS inspection on the old network is dropped.
pub fn network_changed() {
    proxy::forget();
    tls::forget_inspected();
    paths().clear();
}

/// Each host's path on its latest link connection (signaling, the relay,
/// TURN over TLS). Per host and replaced by the next connection to it, so a
/// clean handshake to a host that was inspected clears it: `link_stat`
/// reports the path the link takes now, not the worst one it ever took.
fn paths() -> std::sync::MutexGuard<'static, std::collections::HashMap<String, PathKind>> {
    static PATHS: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, PathKind>>> =
        std::sync::OnceLock::new();
    PATHS.get_or_init(Default::default).lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// A link connection to `host` went out on `path`.
pub fn note(host: &str, path: PathKind) {
    let host = host.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase();
    paths().insert(host, path);
}

/// The way out this network makes the link take, for `link_stat`: the most
/// telling of each host's latest path, `None` when every one went direct.
pub fn seen() -> Option<PathKind> {
    paths().values().copied().filter(|path| *path != PathKind::Direct).max()
}

/// Bound on each hop's TCP connect and proxy handshake.
const HOP_WAIT: Duration = Duration::from_secs(10);

/// How a connection went out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Via {
    Direct,
    Proxy(Hop),
}

/// A TCP stream to `host:port` (`secure`: TLS will run on it, as for an
/// `https` URL): through the first hop of the proxy settings that connects,
/// in order. The destination's name goes to the proxy unresolved (a proxy-only
/// network often resolves outside names only at its proxy).
pub async fn connect_tcp(
    host: &str,
    port: u16,
    secure: bool,
    egress: &Egress,
) -> Result<(TcpStream, Via), EgressError> {
    let mut hops = proxy::hops(host, port, secure, &egress.proxy).await;
    if egress.require_proxy {
        hops.retain(|hop| *hop != Hop::Direct);
        if hops.is_empty() {
            return Err(EgressError::ProxyRequired { target: proxy::authority(host, port) });
        }
    }
    let mut failure: Option<EgressError> = None;
    for hop in hops {
        let attempt =
            tokio::time::timeout(HOP_WAIT, connect_hop(&hop, host, port)).await.unwrap_or_else(|_| {
                Err(EgressError::Io(format!(
                    "{hop}: no connection to {} within {}s",
                    proxy::authority(host, port),
                    HOP_WAIT.as_secs()
                )))
            });
        match attempt {
            Ok(stream) => {
                if hop != Hop::Direct {
                    tracing::debug!(%hop, host, port, "connected through the proxy");
                }
                let via = if hop == Hop::Direct { Via::Direct } else { Via::Proxy(hop) };
                return Ok((stream, via));
            }
            Err(error) => {
                tracing::debug!(%hop, host, port, %error, "this way out did not connect; trying the next");
                if failure.as_ref().is_none_or(|kept| error.rank() >= kept.rank()) {
                    failure = Some(error);
                }
            }
        }
    }
    Err(failure.unwrap_or_else(|| EgressError::Io(format!("no way out to {}", proxy::authority(host, port)))))
}

async fn connect_hop(hop: &Hop, host: &str, port: u16) -> Result<TcpStream, EgressError> {
    let tcp = |host: &str, port: u16| {
        let address = proxy::authority(host, port);
        async move {
            TcpStream::connect(address.as_str())
                .await
                .map_err(|error| EgressError::Io(format!("{address}: {error}")))
        }
    };
    match hop {
        Hop::Direct => tcp(host, port).await,
        Hop::Http(server) => {
            proxy::http_connect(tcp(&server.host, server.port).await?, server, host, port).await
        }
        Hop::Socks5(server) => {
            proxy::socks5_connect(tcp(&server.host, server.port).await?, server, host, port).await
        }
    }
}

/// A TLS stream to `host:port` the way `egress` says, verified against its
/// trust for `host`.
pub async fn connect_tls(
    host: &str,
    port: u16,
    egress: &Egress,
) -> Result<(tokio_rustls::client::TlsStream<TcpStream>, Via), EgressError> {
    let (tcp, via) = connect_tcp(host, port, true, egress).await?;
    let config = tls::client_config(&egress.trust).map_err(EgressError::Io)?;
    let name = rustls::pki_types::ServerName::try_from(host.to_owned())
        .map_err(|error| EgressError::Io(format!("{host}: {error}")))?;
    let stream = tokio_rustls::TlsConnector::from(config)
        .connect(name, tcp)
        .await
        .map_err(|error| EgressError::Io(format!("TLS to {host}: {error}")))?;
    note(host, PathKind::of(&via, host));
    Ok((stream, via))
}

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

/// How a connection's path looks from here, for telemetry: direct, through
/// a proxy, or through a proxy (or middlebox) that inspects TLS.
/// Ordered by how telling it is (`Direct` < `Proxy` < `Inspected`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PathKind {
    Direct,
    Proxy,
    Inspected,
}

impl PathKind {
    /// The path a connection to `host` that went out `via` took.
    pub fn of(via: &Via, host: &str) -> Self {
        if tls::inspected(host) {
            Self::Inspected
        } else if matches!(via, Via::Proxy(_)) {
            Self::Proxy
        } else {
            Self::Direct
        }
    }

    /// The path of a connection that ran no TLS.
    pub fn of_plain(via: &Via) -> Self {
        if matches!(via, Via::Proxy(_)) { Self::Proxy } else { Self::Direct }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Proxy => "proxy",
            Self::Inspected => "inspected",
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
    // Plain `ws://` ran no TLS, so nothing inspected it.
    let path = if secure { PathKind::of(&via, &host) } else { PathKind::of_plain(&via) };
    note(&host, path);
    Ok((socket, via))
}

/// The HTTP client of the link's API calls: the OS trust store, and the
/// system's proxy for each request (the cached answer; [`proxy::warm`]
/// asks ahead of time).
pub fn http_client_builder() -> reqwest::ClientBuilder {
    let builder = reqwest::Client::builder().proxy(reqwest::Proxy::custom(|url| {
        let host = url.host_str()?.trim_start_matches('[').trim_end_matches(']').to_owned();
        let secure = url.scheme() == "https";
        let port = url.port_or_known_default()?;
        // reqwest takes one proxy and no fallback list: the first HTTP proxy,
        // unless the settings go direct before it (this client has no SOCKS).
        for hop in proxy::hops_now(&host, port, secure, &ProxyConfig::System) {
            match hop {
                Hop::Direct => return None,
                Hop::Http(server) => return Some(server.http_url()),
                Hop::Socks5(_) => {}
            }
        }
        None
    }));
    match tls::client_config(&TlsTrust::System) {
        Ok(config) => builder.use_preconfigured_tls((*config).clone()),
        Err(error) => {
            tracing::warn!(%error, "no TLS configuration from the OS trust store; the HTTP client uses its own roots");
            builder
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn latest(host: &str) -> Option<PathKind> {
        paths().get(host).copied()
    }

    /// Review F3: `link_stat.egress` follows each host's latest connection:
    /// one clean connection after an inspected one is not inspected, and a
    /// direct one is not "proxy".
    #[test]
    fn the_latest_connection_to_a_host_sets_its_path() {
        let host = "relay.f3-path.test";
        note(host, PathKind::Inspected);
        assert_eq!(latest(host), Some(PathKind::Inspected));
        note(host, PathKind::Proxy);
        assert_eq!(latest(host), Some(PathKind::Proxy), "a clean handshake through the proxy");
        note(host, PathKind::Direct);
        assert_eq!(latest(host), Some(PathKind::Direct));
        assert!(PathKind::Direct < PathKind::Proxy && PathKind::Proxy < PathKind::Inspected);
        let proxy = Via::Proxy(Hop::Http(ProxyServer::new("proxy.corp", 3128)));
        assert_eq!(PathKind::of_plain(&proxy), PathKind::Proxy);
        assert_eq!(PathKind::of_plain(&Via::Direct), PathKind::Direct);
    }
}
