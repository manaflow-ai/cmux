//! Bulk uploads wait for consent on a metered network (ultra-connectivity design, "Budget-aware":
//! "metered: no bulk striping on cell ... attachments asked before sending over cell"; ledger W5).
//!
//! The phone is **metered** while its network is cellular
//! ([`crate::dial::wireguard::set_cellular_path`]) or expensive or constrained (Low Data Mode,
//! [`set_constrained_path`]). While it is metered and the person has not said yes
//! ([`set_metered_bulk_consent`]), the phone's link holds the data of every channel opened for a
//! [`CONSENT_SERVICES`] service (file uploads, attachments) in that channel's queue: the frames
//! stay queued, the sender waits once the channel's queue is full (back-pressure, never a drop or
//! an error), and the channel's open goes out so the Mac's side is ready. Everything else flows as
//! before: keystrokes, echo, ACKs, pings, chat, screen state.
//!
//! [`state`] says whether bulk bytes are waiting and how many; [`subscribe`] changes when the
//! gate opens or closes or bytes start or stop waiting, so the app can ask once.
//!
//! **Consent lasts until the phone leaves the metered network**, across links and reconnects on
//! it: leaving cell (and Low Data Mode) releases what waits and forgets the yes, so the next
//! time the phone is on cell it asks again. A yes given while not metered is not kept.
//!
//! Phone-local: nothing on the wire changes (the Mac sees a slower upload), and a Mac link
//! ([`crate::Role::Mac`]) never holds anything.
//!
//! Why at the link's channel queues and not the tunnel's datagram class
//! ([`crate::class_queue::SendClass::Bulk`]): the tunnel's bulk class is the main stream's TCP,
//! which also carries chat and screen state; holding its encrypted segments would stall them and
//! make TCP retransmit.

use std::sync::LazyLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use tokio::sync::watch;

/// Services whose channels carry bulk bytes the person is asked about on a metered network.
/// `upload`: a file or photo to the Mac (`LinkUpload.swift`).
pub const CONSENT_SERVICES: &[&str] = &["upload"];

/// Whether a channel opened for `service` waits for consent on a metered network.
pub fn needs_consent(service: &str) -> bool {
    CONSENT_SERVICES.contains(&service)
}

/// The metered-bulk gate as the app sees it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MeteredBulk {
    /// The phone is on cellular, or an expensive or constrained network.
    pub metered: bool,
    /// The person said yes for this metered network.
    pub consent: bool,
    /// Bulk bytes held for consent (0 when the gate is open).
    pub waiting_bytes: u64,
    /// The person chose to wait for Wi-Fi for this waiting batch.
    pub deferred: bool,
    /// Monotonic change cursor for race-free observers.
    pub revision: u64,
}

impl MeteredBulk {
    /// Bulk bytes may go now.
    pub fn allowed(&self) -> bool {
        !self.metered || self.consent
    }
}

/// What [`subscribe`] carries: it changes only when the gate opens or closes or bytes start or
/// stop waiting, never per byte.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Gate {
    pub metered: bool,
    pub consent: bool,
    pub waiting: bool,
    pub deferred: bool,
}

static CONSTRAINED: AtomicBool = AtomicBool::new(false);
static CONSENT: AtomicBool = AtomicBool::new(false);
/// The person chose to wait for Wi-Fi for the current waiting batch.
static DEFERRED: AtomicBool = AtomicBool::new(false);
/// Bytes queued on consent channels across this process's links (held or about to go).
static QUEUED: AtomicU64 = AtomicU64::new(0);
/// Monotonic cursor for genuine gate events.
static REVISION: AtomicU64 = AtomicU64::new(0);
static GATE: LazyLock<watch::Sender<Gate>> = LazyLock::new(|| watch::channel(Gate::default()).0);

/// Whether the phone is metered now.
pub fn is_metered() -> bool {
    crate::dial::wireguard::cellular_path() || CONSTRAINED.load(Ordering::Acquire)
}

/// Whether bulk bytes may go now: not metered, or the person said yes.
pub fn bulk_allowed() -> bool {
    !is_metered() || CONSENT.load(Ordering::Acquire)
}

/// The gate now, with the bytes waiting.
pub fn state() -> MeteredBulk {
    let metered = is_metered();
    let consent = CONSENT.load(Ordering::Acquire);
    let allowed = !metered || consent;
    let waiting_bytes = if allowed { 0 } else { QUEUED.load(Ordering::Acquire) };
    MeteredBulk {
        metered,
        consent,
        waiting_bytes,
        deferred: DEFERRED.load(Ordering::Acquire) && metered && waiting_bytes > 0,
        revision: REVISION.load(Ordering::Acquire),
    }
}

/// Changes when the gate opens or closes or bytes start or stop waiting.
pub fn subscribe() -> watch::Receiver<Gate> {
    GATE.subscribe()
}

/// The network is expensive or constrained, or not (iOS `NWPath.isExpensive || isConstrained`,
/// Low Data Mode; every path update).
pub fn set_constrained_path(constrained: bool) {
    CONSTRAINED.store(constrained, Ordering::Release);
    refresh();
}

/// The person's answer for bulk bytes on this metered network: `true` releases what waits until
/// the phone leaves it; `false` holds again. Kept only while metered.
pub fn set_metered_bulk_consent(consent: bool) {
    CONSENT.store(consent && is_metered(), Ordering::Release);
    if consent {
        DEFERRED.store(false, Ordering::Release);
    }
    refresh();
}

/// The person chose to wait for Wi-Fi for this waiting batch.
pub fn defer_metered_bulk() {
    let now = state();
    if now.metered && !now.consent && now.waiting_bytes > 0 {
        DEFERRED.store(true, Ordering::Release);
        publish();
    }
}

/// Recompute the gate after a network or consent change (also called by `set_cellular_path`):
/// off a metered network the consent is forgotten.
pub(crate) fn refresh() {
    if !is_metered() {
        CONSENT.store(false, Ordering::Release);
        DEFERRED.store(false, Ordering::Release);
    }
    publish();
}

fn publish() {
    if (!is_metered() || QUEUED.load(Ordering::Acquire) == 0) && DEFERRED.load(Ordering::Acquire) {
        DEFERRED.store(false, Ordering::Release);
    }
    let now = state();
    let gate = Gate {
        metered: now.metered,
        consent: now.consent,
        waiting: now.waiting_bytes > 0,
        deferred: now.deferred,
    };
    GATE.send_if_modified(|old| {
        if *old == gate {
            return false;
        }
        *old = gate;
        REVISION.fetch_add(1, Ordering::AcqRel);
        true
    });
}

/// A consent channel queued `bytes`.
pub(crate) fn queued(bytes: usize) {
    if QUEUED.fetch_add(bytes as u64, Ordering::AcqRel) == 0 {
        publish();
    }
}

/// A consent channel's `bytes` left its queue (sent, or dropped with the link).
pub(crate) fn dequeued(bytes: usize) {
    let bytes = bytes as u64;
    let before = QUEUED
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| Some(n.saturating_sub(bytes)))
        .unwrap_or(0);
    if before > 0 && before <= bytes {
        publish();
    }
}

/// A link's consent-channel bytes sent while the phone was metered: the scoreboard row "metered
/// cell, bulk bytes sent without consent" is `unconsented`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MeteredBulkSent {
    /// Sent metered, with the person's yes.
    pub consented: u64,
    /// Sent metered, without it (the gate holds these: 0).
    pub unconsented: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn consent_services_are_uploads_only() {
        assert!(needs_consent("upload"));
        for service in ["chat", "terminal", "daemon", "acpmux", "chief", "browser", "keys"] {
            assert!(!needs_consent(service), "{service}");
        }
    }

    #[test]
    fn the_state_is_open_when_not_metered() {
        let state = MeteredBulk { metered: false, consent: false, waiting_bytes: 0, ..Default::default() };
        assert!(state.allowed());
        assert!(
            !MeteredBulk { metered: true, consent: false, waiting_bytes: 0, ..Default::default() }.allowed()
        );
        assert!(
            MeteredBulk { metered: true, consent: true, waiting_bytes: 0, ..Default::default() }.allowed()
        );
    }
}
