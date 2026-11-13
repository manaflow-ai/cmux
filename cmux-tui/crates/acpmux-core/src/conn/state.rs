//! One byte budget, including the frame currently being written.
use super::{ConnError, Offer};
use crate::wire::{
    CONNECTION_BUDGET_BYTES, CREDIT_WINDOW_BYTES, Credit, Cursor, Dropped, Frame, FrameKind,
    MAX_FRAME_BYTES, MAX_SUBSCRIPTIONS,
};
use std::collections::{HashMap, VecDeque};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
};
use tokio::sync::Notify;

#[derive(Debug, Default)]
pub struct ConnectionMetrics {
    queued: AtomicUsize,
    outside: AtomicUsize,
    notices: AtomicUsize,
    peak_queued: AtomicUsize,
    peak_outside: AtomicUsize,
}
impl ConnectionMetrics {
    pub fn queued_bytes(&self) -> usize {
        self.queued.load(Ordering::Relaxed)
    }
    pub fn outside_budget_bytes(&self) -> usize {
        self.outside.load(Ordering::Relaxed)
    }
    pub fn notices(&self) -> usize {
        self.notices.load(Ordering::Relaxed)
    }
    pub fn peak_queued_bytes(&self) -> usize {
        self.peak_queued.load(Ordering::Relaxed)
    }
    pub fn peak_outside_budget_bytes(&self) -> usize {
        self.peak_outside.load(Ordering::Relaxed)
    }
}

#[derive(Debug, Default)]
pub struct SubscriptionControl {
    ended: AtomicBool,
    pub(super) write_start: std::sync::Mutex<()>,
    written: AtomicU64,
    known: AtomicBool,
}
impl SubscriptionControl {
    pub fn ended(&self) -> bool {
        self.ended.load(Ordering::Acquire)
    }
    fn end(&self) {
        // Linearize the drop with the first non-blocking write poll. A write
        // that returned Pending has started no frame and can still be freed.
        let _start = self.write_start.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.ended.store(true, Ordering::Release);
    }
}
#[derive(Debug)]
pub(super) struct SubscriptionState {
    sent: u64,
    consumed: u64,
    pub cursor: Cursor,
    pub taken: Cursor,
    not_fed: bool,
    pub control: Arc<SubscriptionControl>,
}
#[derive(Debug)]
enum Queued {
    Data(FrameLease),
    Notice { sid: String, control: Arc<SubscriptionControl>, held: usize },
}
#[derive(Debug)]
pub struct FrameLease {
    sid: Option<String>,
    pub(super) control: Option<Arc<SubscriptionControl>>,
    cursor: Cursor,
    exact: bool,
    pub(super) bytes: Vec<u8>,
    notice: bool,
    outside: usize,
}
impl FrameLease {
    pub(super) fn ended(&self) -> bool {
        !self.notice && self.control.as_ref().is_some_and(|c| c.ended())
    }
}

#[derive(Debug)]
pub struct ConnectionState {
    queue: VecDeque<Queued>,
    pub(super) subscriptions: HashMap<String, SubscriptionState>,
    queued_bytes: usize,
    budget: usize,
    notices: usize,
    outside: usize,
    pub(super) metrics: Arc<ConnectionMetrics>,
    ended: Vec<String>,
    reserved: usize,
    reply_control: Option<Arc<SubscriptionControl>>,
    identity: Option<Vec<u8>>,
    pub(super) wake: Arc<Notify>,
}
impl Default for ConnectionState {
    fn default() -> Self {
        Self::new(CONNECTION_BUDGET_BYTES)
    }
}
impl ConnectionState {
    pub fn new(budget: usize) -> Self {
        Self {
            queue: VecDeque::new(),
            subscriptions: HashMap::new(),
            queued_bytes: 0,
            budget,
            notices: 0,
            outside: 0,
            metrics: Arc::new(ConnectionMetrics::default()),
            ended: Vec::new(),
            reserved: 0,
            reply_control: None,
            identity: None,
            wake: Arc::new(Notify::new()),
        }
    }
    fn publish_metrics(&self) {
        self.metrics.queued.store(self.queued_bytes, Ordering::Relaxed);
        self.metrics.outside.store(self.outside, Ordering::Relaxed);
        self.metrics.notices.store(self.notices, Ordering::Relaxed);
        self.metrics.peak_queued.fetch_max(self.queued_bytes, Ordering::Relaxed);
        self.metrics.peak_outside.fetch_max(self.outside, Ordering::Relaxed);
    }
    pub fn queued_bytes(&self) -> usize {
        self.queued_bytes
    }
    pub fn subscription_count(&self) -> usize {
        self.subscriptions.len()
    }
    pub fn identity(&self) -> Option<&[u8]> {
        self.identity.as_deref()
    }
    pub(super) fn set_identity(&mut self, identity: Option<&str>) -> Result<(), ConnError> {
        if identity.is_some_and(|identity| identity.len() > 64) {
            return Err(ConnError::IdentityTooLarge);
        }
        self.identity = identity.map(|s| s.as_bytes().to_vec());
        Ok(())
    }
    pub fn subscribe(&mut self, sid: impl Into<String>, cursor: Cursor) -> Result<(), ConnError> {
        self.subscribe_at(sid, Some(cursor))
    }
    pub fn subscribe_at(
        &mut self,
        sid: impl Into<String>,
        cursor: Option<Cursor>,
    ) -> Result<(), ConnError> {
        // Pending notices reserve their old subscription's slot until written,
        // so repeated sub/drop cycles cannot grow the out-of-budget notice queue.
        if self.subscriptions.len() + self.notices >= MAX_SUBSCRIPTIONS {
            return Err(ConnError::TooManySubscriptions);
        }
        let sid = sid.into();
        if !crate::wire::identifier_fits(&sid) {
            return Err(ConnError::IdentifierTooLong);
        }
        if self.subscriptions.contains_key(&sid) {
            return Err(ConnError::DuplicateSubscription(sid));
        }
        let control = Arc::new(SubscriptionControl::default());
        control.known.store(cursor.is_some(), Ordering::Release);
        let cursor = cursor.unwrap_or_default();
        control.written.store(cursor.0, Ordering::Release);
        self.subscriptions.insert(
            sid,
            SubscriptionState {
                sent: 0,
                consumed: 0,
                cursor,
                taken: cursor,
                not_fed: false,
                control,
            },
        );
        Ok(())
    }
    pub fn control(&self, sid: &str) -> Option<Arc<SubscriptionControl>> {
        self.subscriptions.get(sid).map(|s| s.control.clone())
    }
    pub fn unsubscribe(&mut self, sid: &str) -> bool {
        if let Some(sub) = self.subscriptions.remove(sid) {
            sub.control.end();
            self.remove_queued_for(&sub.control);
            self.publish_metrics();
            true
        } else {
            false
        }
    }
    /// Returns a cursor only when new credit revives a stopped source.
    pub fn credit(&mut self, credit: Credit) -> Result<Option<Cursor>, ConnError> {
        let sub = self
            .subscriptions
            .get_mut(&credit.sid)
            .ok_or_else(|| ConnError::UnknownSubscription(credit.sid.clone()))?;
        // A client may report consumption ahead of a whole socket write. Credit
        // is bounded by frames taken, not by the writer's current progress.
        let consumed = credit.consumed.min(sub.sent).max(sub.consumed);
        let increased = consumed > sub.consumed;
        sub.consumed = consumed;
        if increased && sub.not_fed && sub.sent.saturating_sub(sub.consumed) < CREDIT_WINDOW_BYTES {
            sub.not_fed = false;
            Ok(Some(sub.taken))
        } else {
            Ok(None)
        }
    }
    pub fn offer(&mut self, sid: &str, frame: Frame, cursor: Cursor) -> Offer {
        let Some(control) = self.control(sid) else { return Offer::UnknownSubscription };
        self.offer_from(sid, &control, frame, cursor)
    }
    pub(super) fn offer_from(
        &mut self,
        sid: &str,
        control: &Arc<SubscriptionControl>,
        frame: Frame,
        cursor: Cursor,
    ) -> Offer {
        let Some(sub) =
            self.subscriptions.get_mut(sid).filter(|s| Arc::ptr_eq(&s.control, control))
        else {
            return Offer::UnknownSubscription;
        };
        let bytes = frame.encoded_len();
        if sub.not_fed || sub.sent.saturating_sub(sub.consumed) >= CREDIT_WINDOW_BYTES {
            sub.not_fed = true;
            return Offer::NotFed;
        }
        let own_reply =
            self.reply_control.as_ref().is_some_and(|reply| Arc::ptr_eq(reply, control));
        let reserve = if own_reply { 0 } else { self.reserved };
        if self.queued_bytes.saturating_add(reserve).saturating_add(bytes) > self.budget {
            let cursor = self.drop_subscription(sid);
            self.wake.notify_one();
            return Offer::Dropped { sid: sid.to_owned(), cursor };
        }
        sub.sent = sub.sent.saturating_add(bytes as u64);
        let exact = matches!(frame.kind, FrameKind::Window | FrameKind::Delta);
        if exact {
            sub.taken = cursor;
        }
        self.queued_bytes += bytes;
        if own_reply {
            self.reserved = self.reserved.saturating_sub(bytes);
        }
        self.queue.push_back(Queued::Data(FrameLease {
            sid: Some(sid.to_owned()),
            control: Some(control.clone()),
            cursor,
            exact,
            bytes: frame.encode(),
            notice: false,
            outside: 0,
        }));
        self.publish_metrics();
        self.wake.notify_one();
        Offer::Taken
    }
    pub(super) fn request_room(&self) -> bool {
        self.queued_bytes.saturating_add(MAX_FRAME_BYTES) <= self.budget
    }
    pub(super) fn reserve_reply(&mut self) -> bool {
        if !self.request_room() {
            return false;
        }
        self.reserved = MAX_FRAME_BYTES;
        true
    }
    pub(super) fn begin_subscription_reply(&mut self, control: Arc<SubscriptionControl>) {
        self.reply_control = Some(control);
    }
    pub(super) fn release_reply(&mut self) {
        self.reserved = 0;
        self.reply_control = None;
    }
    pub fn offer_reply(&mut self, frame: Frame) -> Result<(), ConnError> {
        if self.queued_bytes.saturating_add(frame.encoded_len()) > self.budget {
            return Err(ConnError::ReplyBudget);
        }
        self.queued_bytes += frame.encoded_len();
        self.queue.push_back(Queued::Data(FrameLease {
            sid: None,
            control: None,
            cursor: Cursor(0),
            exact: false,
            bytes: frame.encode(),
            notice: false,
            outside: 0,
        }));
        self.publish_metrics();
        self.wake.notify_one();
        Ok(())
    }
    pub(super) fn take_ended(&mut self) -> Vec<String> {
        std::mem::take(&mut self.ended)
    }

    pub fn take(&mut self) -> Option<FrameLease> {
        match self.queue.pop_front()? {
            Queued::Data(lease) => Some(lease),
            Queued::Notice { sid, control, held } => {
                // The previous in-flight frame has finished by now, including
                // a frame that was partly written when this subscription ended.
                let cursor = control
                    .known
                    .load(Ordering::Acquire)
                    .then(|| Cursor(control.written.load(Ordering::Acquire)));
                let frame =
                    Frame::json(FrameKind::Dropped, &Dropped { sid: sid.clone(), cursor }).ok()?;
                Some(FrameLease {
                    sid: Some(sid),
                    control: Some(control),
                    cursor: cursor.unwrap_or_default(),
                    exact: false,
                    bytes: frame.encode(),
                    notice: true,
                    outside: held,
                })
            }
        }
    }
    pub fn written(&mut self, lease: &FrameLease) {
        if lease.notice {
            self.notices = self.notices.saturating_sub(1);
            self.outside = self.outside.saturating_sub(lease.outside);
        } else {
            self.queued_bytes = self.queued_bytes.saturating_sub(lease.bytes.len());
            if lease.exact
                && let Some(control) = &lease.control
            {
                control.written.store(lease.cursor.0, Ordering::Release);
                control.known.store(true, Ordering::Release);
            }
            if lease.exact
                && let Some(sid) = &lease.sid
                && let Some(sub) = self.subscriptions.get_mut(sid)
                && lease.control.as_ref().is_some_and(|c| Arc::ptr_eq(c, &sub.control))
            {
                sub.cursor = lease.cursor;
            }
        }
        self.publish_metrics();
    }
    pub(super) fn abandon(&mut self, lease: &FrameLease) {
        self.queued_bytes = self.queued_bytes.saturating_sub(lease.bytes.len());
        self.publish_metrics();
    }

    fn drop_subscription(&mut self, sid: &str) -> Cursor {
        let Some(sub) = self.subscriptions.remove(sid) else { return Cursor(0) };
        sub.control.end();
        self.remove_queued_for(&sub.control);
        let cursor = Cursor(sub.control.written.load(Ordering::Acquire));
        self.notices += 1;
        self.ended.push(sid.to_owned());
        let held = Frame::json(
            FrameKind::Dropped,
            &Dropped { sid: sid.to_owned(), cursor: Some(Cursor(u64::MAX)) },
        )
        .map_or(0, |frame| frame.encoded_len());
        self.outside = self.outside.saturating_add(held);
        self.queue.push_back(Queued::Notice { sid: sid.to_owned(), control: sub.control, held });
        self.publish_metrics();
        cursor
    }
    fn remove_queued_for(&mut self, control: &Arc<SubscriptionControl>) {
        self.queue.retain(|queued| {
            if let Queued::Data(lease) = queued
                && lease.control.as_ref().is_some_and(|c| Arc::ptr_eq(c, control))
            {
                self.queued_bytes = self.queued_bytes.saturating_sub(lease.bytes.len());
                false
            } else {
                true
            }
        });
    }
}

impl Drop for ConnectionState {
    fn drop(&mut self) {
        self.metrics.queued.store(0, Ordering::Relaxed);
        self.metrics.outside.store(0, Ordering::Relaxed);
        self.metrics.notices.store(0, Ordering::Relaxed);
    }
}
