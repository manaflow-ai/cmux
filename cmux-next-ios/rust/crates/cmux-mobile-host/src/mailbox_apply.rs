//! Applies a checked mailbox reply (`mailbox.rs`) through the services a
//! phone's link reaches, with the same policies, as that phone would:
//!
//! - question, permission: `_acpmux/info` shows the permission still
//!   pending, then `_acpmux/permission_respond` with the approval `_meta` the
//!   phone signed after Face ID (acpmux checks it again); a deny must name a
//!   reject option and carries no approval;
//! - completed, failed: `_acpmux/info` shows the session, then
//!   `session/prompt` with the reply id as its `promptId` (acpmux runs each
//!   once);
//! - chief: `conversation-list` through `ChiefPolicy` shows the conversation
//!   in the phone's scope, then `conversation-op` `message.send`;
//! - terminal: the notification is still in the ledger on that surface
//!   (`list-notifications`), its poster asked for replies (`reply`), it is at
//!   most [`TERMINAL_REPLY_AGE`] old, and the program that posted it (its
//!   process-group leader and executable, which the daemon recorded) still
//!   holds the terminal (`process-info`); then the text is pasted and Return
//!   sent, each write only while that program is still the foreground
//!   (`expect_foreground`), as the Mac's own notification reply does
//!   (`NotificationCenterService.type(_:into:)`). A daemon that records no
//!   poster gets no terminal reply.
//!
//! A service this hostd cannot reach (connect fails before anything is sent)
//! is `Unavailable`: the reply is kept and tried again, not refused.

use std::path::PathBuf;
use std::time::Duration;

use futures_util::future::BoxFuture;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio_tungstenite::tungstenite::Message;

use crate::chief_policy::ChiefPolicy;
use crate::config::AcpmuxTarget;
use crate::mailbox::{ActionKind, Applier, Rejection, Reply, terminal_surface};
use crate::policy::{DaemonPolicy, Verdict};

/// How long one service round trip may take.
const ROUND_TRIP: Duration = Duration::from_secs(10);
/// How long a sent prompt is watched for an immediate refusal.
const PROMPT_ACCEPT: Duration = Duration::from_secs(2);
/// How long the connection that sent a prompt stays open for its turn.
const PROMPT_TURN: Duration = Duration::from_secs(3600);
/// The oldest terminal notification that still takes a reply.
pub const TERMINAL_REPLY_AGE: Duration = Duration::from_secs(15 * 60);

/// The live services of this hostd.
pub struct LiveApplier {
    pub acpmux: AcpmuxTarget,
    /// The app's daemon socket (the `daemon` service's default session).
    pub daemon_socket: PathBuf,
    pub chief_socket: Option<PathBuf>,
}

impl Applier for LiveApplier {
    fn apply<'a>(&'a self, reply: &'a Reply) -> BoxFuture<'a, Result<(), Rejection>> {
        Box::pin(async move {
            match reply.kind.as_str() {
                "question" | "permission" => self.respond(reply).await,
                "completed" | "failed" => self.prompt(reply).await,
                "chief" => self.chief(reply).await,
                "terminal" => self.terminal(reply).await,
                _ => Err(Rejection::Refused("unknown kind".into())),
            }
        })
    }
}

fn refused(why: impl Into<String>) -> Rejection {
    Rejection::Refused(why.into())
}

fn unavailable(why: impl Into<String>) -> Rejection {
    Rejection::Unavailable(why.into())
}

/// `_acpmux/permission_respond` params for a question or permission reply,
/// given the pending prompt (`_acpmux/info`'s `pending` entry).
pub fn permission_params(reply: &Reply, pending: &Value) -> Result<Value, Rejection> {
    let options = pending.pointer("/request/options").and_then(Value::as_array).cloned().unwrap_or_default();
    let kind_of = |o: &Value| o.get("kind").and_then(Value::as_str).unwrap_or_default().to_owned();
    let id_of = |o: &Value| o.get("optionId").and_then(Value::as_str).map(str::to_owned);
    let option_id = match (reply.option_id.clone(), reply.action == ActionKind::Deny) {
        (Some(id), _) => id,
        // A deny from a push the Mac trimmed names no option: the prompt's own
        // reject (reject once first), never an allow.
        (None, true) => options
            .iter()
            .find(|o| kind_of(o) == "reject_once")
            .or_else(|| options.iter().find(|o| kind_of(o).starts_with("reject")))
            .and_then(id_of)
            .ok_or_else(|| refused("this prompt offers no reject"))?,
        (None, false) => return Err(refused("no option")),
    };
    let option_id = option_id.as_str();
    let kind = options
        .iter()
        .find(|o| o.get("optionId").and_then(Value::as_str) == Some(option_id))
        .map(kind_of)
        .ok_or_else(|| refused("the option is not offered"))?;
    let reject = kind.starts_with("reject");
    let mut params = json!({
        "sessionId": reply.target.session_id,
        "permissionId": reply.target.permission_id,
        "optionId": option_id,
    });
    if let Some(answers) = &reply.answers {
        params["answers"] = answers.clone();
    }
    match (reply.action == ActionKind::Deny, reject) {
        // A deny is never signed.
        (true, true) => {}
        (true, false) => return Err(refused("a deny must name a reject option")),
        (false, true) => return Err(refused("an answer must not name a reject option")),
        (false, false) => {
            // An Allow or answer counts only with the phone's own Face ID approval.
            let approval =
                reply.approval.as_ref().ok_or_else(|| refused("an Allow needs the phone's approval"))?;
            let approver = approval.pointer("/acpmux/approverDecision/approver").and_then(Value::as_str);
            if approver != Some(reply.phone.as_str()) {
                return Err(refused("the approval is not this phone's"));
            }
            params["_meta"] = approval.clone();
        }
    }
    Ok(params)
}

/// `session/prompt` params for a text reply to a session.
pub fn prompt_params(reply: &Reply) -> Value {
    json!({
        "sessionId": reply.target.session_id,
        "prompt": [{"type": "text", "text": reply.text}],
        "_meta": {"acpmux": {"promptId": reply.id, "steer": false, "resend": true}},
    })
}

/// The Chief `conversation-op` line for a text reply.
pub fn chief_line(reply: &Reply) -> Value {
    json!({
        "id": "mailbox-send",
        "cmd": "conversation-op",
        "conversation": reply.target.conversation_id,
        "idempotency_key": reply.id,
        "op": {"kind": "message.send", "client_msg_id": reply.id, "parts": [{"type": "text", "text": reply.text}]},
    })
}

/// The row of `notification` (the `notification` event's number) while
/// `ledger` (`list-notifications`) still holds it.
pub fn ledger_row(ledger: &Value, notification: u64) -> Option<&Value> {
    let data = ledger.get("data").unwrap_or(ledger);
    data.get("notifications")?
        .as_array()?
        .iter()
        .find(|row| row.get("notification").and_then(Value::as_u64) == Some(notification))
}

/// The surface of `notification` while `ledger` still holds it; `None` when
/// it is gone or belongs to no terminal.
pub fn ledger_surface(ledger: &Value, notification: u64) -> Option<u64> {
    ledger_row(ledger, notification)?.get("surface").and_then(Value::as_u64)
}

/// The program a terminal reply may go to: the row's poster, when the poster
/// asked for replies, the row is at most [`TERMINAL_REPLY_AGE`] old at
/// `now_ms`, and that same program (pid and executable) holds the terminal now
/// (`info`, `process-info`'s answer). Else why not.
pub fn reply_target(row: &Value, info: &Value, now_ms: u64) -> Result<String, Rejection> {
    if row.get("reply").and_then(Value::as_bool) != Some(true) {
        return Err(refused("this notification takes no reply"));
    }
    let created = row.get("created_at_ms").and_then(Value::as_u64).unwrap_or(0);
    if now_ms.saturating_sub(created) > TERMINAL_REPLY_AGE.as_millis() as u64 {
        return Err(Rejection::NotPending);
    }
    let (Some(pid), Some(executable)) = (
        row.get("poster_pid").and_then(Value::as_u64),
        row.get("poster_executable").and_then(Value::as_str).filter(|e| !e.is_empty()),
    ) else {
        return Err(refused("this Mac can't tell which program asked"));
    };
    let data = info.get("data").unwrap_or(info);
    let now_pid = data.get("foreground_pid").and_then(Value::as_u64);
    let now_executable = data.get("foreground_executable").and_then(Value::as_str);
    if now_pid != Some(pid) || now_executable != Some(executable) {
        return Err(Rejection::NotPending);
    }
    foreground_program(info)
        .filter(|p| p == executable)
        .ok_or_else(|| refused("only a shell runs in that terminal"))
}

/// Whether `ledger` still holds `notification` on `surface`.
pub fn in_ledger(ledger: &Value, notification: u64, surface: u64) -> bool {
    ledger_surface(ledger, notification) == Some(surface)
}

/// A reply to a terminal notification, over the link (`notification-reply`)
/// or from the mailbox: the text goes only to the program that posted
/// `notification`, in its terminal (`surface`, when the caller names one,
/// must be it), while it still holds that terminal ([`reply_target`]).
pub async fn reply_to_notification(
    daemon_socket: &std::path::Path,
    phone: &str,
    notification: u64,
    surface: Option<u64>,
    text: &str,
) -> Result<(), Rejection> {
    let policy = DaemonPolicy::new(phone);
    let mut lines = Lines::connect(daemon_socket).await?;
    let ledger =
        lines.call_daemon(&policy, &json!({"id": "mailbox-ledger", "cmd": "list-notifications"})).await?;
    let row = ledger_row(&ledger, notification).ok_or(Rejection::NotPending)?;
    let found = row.get("surface").and_then(Value::as_u64).ok_or(Rejection::NotPending)?;
    if surface.is_some_and(|s| s != found) {
        return Err(Rejection::NotPending);
    }
    let info = lines
        .call_daemon(&policy, &json!({"id": "mailbox-process", "cmd": "process-info", "surface": found}))
        .await?;
    let now_ms = crate::mailbox::now().saturating_mul(1000);
    let program = reply_target(row, &info, now_ms)?;
    // Any notification on a terminal where an agent runs (a hook's, or `cmux notify
    // --reply` from inside the agent): one write, text and Return, only while that agent
    // waits at its prompt in its own session (`send-expect-agent-v1`, #24205), so a Return
    // never lands on an approval dialog. Without the capability or the session, nothing
    // is typed (review 2, N1, N2). A plain program's terminal takes the two writes below.
    let agents = lines.call_daemon(&policy, &agents_line(found)).await?;
    match agent_session(&agents, found) {
        AgentOnTerminal::None => {}
        AgentOnTerminal::Unknown => return Err(refused("an agent runs in that terminal; answer it in the app")),
        AgentOnTerminal::Session(session) => {
            let identify =
                lines.call_daemon(&policy, &json!({"id": "mailbox-identify", "cmd": "identify"})).await?;
            if !has_capability(&identify, SEND_EXPECT_AGENT) {
                return Err(refused("update cmux on this Mac to reply to an agent from a notification"));
            }
            let Some(answer) = lines
                .call_daemon_if_allowed(&policy, &agent_reply_line(found, text, &program, &session))
                .await?
            else {
                return Err(refused("update cmux on this Mac to reply to an agent from a notification"));
            };
            return failed(&answer).map_or(Ok(()), |why| Err(refused(why)));
        }
    }
    for line in terminal_lines(found, text, &program) {
        let answer = lines.call_daemon(&policy, &line).await?;
        if let Some(why) = failed(&answer) {
            return Err(refused(why));
        }
    }
    Ok(())
}

/// hostd's answer to a phone's `notification-reply` line (already through
/// the policy): a v12 response line, ok or the reason.
///
/// With `reply_id` (the phone's reply id) it is applied at most once with
/// the mailbox copy of the same reply (`spent`): a repeat answers ok with
/// `duplicate: true` and types nothing.
pub async fn answer_notification_reply(
    daemon_socket: &std::path::Path,
    phone: &str,
    spent: Option<&crate::mailbox::SpentReplies>,
    line: &[u8],
) -> String {
    let request: Value = serde_json::from_slice(line).unwrap_or_default();
    let id = request.get("id");
    let notification = request.get("notification").and_then(Value::as_u64).unwrap_or_default();
    let text = request.get("text").and_then(Value::as_str).unwrap_or_default();
    let reply_id = request.get("reply_id").and_then(Value::as_str);
    if let (Some(spent), Some(reply)) = (spent, reply_id) {
        match spent.claim_link_reply(reply, crate::mailbox::now()) {
            crate::mailbox::Claim::Fresh => {}
            // Settled before (the mailbox copy came first): its first outcome again.
            crate::mailbox::Claim::Settled(outcome) if outcome == "applied" => {
                return json!({"id": id.cloned().unwrap_or(Value::Null), "ok": true, "data": {"duplicate": true}})
                    .to_string();
            }
            crate::mailbox::Claim::Settled(outcome) => {
                return crate::policy::error_line(id, "refused", &outcome);
            }
            crate::mailbox::Claim::Seen { .. } | crate::mailbox::Claim::Unreadable => {
                return crate::policy::error_line(
                    id,
                    "unavailable",
                    "that reply is not settled yet; try again",
                );
            }
        }
    }
    let outcome = reply_to_notification(daemon_socket, phone, notification, None, text).await;
    if let (Some(spent), Some(reply)) = (spent, reply_id) {
        match &outcome {
            Err(Rejection::Unavailable(_)) => spent.release_link_reply(reply),
            Ok(()) => spent.settle(reply, None),
            Err(rejection) => spent.settle(reply, Some(rejection.code())),
        }
    }
    match outcome {
        Ok(()) => json!({"id": id.cloned().unwrap_or(Value::Null), "ok": true, "data": {}}).to_string(),
        Err(Rejection::NotPending) => crate::policy::error_line(id, "not_found", "that notification is gone"),
        Err(Rejection::Unavailable(why)) => crate::policy::error_line(id, "unavailable", &why),
        Err(rejection) => {
            let why = match &rejection {
                Rejection::Refused(why) => why.clone(),
                other => other.code().to_owned(),
            };
            crate::policy::error_line(id, "refused", &why)
        }
    }
}

/// The foreground program of `process-info`'s reply when it is not a shell.
pub fn foreground_program(info: &Value) -> Option<String> {
    const SHELLS: &[&str] = &[
        "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login",
    ];
    let data = info.get("data").unwrap_or(info);
    let executable = data.get("foreground_executable").and_then(Value::as_str)?;
    let base = executable.rsplit('/').next().unwrap_or(executable).trim_start_matches('-');
    (!base.is_empty() && !SHELLS.contains(&base)).then(|| executable.to_owned())
}

/// The daemon capability of `send` `expect_agent` and `submit` (#24205).
pub const SEND_EXPECT_AGENT: &str = "send-expect-agent-v1";

/// Whether the daemon's `identify` answer lists `capability`.
pub fn has_capability(identify: &Value, capability: &str) -> bool {
    let data = identify.get("data").unwrap_or(identify);
    data.get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|all| all.iter().any(|c| c.as_str() == Some(capability)))
}

/// One `send` of a reply to an agent's notification: pasted and submitted only
/// while the terminal's agent waits at its prompt and `program` holds the terminal.
pub fn agent_reply_line(surface: u64, text: &str, program: &str, session: &str) -> Value {
    json!({"id": "mailbox-agent-reply", "cmd": "send", "surface": surface, "text": text, "paste": true,
           "submit": true, "expect_agent": {"session": session}, "expect_foreground": program})
}

/// What `list-agents` says runs on a terminal.
#[derive(Debug, PartialEq, Eq)]
pub enum AgentOnTerminal {
    None,
    Unknown,
    Session(String),
}

/// The agent on `surface` in `list-agents`' answer.
/// `list-agents` for the terminal of `surface` only (the daemon resolves the surface to its
/// terminal, whichever placement it reports the agent under).
pub fn agents_line(surface: u64) -> Value {
    json!({"id": "mailbox-agents", "cmd": "list-agents", "surface": surface})
}

/// The agent in `agents_line(surface)`'s answer: its only row. An answer to an unfiltered
/// request (an older daemon that ignores `surface`) is read by `surface`.
pub fn agent_session(agents: &Value, surface: u64) -> AgentOnTerminal {
    let data = agents.get("data").unwrap_or(agents);
    let rows: Vec<&Value> = data.get("agents").and_then(Value::as_array).into_iter().flatten().collect();
    let row = match rows.as_slice() {
        [only] => Some(*only),
        many => many.iter().copied().find(|a| a.get("surface").and_then(Value::as_u64) == Some(surface)),
    };
    let Some(row) = row else {
        return AgentOnTerminal::None;
    };
    match row.get("agent_session_id").and_then(Value::as_str).filter(|s| !s.is_empty()) {
        Some(session) => AgentOnTerminal::Session(session.to_owned()),
        None => AgentOnTerminal::Unknown,
    }
}

/// The two `send` lines of a terminal reply: the text pasted, then Return.
pub fn terminal_lines(surface: u64, text: &str, program: &str) -> [Value; 2] {
    [
        json!({"id": "mailbox-paste", "cmd": "send", "surface": surface, "text": text, "paste": true,
               "expect_foreground": program}),
        json!({"id": "mailbox-return", "cmd": "send", "surface": surface, "text": "\r", "expect_foreground": program}),
    ]
}

fn failed(reply: &Value) -> Option<String> {
    if reply.get("ok") == Some(&Value::Bool(false))
        || reply.get("error").is_some()
        || reply.get("error_code").is_some()
    {
        let message = reply
            .get("error")
            .and_then(|e| e.get("message").and_then(Value::as_str).or_else(|| e.as_str()))
            .or_else(|| reply.get("message").and_then(Value::as_str))
            .unwrap_or("refused");
        return Some(message.to_owned());
    }
    None
}

impl LiveApplier {
    async fn respond(&self, reply: &Reply) -> Result<(), Rejection> {
        let mut acpmux = Acpmux::connect(&self.acpmux).await?;
        let info = acpmux.call("_acpmux/info", json!({"sessionId": reply.target.session_id})).await?;
        let pending = info
            .get("pending")
            .and_then(Value::as_array)
            .and_then(|all| {
                all.iter().find(|p| {
                    p.get("permissionId").and_then(Value::as_str) == reply.target.permission_id.as_deref()
                })
            })
            .cloned()
            .ok_or(Rejection::NotPending)?;
        let params = permission_params(reply, &pending)?;
        acpmux.call("_acpmux/permission_respond", params).await.map(|_| ())
    }

    async fn prompt(&self, reply: &Reply) -> Result<(), Rejection> {
        let mut acpmux = Acpmux::connect(&self.acpmux).await?;
        acpmux
            .call("_acpmux/info", json!({"sessionId": reply.target.session_id}))
            .await
            .map_err(|_| Rejection::NotPending)?;
        acpmux.prompt(prompt_params(reply)).await
    }

    async fn chief(&self, reply: &Reply) -> Result<(), Rejection> {
        let path = self.chief_socket.as_ref().ok_or_else(|| refused("Chief is not set up on this Mac"))?;
        let policy = ChiefPolicy::new();
        let mut lines = Lines::connect(path).await?;
        let list = json!({"id": "mailbox-list", "cmd": "conversation-list"});
        let listed = lines.call_chief(&policy, &list).await?;
        let known = listed.pointer("/data/conversations").and_then(Value::as_array).is_some_and(|all| {
            all.iter().any(|c| c.get("id").and_then(Value::as_str) == reply.target.conversation_id.as_deref())
        });
        if !known {
            return Err(Rejection::NotPending);
        }
        let sent = lines.call_chief(&policy, &chief_line(reply)).await?;
        failed(&sent).map_or(Ok(()), |why| Err(refused(why)))
    }

    async fn terminal(&self, reply: &Reply) -> Result<(), Rejection> {
        let surface =
            terminal_surface(reply.target.tab_id.as_deref()).ok_or_else(|| refused("no terminal"))?;
        let notification: u64 = reply
            .target
            .notification_id
            .as_deref()
            .and_then(|n| n.parse().ok())
            .ok_or_else(|| refused("no notification"))?;
        let text = reply.text.as_deref().unwrap_or_default();
        reply_to_notification(&self.daemon_socket, &reply.phone, notification, Some(surface), text).await
    }
}

/// One acpmux WebSocket of hostd's own.
struct Acpmux {
    socket: crate::services::AcpmuxSocket,
    next: u64,
}

impl Acpmux {
    async fn connect(target: &AcpmuxTarget) -> Result<Self, Rejection> {
        let socket = crate::services::connect_acpmux(target).await.map_err(|r| unavailable(r.reason))?;
        let mut this = Self { socket, next: 0 };
        this.call(
            "initialize",
            json!({"protocolVersion": 1, "clientInfo": {"name": "cmux-mobile-host-mailbox", "version": "1"},
                   "clientCapabilities": {}}),
        )
        .await?;
        Ok(this)
    }

    async fn send(&mut self, method: &str, params: Value) -> Result<String, Rejection> {
        self.next += 1;
        let id = format!("mailbox-{}", self.next);
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string();
        // The phone's own narrowing on top of acpmux's remote guard.
        if crate::acpmux_policy::refusal(&request).is_some() {
            return Err(refused("an agent from iPhone runs only in a mode that asks"));
        }
        self.socket.send(Message::Text(request.into())).await.map_err(|e| refused(e.to_string()))?;
        Ok(id)
    }

    async fn answer(&mut self, id: &str) -> Result<Value, Rejection> {
        while let Some(frame) = self.socket.next().await {
            let Ok(Message::Text(text)) = frame else { continue };
            let Ok(reply) = serde_json::from_str::<Value>(&text) else { continue };
            if reply.get("id").and_then(Value::as_str) != Some(id) {
                continue;
            }
            if let Some(error) = reply.get("error") {
                let message = error.get("message").and_then(Value::as_str).unwrap_or("refused");
                return Err(refused(message.to_owned()));
            }
            return Ok(reply.get("result").cloned().unwrap_or(Value::Null));
        }
        Err(refused("acpmux closed"))
    }

    async fn call(&mut self, method: &str, params: Value) -> Result<Value, Rejection> {
        let id = self.send(method, params).await?;
        tokio::time::timeout(ROUND_TRIP, self.answer(&id))
            .await
            .map_err(|_| refused("acpmux did not answer"))?
    }

    /// Sends a prompt: refused if acpmux says so at once; otherwise accepted,
    /// and the connection stays open in the background until its turn ends.
    async fn prompt(mut self, params: Value) -> Result<(), Rejection> {
        let id = self.send("session/prompt", params).await?;
        match tokio::time::timeout(PROMPT_ACCEPT, self.answer(&id)).await {
            Ok(result) => result.map(|_| ()),
            Err(_) => {
                tokio::spawn(async move {
                    let _ = tokio::time::timeout(PROMPT_TURN, self.answer(&id)).await;
                });
                Ok(())
            }
        }
    }
}

/// A newline-delimited JSON socket (the daemon, the Chief owner).
struct Lines {
    reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: tokio::net::unix::OwnedWriteHalf,
}

impl Lines {
    async fn connect(path: &std::path::Path) -> Result<Self, Rejection> {
        let socket = UnixStream::connect(path).await.map_err(|e| unavailable(e.to_string()))?;
        let (read, writer) = socket.into_split();
        Ok(Self { reader: BufReader::new(read), writer })
    }

    async fn round_trip(&mut self, line: &[u8], id: &Value) -> Result<Value, Rejection> {
        let mut out = line.to_vec();
        out.push(b'\n');
        self.writer.write_all(&out).await.map_err(|e| refused(e.to_string()))?;
        let read = async {
            loop {
                let mut buffer = Vec::new();
                if self.reader.read_until(b'\n', &mut buffer).await.map_err(|e| refused(e.to_string()))? == 0
                {
                    return Err(refused("the socket closed"));
                }
                let Ok(reply) = serde_json::from_slice::<Value>(&buffer) else { continue };
                if reply.get("id") == Some(id) {
                    return Ok((reply, buffer));
                }
            }
        };
        tokio::time::timeout(ROUND_TRIP, read)
            .await
            .map_err(|_| refused("no answer"))?
            .map(|(reply, _)| reply)
    }

    /// `call_daemon`, or `None` when this host's policy refuses the request
    /// (a field it does not know yet): the caller falls back.
    async fn call_daemon_if_allowed(
        &mut self,
        policy: &DaemonPolicy,
        request: &Value,
    ) -> Result<Option<Value>, Rejection> {
        let line = serde_json::to_vec(request).unwrap_or_default();
        let line = match policy.evaluate(&line) {
            Verdict::Forward => line,
            Verdict::Rewrite(line) => line,
            Verdict::Refuse(_) => return Ok(None),
        };
        self.round_trip(&line, &request["id"]).await.map(Some)
    }

    async fn call_daemon(&mut self, policy: &DaemonPolicy, request: &Value) -> Result<Value, Rejection> {
        let line = serde_json::to_vec(request).unwrap_or_default();
        let line = match policy.evaluate(&line) {
            Verdict::Forward => line,
            Verdict::Rewrite(line) => line,
            Verdict::Refuse(answer) => return Err(refused(answer)),
        };
        let reply = self.round_trip(&line, &request["id"]).await?;
        failed(&reply).map_or(Ok(reply), |why| Err(refused(why)))
    }

    async fn call_chief(&mut self, policy: &ChiefPolicy, request: &Value) -> Result<Value, Rejection> {
        let line = serde_json::to_vec(request).unwrap_or_default();
        let line = match policy.evaluate(&line) {
            Verdict::Forward => line,
            Verdict::Rewrite(line) => line,
            Verdict::Refuse(answer) => return Err(refused(answer)),
        };
        let reply = self.round_trip(&line, &request["id"]).await?;
        // Through the reply filter, as the phone would see it (it learns the scope).
        let filtered = policy
            .filter_reply(&serde_json::to_vec(&reply).unwrap_or_default())
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .ok_or_else(|| refused("the Chief owner's answer was not for this request"))?;
        Ok(filtered)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mailbox::Target;

    fn reply(kind: &str, action: ActionKind) -> Reply {
        Reply {
            id: "r1".into(),
            phone: "phone-1".into(),
            kind: kind.into(),
            target: Target {
                session_id: Some("s1".into()),
                permission_id: Some("p1".into()),
                conversation_id: Some("conv_A".into()),
                tab_id: Some("s7".into()),
                notification_id: Some("12".into()),
            },
            action,
            option_id: Some("allow".into()),
            answers: None,
            text: Some("ship it".into()),
            approval: Some(
                json!({"acpmux": {"decisionNonce": "n", "approverDecision": {"approver": "phone-1",
                                  "expiresAt": 1, "signature": "ab"}}}),
            ),
            nonce: "n".repeat(16),
            expires_at: 1,
        }
    }

    fn pending() -> Value {
        json!({"permissionId": "p1", "request": {"options": [
            {"optionId": "allow", "kind": "allow_once"}, {"optionId": "always", "kind": "allow_always"},
            {"optionId": "no", "kind": "reject_once"}]}})
    }

    #[test]
    fn an_allow_carries_the_phones_approval_and_a_deny_none() {
        let allow = permission_params(&reply("permission", ActionKind::Allow), &pending()).unwrap();
        assert_eq!(allow["optionId"], "allow");
        assert_eq!(allow["_meta"]["acpmux"]["approverDecision"]["approver"], "phone-1");
        // Without the approval, or with another phone's: refused before acpmux.
        let mut bare = reply("permission", ActionKind::Allow);
        bare.approval = None;
        assert!(permission_params(&bare, &pending()).is_err());
        let mut borrowed = reply("permission", ActionKind::Allow);
        borrowed.approval = Some(json!({"acpmux": {"approverDecision": {"approver": "phone-2"}}}));
        assert!(permission_params(&borrowed, &pending()).is_err());
        // A deny names a reject option and carries no approval.
        let mut deny = reply("permission", ActionKind::Deny);
        deny.option_id = Some("no".into());
        let params = permission_params(&deny, &pending()).unwrap();
        assert!(params.get("_meta").is_none());
        // A "deny" that names an allow option, an allow that names a reject one, an unknown option: refused.
        let mut sneaky = reply("permission", ActionKind::Deny);
        sneaky.option_id = Some("always".into());
        assert!(permission_params(&sneaky, &pending()).is_err());
        let mut backwards = reply("permission", ActionKind::Allow);
        backwards.option_id = Some("no".into());
        assert!(permission_params(&backwards, &pending()).is_err());
        let mut unknown = reply("permission", ActionKind::Allow);
        unknown.option_id = Some("other".into());
        assert!(permission_params(&unknown, &pending()).is_err());
    }

    #[test]
    fn a_deny_with_no_option_takes_the_prompts_own_reject() {
        let mut deny = reply("permission", ActionKind::Deny);
        deny.option_id = None;
        assert_eq!(permission_params(&deny, &pending()).unwrap()["optionId"], "no");
        let only_always = json!({"permissionId": "p1", "request": {"options": [
            {"optionId": "allow", "kind": "allow_once"}, {"optionId": "never", "kind": "reject_always"}]}});
        assert_eq!(permission_params(&deny, &only_always).unwrap()["optionId"], "never");
        let none = json!({"permissionId": "p1", "request": {"options": [{"optionId": "allow", "kind": "allow_once"}]}});
        assert!(permission_params(&deny, &none).is_err());
        // An allow never picks an option for itself.
        let mut allow = reply("permission", ActionKind::Allow);
        allow.option_id = None;
        assert!(permission_params(&allow, &pending()).is_err());
    }

    #[test]
    fn a_prompt_is_run_once_whichever_way_it_came() {
        // The link sends `resend: true` too: acpmux finds the id in its log even after a restart.
        let params = prompt_params(&reply("completed", ActionKind::Text));
        assert_eq!(params["_meta"]["acpmux"], json!({"promptId": "r1", "steer": false, "resend": true}));
    }

    #[test]
    fn a_terminal_reply_goes_only_to_the_program_that_asked() {
        const NOW_MS: u64 = 1_792_540_900_000;
        let row = json!({"notification": 12, "surface": 7, "reply": true, "created_at_ms": NOW_MS - 60_000,
                         "poster_pid": 4242, "poster_executable": "/usr/bin/vim"});
        let info = json!({"data": {"foreground_pid": 4242, "foreground_executable": "/usr/bin/vim"}});
        assert_eq!(reply_target(&row, &info, NOW_MS).unwrap(), "/usr/bin/vim");
        // Another program holds the terminal now (ssh, sudo, psql...), or the same name in a new process.
        let other = json!({"data": {"foreground_pid": 5000, "foreground_executable": "/usr/bin/ssh"}});
        assert_eq!(reply_target(&row, &other, NOW_MS), Err(Rejection::NotPending));
        let restarted = json!({"data": {"foreground_pid": 5001, "foreground_executable": "/usr/bin/vim"}});
        assert_eq!(reply_target(&row, &restarted, NOW_MS), Err(Rejection::NotPending));
        // A poster that never asked for replies, a row too old, a daemon that records no poster.
        let mut no_reply = row.clone();
        no_reply["reply"] = json!(false);
        assert!(matches!(reply_target(&no_reply, &info, NOW_MS), Err(Rejection::Refused(_))));
        let old = NOW_MS + TERMINAL_REPLY_AGE.as_millis() as u64;
        assert_eq!(reply_target(&row, &info, old), Err(Rejection::NotPending));
        let mut anonymous = row;
        anonymous.as_object_mut().unwrap().remove("poster_pid");
        assert!(matches!(reply_target(&anonymous, &info, NOW_MS), Err(Rejection::Refused(_))));
        // The shell that posted it (`cmux notify --reply` typed at a prompt) gets nothing.
        let shell_row = json!({"notification": 12, "surface": 7, "reply": true, "created_at_ms": NOW_MS,
                               "poster_pid": 10, "poster_executable": "/bin/zsh"});
        let shell = json!({"data": {"foreground_pid": 10, "foreground_executable": "/bin/zsh"}});
        assert!(matches!(reply_target(&shell_row, &shell, NOW_MS), Err(Rejection::Refused(_))));
    }

    #[test]
    fn an_agents_notification_uses_expect_agent_where_the_daemon_has_it() {
        let identify = json!({"id": "x", "ok": true, "data": {"capabilities": ["send-expect-foreground-v1", SEND_EXPECT_AGENT]}});
        assert!(has_capability(&identify, SEND_EXPECT_AGENT));
        assert!(!has_capability(
            &json!({"data": {"capabilities": ["send-expect-foreground-v1"]}}),
            SEND_EXPECT_AGENT
        ));
        let line = agent_reply_line(7, "run the tests", "/usr/local/bin/claude", "0b6c3f8e");
        assert_eq!(line["submit"], true);
        // The daemon refuses `expect_agent` without the agent's session (review 2, N1).
        assert_eq!(line["expect_agent"], json!({"session": "0b6c3f8e"}));
        assert_eq!(line["expect_foreground"], "/usr/local/bin/claude");
        // `identify` passes this host's policy.
        let daemon = DaemonPolicy::new("phone-1");
        let identify = serde_json::to_vec(&json!({"id": "i", "cmd": "identify"})).unwrap();
        assert!(!matches!(daemon.evaluate(&identify), Verdict::Refuse(_)));
    }

    /// Review 2, N2: a reply to any notification on a terminal where an agent runs (a hook's,
    /// or `cmux notify --reply` posted from inside the agent) goes only through
    /// `expect_agent` with that agent's session; without the daemon capability it is
    /// refused, never typed blind onto an approval dialog.
    #[test]
    fn an_agent_on_the_terminal_needs_its_session_or_nothing_is_typed() {
        let agents = json!({"ok": true, "data": {"agents": [
            {"surface": 7, "state": "blocked", "agent": "claude", "agent_session_id": "0b6c3f8e"},
            {"surface": 9, "state": "idle", "agent": "codex"}]}});
        assert_eq!(agent_session(&agents, 7), AgentOnTerminal::Session("0b6c3f8e".into()));
        // An agent whose session is unknown: nothing to bind the write to.
        assert_eq!(agent_session(&agents, 9), AgentOnTerminal::Unknown);
        assert_eq!(agent_session(&agents, 3), AgentOnTerminal::None);
        assert_eq!(agent_session(&json!({"ok": true, "data": {}}), 7), AgentOnTerminal::None);
        // The request asks for that terminal (`list-agents {surface}`): a terminal shown in
        // two tabs reports its agent under another placement's surface, and it still counts
        // (review 3).
        let filtered = json!({"ok": true, "data": {"agents": [
            {"surface": 12, "state": "blocked", "agent": "claude", "agent_session_id": "s-1"}]}});
        assert_eq!(agent_session(&filtered, 7), AgentOnTerminal::Session("s-1".into()));
        assert_eq!(agents_line(7)["surface"], 7);
        let daemon = DaemonPolicy::new("phone-1");
        assert!(!matches!(daemon.evaluate(&serde_json::to_vec(&agents_line(7)).unwrap()), Verdict::Refuse(_)));
    }

    #[test]
    fn requests_pass_the_policies_a_link_uses() {
        // The prompt keeps the session's mode (no mode change in it).
        let prompt = json!({"jsonrpc": "2.0", "id": 1, "method": "session/prompt", "params": prompt_params(&reply("completed", ActionKind::Text))});
        assert!(crate::acpmux_policy::refusal(&prompt.to_string()).is_none());
        assert_eq!(prompt["params"]["_meta"]["acpmux"]["promptId"], "r1");
        // Chief: message.send of the phone's text.
        let line = serde_json::to_vec(&chief_line(&reply("chief", ActionKind::Text))).unwrap();
        let policy = ChiefPolicy::new();
        // Unknown conversation: refused until the list put it in scope.
        assert!(matches!(policy.evaluate(&line), Verdict::Refuse(_)));
        let list = br#"{"id":"mailbox-list","cmd":"conversation-list"}"#;
        assert!(matches!(policy.evaluate(list), Verdict::Forward));
        let listed = json!({"id": "mailbox-list", "ok": true, "data": {"conversations": [{"id": "conv_A", "participants": [
            {"id": "user_local", "kind": "human"}, {"id": "agent_mux", "kind": "agent"}]}]}});
        assert!(policy.filter_reply(listed.to_string().as_bytes()).is_some());
        assert!(matches!(policy.evaluate(&line), Verdict::Forward), "{:?}", policy.evaluate(&line));
        // Terminal: the ledger read, process-info and both sends pass the daemon policy.
        let daemon = DaemonPolicy::new("phone-1");
        for line in terminal_lines(7, "y", "/usr/bin/vim").into_iter().chain([
            json!({"id": "a", "cmd": "list-notifications"}),
            json!({"id": "b", "cmd": "process-info", "surface": 7}),
        ]) {
            let bytes = serde_json::to_vec(&line).unwrap();
            assert!(!matches!(daemon.evaluate(&bytes), Verdict::Refuse(_)), "{line}");
        }
    }

    #[test]
    fn a_terminal_reply_needs_its_notification_and_a_program() {
        let ledger = json!({"id": "x", "ok": true, "data": {"notifications": [{"notification": 12, "surface": 7},
                                                                              {"notification": 13, "workspace_id": "ws_1"}]}});
        assert_eq!(ledger_surface(&ledger, 12), Some(7));
        // A workspace notification has no terminal to reply to.
        assert_eq!(ledger_surface(&ledger, 13), None);
        assert!(in_ledger(&ledger, 12, 7));
        assert!(!in_ledger(&ledger, 12, 8));
        assert!(!in_ledger(&ledger, 13, 7));
        assert_eq!(
            foreground_program(&json!({"data": {"foreground_executable": "/usr/bin/vim"}})).as_deref(),
            Some("/usr/bin/vim")
        );
        assert_eq!(foreground_program(&json!({"data": {"foreground_executable": "-zsh"}})), None);
        assert_eq!(foreground_program(&json!({"data": {}})), None);
        let [paste, enter] = terminal_lines(7, "yes", "/usr/bin/vim");
        assert_eq!(paste["paste"], true);
        assert_eq!(paste["expect_foreground"], "/usr/bin/vim");
        assert_eq!(enter["text"], "\r");
    }
}
