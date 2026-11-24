//! Wi-Fi and cell together (ultra-connectivity P3, RFD 0164 B6).
//!
//! The platform tells the link which interfaces are up ([`set_interfaces`],
//! from iOS `NWPathMonitor`, one entry per interface); the policy is here.
//! When the primary interface is not cellular and a cellular interface is
//! up too, every live session that the peer can take it on
//! ([`MULTIPATH_VERSION`]) gets a second UDP socket bound to the cellular
//! interface. Its routes are probed like the primary socket's, but kept
//! out of the session's path selector: they never carry bulk while a path
//! on the primary interface lives. What they do carry:
//!
//! - every [`crate::class_queue::SendClass::Input`] datagram (keystrokes,
//!   small echo, TCP ACKs, class 0 and 1 datagrams) a second time, so a
//!   Wi-Fi that stalls or dies loses no keystroke and no echo;
//! - everything, while no primary path is alive (the selector holds none or
//!   suspects its route): the session rides cell from the first unanswered
//!   probe, not after a roam;
//! - the session itself once Wi-Fi is gone: [`set_interfaces`] without the
//!   primary promotes the warm socket (its NAT mapping is open and the peer
//!   already probes it), so the move costs no handshake and no new mapping.
//!
//! The peer learns which of the phone's addresses are cellular from the
//! roam announcement's `metered` list and keeps them out of its own
//! selector the same way: it duplicates its echo onto them, and moves bulk
//! there only when nothing else is alive.
//!
//! Off when the person turned it off ([`set_cellular_assist`]), in Low Data
//! Mode (a constrained interface), and while the app is backgrounded.

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use serde::{Deserialize, Serialize};

/// The `wg-offer` / `wg-answer` protocol version at which a side takes a
/// second socket's datagrams and the `metered` announcement list.
pub const MULTIPATH_VERSION: u32 = 3;

/// What an interface is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InterfaceKind {
    Wifi,
    Cellular,
    Wired,
    Other,
}

/// One network interface that is up, as the platform sees it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetInterface {
    /// The BSD name (`en0`, `pdp_ip0`; Linux `wlan0`, `wwan0`).
    pub name: String,
    pub kind: InterfaceKind,
    /// The OS marks it expensive (cellular, a personal hotspot).
    pub expensive: bool,
    /// Low Data Mode is on for it.
    pub constrained: bool,
    /// The OS's preferred interface (the default route).
    pub primary: bool,
}

/// The interfaces up now, as the platform last said.
static INTERFACES: Mutex<Vec<NetInterface>> = Mutex::new(Vec::new());
/// The person allows cell beside Wi-Fi (on unless they turn it off).
static CELLULAR_ASSIST: AtomicBool = AtomicBool::new(true);

/// The platform's interfaces changed. Every live session gets or drops its
/// second socket at once, and one whose primary interface went away moves
/// onto its warm second socket.
pub fn set_interfaces(interfaces: Vec<NetInterface>) {
    *INTERFACES.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = interfaces;
    super::apply_multipath_to_live_sessions();
}

/// The interfaces [`set_interfaces`] stored last.
pub fn interfaces() -> Vec<NetInterface> {
    INTERFACES.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
}

/// The person's setting: cell carries a second copy of keystrokes and echo
/// while Wi-Fi is up.
pub fn set_cellular_assist(allowed: bool) {
    CELLULAR_ASSIST.store(allowed, Ordering::Relaxed);
    super::apply_multipath_to_live_sessions();
}

pub fn cellular_assist() -> bool {
    CELLULAR_ASSIST.load(Ordering::Relaxed)
}

/// The interface a second socket should be bound to, if any: a cellular
/// interface beside a primary that is not cellular, with nothing in Low
/// Data Mode, the person's consent and the app in the foreground.
pub fn secondary_interface(
    interfaces: &[NetInterface],
    allowed: bool,
    backgrounded: bool,
) -> Option<NetInterface> {
    if !allowed || backgrounded || interfaces.iter().any(|interface| interface.constrained) {
        return None;
    }
    let primary = interfaces.iter().find(|interface| interface.primary)?;
    if primary.kind == InterfaceKind::Cellular {
        return None;
    }
    interfaces
        .iter()
        .find(|interface| interface.kind == InterfaceKind::Cellular && !interface.primary)
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn up(name: &str, kind: InterfaceKind, primary: bool) -> NetInterface {
        NetInterface {
            name: name.into(),
            kind,
            expensive: kind == InterfaceKind::Cellular,
            constrained: false,
            primary,
        }
    }

    #[test]
    fn cell_beside_wifi_is_the_second_interface() {
        let both = [up("en0", InterfaceKind::Wifi, true), up("pdp_ip0", InterfaceKind::Cellular, false)];
        assert_eq!(secondary_interface(&both, true, false).map(|i| i.name), Some("pdp_ip0".into()));
    }

    #[test]
    fn no_second_interface_when_off_backgrounded_constrained_or_on_cell() {
        let both = [up("en0", InterfaceKind::Wifi, true), up("pdp_ip0", InterfaceKind::Cellular, false)];
        assert_eq!(secondary_interface(&both, false, false), None);
        assert_eq!(secondary_interface(&both, true, true), None);
        let mut low_data = both.clone();
        low_data[0].constrained = true;
        assert_eq!(secondary_interface(&low_data, true, false), None);
        let cell_only = [up("pdp_ip0", InterfaceKind::Cellular, true)];
        assert_eq!(secondary_interface(&cell_only, true, false), None);
        let wifi_only = [up("en0", InterfaceKind::Wifi, true)];
        assert_eq!(secondary_interface(&wifi_only, true, false), None);
    }
}
