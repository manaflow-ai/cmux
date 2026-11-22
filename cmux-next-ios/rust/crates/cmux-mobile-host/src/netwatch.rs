//! The Mac's own network changes: when its primary address changes (another
//! Wi-Fi, Ethernet unplugged, back from sleep on another network) every live
//! WireGuard session roams (cmux-mobile-link `dial::wireguard::network_changed`), so
//! phones keep their sessions.
//!
//! macOS reports address and interface changes on a routing socket
//! (`PF_ROUTE`): no polling. A burst of messages is coalesced over
//! [`SETTLE`]; then, if the addresses a phone can reach the Mac on changed
//! ([`reachable_addresses`]), signaling and the live endpoints are refreshed.
//! An address that comes and goes on a VM bridge, AWDL or a link-local
//! interface is no change: on cosmic-gray a VM bridge's IPv6 address came and
//! went every 84 s (43 refreshes an hour), and each refresh reconnected the
//! Mac's signaling and roamed every live phone link, which then died of its
//! keepalive about 30 s later (every phone link alive across one, 2 of 2,
//! 2026-11-22). The app's wake (`changed`) still refreshes unconditionally.

use std::sync::OnceLock;
use std::time::Duration;
use tokio::sync::watch;

static CHANGES: OnceLock<watch::Sender<u64>> = OnceLock::new();

/// Coalesced wake/network events. Retaining a generation also interrupts a retry delay.
pub fn changes() -> watch::Receiver<u64> {
    CHANGES.get_or_init(|| watch::channel(0).0).subscribe()
}

/// Called by the app on wake and the routing socket after network changes.
pub fn changed() {
    CHANGES
        .get_or_init(|| watch::channel(0).0)
        .send_modify(|generation| *generation = generation.wrapping_add(1));
}

/// One refresh at a time; events during a refresh coalesce into the next turn.
/// The host loop owns and aborts this task on removal/shutdown. It does not wait
/// for signaling, so a backend outage cannot prevent live tunnels from roaming.
pub async fn refresh_endpoints(mut events: watch::Receiver<u64>) {
    while events.changed().await.is_ok() {
        for (session, timeline) in cmux_mobile_link::dial::wireguard::network_changed().await {
            tracing::info!(session, timings = %timeline.summary(), "roamed");
        }
    }
}

/// How long a burst of routing messages may last before the change is
/// judged (an interface coming up adds and removes several addresses).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const SETTLE: Duration = Duration::from_millis(400);

/// Watch until the process stops. Does nothing where there is no routing
/// socket.
pub async fn run() {
    #[cfg(target_os = "macos")]
    if let Err(error) = watch().await {
        tracing::warn!(%error, "network watcher stopped; WireGuard sessions roam only when the phone moves");
    }
}

#[cfg(target_os = "macos")]
async fn watch() -> std::io::Result<()> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use tokio::io::Interest;
    use tokio::io::unix::AsyncFd;

    // SAFETY: plain socket(2); the descriptor is owned right below.
    let fd = unsafe { libc::socket(libc::PF_ROUTE, libc::SOCK_RAW, libc::AF_UNSPEC) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: `fd` is a fresh descriptor nobody else owns.
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    // SAFETY: fcntl on our own descriptor.
    unsafe {
        let flags = libc::fcntl(fd.as_raw_fd(), libc::F_GETFL);
        libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
    let socket = AsyncFd::with_interest(fd, Interest::READABLE)?;
    let mut buffer = vec![0u8; 2048];
    let mut known = reachable_addresses();
    loop {
        // Wait for a message about addresses or interfaces.
        loop {
            let len = read(&socket, &mut buffer).await?;
            if relevant(&buffer[..len]) {
                break;
            }
        }
        // Let the burst settle, draining what else arrives meanwhile.
        let settle = tokio::time::sleep(SETTLE);
        tokio::pin!(settle);
        loop {
            tokio::select! {
                () = &mut settle => break,
                read = read(&socket, &mut buffer) => { read?; }
            }
        }
        let now = reachable_addresses();
        if now.is_some() && now == known {
            tracing::debug!("an address changed on a local-only interface; nothing to refresh");
            continue;
        }
        known = now;
        tracing::info!("the Mac's network changed; refreshing signaling and endpoints");
        changed();
    }
}

/// The addresses a phone could reach this Mac on: every address of an up,
/// running interface that [`counts`]. Read after a burst settles; equal
/// before and after means the change was on an interface no phone uses.
/// None when the addresses cannot be read: then every change refreshes.
#[cfg(target_os = "macos")]
fn reachable_addresses() -> Option<std::collections::BTreeSet<(String, std::net::IpAddr)>> {
    let mut out = std::collections::BTreeSet::new();
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs fills `head` with a list we free below.
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return None;
    }
    let mut cursor = head;
    while !cursor.is_null() {
        // SAFETY: `cursor` walks the list getifaddrs returned, freed only after the loop.
        let entry = unsafe { &*cursor };
        cursor = entry.ifa_next;
        if entry.ifa_addr.is_null() || entry.ifa_name.is_null() {
            continue;
        }
        // SAFETY: a non-null, NUL-terminated name from getifaddrs.
        let name = unsafe { std::ffi::CStr::from_ptr(entry.ifa_name) }.to_string_lossy().into_owned();
        // SAFETY: `ifa_addr` is non-null; its family says which sockaddr it is.
        let addr = unsafe {
            match i32::from((*entry.ifa_addr).sa_family) {
                libc::AF_INET => {
                    let v4 = &*entry.ifa_addr.cast::<libc::sockaddr_in>();
                    std::net::IpAddr::from(u32::from_be(v4.sin_addr.s_addr).to_be_bytes())
                }
                libc::AF_INET6 => {
                    let v6 = &*entry.ifa_addr.cast::<libc::sockaddr_in6>();
                    std::net::IpAddr::from(v6.sin6_addr.s6_addr)
                }
                _ => continue,
            }
        };
        if counts(&name, entry.ifa_flags, addr) {
            out.insert((name, addr));
        }
    }
    // SAFETY: the list from getifaddrs above, freed once.
    unsafe { libc::freeifaddrs(head) };
    Some(out)
}

/// Interfaces no phone reaches the Mac through: VM and Internet Sharing
/// bridges (`bridge`, `vmenet`, `feth`), AWDL and its low-latency link
/// (`awdl`, `llw`), the Mac's own Wi-Fi access point (`ap`), the Apple
/// silicon debug links (`anpi`), tunnels kept for IPv6 transition (`gif`,
/// `stf`) and loopback.
const LOCAL_ONLY: [&str; 10] = ["bridge", "vmenet", "feth", "awdl", "llw", "ap", "anpi", "gif", "stf", "lo"];

/// Whether one interface address is one a phone could reach this Mac on: the
/// interface is up and running, not one of [`LOCAL_ONLY`], and the address is
/// not link-local (169.254/16, fe80::/10) or loopback.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn counts(name: &str, flags: u32, addr: std::net::IpAddr) -> bool {
    const UP: u32 = 0x1; // IFF_UP
    const LOOPBACK: u32 = 0x8; // IFF_LOOPBACK
    const RUNNING: u32 = 0x40; // IFF_RUNNING
    if flags & UP == 0 || flags & RUNNING == 0 || flags & LOOPBACK != 0 {
        return false;
    }
    let kind = name.trim_end_matches(|c: char| c.is_ascii_digit());
    if LOCAL_ONLY.contains(&kind) {
        return false;
    }
    match addr {
        std::net::IpAddr::V4(v4) => !v4.is_link_local() && !v4.is_loopback() && !v4.is_unspecified(),
        std::net::IpAddr::V6(v6) => {
            (v6.segments()[0] & 0xffc0) != 0xfe80 && !v6.is_loopback() && !v6.is_unspecified()
        }
    }
}

#[cfg(target_os = "macos")]
async fn read(
    socket: &tokio::io::unix::AsyncFd<std::os::fd::OwnedFd>,
    buffer: &mut [u8],
) -> std::io::Result<usize> {
    use std::os::fd::AsRawFd;
    loop {
        let mut guard = socket.readable().await?;
        let result = guard.try_io(|fd| {
            // SAFETY: reading into our own buffer from our own descriptor.
            let n = unsafe { libc::read(fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
            if n < 0 { Err(std::io::Error::last_os_error()) } else { Ok(n as usize) }
        });
        match result {
            Ok(read) => return read,
            Err(_would_block) => continue,
        }
    }
}

/// Whether a routing message is about addresses or interfaces (`rtm_type`
/// is the fourth byte of every routing message header).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn relevant(message: &[u8]) -> bool {
    #[cfg(target_os = "macos")]
    const TYPES: [u8; 3] = [libc::RTM_NEWADDR as u8, libc::RTM_DELADDR as u8, libc::RTM_IFINFO as u8];
    #[cfg(not(target_os = "macos"))]
    const TYPES: [u8; 3] = [0xc, 0xd, 0xe];
    message.len() >= 4 && TYPES.contains(&message[3])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_and_interface_messages_are_relevant() {
        // msglen (2), version (1), type (1).
        assert!(relevant(&[0x40, 0, 5, 0xc]));
        assert!(relevant(&[0x40, 0, 5, 0xd]));
        assert!(relevant(&[0x40, 0, 5, 0xe]));
        // RTM_ADD, RTM_MISS: route churn, not a network change.
        assert!(!relevant(&[0x40, 0, 5, 0x1]));
        assert!(!relevant(&[0x40, 0, 5, 0x7]));
        assert!(!relevant(&[0x40, 0]));
    }

    const UP_RUNNING: u32 = 0x1 | 0x40;

    #[test]
    fn a_vm_bridge_or_link_local_address_is_not_a_network_change() {
        // cosmic-gray, 2026-11-22: this address came and went on bridge0 every 84 s.
        let bridge_v6: std::net::IpAddr = "fd3b:55e7:c578:637e:86d:660c:a307:f086".parse().unwrap();
        assert!(!counts("bridge0", UP_RUNNING, bridge_v6));
        assert!(!counts("bridge100", UP_RUNNING, "192.168.64.1".parse().unwrap()));
        assert!(!counts("awdl0", UP_RUNNING, "fe80::1".parse().unwrap()));
        assert!(!counts("llw0", UP_RUNNING, "2001:db8::1".parse().unwrap()));
        assert!(!counts("ap1", UP_RUNNING, "10.0.0.1".parse().unwrap()));
        assert!(!counts("en4", UP_RUNNING, "169.254.77.221".parse().unwrap()));
        assert!(!counts("en0", UP_RUNNING, "fe80::14d7:a4e9:d868:2ca8".parse().unwrap()));
        assert!(!counts("lo0", UP_RUNNING | 0x8, "127.0.0.1".parse().unwrap()));
    }

    #[test]
    fn the_macs_own_network_addresses_are_a_network_change() {
        assert!(counts("en0", UP_RUNNING, "172.20.21.236".parse().unwrap()));
        assert!(counts("en7", UP_RUNNING, "fd06:f739:7522:42ac:1476:69f2:525c:daa9".parse().unwrap()));
        assert!(counts("en0", UP_RUNNING, "2001:db8::5".parse().unwrap()));
        // A VPN the Mac routes through (Tailscale here).
        assert!(counts("utun16", UP_RUNNING, "100.84.217.73".parse().unwrap()));
        // An interface that went down drops out of the set: a change.
        assert!(!counts("en0", 0x1, "172.20.21.236".parse().unwrap()));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn reading_the_addresses_twice_without_a_change_is_equal() {
        let first = reachable_addresses();
        assert!(first.is_some());
        assert_eq!(first, reachable_addresses());
    }
}
