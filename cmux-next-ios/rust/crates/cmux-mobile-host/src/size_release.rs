//! A phone's terminal size claims on one `daemon` channel, released for it
//! when it leaves on purpose (cmux-next-ios/PROTOCOL.md, "Terminal size
//! claims").
//!
//! The cmux-tui daemon holds the grid for 30 s after a phone's connection
//! ends, for a link drop the phone recovers from. A phone that leaves on
//! purpose releases its size itself (`release-surface-size`); this is the
//! Mac's backstop for the ends it can tell apart from a drop:
//!
//! - the phone closed the channel (a `close` frame, any code but `link_closed`);
//! - the owner removed this phone (the link closed `removed`);
//! - hostd is stopping (iPhone connections turned off, the app quitting).
//!
//! On these the splice sends `release-surface-size` for every terminal the
//! channel attached to or sized, and waits (at most [`RELEASE_WAIT`]) for the
//! daemon's answers before it closes the socket: an end of file the daemon
//! reads first is a dropped view, which holds. Any other end (the link timed
//! out, the transport failed) keeps the daemon's hold.

use std::collections::{BTreeSet, HashSet};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{LazyLock, Mutex, PoisonError};
use std::time::Duration;

use cmux_mobile_link::link::CloseInfo;
use serde_json::Value;
use tokio::sync::{Notify, watch};

/// How long a splice waits for the daemon to answer its releases.
pub const RELEASE_WAIT: Duration = Duration::from_millis(500);

/// How long hostd's exit waits for every splice's releases.
pub const EXIT_WAIT: Duration = Duration::from_millis(700);

/// The prefix of the ids of the releases hostd sends (their answers are not
/// the phone's and are not forwarded).
const RELEASE_ID_PREFIX: &str = "cmux-mobile-host-release-";

/// Why a channel's claims are released, or `None` to keep the daemon's hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReleaseReason {
    /// The phone closed the channel.
    PhoneClosed,
    /// The owner removed this phone.
    Removed,
    /// hostd is stopping.
    Stopping,
}

impl ReleaseReason {
    /// The reason for the end of a channel that closed with `info`.
    pub fn for_close(info: &CloseInfo) -> Option<Self> {
        match info.code.as_str() {
            "link_closed" if info.reason == "removed" => Some(Self::Removed),
            "link_closed" => None,
            _ => Some(Self::PhoneClosed),
        }
    }
}

/// The terminals a channel attached to or sized.
#[derive(Debug, Default)]
pub struct SizeClaims {
    surfaces: BTreeSet<u64>,
}

impl SizeClaims {
    /// Notes a request line the phone sent (after the policy let it through).
    pub fn observe(&mut self, line: &[u8]) {
        // Cheap test first: most lines are input (`send`).
        let text = String::from_utf8_lossy(line);
        if !text.contains("-surface") {
            return;
        }
        let Ok(value) = serde_json::from_slice::<Value>(line) else { return };
        let Some(surface) = value.get("surface").and_then(Value::as_u64) else { return };
        match value.get("cmd").and_then(Value::as_str) {
            Some("attach-surface" | "resize-surface") => {
                self.surfaces.insert(surface);
            }
            // Released by the phone: nothing left to release for it.
            Some("release-surface-size") => {
                self.surfaces.remove(&surface);
            }
            _ => {}
        }
    }

    pub fn is_empty(&self) -> bool {
        self.surfaces.is_empty()
    }

    /// One `release-surface-size` line (without its newline) per claimed
    /// terminal, with the ids its answers carry.
    pub fn release_lines(&self) -> Vec<(String, Vec<u8>)> {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        self.surfaces
            .iter()
            .map(|surface| {
                let id = format!("{RELEASE_ID_PREFIX}{}", NEXT.fetch_add(1, Ordering::Relaxed));
                let line = serde_json::json!({"id": id, "cmd": "release-surface-size", "surface": surface});
                (id, line.to_string().into_bytes())
            })
            .collect()
    }
}

/// The ids of releases still waiting for the daemon's answer.
#[derive(Default)]
pub struct PendingReleases {
    ids: Mutex<HashSet<String>>,
    answered: Notify,
}

impl PendingReleases {
    pub fn add(&self, id: String) {
        self.ids.lock().unwrap_or_else(PoisonError::into_inner).insert(id);
    }

    /// A daemon line: true when it answers one of hostd's releases (then it
    /// is not the phone's to read).
    pub fn answer(&self, line: &[u8]) -> bool {
        let text = String::from_utf8_lossy(line);
        if !text.contains(RELEASE_ID_PREFIX) {
            return false;
        }
        let Ok(value) = serde_json::from_slice::<Value>(line) else { return false };
        let Some(id) = value.get("id").and_then(Value::as_str) else { return false };
        if !id.starts_with(RELEASE_ID_PREFIX) {
            return false;
        }
        let mut ids = self.ids.lock().unwrap_or_else(PoisonError::into_inner);
        // Only hostd's own pending releases: a phone's id with the same
        // prefix is the phone's answer.
        if !ids.remove(id) {
            return false;
        }
        if ids.is_empty() {
            self.answered.notify_waiters();
        }
        true
    }

    /// Waits until every release was answered, at most `limit`.
    pub async fn wait(&self, limit: Duration) {
        let _ = tokio::time::timeout(limit, async {
            loop {
                let answered = self.answered.notified();
                if self.ids.lock().unwrap_or_else(PoisonError::into_inner).is_empty() {
                    return;
                }
                answered.await;
            }
        })
        .await;
    }
}

static STOPPING: LazyLock<watch::Sender<bool>> = LazyLock::new(|| watch::channel(false).0);
/// Daemon splices still running, and a wake when one ends.
static ACTIVE: AtomicUsize = AtomicUsize::new(0);
static ENDED: LazyLock<Notify> = LazyLock::new(Notify::new);

/// Watches for hostd stopping.
pub fn stopping() -> watch::Receiver<bool> {
    STOPPING.subscribe()
}

/// A running daemon splice, counted until dropped.
pub struct ActiveSplice(());

impl ActiveSplice {
    pub fn begin() -> Self {
        ACTIVE.fetch_add(1, Ordering::AcqRel);
        Self(())
    }
}

impl Drop for ActiveSplice {
    fn drop(&mut self) {
        ACTIVE.fetch_sub(1, Ordering::AcqRel);
        ENDED.notify_waiters();
    }
}

/// hostd is stopping: every daemon splice releases its phone's sizes. Returns
/// once they all ended, or after `limit`.
pub async fn stop_and_release(limit: Duration) {
    STOPPING.send_replace(true);
    let _ = tokio::time::timeout(limit, async {
        loop {
            let ended = ENDED.notified();
            if ACTIVE.load(Ordering::Acquire) == 0 {
                return;
            }
            ended.await;
        }
    })
    .await;
}

/// SIGTERM (the app stopping hostd: iPhone connections off, the app
/// quitting) releases the phones' sizes before hostd exits, as the end of
/// stdin does.
#[cfg(unix)]
pub fn exit_on_sigterm() {
    let Ok(mut term) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) else {
        return;
    };
    tokio::spawn(async move {
        if term.recv().await.is_some() {
            tracing::info!("SIGTERM; releasing phone terminal sizes and exiting");
            stop_and_release(EXIT_WAIT).await;
            std::process::exit(0);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_phone_close_and_a_removal_release_and_a_drop_does_not() {
        assert_eq!(ReleaseReason::for_close(&CloseInfo::new("eof", "")), Some(ReleaseReason::PhoneClosed));
        assert_eq!(
            ReleaseReason::for_close(&CloseInfo::new("cancelled", "")),
            Some(ReleaseReason::PhoneClosed)
        );
        assert_eq!(
            ReleaseReason::for_close(&CloseInfo::new("link_closed", "removed")),
            Some(ReleaseReason::Removed)
        );
        assert_eq!(ReleaseReason::for_close(&CloseInfo::new("link_closed", "keepalive timed out")), None);
        assert_eq!(ReleaseReason::for_close(&CloseInfo::new("link_closed", "")), None);
    }

    #[test]
    fn claims_follow_attach_resize_and_release() {
        let mut claims = SizeClaims::default();
        claims.observe(br#"{"id":1,"cmd":"attach-surface","surface":7,"cols":53,"rows":42}"#);
        claims.observe(br#"{"id":2,"cmd":"resize-surface","surface":9,"cols":53,"rows":42}"#);
        claims.observe(br#"{"id":3,"cmd":"send","surface":11,"bytes":"YQ=="}"#);
        claims.observe(br#"{"id":4,"cmd":"vt-state","surface":12}"#);
        let surfaces = |claims: &SizeClaims| {
            claims
                .release_lines()
                .into_iter()
                .map(|(id, line)| {
                    let value: Value = serde_json::from_slice(&line).unwrap();
                    assert_eq!(value["id"], id.as_str());
                    assert_eq!(value["cmd"], "release-surface-size");
                    value["surface"].as_u64().unwrap()
                })
                .collect::<Vec<_>>()
        };
        assert_eq!(surfaces(&claims), [7, 9]);
        claims.observe(br#"{"id":5,"cmd":"release-surface-size","surface":7}"#);
        assert_eq!(surfaces(&claims), [9]);
    }

    #[tokio::test]
    async fn pending_releases_end_on_their_answers_and_hide_them() {
        let pending = PendingReleases::default();
        let mut claims = SizeClaims::default();
        claims.observe(br#"{"cmd":"attach-surface","surface":3}"#);
        let lines = claims.release_lines();
        for (id, _) in &lines {
            pending.add(id.clone());
        }
        assert!(!pending.answer(br#"{"id":"m1","ok":true,"data":{}}"#), "the phone's own answer");
        let lookalike = serde_json::json!({"id": format!("{RELEASE_ID_PREFIX}phone"), "ok": true});
        assert!(!pending.answer(lookalike.to_string().as_bytes()), "a phone id with hostd's prefix");
        let answer = serde_json::json!({"id": lines[0].0, "ok": true, "data": {"outcome": "applied"}});
        assert!(pending.answer(answer.to_string().as_bytes()));
        // Answered: the wait ends at once.
        tokio::time::timeout(Duration::from_millis(100), pending.wait(Duration::from_secs(5)))
            .await
            .expect("an answered release does not wait");
    }
}
