//! `catch-up`: one request carrying every surface's cursor, one reply carrying every
//! surface's changes (`cmux-next-ios/design/background-delta-sync.md`, "one catch-up
//! request and one reply"). A wake used to pay a round trip per surface over the link
//! (workspaces 2, the chat list and each chat 3 to 4, terminals 2); here the phone pays
//! one, and hostd fans out on the Mac over loopback, in parallel:
//!
//! - the daemon: `list-workspaces` with the phone's cursor fields (`known`, `since`,
//!   `epoch`, `seq`, `limit`, `after`, whatever the phone's `workspaces` object holds)
//!   passed through as they came, so a daemon that keeps a change ring answers the
//!   changes and an older one, ignoring a field it does not know, the tree. With
//!   `workspaces.capabilities` a `set-client-info` goes first (`page-tabs-v1` changes
//!   how page tabs read).
//! - acpmux, on one connection (the phone's own credential when the app gave it one, else
//!   the dashboard token, as the `acpmux` channel connects): `_acpmux/watch
//!   {afterSeq, listEpoch}` for the chat list and one `_acpmux/attach` per chat, all
//!   pipelined, their replies matched by JSON-RPC id.
//!
//! Every line passes exactly the checks its own channel applies, through the same
//! functions: a daemon line [`services::checked_daemon_request`] (the session exposure,
//! [`crate::policy::DaemonPolicy`], ownership against the workspace cache, the exposure
//! again) and its reply [`services::exposed_daemon_reply`]; an acpmux message
//! [`services::AcpmuxRelay::upstream`] (canonical ids, exposure, the asking-mode rule,
//! Full-access marking) and its reply [`services::AcpmuxRelay::downstream`]. A chat the
//! phone may not see is left out of the reply altogether. With the exposure unreadable
//! the channel is refused, as `daemon` and `acpmux` are.
//!
//! Terminals are not in the reply. A terminal resume is a stream: its missed bytes and
//! then its live output come on the terminal's own `daemon` channel (`attach-surface
//! {resume_offset, resume_generation, resume_max_bytes}`), which the phone opens
//! pipelined next to this one. A `terminals` list in the request is ignored.
//!
//! Budget: `budgetBytes` (default 64 KiB, at most 256 KiB) is split across the chats in
//! request order (the first of several may take half, the rest share what is left), each
//! asked with its share as `maxBytes`. A chat whose page would take the reply past the
//! budget goes in `cut`, as does any surface that could not be answered (acpmux not
//! reachable, a timeout, an error reply); a cut surface's cursor does not move, and the
//! phone asks again next wake. `cutWhy` says why each was cut.
//!
//! One-shot, as `cloud-directory`: the open's args are the request; one reply frame, then
//! the channel closes.

use std::collections::HashMap;

use bytes::Bytes;
use cmux_mobile_link::link::ChannelSender;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::time::{Duration, Instant, timeout_at};
use tokio_tungstenite::tungstenite::Message;

use crate::config::ServiceConfig;
use crate::policy::DaemonPolicy;
use crate::services::{self, AcpmuxRelay, Downstream, Peer, Refusal, Upstream};

/// `budgetBytes` when the request names none.
pub const DEFAULT_BUDGET_BYTES: u64 = 64 * 1024;
/// The most `budgetBytes` may ask for.
pub const MAX_BUDGET_BYTES: u64 = 256 * 1024;
/// Chats one catch-up reads; the rest go in `cut`.
pub const MAX_CHATS: usize = 32;
/// acpmux's `beforeSeq` past any seq: with `afterSeq` the page is the newest records after
/// it (a tail-first read, `_acpmux/attach`). 2^53 - 1, a plain JSON integer.
pub const TAIL_BEFORE_SEQ: u64 = 9_007_199_254_740_991;
/// The records a chat shows (the app's `AcpmuxHub.chatKinds`), unless the request names its
/// own `chatKinds`.
pub const CHAT_KINDS: [&str; 7] = [
    "transcript",
    "queue_updated",
    "queue_order",
    "queue_paused",
    "queue_resumed",
    "claude.system.api_retry",
    "bookmarks",
];
/// Records per chat page (the app's `pageSize`).
const PAGE_RECORDS: u64 = 400;
/// The most one tool output takes in a page (the app's `toolOutputMaxBytes`).
const TOOL_OUTPUT_MAX_BYTES: u64 = 64 * 1024;
/// Chat list rows when the request names no `limit` (the app's first page).
const LIST_ROWS: u64 = 50;
/// The most chat-list rows one catch-up asks for.
const LIST_ROWS_MAX: u64 = 200;
/// The keys a request's `workspaces` cursor may carry (besides `capabilities`).
const WORKSPACE_KEYS: [&str; 4] = ["known", "since", "limit", "after"];
/// The longest daemon reply line read; a longer one is a failure, not an unbounded read.
const DAEMON_LINE_MAX: u64 = 2 * 1024 * 1024;
/// How long the daemon and acpmux each have to answer.
const ANSWER_WAIT: Duration = Duration::from_secs(10);

const WORKSPACES_ID: &str = "catch-up-workspaces";
const HELLO_ID: &str = "catch-up-hello";
const LIST_ID: &str = "catch-up-list";

/// One chat the phone asks about.
#[derive(Debug, Clone)]
struct Chat {
    session: String,
    last_seq: u64,
    /// The newest page first (`first: "screenful"`, the default), else forward from
    /// `lastSeq` (`first: "forward"`).
    tail: bool,
}

/// A parsed request (the channel's open args).
#[derive(Debug, Clone)]
struct Request {
    foreground: bool,
    budget: u64,
    workspaces: Map<String, Value>,
    capabilities: Option<Vec<Value>>,
    chat_list: Map<String, Value>,
    chats: Vec<Chat>,
    /// Asked chats past [`MAX_CHATS`].
    over: Vec<String>,
    kinds: Vec<Value>,
}

fn bad(reason: impl Into<String>) -> Refusal {
    Refusal::new("bad_request", reason)
}

impl Request {
    fn parse(args: &Value) -> Result<Self, Refusal> {
        let args = args.as_object().ok_or_else(|| bad("catch-up takes an object"))?;
        if args.get("v").and_then(Value::as_u64) != Some(1) {
            return Err(bad("catch-up speaks v 1"));
        }
        let foreground = match args.get("wake").and_then(Value::as_str) {
            None | Some("background") => false,
            Some("foreground") => true,
            Some(_) => return Err(bad("wake is foreground or background")),
        };
        let budget = match args.get("budgetBytes") {
            None => DEFAULT_BUDGET_BYTES,
            Some(value) => {
                value.as_u64().ok_or_else(|| bad("budgetBytes is a number"))?.min(MAX_BUDGET_BYTES)
            }
        };
        let object = |name: &str| -> Result<Map<String, Value>, Refusal> {
            match args.get(name) {
                None | Some(Value::Null) => Ok(Map::new()),
                Some(Value::Object(object)) => Ok(object.clone()),
                Some(_) => Err(bad(format!("{name} is an object"))),
            }
        };
        let mut workspaces = object("workspaces")?;
        let capabilities = match workspaces.remove("capabilities") {
            None | Some(Value::Null) => None,
            Some(Value::Array(names)) if names.len() <= 16 && names.iter().all(Value::is_string) => {
                Some(names)
            }
            Some(_) => return Err(bad("workspaces.capabilities is a list of names")),
        };
        // Only the read's own cursor and paging keys: the line is always a `list-workspaces`
        // read, never a write (a `protocol` key would make the daemon policy judge it as a
        // resource request instead).
        if let Some(key) = workspaces.keys().find(|key| !WORKSPACE_KEYS.contains(&key.as_str())) {
            return Err(bad(format!("workspaces.{key} is not understood")));
        }
        let mut chat_list = Map::new();
        for (key, value) in object("chatList")? {
            match key.as_str() {
                "listEpoch" if value.is_string() => drop(chat_list.insert(key, value)),
                "afterSeq" if value.is_u64() => drop(chat_list.insert(key, value)),
                "limit" if value.is_u64() => {
                    drop(chat_list.insert(key, json!(value.as_u64().unwrap_or(0).min(LIST_ROWS_MAX))))
                }
                _ => return Err(bad(format!("chatList.{key} is not understood"))),
            }
        }
        let mut chats = Vec::new();
        let mut over = Vec::new();
        let listed = match args.get("chats") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(chats)) => chats.clone(),
            Some(_) => return Err(bad("chats is a list")),
        };
        for chat in listed {
            let session = chat
                .get("sessionId")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty() && id.len() <= 256)
                .ok_or_else(|| bad("each chat names its sessionId"))?
                .to_owned();
            let last_seq = match chat.get("lastSeq") {
                None | Some(Value::Null) => 0,
                Some(value) => value.as_u64().ok_or_else(|| bad("lastSeq is a number"))?,
            };
            let tail = match chat.get("first").and_then(Value::as_str) {
                None | Some("screenful") => true,
                Some("forward") => false,
                Some(_) => return Err(bad("first is screenful or forward")),
            };
            if chats.iter().any(|known: &Chat| known.session == session) {
                continue;
            }
            if chats.len() < MAX_CHATS {
                chats.push(Chat { session, last_seq, tail });
            } else {
                over.push(session);
            }
        }
        let kinds = match args.get("chatKinds") {
            None | Some(Value::Null) => CHAT_KINDS.iter().map(|kind| Value::String((*kind).into())).collect(),
            Some(Value::Array(kinds)) if kinds.len() <= 16 && kinds.iter().all(Value::is_string) => {
                kinds.clone()
            }
            Some(_) => return Err(bad("chatKinds is a list of names")),
        };
        Ok(Self { foreground, budget, workspaces, capabilities, chat_list, chats, over, kinds })
    }
}

/// Each chat's `maxBytes`, in request order: the first of several may take half of the
/// budget, the rest share what is left evenly (`cmux-mobile-core::catch_up::plan`).
pub fn shares(budget: u64, chats: usize) -> Vec<u64> {
    let mut left = budget;
    let count = chats as u64;
    (0..count)
        .map(|index| {
            let share = if index == 0 && count > 1 { left / 2 } else { left / (count - index) };
            let share = share.max(1).min(left.max(1));
            left = left.saturating_sub(share);
            share
        })
        .collect()
}

/// Serves one `catch-up` channel: the reply, one frame.
pub(crate) async fn serve(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
) -> Result<(), Refusal> {
    let request = Request::parse(args)?;
    if !exposure_available(peer) {
        return Err(Refusal::new("forbidden", "session exposure state is unavailable"));
    }
    let reply = answer(config, peer, &request).await?;
    sender
        .send(Bytes::from(reply.to_string()))
        .await
        .map_err(|_| Refusal::new("closed", "phone channel closed"))
}

fn exposure_available(peer: &Peer) -> bool {
    peer.session_exposure.as_ref().is_none_or(|exposure| exposure.borrow().available)
}

/// The reply: what the daemon and acpmux answered, in one object.
async fn answer(config: &ServiceConfig, peer: &Peer, request: &Request) -> Result<Value, Refusal> {
    let (workspaces, acpmux) = tokio::join!(workspaces(config, peer, request), acpmux(config, peer, request));
    let mut cut = Vec::<String>::new();
    let mut why = Map::new();
    let mut leave_out = |name: String, reason: String, cut: &mut Vec<String>| {
        why.insert(name.clone(), Value::String(reason));
        cut.push(name);
    };
    let mut reply = Map::new();
    reply.insert("v".into(), json!(1));
    // Checked again now, as the `daemon` splice checks every line it drains.
    if !exposure_available(peer) {
        return Err(Refusal::new("forbidden", "session exposure state is unavailable"));
    }
    match workspaces.and_then(|tree| {
        let line = serde_json::to_vec(&tree).map_err(|e| e.to_string())?;
        let line = services::exposed_daemon_reply(line, peer.session_exposure.as_ref())
            .ok_or_else(|| "filtered".to_owned())?;
        serde_json::from_slice::<Value>(&line).map_err(|e| e.to_string())
    }) {
        Ok(tree) => drop(reply.insert("workspaces".into(), tree)),
        Err(reason) => leave_out("workspaces".into(), reason, &mut cut),
    }
    let AcpmuxAnswers { list, mut chats, closed } = acpmux;
    match list {
        Some(Ok(list)) if !closed => drop(reply.insert("chatList".into(), list)),
        Some(Err(reason)) if !closed => leave_out("chatList".into(), reason, &mut cut),
        _ => leave_out("chatList".into(), "acpmux closed the catch-up".into(), &mut cut),
    }
    let mut used = 0u64;
    let mut entries = Vec::new();
    for chat in &request.chats {
        let name = format!("chats:{}", chat.session);
        match chats.remove(&chat.session) {
            // Refused (not exposed, not resolvable): left out altogether.
            Some(ChatAnswer::Refused) => {}
            _ if closed => leave_out(name, "acpmux closed the catch-up".into(), &mut cut),
            Some(ChatAnswer::Page(page)) => {
                let entry = chat_entry(chat, page);
                let size = entry.to_string().len() as u64;
                if used + size > request.budget {
                    leave_out(name, "budget".into(), &mut cut);
                } else {
                    used += size;
                    entries.push(entry);
                }
            }
            Some(ChatAnswer::Failed(reason)) => leave_out(name, reason, &mut cut),
            None => leave_out(name, "not answered".into(), &mut cut),
        }
    }
    for session in &request.over {
        leave_out(format!("chats:{session}"), "too many chats".into(), &mut cut);
    }
    reply.insert("chats".into(), Value::Array(entries));
    reply.insert("cut".into(), json!(cut));
    reply.insert("cutWhy".into(), Value::Object(why));
    Ok(Value::Object(reply))
}

/// A chat's reply entry: the attach page as acpmux answered it, with its `sessionId` and,
/// for a newest-first page with older records behind it, `olderBefore` (its first seq,
/// where an ordinary `_acpmux/attach {beforeSeq}` pages on).
fn chat_entry(chat: &Chat, page: Value) -> Value {
    let mut entry = match page {
        Value::Object(object) => object,
        other => {
            let mut object = Map::new();
            object.insert("result".into(), other);
            object
        }
    };
    let first_seq = entry
        .get("events")
        .and_then(Value::as_array)
        .and_then(|events| events.first())
        .and_then(|event| event.get("seq"))
        .and_then(Value::as_u64);
    if chat.tail
        && entry.get("hasMore").and_then(Value::as_bool) == Some(true)
        && let Some(seq) = first_seq
    {
        entry.insert("olderBefore".into(), json!(seq));
    }
    entry.insert("sessionId".into(), Value::String(chat.session.clone()));
    Value::Object(entry)
}

/// The daemon's `list-workspaces` reply's `data`, every line through the `daemon`
/// channel's checks; Err says why it is cut.
async fn workspaces(config: &ServiceConfig, peer: &Peer, request: &Request) -> Result<Value, String> {
    let path = config.daemon_socket();
    // As `daemon`: the Chief's owner is reachable only through `chief`.
    if let Some(chief) = &config.chief_socket
        && path.to_string_lossy().eq_ignore_ascii_case(&chief.to_string_lossy())
    {
        return Err("no daemon".into());
    }
    let policy = DaemonPolicy::new(&peer.device_id).with_agent_tab_host(config.agent_tab_host.clone());
    let exposure = peer.session_exposure.as_ref();
    let mut lines = Vec::new();
    if let Some(capabilities) = &request.capabilities {
        let hello = json!({"cmd": "set-client-info", "id": HELLO_ID, "name": "cmux-mobile-catch-up",
            "kind": "ios", "capabilities": capabilities});
        lines.push(hello);
    }
    let mut list = request.workspaces.clone();
    list.insert("cmd".into(), json!("list-workspaces"));
    list.insert("id".into(), json!(WORKSPACES_ID));
    lines.push(Value::Object(list));
    let mut batch = Vec::new();
    for line in lines {
        let line = serde_json::to_vec(&line).map_err(|e| e.to_string())?;
        let checked = services::checked_daemon_request(&policy, None, exposure, line)
            .await
            .map_err(|refusal| format!("refused: {refusal}"))?;
        batch.extend_from_slice(&checked);
    }
    let deadline = Instant::now() + ANSWER_WAIT;
    let read = async {
        let socket = UnixStream::connect(&path).await.map_err(|e| format!("daemon: {e}"))?;
        let (read, mut write) = socket.into_split();
        write.write_all(&batch).await.map_err(|e| format!("daemon: {e}"))?;
        let mut reader = BufReader::with_capacity(64 * 1024, read);
        loop {
            let mut line = Vec::new();
            let read = (&mut reader)
                .take(DAEMON_LINE_MAX + 1)
                .read_until(b'\n', &mut line)
                .await
                .map_err(|e| format!("daemon: {e}"))?;
            if read == 0 {
                return Err("daemon closed".to_owned());
            }
            if line.len() as u64 > DAEMON_LINE_MAX {
                return Err("daemon reply too large".to_owned());
            }
            let Ok(value) = serde_json::from_slice::<Value>(&line) else { continue };
            if value.get("id").and_then(Value::as_str) != Some(WORKSPACES_ID) {
                continue;
            }
            // The reply as the `daemon` channel would hand it to the phone, or nothing.
            let line = services::exposed_daemon_reply(line, exposure).ok_or_else(|| "filtered".to_owned())?;
            let value: Value = serde_json::from_slice(&line).map_err(|e| e.to_string())?;
            if value.get("ok").and_then(Value::as_bool) == Some(false) {
                let message = value.pointer("/error/message").and_then(Value::as_str).unwrap_or("refused");
                return Err(format!("daemon: {message}"));
            }
            return Ok(value.get("data").cloned().unwrap_or(Value::Null));
        }
    };
    timeout_at(deadline, read).await.map_err(|_| "daemon timed out".to_owned())?
}

enum ChatAnswer {
    Page(Value),
    Failed(String),
    /// The relay refused it or filtered its reply: the phone may not see it.
    Refused,
}

struct AcpmuxAnswers {
    list: Option<Result<Value, String>>,
    chats: HashMap<String, ChatAnswer>,
    /// The relay ended (the exposure changed, or became unreadable): nothing it answered
    /// may be sent.
    closed: bool,
}

/// The chat list and each chat's page, from one acpmux connection.
async fn acpmux(config: &ServiceConfig, peer: &Peer, request: &Request) -> AcpmuxAnswers {
    let mut out = AcpmuxAnswers { list: None, chats: HashMap::new(), closed: false };
    let fail = |out: &mut AcpmuxAnswers, reason: &str| {
        out.list.get_or_insert_with(|| Err(reason.to_owned()));
        for chat in &request.chats {
            out.chats.entry(chat.session.clone()).or_insert_with(|| ChatAnswer::Failed(reason.to_owned()));
        }
    };
    let deadline = Instant::now() + ANSWER_WAIT;
    let socket =
        match timeout_at(deadline, services::connect_for_phone(&config.acpmux, &peer.device_id)).await {
            Ok(Ok(socket)) => socket,
            Ok(Err(refusal)) => {
                fail(&mut out, &format!("acpmux: {}", refusal.reason));
                return out;
            }
            Err(_) => {
                fail(&mut out, "acpmux timed out");
                return out;
            }
        };
    let (socket, as_phone) = socket;
    let relay = AcpmuxRelay::new(&config.acpmux, peer.session_exposure.clone(), as_phone);
    // Every message hostd sends, by JSON-RPC id: `None` for the list, else the chat.
    let mut messages: Vec<(String, Option<String>, Value)> = Vec::new();
    let mut watch = request.chat_list.clone();
    watch.insert("enabled".into(), json!(false));
    watch.entry("limit").or_insert(json!(LIST_ROWS));
    messages.push((
        LIST_ID.into(),
        None,
        json!({"jsonrpc": "2.0", "id": LIST_ID, "method": "_acpmux/watch", "params": watch}),
    ));
    for (index, (chat, share)) in
        request.chats.iter().zip(shares(request.budget, request.chats.len())).enumerate()
    {
        let id = format!("catch-up-chat-{index}");
        let mut params = json!({
            "sessionId": chat.session,
            "afterSeq": chat.last_seq,
            "limit": PAGE_RECORDS,
            "maxBytes": share,
            "toolOutputMaxBytes": TOOL_OUTPUT_MAX_BYTES.min(share),
            "kinds": request.kinds,
            "eventStream": true,
            "omitTimeBreakdown": true,
        });
        if chat.tail {
            params["beforeSeq"] = json!(TAIL_BEFORE_SEQ);
        }
        if !request.foreground {
            // A background wake reads; nobody saw the chat.
            params["visible"] = json!(false);
            params["attending"] = json!(false);
        }
        let message = json!({"jsonrpc": "2.0", "id": id, "method": "_acpmux/attach", "params": params});
        messages.push((id, Some(chat.session.clone()), message));
    }
    // Each message through the relay, as the `acpmux` channel checks a phone's, in parallel
    // (each resolves its session id on its own side connection).
    let checked = futures_util::future::join_all(messages.iter().map(|(_, _, message)| {
        let relay = &relay;
        async move {
            let mut side = None;
            let mut known = crate::services::CanonicalIds::default();
            relay.upstream(&mut side, &mut known, &message.to_string()).await
        }
    }));
    let Ok(checked) = timeout_at(deadline, checked).await else {
        fail(&mut out, "acpmux timed out");
        return out;
    };
    let (mut sink, mut source) = socket.split();
    let mut pending: HashMap<String, Option<String>> = HashMap::new();
    for ((id, chat, _), verdict) in messages.into_iter().zip(checked) {
        match verdict {
            Upstream::Send(text) => {
                // Under the deadline: an acpmux that stops reading never holds the channel.
                if !matches!(timeout_at(deadline, sink.send(Message::Text(text.into()))).await, Ok(Ok(()))) {
                    fail(&mut out, "acpmux closed");
                    return out;
                }
                pending.insert(id, chat);
            }
            // Not resolved now: cut, so its cursor stays and the next catch-up asks again.
            Upstream::Unresolved(_) => match chat {
                Some(chat) => drop(out.chats.insert(chat, ChatAnswer::Failed("not resolved".into()))),
                None => out.list = Some(Err("not resolved".into())),
            },
            // Refused, as the channel refuses it: the chat is nowhere in the reply.
            Upstream::Answer(_) => match chat {
                Some(chat) => drop(out.chats.insert(chat, ChatAnswer::Refused)),
                None => out.list = Some(Err("refused".into())),
            },
            Upstream::Close => {
                out.closed = true;
                let _ = timeout_at(deadline, sink.close()).await;
                return out;
            }
        }
    }
    let read = async {
        while !pending.is_empty() {
            let Some(Ok(frame)) = source.next().await else { return Err("acpmux closed") };
            let Message::Text(text) = frame else { continue };
            // The id the reply answers, read before the filter so a filtered reply is
            // known as one; nothing else of it is kept.
            let raw_id = serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|value| value.get("id").and_then(Value::as_str).map(str::to_owned));
            let Some(id) = raw_id.filter(|id| pending.contains_key(id)) else {
                // A notification (`_acpmux/event` of an attached chat) or another reply:
                // still through the relay, which learns from it what the channel would.
                if let Downstream::Close = relay.downstream(&text) {
                    return Err("closed");
                }
                continue;
            };
            let chat = pending.remove(&id).flatten();
            let answer = match relay.downstream(&text) {
                Downstream::Close => return Err("closed"),
                Downstream::Skip => None,
                Downstream::Send(text) => serde_json::from_str::<Value>(&text).ok(),
            };
            let result = match &answer {
                None => Err(None),
                Some(reply) => match (reply.get("result"), reply.get("error")) {
                    (Some(result), _) => Ok(result.clone()),
                    (None, error) => Err(Some(
                        error
                            .and_then(|error| error.get("message"))
                            .and_then(Value::as_str)
                            .unwrap_or("error")
                            .to_owned(),
                    )),
                },
            };
            match (chat, result) {
                (None, Ok(list)) => out.list = Some(Ok(list)),
                (None, Err(reason)) => out.list = Some(Err(reason.unwrap_or_else(|| "filtered".into()))),
                (Some(chat), Ok(page)) => drop(out.chats.insert(chat, ChatAnswer::Page(page))),
                (Some(chat), Err(None)) => drop(out.chats.insert(chat, ChatAnswer::Refused)),
                (Some(chat), Err(Some(reason))) => {
                    drop(out.chats.insert(chat, ChatAnswer::Failed(format!("acpmux: {reason}"))));
                }
            }
        }
        Ok(())
    };
    match timeout_at(deadline, read).await {
        Ok(Ok(())) => {}
        Ok(Err("closed")) => out.closed = true,
        Ok(Err(reason)) => fail(&mut out, reason),
        Err(_) => fail(&mut out, "acpmux timed out"),
    }
    // As the channel's exposure watch: a chat this catch-up touched turned off ends it.
    let state = peer.session_exposure.as_ref().map(|exposure| exposure.borrow().clone()).unwrap_or_default();
    if relay.closed(&state) {
        out.closed = true;
    }
    let _ = tokio::time::timeout(Duration::from_secs(1), sink.close()).await;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shares_give_the_first_of_several_half_and_never_pass_the_budget() {
        assert_eq!(shares(64, 1), vec![64]);
        assert_eq!(shares(64, 2), vec![32, 32]);
        let split = shares(65536, 3);
        assert_eq!(split[0], 32768);
        assert!(split.iter().sum::<u64>() <= 65536);
    }

    #[test]
    fn a_request_parses_its_cursors_and_caps_the_budget() {
        let request = Request::parse(&json!({"v": 1, "wake": "foreground", "budgetBytes": 1 << 30,
            "workspaces": {"known": "r9", "capabilities": ["page-tabs-v1"]},
            "chatList": {"listEpoch": "E", "afterSeq": 88},
            "chats": [{"sessionId": "s1", "lastSeq": 4410}, {"sessionId": "s1"}],
            "terminals": [{"surface": "t1"}]}))
        .unwrap();
        assert_eq!(request.budget, MAX_BUDGET_BYTES);
        assert!(request.foreground);
        assert_eq!(request.workspaces.get("known"), Some(&json!("r9")));
        assert!(!request.workspaces.contains_key("capabilities"));
        assert_eq!(request.chats.len(), 1, "a chat named twice is read once");
        assert!(Request::parse(&json!({"v": 2})).is_err());
        assert!(Request::parse(&json!({"v": 1, "chatList": {"cursor": "x"}})).is_err());
        // The workspaces read stays a read: no `protocol`, `cmd` or other key reaches the line.
        for key in ["protocol", "cmd", "id", "workspace"] {
            let args = json!({"v": 1, "workspaces": {"known": "r9", key: "x"}});
            assert!(Request::parse(&args).is_err(), "{key}");
        }
        let request = Request::parse(&json!({"v": 1, "chatList": {"limit": 1u64 << 40}})).unwrap();
        assert_eq!(request.chat_list.get("limit"), Some(&json!(LIST_ROWS_MAX)));
    }
}
