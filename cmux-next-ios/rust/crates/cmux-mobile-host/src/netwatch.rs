//! The Mac's own network changes: when its primary address changes (another
//! Wi-Fi, Ethernet unplugged, back from sleep on another network) every live
//! WireGuard session roams (cmux-mobile-link `dial::wireguard::network_changed`), so
//! phones keep their sessions.
//!
//! macOS reports address and interface changes on a routing socket
//! (`PF_ROUTE`): no polling. A burst of messages is coalesced over
//! [`SETTLE`], then judged: signaling and the live endpoints are refreshed
//! only when the change touched an interface the Mac's sessions use (the
//! primary one, or the one a session's direct path leaves from), even if
//! that interface's address is unchanged (its link flapped; the NAT may have
//! changed). A Mac sits beside many interfaces it never sends a session on
//! (utun tunnels of VPNs and the system, `awdl0` and `llw0` of AirDrop and
//! Sidecar, bridges of VMs and Thunderbolt), and they come and go every
//! minute or two: each used to roam every session onto a fresh socket and
//! TURN allocation and drop signaling (Leo's NIGHTLY, 2026-11-22: "Mac
//! network changed" every 1-2 min on a wired Mac, each one dropping the
//! phone's link to no path and back to TURN).

// The judge runs only on macOS (the routing socket); its tests run everywhere.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use std::collections::{BTreeSet, HashMap};
use std::net::{IpAddr, SocketAddr};
use std::sync::OnceLock;
use std::time::Duration;
use tokio::sync::watch;

static CHANGES: OnceLock<watch::Sender<u64>> = OnceLock::new();

/// Coalesced wake/network events. Retaining a generation also interrupts a retry delay.
pub fn changes() -> watch::Receiver<u64> {
    CHANGES.get_or_init(|| watch::channel(0).0).subscribe()
}

/// Called by the app on wake and by the routing socket's watch after a
/// change it judged relevant ([`resets`]).
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

/// What the judge reads of this Mac: every interface address, the primary
/// (default-route) address, and the local addresses the live sessions'
/// plain UDP leaves from.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct View {
    pub networks: Vec<Network>,
    pub primary: Option<IpAddr>,
    pub sources: Vec<IpAddr>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Network {
    pub interface: String,
    pub address: IpAddr,
    pub prefix: u8,
}

impl View {
    /// This Mac now.
    pub fn now() -> Self {
        let networks = cmux_transport::local_networks()
            .into_iter()
            .map(|net| Network { interface: net.interface, address: net.address, prefix: net.prefix })
            .collect();
        let destinations: Vec<SocketAddr> = cmux_mobile_link::dial::wireguard::route_destinations();
        Self {
            networks,
            primary: cmux_mobile_link::dial::wireguard::primary_local_ip(),
            sources: destinations.iter().filter_map(|to| source_toward(*to)).collect(),
        }
    }

    fn interface_of(&self, ip: IpAddr) -> Option<&str> {
        self.networks.iter().find(|net| net.address == ip).map(|net| net.interface.as_str())
    }

    fn addresses_of(&self, interface: &str) -> BTreeSet<IpAddr> {
        self.networks.iter().filter(|net| net.interface == interface).map(|net| net.address).collect()
    }

    /// The interfaces a session is on: the primary one (signaling, TURN,
    /// every routed path) and the ones the sessions' plain UDP leaves from,
    /// as the OS routes it. A second interface on the same subnet (Leo's Mac:
    /// Ethernet en7 and Wi-Fi en0 both on 172.20.21.0/24) carries nothing
    /// while the routing table sends from the first, so it is not in use.
    fn in_use(&self) -> BTreeSet<String> {
        self.primary
            .iter()
            .chain(&self.sources)
            .filter_map(|ip| self.interface_of(*ip))
            .map(str::to_owned)
            .collect()
    }
}

/// The local address the OS sends from toward `to` (a connected UDP socket;
/// no packet is sent).
fn source_toward(to: SocketAddr) -> Option<IpAddr> {
    let bind = if to.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    let probe = std::net::UdpSocket::bind(bind).ok()?;
    probe.connect(to).ok()?;
    probe.local_addr().ok().map(|addr| addr.ip()).filter(|ip| !ip.is_unspecified())
}

/// Whether a settled burst of routing messages resets the sessions (a roam
/// onto a new socket and TURN allocation, a new signaling socket), and why.
/// `links` names the interfaces whose link (up and running) flipped in the
/// burst. A change on interfaces no session uses resets nothing.
pub(crate) fn resets(before: &View, after: &View, links: &BTreeSet<String>) -> Option<String> {
    if before.primary != after.primary {
        return Some(format!("primary address {:?} -> {:?}", before.primary, after.primary));
    }
    let used: BTreeSet<String> = before.in_use().union(&after.in_use()).cloned().collect();
    if used.is_empty() {
        // No route anywhere (no primary address either way): nothing to keep.
        return (before.networks != after.networks).then(|| "no interface in use".to_owned());
    }
    for interface in &used {
        if before.addresses_of(interface) != after.addresses_of(interface) {
            return Some(format!("addresses of {interface} changed"));
        }
        if links.contains(interface) {
            return Some(format!("link of {interface} changed"));
        }
    }
    None
}

/// What a burst changed, for the log: the primary (default-route) address
/// if it moved, each interface whose addresses changed (before -> after),
/// and each whose link flipped.
pub(crate) fn what_changed(before: &View, after: &View, links: &BTreeSet<String>) -> Vec<String> {
    let mut out = Vec::new();
    if before.primary != after.primary {
        out.push(format!("primary {} -> {}", show(before.primary), show(after.primary)));
    }
    let names: BTreeSet<&str> =
        before.networks.iter().chain(&after.networks).map(|net| net.interface.as_str()).collect();
    for name in names {
        let (was, is) = (before.addresses_of(name), after.addresses_of(name));
        if was != is {
            out.push(format!("{name} {} -> {}", list(&was), list(&is)));
        }
    }
    out.extend(links.iter().map(|name| format!("{name} link flipped")));
    out
}

fn show(ip: Option<IpAddr>) -> String {
    ip.map_or_else(|| "none".to_owned(), |ip| ip.to_string())
}

fn list(ips: &BTreeSet<IpAddr>) -> String {
    if ips.is_empty() {
        return "none".to_owned();
    }
    ips.iter().map(IpAddr::to_string).collect::<Vec<_>>().join(",")
}

/// Link state per interface index, from `RTM_IFINFO` messages: which ones
/// flipped up or down.
#[derive(Debug, Default)]
pub(crate) struct Links {
    flags: HashMap<u16, i32>,
}

/// `IFF_UP | IFF_RUNNING`: the bits that say a link carries traffic.
const LINK_BITS: i32 = 0x1 | 0x40;

impl Links {
    /// Record an `RTM_IFINFO` message; the interface index whose link flipped.
    pub fn record(&mut self, message: &[u8]) -> Option<u16> {
        let (index, flags) = ifinfo(message)?;
        let bits = flags & LINK_BITS;
        let old = self.flags.insert(index, bits);
        old.is_some_and(|old| old != bits).then_some(index)
    }
}

/// `if_msghdr`: msglen (2), version (1), type (1), addrs (4), flags (4),
/// index (2).
fn ifinfo(message: &[u8]) -> Option<(u16, i32)> {
    const RTM_IFINFO: u8 = 0xe;
    if message.len() < 14 || message[3] != RTM_IFINFO {
        return None;
    }
    let flags = i32::from_ne_bytes(message[8..12].try_into().ok()?);
    let index = u16::from_ne_bytes(message[12..14].try_into().ok()?);
    Some((index, flags))
}

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
    let mut seen = View::now();
    let mut links = Links::default();
    loop {
        let mut flipped = BTreeSet::new();
        let mut note = |message: &[u8], flipped: &mut BTreeSet<String>| {
            if let Some(index) = links.record(message) {
                flipped.insert(interface_name(index).unwrap_or_else(|| format!("index {index}")));
            }
        };
        // Wait for a message about addresses or interfaces.
        loop {
            let len = read(&socket, &mut buffer).await?;
            if relevant(&buffer[..len]) {
                note(&buffer[..len], &mut flipped);
                break;
            }
        }
        // Let the burst settle, draining what else arrives meanwhile.
        let settle = tokio::time::sleep(SETTLE);
        tokio::pin!(settle);
        loop {
            let len = tokio::select! {
                () = &mut settle => break,
                read = read(&socket, &mut buffer) => read?,
            };
            note(&buffer[..len], &mut flipped);
        }
        let now = View::now();
        let what = what_changed(&seen, &now, &flipped);
        let in_use = now.in_use();
        match resets(&seen, &now, &flipped) {
            Some(why) => {
                tracing::info!(
                    why,
                    ?what,
                    ?in_use,
                    "the Mac's network changed; refreshing signaling and endpoints"
                );
                changed();
            }
            None => {
                tracing::info!(?what, ?in_use, "network change on interfaces no session uses; nothing reset")
            }
        }
        seen = now;
    }
}

#[cfg(target_os = "macos")]
fn interface_name(index: u16) -> Option<String> {
    let mut name = [0 as libc::c_char; libc::IF_NAMESIZE];
    // SAFETY: if_indextoname writes at most IF_NAMESIZE bytes, NUL included.
    let found = unsafe { libc::if_indextoname(u32::from(index), name.as_mut_ptr()) };
    if found.is_null() {
        return None;
    }
    // SAFETY: on success the buffer holds a NUL-terminated name.
    let name = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) };
    name.to_str().ok().map(str::to_owned)
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

    fn net(interface: &str, address: &str, prefix: u8) -> Network {
        Network { interface: interface.into(), address: address.parse().unwrap(), prefix }
    }

    /// Leo's wired Mac: Ethernet en0 is primary; Wi-Fi en1 joined too; a
    /// Thunderbolt bridge, a VPN utun and AirDrop's awdl0 and llw0 beside.
    fn wired_mac() -> Vec<Network> {
        vec![
            net("en0", "192.168.1.20", 24),
            net("en1", "192.168.1.21", 24),
            net("bridge0", "169.254.10.2", 16),
            net("utun3", "100.70.1.2", 32),
            net("awdl0", "fe80::1", 64),
            net("llw0", "fe80::2", 64),
        ]
    }

    /// One session's direct path to the phone on the LAN, from en0; one on
    /// TURN (no plain UDP destination): the relay hop.
    fn view(networks: Vec<Network>) -> View {
        View {
            networks,
            primary: Some("192.168.1.20".parse().unwrap()),
            sources: vec!["192.168.1.20".parse().unwrap()],
        }
    }

    /// One flap of an interface no session uses: it goes away, or comes
    /// back with another address, or its link flips.
    fn flap(networks: &[Network], step: usize) -> (Vec<Network>, BTreeSet<String>) {
        let names = ["utun3", "awdl0", "llw0", "bridge0", "utun7"];
        let name = names[step % names.len()];
        let mut after: Vec<Network> = networks.iter().filter(|net| net.interface != name).cloned().collect();
        let mut links = BTreeSet::new();
        match step % 3 {
            0 => {}
            1 => after.push(net(name, &format!("100.70.1.{}", 10 + step % 200), 32)),
            _ => {
                after = networks.to_vec();
                links.insert(name.to_owned());
            }
        }
        (after, links)
    }

    #[test]
    fn a_flap_on_an_interface_no_session_uses_resets_nothing() {
        let before = view(wired_mac());
        for step in 0..30 {
            let (networks, links) = flap(&before.networks, step);
            let after = view(networks);
            assert_eq!(resets(&before, &after, &links), None, "step {step}: {links:?}");
        }
    }

    #[test]
    fn a_change_on_an_interface_a_session_uses_resets() {
        let before = view(wired_mac());
        // Ethernet unplugged: the primary moves to Wi-Fi.
        let mut after = view(wired_mac().into_iter().filter(|net| net.interface != "en0").collect());
        after.primary = Some("192.168.1.21".parse().unwrap());
        after.sources = vec!["192.168.1.21".parse().unwrap()];
        assert!(resets(&before, &after, &BTreeSet::new()).is_some());
        // en0 renewed to another address (the primary address moves with it).
        let mut renewed = wired_mac();
        renewed[0] = net("en0", "192.168.1.40", 24);
        let mut after = view(renewed);
        after.primary = Some("192.168.1.40".parse().unwrap());
        assert!(resets(&before, &after, &BTreeSet::new()).is_some());
        // en0 gained a second address, the primary one unchanged.
        let mut more = wired_mac();
        more.push(net("en0", "192.168.1.41", 24));
        assert_eq!(
            resets(&before, &view(more), &BTreeSet::new()).as_deref(),
            Some("addresses of en0 changed")
        );
        // en0's link flapped (same address).
        let links: BTreeSet<String> = ["en0".to_owned()].into();
        assert!(resets(&before, &view(wired_mac()), &links).is_some());
        // A session on the Thunderbolt bridge loses it.
        let mut bridged = view(wired_mac());
        bridged.sources.push("169.254.10.2".parse().unwrap());
        let mut gone = bridged.clone();
        gone.networks.retain(|net| net.interface != "bridge0");
        gone.sources.retain(|ip| ip.to_string() != "169.254.10.2");
        assert_eq!(
            resets(&bridged, &gone, &BTreeSet::new()).as_deref(),
            Some("addresses of bridge0 changed")
        );
        // A session on the VPN's utun sees it change.
        let mut tunneled = view(wired_mac());
        tunneled.sources.push("100.70.1.2".parse().unwrap());
        let mut moved = tunneled.clone();
        moved.networks.retain(|net| net.interface != "utun3");
        moved.networks.push(net("utun3", "100.70.1.9", 32));
        assert!(resets(&tunneled, &moved, &BTreeSet::new()).is_some());
    }

    #[test]
    fn no_network_at_all_resets_on_any_change() {
        let before = View { networks: vec![net("lo0", "127.0.0.1", 8)], ..View::default() };
        let after = View { networks: wired_mac(), ..View::default() };
        assert!(resets(&before, &after, &BTreeSet::new()).is_some());
        assert!(resets(&before, &before, &BTreeSet::new()).is_none());
    }

    /// Resets per 10 minutes under duress: an unrelated interface flaps every
    /// 60-120 s (seeded), with one session direct on the LAN and one on a
    /// relay hop (TURN). Before: every settled burst reset every session.
    #[test]
    fn resets_per_10_min_under_unrelated_flaps() {
        let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        let mut at = 0u64;
        let (mut before_resets, mut after_resets) = (0, 0);
        let mut seen = view(wired_mac());
        let mut step = 0;
        loop {
            at += 60 + next() % 61;
            if at > 600 {
                break;
            }
            let (networks, links) = flap(&wired_mac(), step);
            let now = view(networks);
            // Before: `relevant` alone decided, and every burst was relevant.
            before_resets += 1;
            if resets(&seen, &now, &links).is_some() {
                after_resets += 1;
            }
            seen = now;
            step += 1;
        }
        eprintln!(
            "resets per 10 min (unrelated flap every 60-120 s, relay hop): before {before_resets}, after {after_resets}"
        );
        assert!(before_resets >= 5);
        assert_eq!(after_resets, 0);
    }

    /// Leo's Mac (`scutil --nwi`, 2026-11-22 19:2xZ): Ethernet en7
    /// 172.20.21.235 and Wi-Fi en0 172.20.21.236 on one subnet, en7 primary
    /// and the one the phone's direct path leaves from, plus utun16.
    fn dual_homed() -> View {
        View {
            networks: vec![
                net("en7", "172.20.21.235", 24),
                net("en0", "172.20.21.236", 24),
                net("utun16", "fe80::16", 64),
            ],
            primary: Some("172.20.21.235".parse().unwrap()),
            sources: vec!["172.20.21.235".parse().unwrap()],
        }
    }

    /// The second interface on the same subnet (Wi-Fi beside Ethernet) and
    /// the utun come and go: 0 resets, and the log names what changed.
    #[test]
    fn dual_homed_mac_resets_nothing_on_its_second_interface_or_utun() {
        let before = dual_homed();
        let without = |name: &str| {
            let mut view = dual_homed();
            view.networks.retain(|net| net.interface != name);
            view
        };
        let renewed = {
            let mut view = without("en0");
            view.networks.push(net("en0", "172.20.21.237", 24));
            view
        };
        let none = BTreeSet::new();
        let en0: BTreeSet<String> = ["en0".to_owned()].into();
        let utun: BTreeSet<String> = ["utun16".to_owned()].into();
        let cases = [
            (without("en0"), &none, "en0 172.20.21.236 -> none"),
            (renewed, &none, "en0 172.20.21.236 -> 172.20.21.237"),
            (dual_homed(), &en0, "en0 link flipped"),
            (without("utun16"), &none, "utun16 fe80::16 -> none"),
            (dual_homed(), &utun, "utun16 link flipped"),
        ];
        for (after, links, logged) in cases {
            assert_eq!(resets(&before, &after, links), None, "{logged}");
            assert_eq!(resets(&after, &before, links), None, "back: {logged}");
            assert_eq!(what_changed(&before, &after, links), vec![logged.to_owned()]);
        }
        // The interface the link uses changing still resets, and says so.
        let unplugged = View {
            primary: Some("172.20.21.236".parse().unwrap()),
            sources: vec!["172.20.21.236".parse().unwrap()],
            ..without("en7")
        };
        assert!(resets(&before, &unplugged, &none).is_some());
        assert_eq!(
            what_changed(&before, &unplugged, &none),
            vec!["primary 172.20.21.235 -> 172.20.21.236".to_owned(), "en7 172.20.21.235 -> none".to_owned()]
        );
        let en7: BTreeSet<String> = ["en7".to_owned()].into();
        assert_eq!(resets(&before, &dual_homed(), &en7).as_deref(), Some("link of en7 changed"));
    }

    /// Resets per 10 minutes on Leo's dual-homed Mac under duress: en0 or
    /// utun16 changes every 60-120 s (seeded), the phone's session direct
    /// from en7 and one relay hop. Before: every burst reset.
    #[test]
    fn dual_homed_resets_per_10_min_under_second_interface_flaps() {
        let mut seed: u64 = 0x2545_f491_4f6c_dd1d;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        let (mut at, mut step) = (0u64, 0usize);
        let (mut before_resets, mut after_resets) = (0, 0);
        let mut seen = dual_homed();
        loop {
            at += 60 + next() % 61;
            if at > 600 {
                break;
            }
            let name = ["en0", "utun16"][step % 2];
            let mut now = dual_homed();
            let mut links = BTreeSet::new();
            match step % 3 {
                0 => now.networks.retain(|net| net.interface != name),
                1 => {}
                _ => {
                    links.insert(name.to_owned());
                }
            }
            before_resets += 1;
            if resets(&seen, &now, &links).is_some() {
                after_resets += 1;
            }
            seen = now;
            step += 1;
        }
        eprintln!(
            "dual-homed resets per 10 min (en0/utun16 change every 60-120 s, relay hop): before {before_resets}, after {after_resets}"
        );
        assert!(before_resets >= 5);
        assert_eq!(after_resets, 0);
    }

    #[test]
    fn link_flips_come_from_ifinfo_flags() {
        let message = |flags: i32, index: u16| {
            let mut m = vec![0u8; 112];
            m[3] = 0xe;
            m[8..12].copy_from_slice(&flags.to_ne_bytes());
            m[12..14].copy_from_slice(&index.to_ne_bytes());
            m
        };
        let mut links = Links::default();
        assert_eq!(links.record(&message(0x1 | 0x40 | 0x8000, 4)), None, "first sight");
        assert_eq!(links.record(&message(0x1 | 0x40, 4)), None, "other bits only");
        assert_eq!(links.record(&message(0x1, 4)), Some(4), "not running");
        assert_eq!(links.record(&message(0x1 | 0x40, 4)), Some(4), "running again");
        assert_eq!(links.record(&message(0x1, 5)), None);
        let mut addr = message(0, 4);
        addr[3] = 0xc;
        assert_eq!(links.record(&addr), None, "address messages carry no link state");
    }

    /// A nightly host log, 2026-11-22: a VM bridge's IPv6 address came and
    /// went on bridge0 every 84 s (43 refreshes an hour), and each refresh
    /// roamed every live phone link, which then died of its keepalive about
    /// 30 s later. With no session on bridge0, neither direction resets; a
    /// session that does leave from bridge0 still resets.
    #[test]
    fn a_vm_bridge_address_coming_and_going_resets_nothing() {
        let before = view(wired_mac());
        let mut after = view(wired_mac());
        after.networks.push(net("bridge0", "fd3b:55e7:c578:637e:86d:660c:a307:f086", 64));
        after.networks.push(net("bridge100", "192.168.64.1", 24));
        assert_eq!(resets(&before, &after, &BTreeSet::new()), None, "address came");
        assert_eq!(resets(&after, &before, &BTreeSet::new()), None, "address went");
        let mut bridged = after.clone();
        bridged.sources.push("192.168.64.1".parse().unwrap());
        let mut gone = before.clone();
        gone.sources = bridged.sources.clone();
        assert!(resets(&bridged, &gone, &BTreeSet::new()).is_some(), "a session on the bridge");
    }
}
