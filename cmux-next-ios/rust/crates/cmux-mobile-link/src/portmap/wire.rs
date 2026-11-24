//! PCP (RFC 6887) and NAT-PMP (RFC 6886) over UDP to the gateway: MAP requests for one UDP
//! port, their answers, and the delete (lifetime 0). Pure codecs plus one request/answer
//! exchange with the RFCs' retransmission, shortened to a configured step.

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::Duration;

use tokio::net::UdpSocket;

use super::{Failure, Granted};

/// UDP in the MAP request's protocol byte.
const UDP: u8 = 17;

/// A PCP MAP request (60 bytes) for UDP `internal` on this host (`client`).
pub(super) fn pcp_request(
    client: Ipv4Addr,
    nonce: [u8; 12],
    internal: u16,
    suggested: u16,
    lifetime: u32,
) -> [u8; 60] {
    let mut out = [0u8; 60];
    out[0] = 2; // version
    out[1] = 1; // request, opcode MAP
    out[4..8].copy_from_slice(&lifetime.to_be_bytes());
    out[8..24].copy_from_slice(&client.to_ipv6_mapped().octets());
    out[24..36].copy_from_slice(&nonce);
    out[36] = UDP;
    out[40..42].copy_from_slice(&internal.to_be_bytes());
    out[42..44].copy_from_slice(&suggested.to_be_bytes());
    // Suggested external address ::ffff:0.0.0.0 ("any"), as RFC 6887 allows for IPv4.
    out[44..60].copy_from_slice(&Ipv4Addr::UNSPECIFIED.to_ipv6_mapped().octets());
    out
}

/// What a gateway answered to a PCP MAP request.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum PcpAnswer {
    Granted(Granted),
    /// A NAT-PMP-only gateway (version 0 reply) or a PCP one that refuses version 2.
    Unsupported,
    Refused(u8),
}

/// Parse a PCP answer to the request made with `nonce` and `internal`; `None` when it is not an
/// answer to that request (another packet, another nonce).
pub(super) fn parse_pcp(packet: &[u8], nonce: [u8; 12], internal: u16) -> Option<PcpAnswer> {
    if packet.len() < 24 {
        return None;
    }
    if packet[0] == 0 {
        // A NAT-PMP gateway answering version 2 with its own unsupported-version reply.
        return (packet[1] == 128 || packet[1] == 0x81).then_some(PcpAnswer::Unsupported);
    }
    if packet[0] != 2 || packet[1] != 0x81 {
        return None;
    }
    let result = packet[3];
    if result == 1 {
        return Some(PcpAnswer::Unsupported);
    }
    if packet.len() < 60
        || packet[24..36] != nonce
        || u16::from_be_bytes([packet[40], packet[41]]) != internal
    {
        return None;
    }
    if result != 0 {
        return Some(PcpAnswer::Refused(result));
    }
    let lifetime = u32::from_be_bytes([packet[4], packet[5], packet[6], packet[7]]);
    let port = u16::from_be_bytes([packet[42], packet[43]]);
    let octets: [u8; 16] = packet[44..60].try_into().ok()?;
    let address = std::net::Ipv6Addr::from(octets);
    let ip = address.to_ipv4_mapped().or_else(|| address.to_ipv4())?;
    Some(PcpAnswer::Granted(Granted {
        external: SocketAddrV4::new(ip, port),
        lifetime: Duration::from_secs(u64::from(lifetime)),
    }))
}

/// A NAT-PMP UDP map request (12 bytes); `lifetime` 0 with `suggested` 0 deletes.
pub(super) fn natpmp_map_request(internal: u16, suggested: u16, lifetime: u32) -> [u8; 12] {
    let mut out = [0u8; 12];
    out[1] = 1; // map UDP
    out[4..6].copy_from_slice(&internal.to_be_bytes());
    out[6..8].copy_from_slice(&suggested.to_be_bytes());
    out[8..12].copy_from_slice(&lifetime.to_be_bytes());
    out
}

/// NAT-PMP's external address request (2 bytes).
pub(super) const NATPMP_ADDRESS_REQUEST: [u8; 2] = [0, 0];

/// The external address of a NAT-PMP address answer.
pub(super) fn parse_natpmp_address(packet: &[u8]) -> Option<Result<Ipv4Addr, u16>> {
    if packet.len() < 12 || packet[0] != 0 || packet[1] != 128 {
        return None;
    }
    let result = u16::from_be_bytes([packet[2], packet[3]]);
    if result != 0 {
        return Some(Err(result));
    }
    Some(Ok(Ipv4Addr::new(packet[8], packet[9], packet[10], packet[11])))
}

/// The mapped port and lifetime of a NAT-PMP map answer for `internal`.
pub(super) fn parse_natpmp_map(packet: &[u8], internal: u16) -> Option<Result<(u16, Duration), u16>> {
    if packet.len() < 16 || packet[0] != 0 || packet[1] != 129 {
        return None;
    }
    if u16::from_be_bytes([packet[8], packet[9]]) != internal {
        return None;
    }
    let result = u16::from_be_bytes([packet[2], packet[3]]);
    if result != 0 {
        return Some(Err(result));
    }
    let port = u16::from_be_bytes([packet[10], packet[11]]);
    let lifetime = u32::from_be_bytes([packet[12], packet[13], packet[14], packet[15]]);
    Some(Ok((port, Duration::from_secs(u64::from(lifetime)))))
}

/// Send `request` to `to` and wait for an answer `accept` takes: three tries, the wait doubling
/// from `step` (RFC 6886 starts at 250 ms and doubles; the tries are fewer so a gateway with no
/// mapping service costs a second or two, in the background).
async fn exchange<T>(
    socket: &UdpSocket,
    request: &[u8],
    step: Duration,
    accept: impl Fn(&[u8]) -> Option<T>,
) -> Option<T> {
    let mut wait = step;
    let mut buffer = [0u8; 128];
    for _ in 0..3 {
        socket.send(request).await.ok()?;
        let deadline = tokio::time::Instant::now() + wait;
        while let Ok(Ok(len)) = tokio::time::timeout_at(deadline, socket.recv(&mut buffer)).await {
            if let Some(found) = accept(&buffer[..len]) {
                return Some(found);
            }
        }
        wait *= 2;
    }
    None
}

/// A socket connected to the gateway's mapping port, and the address this host uses toward it.
pub(super) async fn connect(to: SocketAddr) -> std::io::Result<(UdpSocket, Ipv4Addr)> {
    let socket = UdpSocket::bind("0.0.0.0:0").await?;
    socket.connect(to).await?;
    let local = match socket.local_addr()? {
        SocketAddr::V4(addr) => *addr.ip(),
        SocketAddr::V6(_) => Ipv4Addr::UNSPECIFIED,
    };
    Ok((socket, local))
}

/// Ask a PCP gateway for a mapping of UDP `internal`.
pub(super) async fn pcp_map(
    to: SocketAddr,
    nonce: [u8; 12],
    internal: u16,
    suggested: u16,
    lifetime: u32,
    step: Duration,
) -> Result<Granted, Failure> {
    let (socket, client) = connect(to).await.map_err(|_| Failure::Silent)?;
    let request = pcp_request(client, nonce, internal, suggested, lifetime);
    match exchange(&socket, &request, step, |packet| parse_pcp(packet, nonce, internal)).await {
        Some(PcpAnswer::Granted(granted)) => Ok(granted),
        Some(PcpAnswer::Unsupported) => Err(Failure::Unsupported),
        Some(PcpAnswer::Refused(code)) => Err(Failure::Refused(u32::from(code))),
        None => Err(Failure::Silent),
    }
}

/// Ask a NAT-PMP gateway for a mapping of UDP `internal` and for its external address.
pub(super) async fn natpmp_map(
    to: SocketAddr,
    internal: u16,
    suggested: u16,
    lifetime: u32,
    step: Duration,
) -> Result<Granted, Failure> {
    let (socket, _) = connect(to).await.map_err(|_| Failure::Silent)?;
    let address = exchange(&socket, &NATPMP_ADDRESS_REQUEST, step, parse_natpmp_address)
        .await
        .ok_or(Failure::Silent)?;
    let ip = address.map_err(|code| Failure::Refused(u32::from(code)))?;
    let request = natpmp_map_request(internal, suggested, lifetime);
    let answer = exchange(&socket, &request, step, |packet| parse_natpmp_map(packet, internal))
        .await
        .ok_or(Failure::Silent)?;
    let (port, lifetime) = answer.map_err(|code| Failure::Refused(u32::from(code)))?;
    Ok(Granted { external: SocketAddrV4::new(ip, port), lifetime })
}

/// Delete a PCP mapping (a MAP with lifetime 0 and the same nonce), without waiting.
pub(super) fn pcp_delete_now(to: SocketAddr, local: Ipv4Addr, nonce: [u8; 12], internal: u16) {
    if let Ok(socket) = std::net::UdpSocket::bind("0.0.0.0:0") {
        let _ = socket.send_to(&pcp_request(local, nonce, internal, 0, 0), to);
    }
}

/// Delete a NAT-PMP mapping (lifetime 0, suggested port 0), without waiting.
pub(super) fn natpmp_delete_now(to: SocketAddr, internal: u16) {
    if let Ok(socket) = std::net::UdpSocket::bind("0.0.0.0:0") {
        let _ = socket.send_to(&natpmp_map_request(internal, 0, 0), to);
    }
}
