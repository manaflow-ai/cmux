//! The relay-held send queue on a live relay socket (RFD 0142 R8): [`relay_hold`](crate::relay_hold)'s pure
//! ends driven over a session's [`HoldPort`], which follows the session's relay redials.
//!
//! - [`HoldRoute`] (phone): one send as `hold`, answered `held` in one relay RTT; sent again on every new
//!   socket until answered. A refused, unanswered or socketless send comes back so the caller routes the
//!   same id another way (the mailbox, or a new link): hostd's spent ids keep it to one effect.
//! - [`drain_held`] (Mac): every `held_item` through the caller's apply (hostd's mailbox gives
//!   at-most-once), then `held_ack` for what it settled. Unsettled items are tried again while the socket
//!   lives, and the relay redelivers them on the next join.
//!
//! Off unless the caller starts them: the app opts in per link, hostd with `CMUX_MOBILE_RELAY_HOLD=1`.

use std::future::Future;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use tokio::sync::{broadcast, watch};
use tokio::task::JoinHandle;

use crate::dial::relay::HoldPort;
use crate::relay_hold::{HoldSender, Incoming, RefusedCode, SendState, SenderEvent};

/// What became of one [`HoldRoute::send`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HoldOutcome {
    /// The relay holds it (`ms` after the first write): done as far as the user is concerned.
    Accepted { ms: u64 },
    /// The Mac acked it before the relay's `held` arrived here.
    Delivered,
    /// The relay will not hold it: route the same id another way.
    Refused(RefusedCode),
    /// No joined relay socket, or no answer in time: route the same id another way.
    Unanswered,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

struct RouteInner {
    sender: Mutex<HoldSender>,
    events: broadcast::Sender<SenderEvent>,
    port: watch::Receiver<Option<HoldPort>>,
}

/// The phone's relay-held sends on one session.
pub struct HoldRoute {
    inner: Arc<RouteInner>,
    pump: JoinHandle<()>,
}

impl HoldRoute {
    /// Start on a session's port watch ([`crate::dial::wireguard::relay_hold_port`]). Needs a Tokio runtime.
    pub fn start(port: watch::Receiver<Option<HoldPort>>) -> Self {
        let (events, _) = broadcast::channel(256);
        let inner = Arc::new(RouteInner { sender: Mutex::new(HoldSender::new()), events, port });
        let pump = tokio::spawn(pump(Arc::clone(&inner)));
        Self { inner, pump }
    }

    /// Hold `sealed` (a store-and-forward item, [`crate::mailbox_client`]) under `id` and wait up to `wait`
    /// for the relay's answer.
    pub async fn send(&self, id: &str, sealed: &str, wait: Duration) -> HoldOutcome {
        let id = id.to_lowercase();
        let mut events = self.inner.events.subscribe();
        let frame = lock(&self.inner.sender).send(&id, sealed, now_ms());
        let port = self.inner.port.borrow().clone();
        let written = port.is_some_and(|port| port.send_text(frame));
        if !written {
            // No socket now: the pump writes it on the next join, but the caller should not wait for one.
            lock(&self.inner.sender).forget(&id);
            return HoldOutcome::Unanswered;
        }
        let answer = tokio::time::timeout(wait, async {
            loop {
                match events.recv().await {
                    Ok(SenderEvent::Accepted { id: got, ms }) if got == id => {
                        return HoldOutcome::Accepted { ms };
                    }
                    Ok(SenderEvent::Delivered { id: got }) if got == id => return HoldOutcome::Delivered,
                    Ok(SenderEvent::Refused { id: got, code }) if got == id => {
                        return HoldOutcome::Refused(code);
                    }
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {
                        // A lagged reader may have missed its own answer: read the state.
                        match self.state(&id) {
                            Some(SendState::Accepted) => return HoldOutcome::Accepted { ms: 0 },
                            Some(SendState::Delivered) => return HoldOutcome::Delivered,
                            _ => {}
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => return HoldOutcome::Unanswered,
                }
            }
        })
        .await;
        match answer {
            Ok(outcome) => outcome,
            Err(_) => {
                lock(&self.inner.sender).forget(&id);
                HoldOutcome::Unanswered
            }
        }
    }

    pub fn state(&self, id: &str) -> Option<SendState> {
        lock(&self.inner.sender).state(id)
    }

    /// What the relay says about the sends from now on (accepted, delivered, refused).
    pub fn events(&self) -> broadcast::Receiver<SenderEvent> {
        self.inner.events.subscribe()
    }
}

impl Drop for HoldRoute {
    fn drop(&mut self) {
        self.pump.abort();
    }
}

async fn pump(inner: Arc<RouteInner>) {
    let mut ports = inner.port.clone();
    loop {
        let port = ports.borrow_and_update().clone();
        let mut replaced = false;
        if let Some(port) = port.filter(|p| !p.is_dead()) {
            let (unread, mut frames) = port.subscribe();
            for frame in unread {
                if let Some(event) = lock(&inner.sender).on_frame(&frame, now_ms()) {
                    let _ = inner.events.send(event);
                }
            }
            // A new socket: every unanswered send again, under its own id.
            for frame in lock(&inner.sender).resend() {
                port.send_text(frame);
            }
            let mut dead = port.dead();
            loop {
                tokio::select! {
                    frame = frames.recv() => match frame {
                        Ok(frame) => {
                            let event = lock(&inner.sender).on_frame(&frame, now_ms());
                            if let Some(event) = event {
                                let _ = inner.events.send(event);
                            }
                            lock(&inner.sender).prune_delivered();
                        }
                        Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => break,
                    },
                    changed = dead.changed() => if changed.is_err() || *dead.borrow() { break },
                    changed = ports.changed() => {
                        if changed.is_err() { return }
                        replaced = true;
                        break;
                    }
                }
            }
        }
        if !replaced && ports.changed().await.is_err() {
            return;
        }
    }
}

/// One `held_item` for the Mac to apply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldItem {
    pub id: String,
    pub from: String,
    pub sealed: String,
    pub at: u64,
    pub expires_at: u64,
}

/// How often the Mac tries an item it could not settle again while the socket lives.
pub const HELD_RETRY: Duration = Duration::from_secs(30);

/// The Mac's side on one session: every `held_item` through `apply` (which returns the ids it settled,
/// applied or already spent), then `held_ack` for each, until the session ends. Unsettled items are tried
/// again every [`HELD_RETRY`] while the socket lives.
pub async fn drain_held<F, Fut>(mut ports: watch::Receiver<Option<HoldPort>>, mut apply: F)
where
    F: FnMut(Vec<HeldItem>) -> Fut,
    Fut: Future<Output = Vec<String>>,
{
    loop {
        let port = ports.borrow_and_update().clone();
        let mut replaced = false;
        if let Some(port) = port.filter(|p| !p.is_dead()) {
            let (unread, mut frames) = port.subscribe();
            let mut dead = port.dead();
            // What the relay drained before this reader started goes first.
            let mut later: Vec<HeldItem> = unread
                .into_iter()
                .filter_map(|frame| match frame {
                    Incoming::HeldItem { id, from, sealed, at, expires_at } => {
                        Some(HeldItem { id, from, sealed, at, expires_at })
                    }
                    _ => None,
                })
                .collect();
            let mut first = !later.is_empty();
            let mut retry = tokio::time::interval_at(tokio::time::Instant::now() + HELD_RETRY, HELD_RETRY);
            loop {
                let batch = if std::mem::take(&mut first) {
                    std::mem::take(&mut later)
                } else {
                    tokio::select! {
                        frame = frames.recv() => match frame {
                            Ok(Incoming::HeldItem { id, from, sealed, at, expires_at }) => {
                                let mut batch = vec![HeldItem { id, from, sealed, at, expires_at }];
                                // What else arrived with it (a join drains the whole queue at once).
                                while let Ok(next) = frames.try_recv() {
                                    if let Incoming::HeldItem { id, from, sealed, at, expires_at } = next {
                                        batch.push(HeldItem { id, from, sealed, at, expires_at });
                                    }
                                }
                                batch
                            }
                            Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                            Err(broadcast::error::RecvError::Closed) => break,
                        },
                        _ = retry.tick() => {
                            if later.is_empty() { continue }
                            std::mem::take(&mut later)
                        }
                        changed = dead.changed() => if changed.is_err() || *dead.borrow() { break } else { continue },
                        changed = ports.changed() => {
                            if changed.is_err() { return }
                            replaced = true;
                            break;
                        }
                    }
                };
                let settled = apply(batch.clone()).await;
                for item in batch {
                    if settled.iter().any(|id| id.eq_ignore_ascii_case(&item.id)) {
                        port.send_text(crate::relay_hold::HeldInbox::ack(&item.id));
                    } else if !later.iter().any(|l| l.id == item.id) {
                        later.push(item);
                    }
                }
            }
        }
        if !replaced && ports.changed().await.is_err() {
            return;
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
