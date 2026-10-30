//! The Mac's own network changes: when its primary address changes (another
//! Wi-Fi, Ethernet unplugged, back from sleep on another network) every live
//! WireGuard session roams (cmux-mobile-link `dial::wireguard::network_changed`), so
//! phones keep their sessions.
//!
//! macOS reports address and interface changes on a routing socket
//! (`PF_ROUTE`): no polling. A burst of messages is coalesced over
//! [`SETTLE`], then signaling and the live endpoints are refreshed, even if the local
//! address is unchanged (the NAT or interface may have changed).

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
        tracing::info!("the Mac's network changed; refreshing signaling and endpoints");
        changed();
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
}
