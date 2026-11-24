//! What this device learned about UDP on the network it is on now: a dial
//! whose STUN went unanswered (and took no TURN over UDP) marks the network
//! UDP-silent, and the next dial on it starts as if STUN had already been
//! silent for [`super::wireguard::STUN_SILENT`]: its TURN allocation takes
//! TCP or TLS the moment that is ready instead of giving UDP its 250 ms
//! first (netlab hotel: link up p50 404 → 242 ms with UDP known silent).
//!
//! The memory is per network: [`network_changed`] (the app's path monitor,
//! through `wireguard::network_changed`) starts a new epoch, and a mark
//! taken by a dial that began in an older epoch is ignored. Nothing is
//! stored about the network itself (no address, no name), and nothing
//! leaves the device. A wrong mark costs little: STUN is still asked and
//! the UDP allocation still runs beside the stream; a STUN answer or a UDP
//! allocation that lands clears the mark ([`udp_answered`]), and the
//! session moves onto UDP (`Session::upgrade_turn_when`).
//!
//! Only a dial with `DialOptions::remember_udp` (the phone app's) reads or
//! writes the mark; the Mac's answers, roams, tests and tools leave it alone.

use std::sync::atomic::{AtomicU64, Ordering};

/// The network epoch: one per network the device has been on.
static EPOCH: AtomicU64 = AtomicU64::new(1);
/// The epoch whose network was found UDP-silent, or 0.
static SILENT_IN: AtomicU64 = AtomicU64::new(0);

/// The network epoch now; a dial reads it when it starts.
pub(crate) fn epoch() -> u64 {
    EPOCH.load(Ordering::Acquire)
}

/// The device is on another network (or back on one): what was learned
/// about the last one no longer applies.
pub(crate) fn network_changed() {
    EPOCH.fetch_add(1, Ordering::AcqRel);
    SILENT_IN.store(0, Ordering::Release);
}

/// Whether the network the device is on now was found UDP-silent.
pub(crate) fn udp_silent_here() -> bool {
    SILENT_IN.load(Ordering::Acquire) == epoch()
}

/// A dial that started in `epoch` asked STUN and heard nothing, and took no
/// TURN over UDP either.
pub(crate) fn udp_was_silent(epoch: u64) {
    // Only for the network the device is still on.
    if epoch == self::epoch() {
        let _ = SILENT_IN.compare_exchange(0, epoch, Ordering::AcqRel, Ordering::Acquire);
    }
}

/// UDP answered after all (STUN, or a TURN allocation over UDP) for a dial
/// that started in `epoch`: that network's mark goes (a late answer from an
/// older network leaves this one's alone).
pub(crate) fn udp_answered(epoch: u64) {
    let _ = SILENT_IN.compare_exchange(epoch, 0, Ordering::AcqRel, Ordering::Acquire);
}

#[cfg(test)]
pub(crate) fn reset_for_test() {
    network_changed();
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// The marks are process-wide; one test holds them at a time.
    pub(crate) static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn a_mark_holds_for_its_network_only() {
        let _one = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        reset_for_test();
        assert!(!udp_silent_here());
        let here = epoch();
        udp_was_silent(here);
        assert!(udp_silent_here());
        network_changed();
        assert!(!udp_silent_here(), "the next network starts unknown");
        // A dial that began on the old network and ended after the change
        // says nothing about this one.
        udp_was_silent(here);
        assert!(!udp_silent_here());
        udp_was_silent(epoch());
        assert!(udp_silent_here());
        udp_answered(here);
        assert!(udp_silent_here(), "a late answer from the old network keeps this one's mark");
        udp_answered(epoch());
        assert!(!udp_silent_here(), "UDP answering clears the mark");
    }
}
