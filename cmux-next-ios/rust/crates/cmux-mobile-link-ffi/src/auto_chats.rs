//! Auto chats for the app (`plans/cmux-next/auto-mode/DESIGN.md`, slice E): the person's Auto
//! chats listed, opened, sent to and started through the Cloud service with no Mac.
//!
//! The logic is `cmux-mobile-auto`. This file is its surface for Swift:
//!
//! - [`AutoHttp`] is implemented by the app: one request to the Cloud service as the signed-in
//!   person, over the path its other Cloud pages use (the bearer and the build space are the
//!   app's).
//! - [`AutoChats`] lists and starts chats; [`AutoChat`] is one open chat.
//!
//! Lists, rows and batches cross as JSON text (camelCase, the shapes of `cmux_mobile_auto`'s
//! `ChatList`, `Started` and `Batch`), so the transcript records reach Swift as the records its
//! chat view already reads.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use cmux_auto_session::cloud::AutoCloudError;
use cmux_mobile_auto::chat::{Batch, ChatSession};
use cmux_mobile_auto::http::{HttpAutoCloud, HttpReply, HttpRequest, HttpTransport};
use cmux_mobile_auto::start::NewChat;
use cmux_mobile_auto::{rows, start};
use serde::Serialize;
use tokio::sync::watch;

/// One request to the Cloud service. `path` starts with `/v1/auto-sessions`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AutoHttpRequest {
    pub method: String,
    pub path: String,
    /// A JSON body, when the request has one.
    pub body: Option<String>,
    /// Give up after this long. A held request asks for more than an ordinary one.
    pub timeout_ms: u64,
}

/// The service's answer, whatever its status.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AutoHttpReply {
    pub status: u16,
    pub body: String,
}

/// A request that got no answer: no network, a timeout, no sign-in to send it with.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum AutoHttpError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for AutoHttpError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed { message: error.reason }
    }
}

/// The app's HTTP path to the Cloud service as the signed-in person.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait AutoHttp: Send + Sync {
    async fn send(&self, request: AutoHttpRequest) -> Result<AutoHttpReply, AutoHttpError>;
}

/// Why a call failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum AutoChatError {
    /// No answer arrived. The same call may work later.
    #[error("no answer: {message}")]
    Unreachable { message: String },
    /// The service answered with an error: its status, its code (`auto.no_machine`,
    /// `not_found`, `auth.forbidden`; empty when it gave none) and its words.
    #[error("refused: {status} {code}: {message}")]
    Refused { status: u16, code: String, message: String },
    /// An answer this build cannot read.
    #[error("unreadable: {message}")]
    Unreadable { message: String },
}

impl From<AutoCloudError> for AutoChatError {
    fn from(error: AutoCloudError) -> Self {
        match error {
            AutoCloudError::Http { status, raw_code, message, .. } => {
                Self::Refused { status, code: raw_code, message }
            }
            AutoCloudError::Transport { message } => Self::Unreachable { message },
            AutoCloudError::Decoding { message } => Self::Unreadable { message },
        }
    }
}

/// The app's [`AutoHttp`] as the transport the client logic sends through.
#[derive(Clone)]
struct AppHttp(Arc<dyn AutoHttp>);

impl HttpTransport for AppHttp {
    async fn send(&self, request: HttpRequest) -> Result<HttpReply, String> {
        let request = AutoHttpRequest {
            method: request.method.to_owned(),
            path: request.path,
            body: request.body,
            timeout_ms: request.timeout_ms,
        };
        match self.0.send(request).await {
            Ok(reply) => Ok(HttpReply { status: reply.status, body: reply.body }),
            Err(error) => Err(error.to_string()),
        }
    }
}

fn json<T: Serialize>(value: &T) -> Result<String, AutoChatError> {
    serde_json::to_string(value).map_err(|error| AutoChatError::Unreadable { message: error.to_string() })
}

/// The person's Auto chats.
#[derive(uniffi::Object)]
pub struct AutoChats {
    cloud: HttpAutoCloud<AppHttp>,
}

#[uniffi::export]
impl AutoChats {
    #[uniffi::constructor]
    pub fn new(http: Arc<dyn AutoHttp>) -> Arc<Self> {
        Arc::new(Self { cloud: HttpAutoCloud::new(AppHttp(http)) })
    }

    /// The person's open chats, newest first, and the repositories they work in: the JSON of
    /// `{chats: [row], repos: [{remote, branch}], more}`. A row is `{id, title, harness, place,
    /// keepInCloud, inCloud, repo, updatedAt, closed}`; `place` is `cloud`, `resuming`,
    /// `coming_back`, `on_mac`, `idle` or `no_machine`.
    pub async fn list(&self) -> Result<String, AutoChatError> {
        json(&rows::list(&self.cloud).await?)
    }

    /// Whether the person has a Cloud machine for Auto chats to run on.
    pub async fn has_machine(&self) -> Result<bool, AutoChatError> {
        Ok(start::has_machine(&self.cloud).await?)
    }

    /// Starts a chat in `remote` at `branch` with a first message. `message_id` is made once
    /// for the message: the same call again reaches the chat the first one made. The JSON of
    /// `{outcome: "chat", chat: row}`, `{outcome: "no_machine"}` or `{outcome: "incomplete"}`.
    pub async fn start(
        &self,
        remote: String,
        branch: String,
        message_id: String,
        text: String,
    ) -> Result<String, AutoChatError> {
        let new = NewChat { remote, branch, message_id, text };
        json(&start::start(&self.cloud, &new).await?)
    }

    /// One chat, to open.
    pub fn chat(&self, id: String) -> Arc<AutoChat> {
        let cloud = HttpAutoCloud::new(self.cloud.transport().clone());
        let (closed, _) = watch::channel(false);
        Arc::new(AutoChat { session: ChatSession::new(cloud, id), closed, wait_ms: AtomicU64::new(0) })
    }
}

/// One open chat. Every answer is the JSON of a batch: `{chat: row, records: [record],
/// caughtUp, ended, retryAfterMs}`. `records` are transcript records to draw, oldest first.
#[derive(uniffi::Object)]
pub struct AutoChat {
    session: ChatSession<HttpAutoCloud<AppHttp>>,
    /// True once the app left the chat: a held `next` ends.
    closed: watch::Sender<bool>,
    /// How long the next read waits first: what the last one asked for when it got no answer.
    wait_ms: AtomicU64,
}

#[uniffi::export]
impl AutoChat {
    /// Reads the chat and its first page of records.
    pub async fn open(&self) -> Result<String, AutoChatError> {
        json(&self.session.open().await?)
    }

    /// The next records. The call is held until the chat changes, or about 25 s, so the app
    /// calls it again as soon as it answers, until a batch says `ended`. After a read that got
    /// no answer it waits before it reads again; the app does not time anything. An error is
    /// the service refusing the chat.
    pub async fn next(&self) -> Result<String, AutoChatError> {
        let wait_ms = self.wait_ms.swap(0, Ordering::SeqCst);
        let read = async {
            if wait_ms > 0 {
                pause(wait_ms).await;
            }
            self.session.next().await
        };
        let mut closed = self.closed.subscribe();
        let left = async {
            let _ = closed.wait_for(|closed| *closed).await;
        };
        let batch = tokio::select! {
            biased;
            () = left => ended(),
            batch = read => batch?,
        };
        self.wait_ms.store(batch.retry_after_ms.unwrap_or(0), Ordering::SeqCst);
        json(&batch)
    }

    /// Sends `text` under `message_id`. The same id again is not a second message, so a send
    /// that failed is sent again with the id it had.
    pub async fn send(&self, message_id: String, text: String) -> Result<String, AutoChatError> {
        json(&self.session.send(&message_id, &text).await?)
    }

    /// Keeps the chat in the Cloud when a Mac returns, or stops keeping it.
    pub async fn keep(&self, keep_in_cloud: bool) -> Result<String, AutoChatError> {
        json(&self.session.keep(keep_in_cloud).await?)
    }

    /// The app left the chat: a held `next` answers `ended` now, and so does every later one.
    pub fn close(&self) {
        self.closed.send_replace(true);
    }
}

/// The batch of a chat the app left.
fn ended() -> Batch {
    Batch { chat: None, records: Vec::new(), caught_up: false, ended: true, retry_after_ms: None }
}

/// Waits `ms` on the library's timer.
async fn pause(ms: u64) {
    let _ = crate::runtime().spawn(tokio::time::sleep(Duration::from_millis(ms))).await;
}

#[cfg(test)]
mod tests;
