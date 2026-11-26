//! The signaling WebSocket's TCP dial, raced and remembered (Braid, RFD 0164 slice B1b).
//!
//! `tokio_tungstenite::connect_async` tries the resolver's addresses one after the other on
//! one socket each: on a dual-stack network whose IPv6 is black-holed, the IPv6 SYN is
//! retransmitted until the operating system gives up, past [`crate::signaling::CONNECT_WAIT`],
//! and the phone never reaches signaling at all. Here the addresses race through
//! `cmux_braid_path` (IPv6 first, IPv4 joining after the stagger), and the address that won is
//! remembered per host and port: the next connect starts there, with a stagger of 1.5 times its
//! connect time. `CMUX_BRAID_LAST_GOOD=0` turns the memory off. The upgrade and TLS then run
//! over the won socket exactly as `connect_async` runs them.

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::sync::LazyLock;

use cmux_braid_path::{LastGood, RacePolicy};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::{self, handshake::client::Request};

/// The address that last connected per `(host, port)`, for the whole process.
static LAST_GOOD: LazyLock<LastGood<(String, u16), SocketAddr>> = LazyLock::new(LastGood::from_env);

/// How the addresses race: a second attempt after 400 ms (or 1.5 times the remembered connect
/// time, at least 100 ms), three at a time, each but the last given 3 s.
pub(crate) const POLICY: RacePolicy = RacePolicy::INTERNET;

/// The request's host (brackets off an IPv6 literal) and port (the scheme's default if none).
fn host_port(request: &Request) -> Result<(String, u16), tungstenite::Error> {
    let uri = request.uri();
    let host = uri.host().ok_or(tungstenite::Error::Url(tungstenite::error::UrlError::NoHostName))?;
    let host = host.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase();
    let port = uri.port_u16().unwrap_or(if uri.scheme_str() == Some("wss") { 443 } else { 80 });
    Ok((host, port))
}

/// A TCP connect to `host:port` over `addresses` through `memory` (module docs).
pub(crate) async fn connect_remembered<T, F, Fut>(
    memory: &LastGood<(String, u16), SocketAddr>,
    host: &str,
    port: u16,
    addresses: &[SocketAddr],
    connect: F,
) -> io::Result<T>
where
    F: FnMut(SocketAddr) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    let key = (host.to_ascii_lowercase(), port);
    let ordered = cmux_braid_path::v6_first(addresses);
    cmux_braid_path::race_remembered(memory, key, &ordered, POLICY, connect).await.map(|(_, won)| won.value)
}

/// The raced TCP connect for `request`'s host (module docs).
///
/// # Errors
/// A URL with no host, a failed lookup, or the race's last error.
pub async fn connect_tcp(request: &Request) -> Result<TcpStream, tungstenite::Error> {
    let (host, port) = host_port(request)?;
    let addresses: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), port)).await?.collect();
    Ok(connect_remembered(&LAST_GOOD, &host, port, &addresses, TcpStream::connect).await?)
}

#[cfg(test)]
#[path = "signal_dial_tests.rs"]
mod tests;
