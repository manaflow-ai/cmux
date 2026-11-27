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
//! - send (store and forward): the same `session/prompt`, keyed by the
//!   composer's client message id, so a copy that also came over the link runs
//!   once; it steers unless the phone said not to;
//! - compose: `_acpmux/info` shows the session, then `_acpmux/queue_edit`
//!   (`_acpmux/queue_remove` for `remove`); a queued prompt that is gone is
//!   `not_pending`;
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

use cmux_deadline::{IdleDeadline, Stalled};
use futures_util::future::BoxFuture;
use futures_util::{SinkExt, Stream, StreamExt};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio_tungstenite::tungstenite::Message;

use crate::chief_policy::ChiefPolicy;
use crate::config::AcpmuxTarget;
use crate::mailbox::{ActionKind, Applier, Rejection, Reply, terminal_surface};
use crate::policy::{DaemonPolicy, Verdict};

/// How long one daemon or Chief round trip may take: one answer line on a socket that sends
/// nothing else for the request to show progress with.
const ROUND_TRIP: Duration = Duration::from_secs(10);
/// How long acpmux may say nothing at all (no frame on hostd's own WebSocket) before a round trip
/// to it is given up. Any frame restarts it: a busy acpmux that is still talking is not failed.
/// Leo, 2026-11-24: "10s timeout for messages being sendsble is a shame. if it's making good
/// progress, it shiukd be allowed to keep going?"
const ACPMUX_SILENCE: Duration = Duration::from_secs(10);
/// The backstop past which an acpmux round trip that kept talking but never answered is left.
/// Like a silent one it is `Unavailable`: the reply is kept and tried again, never refused.
const ACPMUX_CAP: Duration = Duration::from_secs(10 * 60);
/// How long a sent prompt is watched for an immediate refusal.
const PROMPT_ACCEPT: Duration = Duration::from_secs(2);
/// How long the connection that sent a prompt stays open for its turn once acpmux says nothing:
/// a silence bound, so a turn that keeps streaming keeps its connection.
const PROMPT_TURN: Duration = Duration::from_secs(3600);
/// The oldest terminal notification that still takes a reply.
pub const TERMINAL_REPLY_AGE: Duration = Duration::from_secs(15 * 60);

/// The live services of this hostd.
pub struct LiveApplier {
    pub acpmux: AcpmuxTarget,
    /// The app's daemon socket (the `daemon` service's default session).
    pub daemon_socket: PathBuf,
    pub chief_socket: Option<PathBuf>,
    pub session_exposure: Option<tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
}

impl Applier for LiveApplier {
    fn apply<'a>(&'a self, reply: &'a Reply) -> BoxFuture<'a, Result<(), Rejection>> {
        Box::pin(async move {
            match reply.kind.as_str() {
                "question" | "permission" => self.respond(reply).await,
                "completed" | "failed" | "send" => self.prompt(reply).await,
                "compose" => self.compose(reply).await,
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

/// `_acpmux/info` refusing the session means it is gone (`not_pending`); acpmux
/// not answering (closed, silent, unreachable) is not an answer, so the item is
/// kept and tried again rather than settled.
fn gone_unless_unreachable(rejection: Rejection) -> Rejection {
    match rejection {
        Rejection::Unavailable(why) => Rejection::Unavailable(why),
        _ => Rejection::NotPending,
    }
}

/// `_acpmux/info` is the authority that resolves a phone-facing alias to the
/// ACP session id. An absent or malformed result is unknown and therefore
/// refused before any mutation can be sent.
fn resolved_session(info: &Value) -> Result<String, Rejection> {
    info.get("sessionId")
        .and_then(Value::as_str)
        .filter(|session| !session.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| refused("acpmux did not identify the session"))
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

/// `session/prompt` params for a text reply to a session. It steers a running turn, as the
/// link's reply (`PushReplyPlan.promptMeta`) and Send in the chat do (Leo, 2026-11-05: "WHY THE
/// F*** ARE MY MESSAGES BEING QUEUED INSTEAD OF STEERING"); an idle chat, or an agent that
/// cannot steer, runs it as its next turn.
///
/// A `send` (store and forward) is the chat's own Send: its id is the composer's client message
/// id, the `promptId` its link copy carries too, so acpmux runs it once whichever came first
/// (`resend: true`); it steers unless the phone said `steer: false`.
pub fn prompt_params(reply: &Reply) -> Value {
    json!({
        "sessionId": reply.target.session_id,
        "prompt": [{"type": "text", "text": reply.text}],
        "_meta": {"acpmux": {"promptId": reply.id, "steer": reply.steer, "resend": true}},
    })
}

/// The acpmux method and params of a `compose` item: `_acpmux/queue_remove`
/// for `remove`, else `_acpmux/queue_edit {sessionId, promptId, op, text?, index?}`.
pub fn compose_request(reply: &Reply) -> Result<(&'static str, Value), Rejection> {
    let queue = reply.queue.as_ref().ok_or_else(|| refused("no queue action"))?;
    let mut params = json!({"sessionId": reply.target.session_id, "promptId": queue.prompt_id});
    if queue.op == "remove" {
        return Ok(("_acpmux/queue_remove", params));
    }
    params["op"] = json!(queue.op);
    if let Some(text) = &queue.text {
        params["text"] = json!(text);
    }
    if let Some(index) = queue.index {
        params["index"] = json!(index);
    }
    Ok(("_acpmux/queue_edit", params))
}

/// A queue answer: `queue_edit`'s `ok` or `queue_remove`'s `removed` false means
/// the prompt no longer waits.
pub fn compose_outcome(method: &str, answer: &Value) -> Result<(), Rejection> {
    let key = if method == "_acpmux/queue_remove" { "removed" } else { "ok" };
    match answer.get(key).and_then(Value::as_bool) {
        Some(true) => Ok(()),
        Some(false) => Err(Rejection::NotPending),
        None => Err(refused("acpmux did not say whether the queue changed")),
    }
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
    reply_to_notification_with_exposure(daemon_socket, phone, notification, surface, None, text, None).await
}

async fn reply_to_notification_with_exposure(
    daemon_socket: &std::path::Path,
    phone: &str,
    notification: u64,
    surface: Option<u64>,
    target_session: Option<&str>,
    text: &str,
    session_exposure: Option<&tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
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
        AgentOnTerminal::Unknown => {
            return Err(refused("an agent runs in that terminal; answer it in the app"));
        }
        AgentOnTerminal::Session(session) => {
            exposure_allows(session_exposure, Some(&session))?;
            let identify =
                lines.call_daemon(&policy, &json!({"id": "mailbox-identify", "cmd": "identify"})).await?;
            if !has_capability(&identify, SEND_EXPECT_AGENT) {
                return Err(refused("update cmux on this Mac to reply to an agent from a notification"));
            }
            exposure_allows(session_exposure, Some(&session))?;
            let Some(answer) = lines
                .call_daemon_if_allowed(&policy, &agent_reply_line(found, text, &program, &session))
                .await?
            else {
                return Err(refused("update cmux on this Mac to reply to an agent from a notification"));
            };
            return failed(&answer).map_or(Ok(()), |why| Err(refused(why)));
        }
    }
    // A terminal without an agent mapping is an unrelated terminal and keeps
    // its existing reply behavior. If the reply itself names a session, use it
    // as the final exposure key before the first terminal write.
    exposure_allows(session_exposure, target_session)?;
    for line in terminal_lines(found, text, &program) {
        exposure_allows(session_exposure, target_session)?;
        let answer = lines.call_daemon(&policy, &line).await?;
        if let Some(why) = failed(&answer) {
            return Err(refused(why));
        }
    }
    Ok(())
}

fn exposure_allows(
    exposure: Option<&tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
    session: Option<&str>,
) -> Result<(), Rejection> {
    if let (Some(session), Some(exposure)) = (session, exposure) {
        let state = exposure.borrow().clone();
        if !state.available || state.blocked.contains(session) {
            return Err(refused("this chat is not exposed to iPhone Remote Control"));
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
    session_exposure: Option<&tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
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
    let outcome = reply_to_notification_with_exposure(
        daemon_socket,
        phone,
        notification,
        None,
        None,
        text,
        session_exposure,
    )
    .await;
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
pub const SEND_EXPECT_AGENT: &str = cmux_mobile_link::names::SEND_EXPECT_AGENT;

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
    fn exposure_allows(&self, session: Option<&str>) -> Result<(), Rejection> {
        exposure_allows(self.session_exposure.as_ref(), session)
    }
    async fn respond(&self, reply: &Reply) -> Result<(), Rejection> {
        let mut acpmux = Acpmux::connect(&self.acpmux).await?;
        let info = acpmux.call("_acpmux/info", json!({"sessionId": reply.target.session_id})).await?;
        let session = resolved_session(&info)?;
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
        let mut params = permission_params(reply, &pending)?;
        params["sessionId"] = Value::String(session.clone());
        // This is deliberately the last policy read before the mutation. The
        // signed alias is never used as the exposure key or wire session id.
        self.exposure_allows(Some(&session))?;
        acpmux.call("_acpmux/permission_respond", params).await.map(|_| ())
    }

    async fn prompt(&self, reply: &Reply) -> Result<(), Rejection> {
        let mut acpmux = Acpmux::connect(&self.acpmux).await?;
        // An acpmux that went quiet is not an answer: the reply is kept and tried again.
        let info = acpmux
            .call("_acpmux/info", json!({"sessionId": reply.target.session_id}))
            .await
            .map_err(gone_unless_unreachable)?;
        let session = resolved_session(&info)?;
        let mut params = prompt_params(reply);
        params["sessionId"] = Value::String(session.clone());
        // Keep this check immediately before the prompt send: a revocation
        // during alias resolution must win over a stale signed reply.
        self.exposure_allows(Some(&session))?;
        acpmux.prompt(params).await
    }

    async fn compose(&self, reply: &Reply) -> Result<(), Rejection> {
        let (method, mut params) = compose_request(reply)?;
        let mut acpmux = Acpmux::connect(&self.acpmux).await?;
        let info = acpmux
            .call("_acpmux/info", json!({"sessionId": reply.target.session_id}))
            .await
            .map_err(gone_unless_unreachable)?;
        let session = resolved_session(&info)?;
        params["sessionId"] = Value::String(session.clone());
        // Last before the change, as for a prompt: a revocation meanwhile wins.
        self.exposure_allows(Some(&session))?;
        let answer = acpmux.call(method, params).await?;
        compose_outcome(method, &answer)
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
        reply_to_notification_with_exposure(
            &self.daemon_socket,
            &reply.phone,
            notification,
            Some(surface),
            reply.target.session_id.as_deref(),
            text,
            self.session_exposure.as_ref(),
        )
        .await
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
        // A lost connection is not an answer: the item is kept and tried again.
        self.socket.send(Message::Text(request.into())).await.map_err(|e| unavailable(e.to_string()))?;
        Ok(id)
    }

    async fn call(&mut self, method: &str, params: Value) -> Result<Value, Rejection> {
        let id = self.send(method, params).await?;
        answer_within(&mut self.socket, &id, ACPMUX_SILENCE, Some(ACPMUX_CAP)).await
    }

    /// Sends a prompt: refused if acpmux says so at once; otherwise accepted,
    /// and the connection stays open in the background until its turn ends.
    async fn prompt(mut self, params: Value) -> Result<(), Rejection> {
        let id = self.send("session/prompt", params).await?;
        match answer_within(&mut self.socket, &id, PROMPT_ACCEPT, Some(PROMPT_ACCEPT)).await {
            // Not answered at once: accepted. The connection stays open for the turn.
            Err(Rejection::Unavailable(_)) => {
                tokio::spawn(async move {
                    let _ = answer_within(&mut self.socket, &id, PROMPT_TURN, None).await;
                });
                Ok(())
            }
            result => result.map(|_| ()),
        }
    }
}

/// Reads acpmux `frames` until the answer to `id`. Every frame acpmux sends restarts the `silence`
/// bound, so only an acpmux that said nothing for it (or kept talking past `cap`) is given up,
/// and that is `Unavailable`: the reply is kept and tried again, not refused. Each acpmux step is
/// safe to try again (`_acpmux/info` first; a prompt runs once per `promptId`).
async fn answer_within<S, E>(
    frames: &mut S,
    id: &str,
    silence: Duration,
    cap: Option<Duration>,
) -> Result<Value, Rejection>
where
    S: Stream<Item = Result<Message, E>> + Unpin,
{
    let mut deadline = IdleDeadline::<tokio::time::Instant>::new(silence, cap);
    loop {
        let frame = tokio::select! {
            frame = frames.next() => frame,
            () = tokio::time::sleep_until(deadline.end()) => {
                return Err(match deadline.stalled() {
                    Some(Stalled::Cap { elapsed }) => {
                        unavailable(format!("acpmux kept talking but did not answer in {elapsed:?}"))
                    }
                    _ => unavailable(format!("acpmux said nothing for {silence:?}")),
                });
            }
        };
        let Some(frame) = frame else { return Err(refused("acpmux closed")) };
        deadline.progressed();
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
            steer: true,
            queue: None,
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
    fn an_info_answer_must_name_a_canonical_session() {
        assert_eq!(resolved_session(&json!({"sessionId": "s-canonical"})).unwrap(), "s-canonical");
        assert!(resolved_session(&json!({"sessionId": ""})).is_err());
        assert!(resolved_session(&json!({"pending": []})).is_err());
    }

    #[test]
    fn exposure_checks_use_the_resolved_session_id() {
        let (tx, exposure) = tokio::sync::watch::channel(crate::control::SessionExposure {
            available: true,
            configured: true,
            allowed: Default::default(),
            blocked: ["s-canonical".to_owned()].into_iter().collect(),
        });
        assert!(exposure_allows(Some(&exposure), Some("s-canonical")).is_err());
        assert!(exposure_allows(Some(&exposure), Some("visible-alias")).is_ok());
        let previous = exposure.borrow().clone();
        tx.send_replace(crate::control::SessionExposure { available: false, ..previous });
        assert!(exposure_allows(Some(&exposure), Some("visible-alias")).is_err());
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
        // It steers a running turn, as the link's reply and Send in the chat do.
        let params = prompt_params(&reply("completed", ActionKind::Text));
        assert_eq!(params["_meta"]["acpmux"], json!({"promptId": "r1", "steer": true, "resend": true}));
    }

    #[test]
    fn a_send_is_the_chats_own_send_keyed_by_its_client_message_id() {
        // The link copy of the chat's Send (`session/prompt` with the composer's client message
        // id as `promptId`) and its mailbox copy name one prompt: acpmux runs it once.
        let mut send = reply("send", ActionKind::Text);
        send.id = "msg-7f3a".into();
        let mailbox_copy = prompt_params(&send);
        let link_copy = json!({"sessionId": "s1", "prompt": [{"type": "text", "text": "ship it"}],
                               "_meta": {"acpmux": {"promptId": "msg-7f3a", "steer": true}}});
        assert_eq!(mailbox_copy["_meta"]["acpmux"]["promptId"], link_copy["_meta"]["acpmux"]["promptId"]);
        assert_eq!(mailbox_copy["_meta"]["acpmux"]["resend"], true);
        assert_eq!(mailbox_copy["prompt"], link_copy["prompt"]);
        // `steer: false` from the phone queues it as the next turn.
        send.steer = false;
        assert_eq!(prompt_params(&send)["_meta"]["acpmux"]["steer"], false);
        let request =
            json!({"jsonrpc": "2.0", "id": 1, "method": "session/prompt", "params": prompt_params(&send)});
        assert!(crate::acpmux_policy::refusal(&request.to_string()).is_none());
    }

    #[test]
    fn a_compose_is_a_queue_edit_or_remove_and_a_gone_prompt_is_not_pending() {
        let compose = |op: &str, text: Option<&str>, index: Option<u64>| {
            let mut r = reply("compose", ActionKind::Queue);
            r.queue = Some(crate::mailbox::QueueAction {
                op: op.into(),
                prompt_id: "q1".into(),
                text: text.map(str::to_owned),
                index,
            });
            compose_request(&r).unwrap()
        };
        assert_eq!(
            compose("update", Some("new words"), None),
            (
                "_acpmux/queue_edit",
                json!({"sessionId": "s1", "promptId": "q1", "op": "update", "text": "new words"})
            )
        );
        assert_eq!(
            compose("move", None, Some(0)),
            ("_acpmux/queue_edit", json!({"sessionId": "s1", "promptId": "q1", "op": "move", "index": 0}))
        );
        assert_eq!(
            compose("send_now", None, None),
            ("_acpmux/queue_edit", json!({"sessionId": "s1", "promptId": "q1", "op": "send_now"}))
        );
        assert_eq!(
            compose("remove", None, None),
            ("_acpmux/queue_remove", json!({"sessionId": "s1", "promptId": "q1"}))
        );
        assert!(compose_request(&reply("compose", ActionKind::Queue)).is_err());
        // Both pass the phone's acpmux narrowing.
        for (method, params) in [compose("update", Some("x"), None), compose("remove", None, None)] {
            let request = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
            assert!(crate::acpmux_policy::refusal(&request.to_string()).is_none(), "{method}");
        }
        // acpmux's answers: changed, or the prompt no longer waits.
        assert_eq!(compose_outcome("_acpmux/queue_edit", &json!({"ok": true, "op": "update"})), Ok(()));
        assert_eq!(compose_outcome("_acpmux/queue_edit", &json!({"ok": false})), Err(Rejection::NotPending));
        assert_eq!(compose_outcome("_acpmux/queue_remove", &json!({"removed": true})), Ok(()));
        assert_eq!(
            compose_outcome("_acpmux/queue_remove", &json!({"removed": false})),
            Err(Rejection::NotPending)
        );
        assert!(matches!(compose_outcome("_acpmux/queue_edit", &json!({})), Err(Rejection::Refused(_))));
    }

    #[test]
    fn an_unreachable_acpmux_is_unavailable_not_a_gone_prompt() {
        // A lost socket or a timeout is not an answer: the item stays held and is retried.
        assert!(matches!(gone_unless_unreachable(unavailable("acpmux closed")), Rejection::Unavailable(_)));
        // An answer that the session or prompt is not there is final.
        assert_eq!(
            gone_unless_unreachable(Rejection::Refused("no such session".into())),
            Rejection::NotPending
        );
        assert_eq!(gone_unless_unreachable(Rejection::NotPending), Rejection::NotPending);
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
        assert!(!matches!(
            daemon.evaluate(&serde_json::to_vec(&agents_line(7)).unwrap()),
            Verdict::Refuse(_)
        ));
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

#[cfg(test)]
mod live_notification_exposure_tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    #[tokio::test]
    async fn live_notification_reply_cannot_type_into_a_blocked_agent() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("daemon.sock");
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let backend = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let (read, mut write) = socket.into_split();
            let mut lines = BufReader::new(read).lines();
            let mut commands = Vec::new();
            while let Some(line) = lines.next_line().await.unwrap() {
                let request: Value = serde_json::from_str(&line).unwrap();
                let cmd = request["cmd"].as_str().unwrap().to_owned();
                commands.push(cmd.clone());
                let data = match cmd.as_str() {
                    "list-notifications" => {
                        json!({"notifications":[{"notification":12,"surface":7,"reply":true,
                        "created_at_ms":crate::mailbox::now()*1000,"poster_pid":5000,"poster_executable":"/usr/local/bin/claude"}]})
                    }
                    "process-info" => {
                        json!({"foreground_pid":5000,"foreground_executable":"/usr/local/bin/claude"})
                    }
                    "list-agents" => {
                        json!({"agents":[{"surface":7,"agent":"claude","state":"blocked","agent_session_id":"chat-off"}]})
                    }
                    "identify" => json!({"capabilities":[SEND_EXPECT_AGENT]}),
                    _ => json!({}),
                };
                let answer = json!({"id":request["id"],"ok":true,"data":data});
                write.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
            }
            commands
        });
        let (_tx, exposure) = tokio::sync::watch::channel(crate::control::SessionExposure {
            configured: true,
            blocked: ["chat-off".to_owned()].into_iter().collect(),
            ..crate::control::SessionExposure::default()
        });
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            answer_notification_reply(
                &path,
                "phone",
                None,
                br#"{"id":"phone-reply","cmd":"notification-reply","notification":12,"text":"do it"}"#,
                Some(&exposure),
            ),
        )
        .await
        .unwrap();
        let result: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["error_code"], "refused");
        assert!(result["error"].as_str().unwrap().contains("not exposed"));
        let commands =
            tokio::time::timeout(std::time::Duration::from_secs(5), backend).await.unwrap().unwrap();
        assert!(commands.iter().any(|cmd| cmd == "list-agents"));
        assert!(!commands.iter().any(|cmd| cmd == "send"));
    }
}

#[cfg(test)]
mod acpmux_silence_tests {
    use super::*;
    use tokio::sync::mpsc;
    use tokio::time::Instant;

    type Frames = std::pin::Pin<Box<dyn Stream<Item = Result<Message, std::convert::Infallible>> + Send>>;

    /// acpmux as a stream of frames fed by `tx`.
    fn acpmux() -> (mpsc::UnboundedSender<Message>, Frames) {
        let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
        let frames = futures_util::stream::poll_fn(move |cx| rx.poll_recv(cx).map(|m| m.map(Ok)));
        (tx, Box::pin(frames))
    }

    /// `elapsed` is `expected`, give or take the timer's millisecond.
    fn about(elapsed: Duration, expected: Duration) {
        assert!(
            elapsed >= expected && elapsed < expected + Duration::from_millis(5),
            "{elapsed:?} vs {expected:?}"
        );
    }

    fn notice() -> Message {
        Message::Text(json!({"jsonrpc":"2.0","method":"session/update","params":{}}).to_string().into())
    }

    #[tokio::test(start_paused = true)]
    async fn an_acpmux_that_keeps_talking_is_waited_for_past_the_old_round_trip() {
        // Leo, 2026-11-24: "if it's making good progress, it shiukd be allowed to keep going?"
        // A frame every 8 s for 2 minutes against the 10 s bound that used to count from the send:
        // the answer at 2 minutes is taken, not refused.
        let (tx, mut frames) = acpmux();
        let talker = tokio::spawn(async move {
            for _ in 0..15 {
                tokio::time::sleep(Duration::from_secs(8)).await;
                tx.send(notice()).unwrap();
            }
            let answer = json!({"jsonrpc":"2.0","id":"mailbox-1","result":{"ok":true}});
            tx.send(Message::Text(answer.to_string().into())).unwrap();
            tx
        });
        let started = Instant::now();
        let answer = answer_within(&mut frames, "mailbox-1", ACPMUX_SILENCE, Some(ACPMUX_CAP)).await;
        assert_eq!(answer, Ok(json!({"ok":true})));
        about(started.elapsed(), Duration::from_secs(120));
        drop(talker.await.unwrap());
    }

    #[tokio::test(start_paused = true)]
    async fn a_silent_acpmux_is_given_up_at_the_silence_bound_and_the_reply_kept() {
        let (tx, mut frames) = acpmux();
        let started = Instant::now();
        let answer = answer_within(&mut frames, "mailbox-1", ACPMUX_SILENCE, Some(ACPMUX_CAP)).await;
        assert!(matches!(answer, Err(Rejection::Unavailable(_))), "{answer:?}");
        about(started.elapsed(), ACPMUX_SILENCE);
        drop(tx);
    }

    #[tokio::test(start_paused = true)]
    async fn an_acpmux_that_talked_then_went_quiet_is_given_up_one_bound_after_its_last_frame() {
        let (tx, mut frames) = acpmux();
        let talker = tokio::spawn(async move {
            for _ in 0..3 {
                tokio::time::sleep(Duration::from_secs(8)).await;
                tx.send(notice()).unwrap();
            }
            tx
        });
        let started = Instant::now();
        let answer = answer_within(&mut frames, "mailbox-1", ACPMUX_SILENCE, Some(ACPMUX_CAP)).await;
        assert!(matches!(answer, Err(Rejection::Unavailable(_))), "{answer:?}");
        about(started.elapsed(), Duration::from_secs(24) + ACPMUX_SILENCE);
        drop(talker.await.unwrap());
    }

    #[tokio::test(start_paused = true)]
    async fn an_acpmux_that_talks_forever_without_answering_ends_at_the_backstop_kept() {
        let (tx, mut frames) = acpmux();
        let talker = tokio::spawn(async move {
            while tx.send(notice()).is_ok() {
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        });
        let started = Instant::now();
        let answer = answer_within(&mut frames, "mailbox-1", ACPMUX_SILENCE, Some(ACPMUX_CAP)).await;
        assert!(matches!(answer, Err(Rejection::Unavailable(_))), "{answer:?}");
        about(started.elapsed(), ACPMUX_CAP);
        drop(frames);
        talker.await.unwrap();
    }
}
