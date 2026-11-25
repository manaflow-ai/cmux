//! A store whose answer to a send takes its time: the store takes the message at once, and the
//! phone hears of it only when the test lets the answer go, or never.

#![allow(dead_code)]

use std::future::poll_fn;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, PoisonError};
use std::task::Poll;

use cmux_auto_session::cloud::{AutoCloud, AutoCloudError, CloudResult};
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{
    Assignment, CreateRequest, EventsAppend, EventsPage, Fence, InboxAck, InboxMessage, InboxPost,
    InboxPosted, LeaseAnswer, LeaseRequest, MachineSetting, PutRequest, SessionList, SessionView,
    SnapshotAnswer, SnapshotPost,
};

/// What becomes of a held answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fate {
    /// It never arrives: the phone's request ends with no answer.
    Lost,
    /// It arrives as the store wrote it, after whatever happened meanwhile.
    Late,
}

/// The store, holding the answer of the next send when told to.
#[derive(Debug)]
pub struct Slow {
    pub inner: FakeAutoCloud,
    /// What becomes of the next send's answer. None: it arrives at once.
    next: Mutex<Option<Fate>>,
    /// The held answer may go.
    gone: AtomicBool,
}

impl Slow {
    pub fn new(inner: &FakeAutoCloud) -> Slow {
        Slow { inner: inner.clone(), next: Mutex::new(None), gone: AtomicBool::new(false) }
    }

    /// The next send reaches the store at once. Its answer is held until [`Slow::let_go`].
    pub fn hold_next_send(&self, fate: Fate) {
        self.gone.store(false, Ordering::SeqCst);
        *self.next.lock().unwrap_or_else(PoisonError::into_inner) = Some(fate);
    }

    /// The held answer arrives now, or the phone stops waiting for a lost one.
    pub fn let_go(&self) {
        self.gone.store(true, Ordering::SeqCst);
    }

    fn held(&self) -> Option<Fate> {
        self.next.lock().unwrap_or_else(PoisonError::into_inner).take()
    }
}

impl AutoCloud for Slow {
    async fn machine(&self) -> CloudResult<MachineSetting> {
        self.inner.machine().await
    }

    async fn set_machine(&self, setting: &MachineSetting) -> CloudResult<MachineSetting> {
        self.inner.set_machine(setting).await
    }

    async fn put(&self, id: &str, request: &PutRequest) -> CloudResult<SessionView> {
        self.inner.put(id, request).await
    }

    async fn create(&self, request: &CreateRequest) -> CloudResult<SessionView> {
        self.inner.create(request).await
    }

    async fn list(&self, limit: Option<u32>, cursor: Option<&str>) -> CloudResult<SessionList> {
        self.inner.list(limit, cursor).await
    }

    async fn get(&self, id: &str) -> CloudResult<SessionView> {
        self.inner.get(id).await
    }

    async fn wait(&self, id: &str, after: u64, timeout_ms: u64) -> CloudResult<SessionView> {
        self.inner.wait(id, after, timeout_ms).await
    }

    async fn lease(&self, id: &str, request: &LeaseRequest) -> CloudResult<LeaseAnswer> {
        self.inner.lease(id, request).await
    }

    async fn release(&self, id: &str, fence: &Fence) -> CloudResult<SessionView> {
        self.inner.release(id, fence).await
    }

    async fn append_events(&self, id: &str, request: &EventsAppend) -> CloudResult<u64> {
        self.inner.append_events(id, request).await
    }

    async fn events(&self, id: &str, after: u64, limit: Option<u32>) -> CloudResult<EventsPage> {
        self.inner.events(id, after, limit).await
    }

    async fn put_chunk(&self, id: &str, sha256: &str, bytes: &[u8], fence: &Fence) -> CloudResult<()> {
        self.inner.put_chunk(id, sha256, bytes, fence).await
    }

    async fn chunk(&self, id: &str, sha256: &str) -> CloudResult<Vec<u8>> {
        self.inner.chunk(id, sha256).await
    }

    async fn post_snapshot(&self, id: &str, request: &SnapshotPost) -> CloudResult<u64> {
        self.inner.post_snapshot(id, request).await
    }

    async fn snapshot(&self, id: &str) -> CloudResult<SnapshotAnswer> {
        self.inner.snapshot(id).await
    }

    async fn post_inbox(&self, id: &str, message: &InboxPost) -> CloudResult<InboxPosted> {
        let answer = self.inner.post_inbox(id, message).await;
        let Some(fate) = self.held() else { return answer };
        poll_fn(|_| if self.gone.load(Ordering::SeqCst) { Poll::Ready(()) } else { Poll::Pending }).await;
        match fate {
            Fate::Late => answer,
            Fate::Lost => {
                drop(answer.expect("the store took the message"));
                Err(AutoCloudError::transport("the answer was lost"))
            }
        }
    }

    async fn inbox(&self, id: &str, after: u64) -> CloudResult<Vec<InboxMessage>> {
        self.inner.inbox(id, after).await
    }

    async fn ack_inbox(&self, id: &str, ack: &InboxAck) -> CloudResult<SessionView> {
        self.inner.ack_inbox(id, ack).await
    }

    async fn keep(&self, id: &str, keep_in_cloud: bool) -> CloudResult<SessionView> {
        self.inner.keep(id, keep_in_cloud).await
    }

    async fn assignments(&self, timeout_ms: u64) -> CloudResult<Vec<Assignment>> {
        self.inner.assignments(timeout_ms).await
    }

    async fn ack_assignment(&self, id: &str, fence: &Fence) -> CloudResult<SessionView> {
        self.inner.ack_assignment(id, fence).await
    }
}
