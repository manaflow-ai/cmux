//! `localhost`: a phone's native browser tab reaches a port on this Mac's
//! loopback (PROTOCOL.md `localhost`, SECURITY.md `localhost`).
//!
//! The phone listens on its own `127.0.0.1:<port>` for a tab it opened at
//! `http(s)://localhost:<port>` and opens one channel per connection, so the
//! page keeps its origin. This service connects that channel to the same port
//! on the Mac's loopback and passes bytes both ways until either side closes.
//!
//! The phone names only a port: the host is always loopback (`127.0.0.1`, then
//! `[::1]`, where `localhost` dev servers often listen), never an address the
//! phone chooses. A paired phone already reaches these ports through a
//! streamed `browser` tab and the Mac's terminals, so this adds no reach.

use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};

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

/// Connects to the port on the Mac's loopback: IPv4 first, then IPv6.
async fn connect(port: u16) -> Result<TcpStream, Refusal> {
    for ip in [Ipv4Addr::LOCALHOST.into(), Ipv6Addr::LOCALHOST.into()] {
        if let Ok(stream) = TcpStream::connect(SocketAddr::new(ip, port)).await {
            return Ok(stream);
        }
    }
    Err(Refusal::new("unavailable", format!("Nothing is listening on port {port} on this Mac.")))
}

/// Serves one forwarded connection to completion.
pub async fn serve(args: &Value, sender: &ChannelSender, mut receiver: ChannelReceiver) -> Result<(), Refusal> {
    let port = port(args)?;
    let stream = connect(port).await?;
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
