//! Replies leave from the address the peer dialed.
//!
//! The tunnel socket is bound to `0.0.0.0`, so the OS picks a reply's source
//! address from its routing table. A Mac on the same subnet twice (Wi-Fi
//! `en0` 172.20.21.231 and USB Ethernet `en7` 172.20.21.235, two default
//! routes) answers a phone that dialed `.231` from `.235`: the phone's link
//! sees its peer at an address it never dialed, its route selector moves
//! there, the next reply comes from the other one, and the tunnel flaps.
//!
//! With `IP_PKTINFO` (Linux and Darwin) every received datagram says which
//! local address it arrived at; replies to that peer address go out from the
//! address its latest datagram arrived at. A peer probing both of our
//! addresses hears each probe's answer from the address it probed (its path
//! table credits a path by the source it hears), and a peer on one path
//! hears one stable source. Until a peer is heard the OS picks, as before.

use std::collections::HashMap;
use std::io;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::os::fd::AsRawFd;
use std::sync::Mutex;
use std::time::Instant;

/// Peer addresses remembered at once (the oldest goes first).
const MAX_PEERS: usize = 64;

#[derive(Debug, Clone, Copy)]
struct Arrival {
    local: Ipv4Addr,
    heard: Instant,
}

/// The local address each peer address's datagrams arrive at.
#[derive(Debug, Default)]
pub(super) struct ReplySource {
    arrivals: Mutex<HashMap<SocketAddr, Arrival>>,
}

impl ReplySource {
    /// Turns on `IP_PKTINFO` for an IPv4 socket; `None` when the OS refuses.
    pub(super) fn enable(socket: &impl AsRawFd) -> Option<Self> {
        let on: libc::c_int = 1;
        // SAFETY: a valid fd and a c_int option value of the right size.
        let result = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::IPPROTO_IP,
                libc::IP_PKTINFO,
                (&raw const on).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
        (result == 0).then(Self::default)
    }

    /// A datagram from `peer` arrived at local address `local`.
    pub(super) fn note(&self, peer: SocketAddr, local: Ipv4Addr, now: Instant) {
        if local.is_unspecified() || local.is_multicast() || local.is_broadcast() {
            return;
        }
        let mut arrivals = self.arrivals.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match arrivals.get_mut(&peer) {
            Some(arrival) => *arrival = Arrival { local, heard: now },
            None => {
                if arrivals.len() >= MAX_PEERS
                    && let Some(oldest) =
                        arrivals.iter().min_by_key(|(_, arrival)| arrival.heard).map(|(k, _)| *k)
                {
                    arrivals.remove(&oldest);
                }
                arrivals.insert(peer, Arrival { local, heard: now });
            }
        }
    }

    /// The source address replies to `peer` leave from, if one is known.
    pub(super) fn source_for(&self, peer: SocketAddr) -> Option<Ipv4Addr> {
        self.arrivals
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&peer)
            .map(|arrival| arrival.local)
    }

    /// The source went away (a roam took the address): plain sends again.
    pub(super) fn forget(&self, peer: SocketAddr) {
        self.arrivals.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&peer);
    }
}

/// Room for one `in_pktinfo` control message (and a spare one).
#[repr(C, align(8))]
struct Control([u8; 128]);

/// `recvmsg` on a nonblocking IPv4 socket: the length, the source, and the
/// local address the datagram arrived at (when the OS said).
pub(super) fn recv(
    fd: &impl AsRawFd,
    buffer: &mut [u8],
) -> io::Result<(usize, SocketAddr, Option<Ipv4Addr>)> {
    // SAFETY: every pointer handed to recvmsg points into a live local of the
    // size given; the control messages are read only within `msg_controllen`.
    unsafe {
        let mut source: libc::sockaddr_in = std::mem::zeroed();
        let mut iov = libc::iovec { iov_base: buffer.as_mut_ptr().cast(), iov_len: buffer.len() };
        let mut control = Control([0; 128]);
        let mut message: libc::msghdr = std::mem::zeroed();
        message.msg_name = (&raw mut source).cast();
        message.msg_namelen = std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t;
        message.msg_iov = &raw mut iov;
        message.msg_iovlen = 1;
        message.msg_control = control.0.as_mut_ptr().cast();
        message.msg_controllen = control.0.len() as _;
        let len = libc::recvmsg(fd.as_raw_fd(), &raw mut message, 0);
        if len < 0 {
            return Err(io::Error::last_os_error());
        }
        if libc::c_int::from(source.sin_family) != libc::AF_INET {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "not an IPv4 source"));
        }
        let from = SocketAddr::V4(SocketAddrV4::new(
            Ipv4Addr::from(u32::from_be(source.sin_addr.s_addr)),
            u16::from_be(source.sin_port),
        ));
        let mut local = None;
        let mut header = libc::CMSG_FIRSTHDR(&raw const message);
        while !header.is_null() {
            if (*header).cmsg_level == libc::IPPROTO_IP && (*header).cmsg_type == libc::IP_PKTINFO {
                let info: libc::in_pktinfo = std::ptr::read_unaligned(libc::CMSG_DATA(header).cast());
                local = Some(Ipv4Addr::from(u32::from_be(info.ipi_addr.s_addr)));
            }
            header = libc::CMSG_NXTHDR(&raw const message, header);
        }
        Ok((len as usize, from, local))
    }
}

/// `sendmsg` to `target` from source address `local` (`IP_PKTINFO`'s
/// `ipi_spec_dst`; no interface index, so the OS routes it, from that address).
pub(super) fn send_from(
    fd: &impl AsRawFd,
    datagram: &[u8],
    target: SocketAddrV4,
    local: Ipv4Addr,
) -> io::Result<usize> {
    // SAFETY: as in `recv`; the one control message is written within the
    // buffer, at CMSG_FIRSTHDR, with CMSG_LEN of an `in_pktinfo`.
    unsafe {
        let mut destination: libc::sockaddr_in = std::mem::zeroed();
        destination.sin_family = libc::AF_INET as libc::sa_family_t;
        destination.sin_port = target.port().to_be();
        destination.sin_addr.s_addr = u32::from(*target.ip()).to_be();
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        {
            destination.sin_len = std::mem::size_of::<libc::sockaddr_in>() as u8;
        }
        let mut iov = libc::iovec { iov_base: datagram.as_ptr().cast_mut().cast(), iov_len: datagram.len() };
        let mut control = Control([0; 128]);
        let space = libc::CMSG_SPACE(std::mem::size_of::<libc::in_pktinfo>() as u32) as usize;
        let mut message: libc::msghdr = std::mem::zeroed();
        message.msg_name = (&raw mut destination).cast();
        message.msg_namelen = std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t;
        message.msg_iov = &raw mut iov;
        message.msg_iovlen = 1;
        message.msg_control = control.0.as_mut_ptr().cast();
        message.msg_controllen = space as _;
        let header = libc::CMSG_FIRSTHDR(&raw const message);
        (*header).cmsg_level = libc::IPPROTO_IP;
        (*header).cmsg_type = libc::IP_PKTINFO;
        (*header).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<libc::in_pktinfo>() as u32) as _;
        let mut info: libc::in_pktinfo = std::mem::zeroed();
        info.ipi_spec_dst.s_addr = u32::from(local).to_be();
        std::ptr::write_unaligned(libc::CMSG_DATA(header).cast(), info);
        let sent = libc::sendmsg(fd.as_raw_fd(), &raw const message, 0);
        if sent < 0 { Err(io::Error::last_os_error()) } else { Ok(sent as usize) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replies_follow_the_address_the_latest_datagram_arrived_at() {
        let source = ReplySource::default();
        let peer: SocketAddr = "172.20.21.50:40000".parse().unwrap();
        let other: SocketAddr = "172.20.21.51:40000".parse().unwrap();
        let wifi = Ipv4Addr::new(172, 20, 21, 231);
        let wired = Ipv4Addr::new(172, 20, 21, 235);
        let start = Instant::now();
        assert_eq!(source.source_for(peer), None, "an unheard peer has a source");
        source.note(peer, wifi, start);
        source.note(other, wired, start);
        assert_eq!(source.source_for(peer), Some(wifi));
        source.note(peer, wired, start + std::time::Duration::from_millis(500));
        assert_eq!(source.source_for(peer), Some(wired), "a probe to .235 would be answered from .231");
        assert_eq!(source.source_for(other), Some(wired));
        source.note(peer, Ipv4Addr::UNSPECIFIED, start);
        assert_eq!(source.source_for(peer), Some(wired));
        source.forget(peer);
        assert_eq!(source.source_for(peer), None);
    }
}
