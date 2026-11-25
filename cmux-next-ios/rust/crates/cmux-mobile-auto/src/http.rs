//! The Cloud store's owner routes over the phone's HTTP path.
//!
//! The phone already reaches the Cloud service as the signed-in person (its Chief and Cloud
//! Machines pages). [`HttpTransport`] is that path: it adds the bearer and the build space and
//! sends one request. [`HttpAutoCloud`] is the store on top of it.
//!
//! A phone reads chats and writes to the inbox, `keep` and `POST /`. It never holds a chat, so
//! the holder's and the machine's routes are refused here without a request.

use std::future::Future;

use cmux_auto_session::cloud::{AutoCloud, AutoCloudError, CloudResult};
use cmux_auto_session::consts::WAIT_MAX_MS;
use cmux_auto_session::wire::{
    Assignment, CreateRequest, EventsAppend, EventsPage, Fence, InboxAck, InboxMessage, InboxPost,
    InboxPosted, KeepRequest, LeaseAnswer, LeaseRequest, MachineSetting, PutRequest, SessionAnswer,
    SessionList, SessionView, SnapshotAnswer, SnapshotPost,
};
use serde::Serialize;
use serde::de::DeserializeOwned;

/// Where the store's routes live on the Cloud service.
pub const ROOT: &str = "/v1/auto-sessions";

/// How long an ordinary request may take.
pub const REQUEST_TIMEOUT_MS: u64 = 20_000;

/// A held request may take this much longer than the time the store holds it.
pub const HELD_SLACK_MS: u64 = 10_000;

/// One request to the Cloud service. The transport adds who sends it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpRequest {
    pub method: &'static str,
    /// The path and query, from the service's root.
    pub path: String,
    /// A JSON body, when the request has one.
    pub body: Option<String>,
    /// The transport gives up after this long.
    pub timeout_ms: u64,
}

/// The service's answer, whatever its status.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpReply {
    pub status: u16,
    pub body: String,
}

/// The phone's HTTP path to the Cloud service as the signed-in person. An error is a request
/// that got no answer (no network, a timeout), in words for a log.
pub trait HttpTransport: Send + Sync {
    fn send(&self, request: HttpRequest) -> impl Future<Output = Result<HttpReply, String>> + Send;
}

/// The store as the signed-in person, over `T`.
#[derive(Debug)]
pub struct HttpAutoCloud<T> {
    transport: T,
}

impl<T: HttpTransport> HttpAutoCloud<T> {
    pub fn new(transport: T) -> HttpAutoCloud<T> {
        HttpAutoCloud { transport }
    }

    pub fn transport(&self) -> &T {
        &self.transport
    }

    async fn call<A: DeserializeOwned>(&self, request: HttpRequest) -> CloudResult<A> {
        let reply = self.transport.send(request).await.map_err(AutoCloudError::transport)?;
        if !(200..300).contains(&reply.status) {
            return Err(AutoCloudError::from_response(reply.status, reply.body.as_bytes()));
        }
        serde_json::from_str(&reply.body).map_err(|error| AutoCloudError::decoding(error.to_string()))
    }

    async fn read<A: DeserializeOwned>(&self, path: String, timeout_ms: u64) -> CloudResult<A> {
        self.call(HttpRequest { method: "GET", path, body: None, timeout_ms }).await
    }

    async fn post<B: Serialize + Sync, A: DeserializeOwned>(&self, path: String, body: &B) -> CloudResult<A> {
        let body =
            serde_json::to_string(body).map_err(|error| AutoCloudError::decoding(error.to_string()))?;
        let request = HttpRequest { method: "POST", path, body: Some(body), timeout_ms: REQUEST_TIMEOUT_MS };
        self.call(request).await
    }
}

/// A chat's path. An id that is not one of the store's is refused here, so it never becomes
/// part of a path; a `:` goes percent-encoded, which the store reads back.
fn chat_path(id: &str, rest: &str) -> CloudResult<String> {
    let named = !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b':' | b'-'));
    if !named || id == "machine" || id == "assignments" {
        return Err(AutoCloudError::http(404, "not_found", "no such chat"));
    }
    Ok(format!("{ROOT}/{}{rest}", id.replace(':', "%3A")))
}

/// `value` as one query value.
fn query(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// A route only a holder or a Cloud machine uses.
fn not_a_phones<A>() -> CloudResult<A> {
    Err(AutoCloudError::http(403, "auth.forbidden", "a phone does not hold a chat"))
}

impl<T: HttpTransport> AutoCloud for HttpAutoCloud<T> {
    async fn machine(&self) -> CloudResult<MachineSetting> {
        self.read(format!("{ROOT}/machine"), REQUEST_TIMEOUT_MS).await
    }

    async fn set_machine(&self, _setting: &MachineSetting) -> CloudResult<MachineSetting> {
        not_a_phones()
    }

    async fn put(&self, _id: &str, _request: &PutRequest) -> CloudResult<SessionView> {
        not_a_phones()
    }

    async fn create(&self, request: &CreateRequest) -> CloudResult<SessionView> {
        let answer: SessionAnswer = self.post(ROOT.to_owned(), request).await?;
        Ok(answer.session)
    }

    async fn list(&self, limit: Option<u32>, cursor: Option<&str>) -> CloudResult<SessionList> {
        let mut parts: Vec<String> = Vec::new();
        if let Some(limit) = limit {
            parts.push(format!("limit={limit}"));
        }
        if let Some(cursor) = cursor.filter(|cursor| !cursor.is_empty()) {
            parts.push(format!("cursor={}", query(cursor)));
        }
        let path = if parts.is_empty() { ROOT.to_owned() } else { format!("{ROOT}?{}", parts.join("&")) };
        self.read(path, REQUEST_TIMEOUT_MS).await
    }

    async fn get(&self, id: &str) -> CloudResult<SessionView> {
        let answer: SessionAnswer = self.read(chat_path(id, "")?, REQUEST_TIMEOUT_MS).await?;
        Ok(answer.session)
    }

    async fn wait(&self, id: &str, after: u64, timeout_ms: u64) -> CloudResult<SessionView> {
        let held = timeout_ms.min(WAIT_MAX_MS);
        let path = chat_path(id, &format!("/wait?after={after}&timeoutMs={held}"))?;
        let answer: SessionAnswer = self.read(path, held.saturating_add(HELD_SLACK_MS)).await?;
        Ok(answer.session)
    }

    async fn lease(&self, _id: &str, _request: &LeaseRequest) -> CloudResult<LeaseAnswer> {
        not_a_phones()
    }

    async fn release(&self, _id: &str, _fence: &Fence) -> CloudResult<SessionView> {
        not_a_phones()
    }

    async fn append_events(&self, _id: &str, _request: &EventsAppend) -> CloudResult<u64> {
        not_a_phones()
    }

    async fn events(&self, id: &str, after: u64, limit: Option<u32>) -> CloudResult<EventsPage> {
        let limit = limit.map(|limit| format!("&limit={limit}")).unwrap_or_default();
        self.read(chat_path(id, &format!("/events?after={after}{limit}"))?, REQUEST_TIMEOUT_MS).await
    }

    async fn put_chunk(&self, _id: &str, _sha256: &str, _bytes: &[u8], _fence: &Fence) -> CloudResult<()> {
        not_a_phones()
    }

    async fn chunk(&self, _id: &str, _sha256: &str) -> CloudResult<Vec<u8>> {
        not_a_phones()
    }

    async fn post_snapshot(&self, _id: &str, _request: &SnapshotPost) -> CloudResult<u64> {
        not_a_phones()
    }

    async fn snapshot(&self, _id: &str) -> CloudResult<SnapshotAnswer> {
        not_a_phones()
    }

    async fn post_inbox(&self, id: &str, message: &InboxPost) -> CloudResult<InboxPosted> {
        self.post(chat_path(id, "/inbox")?, message).await
    }

    async fn inbox(&self, _id: &str, _after: u64) -> CloudResult<Vec<InboxMessage>> {
        not_a_phones()
    }

    async fn ack_inbox(&self, _id: &str, _ack: &InboxAck) -> CloudResult<SessionView> {
        not_a_phones()
    }

    async fn keep(&self, id: &str, keep_in_cloud: bool) -> CloudResult<SessionView> {
        let answer: SessionAnswer =
            self.post(chat_path(id, "/keep")?, &KeepRequest { keep_in_cloud }).await?;
        Ok(answer.session)
    }

    async fn assignments(&self, _timeout_ms: u64) -> CloudResult<Vec<Assignment>> {
        not_a_phones()
    }

    async fn ack_assignment(&self, _id: &str, _fence: &Fence) -> CloudResult<SessionView> {
        not_a_phones()
    }
}
