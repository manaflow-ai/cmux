//! The debug "Drop WireGuard" network ([`super::DialOptions::drop_wireguard_udp`]):
//! a firewall whose packet inspection blocks WireGuard, as some company and
//! school networks run. STUN and TURN's own requests pass, so UDP looks open;
//! every datagram that carries a WireGuard message is dropped without a word,
//! bare or inside TURN over UDP (ChannelData, Send and Data indications), both
//! ways. Only TURN over TLS (or TCP) gets the tunnel through.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use webrtc::util::Conn;

/// Datagrams the simulation dropped in this process (tests check that it
/// dropped something, so a pass is not vacuous).
static DROPPED: AtomicU64 = AtomicU64::new(0);

/// Datagrams the "Drop WireGuard" simulation dropped so far in this process.
#[doc(hidden)]
pub fn dropped_wireguard_datagrams() -> u64 {
    DROPPED.load(Ordering::Relaxed)
}

pub(crate) fn count_drop() {
    DROPPED.fetch_add(1, Ordering::Relaxed);
}

/// A WireGuard message: type 1 to 4 then three zero bytes, 32 bytes at
/// least (a keepalive), or this tunnel's repair data.
fn is_wireguard_message(payload: &[u8]) -> bool {
    (payload.len() >= 32 && (1..=4).contains(&payload[0]) && payload[1..4] == [0, 0, 0])
        || cmux_wg::is_ultra_parity(payload)
}

/// The DATA attribute of a STUN Send or Data indication (RFC 8656 §11).
fn indication_data(message: &[u8]) -> Option<&[u8]> {
    if message.len() < 20 || message[4..8] != [0x21, 0x12, 0xA4, 0x42] {
        return None;
    }
    let kind = u16::from_be_bytes([message[0], message[1]]);
    if kind != 0x0016 && kind != 0x0017 {
        return None;
    }
    let length = usize::from(u16::from_be_bytes([message[2], message[3]]));
    let body = message.get(20..20 + length)?;
    let mut at = 0;
    while at + 4 <= body.len() {
        let attribute = u16::from_be_bytes([body[at], body[at + 1]]);
        let len = usize::from(u16::from_be_bytes([body[at + 2], body[at + 3]]));
        let value = body.get(at + 4..at + 4 + len)?;
        if attribute == 0x0013 {
            return Some(value);
        }
        at += 4 + ((len + 3) & !3);
    }
    None
}

/// Whether a UDP datagram carries WireGuard, bare or relayed through TURN.
pub(crate) fn carries_wireguard(datagram: &[u8]) -> bool {
    if is_wireguard_message(datagram) {
        return true;
    }
    match datagram.first().map(|first| first >> 6) {
        // ChannelData: a 4-byte header, then the datagram.
        Some(0b01) => datagram.get(4..).is_some_and(is_wireguard_message),
        Some(0b00) => indication_data(datagram).is_some_and(is_wireguard_message),
        _ => false,
    }
}

/// A TURN client's UDP socket behind such a firewall.
pub(crate) struct DpiConn {
    inner: Arc<dyn Conn + Send + Sync>,
}

impl DpiConn {
    pub(crate) fn new(inner: Arc<dyn Conn + Send + Sync>) -> Self {
        Self { inner }
    }
}

#[async_trait::async_trait]
impl Conn for DpiConn {
    async fn connect(&self, addr: SocketAddr) -> webrtc::util::Result<()> {
        self.inner.connect(addr).await
    }

    async fn recv(&self, buf: &mut [u8]) -> webrtc::util::Result<usize> {
        self.recv_from(buf).await.map(|(len, _)| len)
    }

    async fn recv_from(&self, buf: &mut [u8]) -> webrtc::util::Result<(usize, SocketAddr)> {
        loop {
            let (len, from) = self.inner.recv_from(buf).await?;
            if !carries_wireguard(&buf[..len]) {
                return Ok((len, from));
            }
            count_drop();
        }
    }

    async fn send(&self, buf: &[u8]) -> webrtc::util::Result<usize> {
        if carries_wireguard(buf) {
            count_drop();
            return Ok(buf.len());
        }
        self.inner.send(buf).await
    }

    async fn send_to(&self, buf: &[u8], target: SocketAddr) -> webrtc::util::Result<usize> {
        if carries_wireguard(buf) {
            count_drop();
            return Ok(buf.len());
        }
        self.inner.send_to(buf, target).await
    }

    fn local_addr(&self) -> webrtc::util::Result<SocketAddr> {
        self.inner.local_addr()
    }

    fn remote_addr(&self) -> Option<SocketAddr> {
        self.inner.remote_addr()
    }

    async fn close(&self) -> webrtc::util::Result<()> {
        self.inner.close().await
    }

    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wireguard(kind: u8, len: usize) -> Vec<u8> {
        let mut message = vec![0u8; len];
        message[0] = kind;
        message
    }

    #[test]
    fn wireguard_is_seen_bare_and_inside_turn_but_stun_is_not() {
        let init = wireguard(1, 148);
        assert!(carries_wireguard(&init));
        assert!(carries_wireguard(&wireguard(4, 32)));
        assert!(!carries_wireguard(&wireguard(5, 148)));
        assert!(!carries_wireguard(&wireguard(4, 31)));
        // ChannelData 0x4001 around a handshake initiation.
        let mut channel = vec![0x40, 0x01, 0x00, 148];
        channel.extend_from_slice(&init);
        assert!(carries_wireguard(&channel));
        // A Send indication (0x0016) with XOR-PEER-ADDRESS, then DATA.
        let mut body = vec![0x00, 0x12, 0x00, 0x08, 0, 1, 0, 0, 1, 2, 3, 4];
        body.extend_from_slice(&[0x00, 0x13, 0x00, 148]);
        body.extend_from_slice(&init);
        let mut send = vec![0x00, 0x16];
        send.extend_from_slice(&(body.len() as u16).to_be_bytes());
        send.extend_from_slice(&[0x21, 0x12, 0xA4, 0x42]);
        send.extend_from_slice(&[7; 12]);
        send.extend_from_slice(&body);
        assert!(carries_wireguard(&send));
        // STUN Binding request and success, TURN Allocate success: not WireGuard.
        let binding = cmux_transport::stun::binding_request([9; 12]);
        assert!(!carries_wireguard(&binding));
        let success = cmux_transport::stun::binding_success([9; 12], "198.51.100.7:4000".parse().unwrap());
        assert!(!carries_wireguard(&success));
        let mut allocate = vec![0x01, 0x03, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42];
        allocate.extend_from_slice(&[1; 12]);
        assert!(!carries_wireguard(&allocate));
        // ChannelData around something else (not this tunnel's).
        assert!(!carries_wireguard(&[0x40, 0x01, 0x00, 0x04, 9, 9, 9, 9]));
    }
}
