//! `localhost`: a phone's native browser tab reaches a port on this Mac's
//! loopback (PROTOCOL.md `localhost`, SECURITY.md `localhost`).
//!
//! The phone listens on its own `127.0.0.1:<port>` for a tab it opened at
//! `http(s)://localhost:<port>` and opens one channel per connection, so the
//! page keeps its origin. This service connects that channel to the same port
//! on the Mac's loopback and passes bytes both ways until either side closes.
//!
//! The phone names a port, and with `localhost-hosts-v1` may also name a host
//! (`devbox:3000`, a tailnet name, a Cloud VM's private address). Without a
//! host the target is loopback (`127.0.0.1`, then `[::1]`, where `localhost`
//! dev servers often listen). A named host is resolved on this Mac and used
//! only when every address it resolves to is private (see [`allowed_ip`]): the
//! phone can never use this Mac as a proxy to the public internet, or to the
//! link-local range (cloud metadata services). Bytes are forwarded untouched,
//! so an `https` dev server's TLS runs end to end between the phone's web view
//! and the server; trusting a self-signed certificate is the phone's decision.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::services::Refusal;

/// How much is read from the Mac's port per link frame.
const READ_BYTES: usize = 16 * 1024;

/// The port in `{"port": N}` (a number, or a string as the iPhone sends it).
pub fn port(args: &Value) -> Result<u16, Refusal> {
    let value = match &args["port"] {
        Value::Number(number) => number.as_u64(),
        Value::String(text) => text.parse::<u64>().ok(),
        _ => None,
    };
    match value.and_then(|port| u16::try_from(port).ok()) {
        Some(port) if port != 0 => Ok(port),
        _ => Err(Refusal::new("bad_request", "localhost needs a port from 1 to 65535")),
    }
}

/// The host in `{"host": "devbox"}`: `None` for loopback (absent, empty or `localhost`).
/// A name is a DNS name or an IP literal (`[::1]` brackets allowed); anything with a
/// path, userinfo, port or whitespace is `bad_request`.
pub fn host(args: &Value) -> Result<Option<String>, Refusal> {
    let text = match &args["host"] {
        Value::Null => return Ok(None),
        Value::String(text) => text.trim(),
        _ => return Err(Refusal::new("bad_request", "localhost host must be text")),
    };
    let text = text.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(text);
    if text.is_empty() || text.eq_ignore_ascii_case("localhost") {
        return Ok(None);
    }
    let name_ok = text.len() <= 253
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_'))
        && !text.starts_with(['-', '.']);
    if name_ok || text.parse::<Ipv6Addr>().is_ok() {
        Ok(Some(text.to_owned()))
    } else {
        Err(Refusal::new("bad_request", "localhost host must be a host name or an address"))
    }
}

/// Whether the phone may reach `ip` through this Mac: loopback, the private ranges
/// (RFC 1918, unique-local IPv6), and carrier-grade NAT `100.64.0.0/10` where tailnets
/// live. Never the public internet, and never link-local (`169.254.0.0/16`, `fe80::/10`:
/// cloud metadata endpoints), unspecified, multicast or broadcast addresses.
pub fn allowed_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            v4.is_loopback() || v4.is_private() || (a == 100 && (64..128).contains(&b))
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return allowed_ip(IpAddr::V4(v4));
            }
            v6.is_loopback() || (v6.segments()[0] & 0xfe00) == 0xfc00
        }
    }
}

/// The addresses `host` resolves to on this Mac, all of which must be allowed.
/// Connecting to these exact addresses (not resolving again) closes a rebinding gap.
async fn resolve(host: &str, port: u16) -> Result<Vec<SocketAddr>, Refusal> {
    let addrs: Vec<SocketAddr> = match host.parse::<IpAddr>() {
        Ok(ip) => vec![SocketAddr::new(ip, port)],
        Err(_) => tokio::net::lookup_host((host, port))
            .await
            .map_err(|_| Refusal::new("unavailable", format!("This Mac can't resolve {host}.")))?
            .collect(),
    };
    if addrs.is_empty() {
        return Err(Refusal::new("unavailable", format!("This Mac can't resolve {host}.")));
    }
    if addrs.iter().any(|addr| !allowed_ip(addr.ip())) {
        return Err(Refusal::new(
            "forbidden",
            format!("{host} is not on this Mac's private network, so it isn't forwarded."),
        ));
    }
    Ok(addrs)
}

/// Connects to the port on the Mac's loopback (IPv4 first, then IPv6), or to the
/// named private host.
async fn connect(host: Option<&str>, port: u16) -> Result<TcpStream, Refusal> {
    let Some(host) = host else {
        for ip in [Ipv4Addr::LOCALHOST.into(), Ipv6Addr::LOCALHOST.into()] {
            if let Ok(stream) = TcpStream::connect(SocketAddr::new(ip, port)).await {
                return Ok(stream);
            }
        }
        return Err(Refusal::new("unavailable", format!("Nothing is listening on port {port} on this Mac.")));
    };
    for addr in resolve(host, port).await? {
        if let Ok(stream) = TcpStream::connect(addr).await {
            return Ok(stream);
        }
    }
    Err(Refusal::new("unavailable", format!("Nothing is listening on {host}:{port} from this Mac.")))
}

/// Serves one forwarded connection to completion.
pub async fn serve(
    args: &Value,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let port = port(args)?;
    let host = host(args)?;
    let stream = connect(host.as_deref(), port).await?;
    let _ = stream.set_nodelay(true);
    let (mut from_port, mut to_port) = stream.into_split();
    // The Mac's port → the phone, until the port closes or the link refuses a frame.
    let to_phone = async {
        let mut buffer = vec![0u8; READ_BYTES];
        loop {
            match from_port.read(&mut buffer).await {
                Ok(0) | Err(_) => return,
                Ok(count) => {
                    if sender.send(Bytes::copy_from_slice(&buffer[..count])).await.is_err() {
                        return;
                    }
                }
            }
        }
    };
    // The phone → the Mac's port, until the phone closes the channel.
    let from_phone = async {
        while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
            if to_port.write_all(&bytes).await.is_err() {
                return;
            }
        }
        let _ = to_port.shutdown().await;
    };
    // Either side ending ends the connection (a browser closes whole connections).
    tokio::select! {
        () = to_phone => {}
        () = from_phone => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_host_is_loopback_a_name_or_an_address_and_nothing_else() {
        for none in
            [serde_json::json!({}), serde_json::json!({"host": ""}), serde_json::json!({"host": "LocalHost"})]
        {
            assert_eq!(host(&none).unwrap(), None, "{none}");
        }
        for (given, want) in [
            ("devbox", "devbox"),
            ("a.tail1234.ts.net", "a.tail1234.ts.net"),
            ("[fd00::1]", "fd00::1"),
            ("10.0.0.2", "10.0.0.2"),
        ] {
            assert_eq!(host(&serde_json::json!({"host": given})).unwrap().as_deref(), Some(want));
        }
        for bad in ["a/b", "u@h", "h:80", "-x", "a b", "http://x"] {
            assert_eq!(host(&serde_json::json!({"host": bad})).unwrap_err().code, "bad_request", "{bad}");
        }
        assert_eq!(host(&serde_json::json!({"host": 5})).unwrap_err().code, "bad_request");
    }

    #[test]
    fn only_private_tailnet_and_loopback_addresses_are_allowed() {
        for ok in [
            "127.0.0.1",
            "::1",
            "10.1.2.3",
            "172.16.0.9",
            "172.31.255.1",
            "192.168.1.5",
            "100.64.0.1",
            "100.127.255.1",
            "fd7a:115c:a1e0::1",
            "::ffff:10.0.0.1",
        ] {
            assert!(allowed_ip(ok.parse().unwrap()), "{ok}");
        }
        for no in [
            "8.8.8.8",
            "1.1.1.1",
            "100.63.255.1",
            "100.128.0.1",
            "172.32.0.1",
            "169.254.169.254",
            "fe80::1",
            "0.0.0.0",
            "::",
            "224.0.0.1",
            "255.255.255.255",
            "2606:4700::1111",
            "::ffff:8.8.8.8",
        ] {
            assert!(!allowed_ip(no.parse().unwrap()), "{no}");
        }
    }

    #[tokio::test]
    async fn a_public_or_metadata_host_is_forbidden_before_any_connection() {
        for bad in ["8.8.8.8", "169.254.169.254", "2606:4700::1111"] {
            assert_eq!(connect(Some(bad), 80).await.unwrap_err().code, "forbidden", "{bad}");
        }
    }

    #[test]
    fn a_port_is_a_number_or_its_text_and_never_zero_or_out_of_range() {
        assert_eq!(port(&serde_json::json!({"port": 3000})).unwrap(), 3000);
        assert_eq!(port(&serde_json::json!({"port": "5173"})).unwrap(), 5173);
        for bad in [
            serde_json::json!({}),
            serde_json::json!({"port": 0}),
            serde_json::json!({"port": 70000}),
            serde_json::json!({"port": "x"}),
            serde_json::json!({"port": -1}),
            serde_json::json!({"host": "10.0.0.2", "port": "80:80"}),
        ] {
            assert_eq!(port(&bad).unwrap_err().code, "bad_request", "{bad}");
        }
    }
}
