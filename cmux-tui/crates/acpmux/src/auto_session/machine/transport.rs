//! The Cloud machine's transport: [`AutoCloud`] through the machine's Cloud agent.
//!
//! A Cloud machine's daemon holds no Cloud credential. Each store call is one JSON line to the
//! agent's Auto mode socket (cmux-host `cloud/auto_session.rs`), which sends it as the machine's
//! VM install and writes one reply line back. One connection per call, so a held `assignments`
//! wait never delays a renewal.
//!
//! The store takes a VM install for a machine: its holder is `vm:<that machine>`
//! ([`MachineCloud::holder`]) and it reaches only chats that machine holds. The routes that are
//! the owner's (the Auto machine setting, `PUT`, `POST`, the list, `wait`, a send to the inbox,
//! `keep`) are refused here as the store would refuse them, without a request.

use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_auto_session::cloud::{AutoCloud, AutoCloudError, CloudResult};
use cmux_auto_session::wire::{
    Assignment, Assignments, CreateRequest, EventsAppend, EventsAppended, EventsPage, Fence,
    Holder, InboxAck, InboxMessage, InboxPage, InboxPost, InboxPosted, LeaseAnswer, LeaseRequest,
    MachineSetting, PutRequest, SessionAnswer, SessionList, SessionView, SnapshotAnswer,
    SnapshotPost, SnapshotPosted,
};
use cmux_host::cloud::auto_session::{Call, Kind, SOCKET};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};

/// Overrides the agent's Auto mode socket path (tests, and a dev machine's own agent).
pub const SOCKET_ENV: &str = "ACPMUX_CLOUD_AUTO_SESSION_SOCKET";

/// How long past the call's own bound the daemon waits for the reply line: the agent may mint a
/// bearer first.
const REPLY_MARGIN: Duration = Duration::from_secs(20);

/// The agent's Auto mode socket: [`SOCKET_ENV`], else cmux-host's path.
pub fn socket_path() -> PathBuf {
    std::env::var_os(SOCKET_ENV).map_or_else(|| PathBuf::from(SOCKET), PathBuf::from)
}

/// The store, reached through the Cloud agent's socket.
#[derive(Clone, Debug)]
pub struct MachineCloud {
    socket: PathBuf,
}

impl MachineCloud {
    /// The store behind the agent socket at `socket`.
    pub fn new(socket: impl Into<PathBuf>) -> MachineCloud {
        MachineCloud { socket: socket.into() }
    }

    /// The store behind this machine's agent ([`socket_path`]).
    pub fn here() -> MachineCloud {
        MachineCloud::new(socket_path())
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// The agent's socket is there. An agent older than Auto mode has none.
    pub fn present(&self) -> bool {
        self.socket.exists()
    }

    /// This machine's holder name, `vm:<machine>`: the machine the agent's install is bound to.
    /// An error until the agent is bound.
    pub async fn holder(&self) -> CloudResult<Holder> {
        let reply = self.ask(&Call::machine()).await?;
        match reply.get("machine").and_then(Value::as_str).filter(|m| !m.is_empty()) {
            Some(machine) => Ok(Holder::vm(machine)),
            None => Err(AutoCloudError::decoding("the Cloud agent did not name its machine")),
        }
    }

    /// One call. `Ok` is a reply with `ok: true`.
    async fn ask(&self, call: &Call) -> CloudResult<Value> {
        read_reply(self.exchange(call).await?)
    }

    /// One call: its line out, the reply line in, whatever it says.
    async fn exchange(&self, call: &Call) -> CloudResult<Value> {
        let line = call.to_line();
        let exchange = async {
            let mut stream = tokio::net::UnixStream::connect(&self.socket).await?;
            stream.write_all(line.as_bytes()).await?;
            stream.write_all(b"\n").await?;
            let mut reply = Vec::new();
            let mut reader = tokio::io::BufReader::new(stream.take(reply_cap(call)));
            reader.read_until(b'\n', &mut reply).await?;
            Ok::<_, std::io::Error>(reply)
        };
        let reply = match tokio::time::timeout(call.within() + REPLY_MARGIN, exchange).await {
            Err(_) => return Err(AutoCloudError::transport("the Cloud agent did not answer")),
            Ok(Err(error)) => {
                return Err(AutoCloudError::transport(format!("the agent's socket: {error}")));
            }
            Ok(Ok(reply)) => reply,
        };
        if reply.last() != Some(&b'\n') {
            return Err(AutoCloudError::transport("the Cloud agent closed without a reply"));
        }
        serde_json::from_slice(&reply)
            .map_err(|_| AutoCloudError::decoding("the Cloud agent's reply is not JSON"))
    }

    /// The store's JSON answer to `call`, as `T`.
    async fn answer<T: DeserializeOwned>(&self, call: Call) -> CloudResult<T> {
        body_of(&call, self.ask(&call).await?)
    }

    /// A write: `body` is the route's JSON body.
    async fn write<T: DeserializeOwned>(
        &self,
        kind: Kind,
        id: &str,
        body: &impl Serialize,
    ) -> CloudResult<T> {
        let body = serde_json::to_value(body)
            .map_err(|error| AutoCloudError::decoding(format!("the request's body: {error}")))?;
        self.answer(Call::write(kind, id, body)).await
    }
}

/// The most bytes a reply line may have: the answer and its JSON wrapper, a third more for a
/// chunk in base64.
fn reply_cap(call: &Call) -> u64 {
    let answer = call.answer_limit() as u64;
    let answer = if call.kind == Kind::Chunk { answer / 3 * 4 + 4 } else { answer };
    answer + 64 * 1024
}

/// The `body` of an `ok` reply to `call`, as `T`.
fn body_of<T: DeserializeOwned>(call: &Call, mut reply: Value) -> CloudResult<T> {
    let body = reply.get_mut("body").map(Value::take).unwrap_or(Value::Null);
    serde_json::from_value(body).map_err(|error| {
        AutoCloudError::decoding(format!("the store's answer to {}: {error}", call.kind.name()))
    })
}

/// The code of a refusal the agent made itself (it has no `status`).
fn agent_code(reply: &Value) -> Option<&str> {
    if reply.get("status").is_some() {
        return None;
    }
    reply.get("error")?.get("code")?.as_str()
}

/// A reply line as a result: the reply itself when it says `ok`, else why not.
fn read_reply(reply: Value) -> CloudResult<Value> {
    if reply.get("ok") == Some(&Value::Bool(true)) {
        return Ok(reply);
    }
    // The store's own refusal: its status and its body as it sent them.
    if let Some(status) = reply.get("status").and_then(Value::as_u64) {
        let body = serde_json::to_vec(reply.get("body").unwrap_or(&Value::Null));
        let status = u16::try_from(status).unwrap_or(500);
        return Err(AutoCloudError::from_response(status, &body.unwrap_or_default()));
    }
    // The agent's: it did not send the call, or no answer came.
    let field = |name: &str| {
        reply.get("error").and_then(|e| e.get(name)).and_then(Value::as_str).unwrap_or("")
    };
    let (code, message) = (field("code"), field("message"));
    Err(match code {
        "request.invalid" => AutoCloudError::http(400, code, message),
        "auto.bad_answer" => AutoCloudError::decoding(message),
        // `busy`, `vm.unbound`, `vm.agent_stopping`, `auto.unreachable`, `auto.resumed`: the
        // same call may go through later.
        _ => AutoCloudError::transport(format!("the Cloud agent: {code}: {message}")),
    })
}

/// The store's answer to a machine on a route that is the owner's.
fn owners<T>() -> CloudResult<T> {
    Err(AutoCloudError::http(403, "auth.forbidden", "a Cloud machine cannot do this"))
}

impl AutoCloud for MachineCloud {
    async fn machine(&self) -> CloudResult<MachineSetting> {
        owners()
    }

    async fn set_machine(&self, _setting: &MachineSetting) -> CloudResult<MachineSetting> {
        owners()
    }

    async fn put(&self, _id: &str, _request: &PutRequest) -> CloudResult<SessionView> {
        owners()
    }

    async fn create(&self, _request: &CreateRequest) -> CloudResult<SessionView> {
        owners()
    }

    async fn list(&self, _limit: Option<u32>, _cursor: Option<&str>) -> CloudResult<SessionList> {
        owners()
    }

    async fn get(&self, id: &str) -> CloudResult<SessionView> {
        let answer: SessionAnswer = self.answer(Call::read(Kind::Get, id)).await?;
        Ok(answer.session)
    }

    async fn wait(&self, _id: &str, _after: u64, _timeout_ms: u64) -> CloudResult<SessionView> {
        owners()
    }

    async fn lease(&self, id: &str, request: &LeaseRequest) -> CloudResult<LeaseAnswer> {
        self.write(Kind::Lease, id, request).await
    }

    async fn release(&self, id: &str, fence: &Fence) -> CloudResult<SessionView> {
        let answer: SessionAnswer = self.write(Kind::Release, id, fence).await?;
        Ok(answer.session)
    }

    async fn append_events(&self, id: &str, request: &EventsAppend) -> CloudResult<u64> {
        let answer: EventsAppended = self.write(Kind::EventsAppend, id, request).await?;
        Ok(answer.last_seq)
    }

    async fn events(&self, id: &str, after: u64, limit: Option<u32>) -> CloudResult<EventsPage> {
        self.answer(Call::page(Kind::Events, id, after, limit)).await
    }

    async fn put_chunk(
        &self,
        id: &str,
        sha256: &str,
        bytes: &[u8],
        fence: &Fence,
    ) -> CloudResult<()> {
        let holder = fence.holder.to_string();
        self.ask(&Call::chunk_put(id, sha256, &holder, fence.epoch, bytes)).await.map(|_| ())
    }

    async fn chunk(&self, id: &str, sha256: &str) -> CloudResult<Vec<u8>> {
        let reply = self.ask(&Call::chunk(id, sha256)).await?;
        reply
            .get("bytes")
            .and_then(Value::as_str)
            .and_then(|text| BASE64.decode(text).ok())
            .ok_or_else(|| AutoCloudError::decoding("the Cloud agent's reply has no chunk"))
    }

    async fn post_snapshot(&self, id: &str, request: &SnapshotPost) -> CloudResult<u64> {
        let answer: SnapshotPosted = self.write(Kind::SnapshotPost, id, request).await?;
        Ok(answer.snapshot)
    }

    async fn snapshot(&self, id: &str) -> CloudResult<SnapshotAnswer> {
        self.answer(Call::read(Kind::Snapshot, id)).await
    }

    async fn post_inbox(&self, _id: &str, _message: &InboxPost) -> CloudResult<InboxPosted> {
        owners()
    }

    async fn inbox(&self, id: &str, after: u64) -> CloudResult<Vec<InboxMessage>> {
        let page: InboxPage = self.answer(Call::page(Kind::Inbox, id, after, None)).await?;
        Ok(page.messages)
    }

    async fn ack_inbox(&self, id: &str, ack: &InboxAck) -> CloudResult<SessionView> {
        let answer: SessionAnswer = self.write(Kind::InboxAck, id, ack).await?;
        Ok(answer.session)
    }

    async fn keep(&self, _id: &str, _keep_in_cloud: bool) -> CloudResult<SessionView> {
        owners()
    }

    async fn assignments(&self, timeout_ms: u64) -> CloudResult<Vec<Assignment>> {
        let call = Call::assignments(timeout_ms);
        let reply = self.exchange(&call).await?;
        // The machine resumed while the store held the wait. The agent ended it so the daemon
        // asks again at once: nothing was lost, there is only nothing to report from this one.
        if agent_code(&reply) == Some("auto.resumed") {
            return Ok(Vec::new());
        }
        let answer: Assignments = body_of(&call, read_reply(reply)?)?;
        Ok(answer.assignments)
    }

    async fn ack_assignment(&self, id: &str, fence: &Fence) -> CloudResult<SessionView> {
        let answer: SessionAnswer = self.write(Kind::AssignmentAck, id, fence).await?;
        Ok(answer.session)
    }
}
