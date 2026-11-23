//! What the phone's tests share: a fake store with one chat, the chat's holders, and a store
//! that loses an answer.

#![allow(dead_code)]

use std::future::Future;
use std::pin::{Pin, pin};
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll, Waker};

use cmux_auto_session::cloud::{AutoCloud, AutoCloudError, CloudResult};
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{
    Assignment, CreateRequest, EventsAppend, EventsPage, Fence, Holder, InboxAck, InboxMessage, InboxPost,
    InboxPosted, LeaseAnswer, LeaseRequest, MachineSetting, PutRequest, Repo, SeqRecord, SessionList,
    SessionView, SnapshotAnswer, SnapshotPost,
};
use serde_json::{Value, json};

pub const CHAT: &str = "chat_1";
pub const VM: &str = "vm_1";
pub const TEAM: &str = "team_0123456789abcdef0123";

/// The answer of a request the store does not hold.
pub fn ready<T>(future: impl Future<Output = T>) -> T {
    match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
        Poll::Ready(answer) => answer,
        Poll::Pending => panic!("the store holds the request"),
    }
}

/// One look at a request that may be held.
pub fn look<T>(future: &mut Pin<Box<impl Future<Output = T>>>) -> Option<T> {
    match future.as_mut().poll(&mut Context::from_waker(Waker::noop())) {
        Poll::Ready(answer) => Some(answer),
        Poll::Pending => None,
    }
}

pub fn mac() -> Holder {
    Holder::device("mac")
}

pub fn vm() -> Holder {
    Holder::vm(VM)
}

pub fn repo(name: &str, branch: &str) -> Repo {
    Repo { remote: format!("https://example.com/{name}.git"), branch: branch.to_owned() }
}

pub fn put_request(title: &str, repo: Option<Repo>) -> PutRequest {
    PutRequest {
        auto: true,
        title: title.to_owned(),
        harness: "claude".to_owned(),
        device: "mac".to_owned(),
        keep_in_cloud: None,
        repo,
    }
}

/// A store with the Auto machine `VM` and no chat.
pub fn with_machine() -> FakeAutoCloud {
    let owner = FakeAutoCloud::new();
    let setting = MachineSetting { team: TEAM.to_owned(), machine: VM.to_owned() };
    ready(owner.set_machine(&setting)).expect("the Auto machine");
    owner
}

/// A store with the Auto machine and the chat `CHAT`, held by the laptop `mac` at epoch 1.
pub fn store() -> FakeAutoCloud {
    let owner = with_machine();
    ready(owner.put(CHAT, &put_request("Fix the build", Some(repo("app", "main"))))).expect("the chat");
    owner
}

pub fn chat(cloud: &FakeAutoCloud) -> SessionView {
    cloud.peek(CHAT).expect("the chat")
}

/// A renewal as the holder.
pub fn renew(cloud: &FakeAutoCloud, holder: &Holder, epoch: u64, needs_run: bool) -> LeaseAnswer {
    let request = LeaseRequest { holder: holder.clone(), epoch, needs_run, standby: None };
    ready(cloud.lease(CHAT, &request)).expect("a lease answer")
}

/// An acpmux log record as a holder writes it.
pub fn log(kind: &str, msg: Value) -> Value {
    json!({ "sessionId": "local", "seq": 0, "at": 1_000, "dir": "mux", "kind": kind, "msg": msg })
}

/// The record of a prompt that ran.
pub fn prompt(id: &str, turn: &str, text: &str) -> Value {
    log("user_message", json!({ "promptId": id, "turnId": turn, "text": text }))
}

/// `holder` appends `records` after the store's last event.
pub fn append(cloud: &FakeAutoCloud, holder: &Holder, epoch: u64, records: Vec<Value>) -> u64 {
    let mut last = chat(cloud).last_seq;
    for batch in records.chunks(256) {
        let events =
            batch.iter().zip(last + 1..).map(|(record, seq)| SeqRecord { seq, record: record.clone() });
        let request = EventsAppend { holder: holder.clone(), epoch, events: events.collect() };
        last = ready(cloud.append_events(CHAT, &request)).expect("appended");
    }
    last
}

/// `holder` takes every message in the inbox, and answers them.
pub fn drain(cloud: &FakeAutoCloud, holder: &Holder, epoch: u64) -> Vec<InboxMessage> {
    let messages = ready(cloud.inbox(CHAT, 0)).expect("the inbox");
    if let Some(last) = messages.last() {
        let ack = InboxAck { holder: holder.clone(), epoch, through: last.n };
        ready(cloud.ack_inbox(CHAT, &ack)).expect("acked");
    }
    messages
}

/// The kinds of a batch's records, with the prompt id where a record names one.
pub fn drawn(records: &[Value]) -> Vec<String> {
    let label = |record: &Value| {
        let kind = record["kind"].as_str().unwrap_or("?");
        match record["msg"]["promptId"].as_str() {
            Some(id) => format!("{kind}:{id}"),
            None => kind.to_owned(),
        }
    };
    records.iter().map(label).collect()
}

/// The store, losing the answer of the next send or start when told to: the request reaches
/// the store, and the caller hears nothing.
#[derive(Debug)]
pub struct Lossy {
    pub inner: FakeAutoCloud,
    lose: AtomicBool,
}

impl Lossy {
    pub fn new(inner: &FakeAutoCloud) -> Lossy {
        Lossy { inner: inner.clone(), lose: AtomicBool::new(false) }
    }

    /// The next send or start is stored, and its answer is lost.
    pub fn lose_next_answer(&self) {
        self.lose.store(true, Ordering::SeqCst);
    }

    fn answer<T>(&self, answer: CloudResult<T>) -> CloudResult<T> {
        if self.lose.swap(false, Ordering::SeqCst) {
            drop(answer.expect("the store took the request"));
            return Err(AutoCloudError::transport("the answer was lost"));
        }
        answer
    }
}

impl AutoCloud for Lossy {
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
        self.answer(self.inner.create(request).await)
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
        self.answer(self.inner.post_inbox(id, message).await)
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
