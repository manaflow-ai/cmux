//! Push notifications for Feed-worthy agent events (PROTOCOL.md
//! `POST /v1/devices/:deviceId/notify`).
//!
//! The notifier holds its own acpmux connection with `_acpmux/watch` (the
//! same events the phone's Feed uses) and reports, for each new question,
//! permission request and finished turn, one event to the backend, which
//! pushes it to the owner's phones. Content is minimized here: only the kind,
//! a short agent name, the session's folder name and ids leave the Mac; never
//! prompts, agent output, tool arguments or paths. `CMUX_MOBILE_PUSH=0` turns it off.
//!
//! Only what a person can act on is pushed:
//! - never a Chief's compactor (`cmux.chief.role` `compactor`, or an
//!   `optchat-compact-` name, preset or working directory): its slots finish a
//!   turn every few seconds while the Chief works;
//! - a Chief's turn (tag `cmux.chief`, another role) is "Chief replied",
//!   coalesced per Chief home;
//! - no finished turn of a sub-session (`startedBy`, `spawnedBy`, depth > 0)
//!   or a Chief's child (`mux.parent`): its parent reports; their asks still push;
//! - at most one finished turn, and one error, per session (or Chief) in
//!   `TURN_WINDOW`: the first goes at once, the newest of the rest when the
//!   window ends (`due`), so the last state always arrives.
//!
//! acpmux's `shown` is not used to skip a turn: the phone attaches without
//! `visible`, so a link left open after the phone locks reads as shown. The
//! phone drops a banner for the tab on its screen itself (`NotificationRouter`).

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_mobile_link::api::{ApiClient, NotifyEvent};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;

use crate::auth::Tokens;
use crate::config::AcpmuxTarget;

/// What the notifier remembers about a session (labels only).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SessionLabel {
    pub agent: String,
    pub place: String,
    pub chief: bool,
    /// The home id of a Chief turn session (`cmux.chief`): its turns coalesce per Chief.
    pub chief_home: Option<String>,
    /// A Chief's compactor session: never pushed.
    pub internal: bool,
    /// A sub-session or a Chief's child: its finished turns are not pushed.
    pub sub: bool,
}

/// Turns acpmux watch traffic into notify events.
#[derive(Debug, Default)]
pub struct Classifier {
    sessions: HashMap<String, SessionLabel>,
    /// Event ids already reported (bounded), so a re-watch never repeats one.
    seen: HashSet<String>,
    order: VecDeque<String>,
    /// Per session (or Chief) and finished-or-error: the last push and the newest turn held since.
    turns: HashMap<(String, bool), TurnGate>,
}

#[derive(Debug)]
struct TurnGate {
    sent: Instant,
    held: Option<NotifyEvent>,
}

const SEEN_LIMIT: usize = 512;

/// At most one finished-turn push per session in this window.
pub const TURN_WINDOW: Duration = Duration::from_secs(30);

/// A printable label of at most `max` characters.
pub fn label(text: &str, max: usize) -> String {
    let hidden = |c: char| {
        c.is_control()
            || matches!(c, '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}')
    };
    let cleaned: String = text.chars().map(|c| if hidden(c) { ' ' } else { c }).collect();
    cleaned.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(max).collect()
}

/// An id the backend accepts (`[A-Za-z0-9._:-]{1,64}`).
pub fn event_id(prefix: &str, parts: &[&str]) -> String {
    let mut id = String::from(prefix);
    for part in parts {
        id.push('-');
        id.extend(part.chars().filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-')));
    }
    id.chars().take(64).collect()
}

fn agent_name(harness: &str) -> &'static str {
    match harness.to_ascii_lowercase().as_str() {
        h if h.contains("claude") => "Claude",
        h if h.contains("codex") => "Codex",
        h if h.contains("gemini") => "Gemini",
        h if h.contains("opencode") => "OpenCode",
        h if h.contains("chief") => "Chief",
        _ => "Your agent",
    }
}

/// The tag on every session a Chief runs itself (its turns and compactor),
/// valued with its home id (optchat-chief `CHIEF_TAG`).
const CHIEF_TAG: &str = "cmux.chief";
/// `turn` or `compactor`, next to `cmux.chief` (optchat-chief `CHIEF_ROLE_TAG`).
const CHIEF_ROLE_TAG: &str = "cmux.chief.role";
/// The tag on a Chief's children (optchat-chief `agents.rs`).
const CHIEF_CHILD_TAG: &str = "mux.parent";
/// A compactor without its tags, as the Mac's quit census knows it
/// (`AcpmuxSessionCensus.isChief`): its name or preset, or its working
/// directory (`$TMPDIR/optchat-compact-<id>/slot-<k>`).
const CHIEF_COMPACTOR_PREFIX: &str = "optchat-compact-";
/// Labels kept at most; past it they are relearned from the next change.
const SESSIONS_LIMIT: usize = 4096;

fn session_label(session: &Value) -> Option<(String, SessionLabel)> {
    let id = session.get("sessionId")?.as_str()?.to_owned();
    let text = |key: &str| session.get(key).and_then(Value::as_str);
    let harness = text("harness").unwrap_or("agent");
    let cwd = text("cwd").unwrap_or("");
    // The folder name only, never the path.
    let place = cwd.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let tag = |key: &str| session.get("tags").and_then(|t| t.get(key)).filter(|v| !v.is_null());
    let internal = tag(CHIEF_ROLE_TAG).and_then(Value::as_str) == Some("compactor")
        || text("name").is_some_and(|n| n.starts_with(CHIEF_COMPACTOR_PREFIX))
        || harness.starts_with(CHIEF_COMPACTOR_PREFIX)
        || cwd.contains(&format!("/{CHIEF_COMPACTOR_PREFIX}"));
    let chief_home =
        tag(CHIEF_TAG).filter(|_| !internal).map(|v| v.as_str().map_or_else(|| v.to_string(), str::to_owned));
    let present = |key: &str| text(key).is_some_and(|v| !v.is_empty());
    let sub = present("startedBy")
        || present("spawnedBy")
        || session.get("depth").and_then(Value::as_u64).is_some_and(|d| d > 0)
        || tag(CHIEF_CHILD_TAG).is_some();
    Some((
        id,
        SessionLabel {
            agent: if chief_home.is_some() { "Chief".into() } else { agent_name(harness).into() },
            place: label(place, 60),
            chief: chief_home.is_some() || harness.to_ascii_lowercase().contains("chief"),
            chief_home,
            internal,
            sub,
        },
    ))
}

/// Whether a permission request is an agent question (as the phone's Feed decides).
pub fn is_question(request: &Value) -> bool {
    let tool_call = request.get("toolCall").unwrap_or(&Value::Null);
    tool_call.pointer("/_meta/acpmux/question").is_some()
        || tool_call.pointer("/_meta/claude/tool").and_then(Value::as_str) == Some("AskUserQuestion")
        || tool_call.pointer("/rawInput/questions").and_then(Value::as_array).is_some_and(|q| !q.is_empty())
}

impl Classifier {
    /// Sessions from the `_acpmux/watch` result: labels only, no events.
    pub fn load(&mut self, watch_result: &Value) {
        for session in watch_result.get("sessions").and_then(Value::as_array).into_iter().flatten() {
            if let Some((id, label)) = session_label(session) {
                self.sessions.insert(id, label);
            }
        }
    }

    fn first_time(&mut self, id: &str) -> bool {
        if !self.seen.insert(id.to_owned()) {
            return false;
        }
        self.order.push_back(id.to_owned());
        if self.order.len() > SEEN_LIMIT
            && let Some(old) = self.order.pop_front()
        {
            self.seen.remove(&old);
        }
        true
    }

    /// One JSON-RPC notification from acpmux; `Some` when it should be pushed.
    pub fn handle(&mut self, message: &Value) -> Option<NotifyEvent> {
        self.handle_at(message, Instant::now())
    }

    /// `handle` at `now` (the clock of `TURN_WINDOW`).
    pub fn handle_at(&mut self, message: &Value, now: Instant) -> Option<NotifyEvent> {
        let params = message.get("params")?;
        match message.get("method")?.as_str()? {
            "_acpmux/permission_pending" => {
                let session_id = params.get("sessionId")?.as_str()?;
                let permission_id = params.get("permissionId")?.as_str()?;
                let id = event_id("p", &[permission_id]);
                if !self.first_time(&id) || self.sessions.get(session_id).is_some_and(|s| s.internal) {
                    return None;
                }
                // The agent now waits on the person: a held "finished" would say otherwise.
                self.drop_held(session_id);
                let kind =
                    if params.get("request").is_some_and(is_question) { "question" } else { "permission" };
                Some(self.event(id, kind, session_id))
            }
            "_acpmux/session_changed" => {
                let session = params.get("session")?;
                if let Some((id, label)) = session_label(session) {
                    if self.sessions.len() >= SESSIONS_LIMIT && !self.sessions.contains_key(&id) {
                        self.sessions.clear();
                    }
                    self.sessions.insert(id, label);
                }
                let record = params.get("recordKind").or_else(|| params.get("kind")).and_then(Value::as_str);
                if record != Some("turn_result") {
                    // Working again, or waiting on the person: a held "finished" is out of date.
                    if let Some(id) = session.get("sessionId").and_then(Value::as_str)
                        && matches!(
                            session.get("status").and_then(Value::as_str),
                            Some("running" | "waiting")
                        )
                    {
                        self.drop_held(id);
                    }
                    return None;
                }
                let session_id = session.get("sessionId")?.as_str()?;
                let turn = session.pointer("/lastTurn/turnId").and_then(Value::as_str);
                let seq = params.get("seq").map(Value::to_string).unwrap_or_default();
                let id = event_id("t", &[session_id, turn.unwrap_or(&seq)]);
                if !self.first_time(&id) {
                    return None;
                }
                let status = session.pointer("/lastTurn/status").and_then(Value::as_str);
                let label = self.sessions.get(session_id).cloned().unwrap_or_default();
                // A Chief's compactor; a sub-session's or a child's turn: the parent reports.
                if label.internal || label.sub {
                    return None;
                }
                let chief = label.chief;
                let kind = match status {
                    // A stopped turn is the person's own doing: nothing to tell them.
                    Some("cancelled") => return None,
                    Some("failed") => "failed",
                    _ if chief => "chief",
                    _ => "completed",
                };
                let event = self.event(id, kind, session_id);
                self.gate((self.scope(session_id), kind == "failed"), event, now)
            }
            _ => None,
        }
    }

    /// The turn-ending `event` of `key` at `now`: pushed when its window is over,
    /// else held (replacing an older held one) until `due`.
    fn gate(&mut self, key: (String, bool), event: NotifyEvent, now: Instant) -> Option<NotifyEvent> {
        if let Some(gate) = self.turns.get_mut(&key)
            && now.saturating_duration_since(gate.sent) < TURN_WINDOW
        {
            gate.held = Some(event);
            return None;
        }
        self.turns.insert(key, TurnGate { sent: now, held: None });
        if self.turns.len() > SEEN_LIMIT {
            self.turns.retain(|_, g| g.held.is_some() || now.saturating_duration_since(g.sent) < TURN_WINDOW);
        }
        Some(event)
    }

    /// What a session's turns coalesce under: the session, or its Chief.
    fn scope(&self, session_id: &str) -> String {
        match self.sessions.get(session_id).and_then(|l| l.chief_home.as_deref()) {
            Some(home) => format!("chief:{home}"),
            None => session_id.to_owned(),
        }
    }

    /// Forgets the session's held turns (finished and error).
    fn drop_held(&mut self, session_id: &str) {
        let scope = self.scope(session_id);
        for failed in [false, true] {
            if let Some(gate) = self.turns.get_mut(&(scope.clone(), failed)) {
                gate.held = None;
            }
        }
    }

    /// When the next held turn is due (its window ends).
    pub fn next_due(&self) -> Option<Instant> {
        self.turns.values().filter(|g| g.held.is_some()).map(|g| g.sent + TURN_WINDOW).min()
    }

    /// Held turns whose window ended by `now`, the newest of each: pushed now,
    /// which starts a new window.
    pub fn due(&mut self, now: Instant) -> Vec<NotifyEvent> {
        let mut out = Vec::new();
        for gate in self.turns.values_mut() {
            if now >= gate.sent + TURN_WINDOW
                && let Some(event) = gate.held.take()
            {
                gate.sent = now;
                out.push(event);
            }
        }
        out
    }

    fn event(&self, event_id: String, kind: &str, session_id: &str) -> NotifyEvent {
        let label = self.sessions.get(session_id).cloned().unwrap_or_default();
        NotifyEvent {
            event_id,
            kind: kind.into(),
            agent: Some(label.agent).filter(|a| !a.is_empty()),
            place: Some(label.place).filter(|p| !p.is_empty()),
            session_id: Some(label_id(session_id)).filter(|s| !s.is_empty()),
        }
    }
}

fn label_id(id: &str) -> String {
    id.chars().filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-')).take(128).collect()
}

/// Whether pushes are on (`CMUX_MOBILE_PUSH=0` turns them off).
pub fn enabled() -> bool {
    std::env::var("CMUX_MOBILE_PUSH").map(|v| v.trim() != "0").unwrap_or(true)
}

/// Runs until the process stops: watch acpmux, report events, reconnect.
pub async fn run(base_url: String, device_id: String, tokens: Arc<Tokens>, acpmux: AcpmuxTarget) {
    let mut classifier = Classifier::default();
    let mut backoff = Duration::from_secs(2);
    loop {
        match watch_once(&base_url, &device_id, &tokens, &acpmux, &mut classifier).await {
            Ok(()) => backoff = Duration::from_secs(2),
            Err(reason) => {
                tracing::debug!(reason, "push watch ended");
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        }
        // Held turns still go while acpmux is away.
        let until = tokio::time::Instant::now() + backoff;
        loop {
            match classifier.next_due().map(tokio::time::Instant::from_std) {
                Some(at) if at < until => {
                    tokio::time::sleep_until(at).await;
                    for event in classifier.due(Instant::now()) {
                        report(&base_url, &device_id, &tokens, event);
                    }
                }
                _ => break tokio::time::sleep_until(until).await,
            }
        }
    }
}

async fn watch_once(
    base_url: &str,
    device_id: &str,
    tokens: &Arc<Tokens>,
    acpmux: &AcpmuxTarget,
    classifier: &mut Classifier,
) -> Result<(), String> {
    let socket = crate::services::connect_acpmux(acpmux).await.map_err(|r| r.reason)?;
    let (mut sink, mut source) = socket.split();
    let requests = [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientInfo":{"name":"cmux-mobile-host-push","version":"1"},"clientCapabilities":{}}}),
        json!({"jsonrpc":"2.0","id":2,"method":"_acpmux/watch","params":{"enabled":true}}),
    ];
    for request in requests {
        sink.send(Message::Text(request.to_string().into())).await.map_err(|e| e.to_string())?;
    }
    tracing::info!("push watch started");
    loop {
        let due = classifier.next_due();
        let message = tokio::select! {
            message = source.next() => message,
            () = async {
                match due {
                    Some(at) => tokio::time::sleep_until(tokio::time::Instant::from_std(at)).await,
                    None => std::future::pending().await,
                }
            } => {
                for event in classifier.due(Instant::now()) {
                    report(base_url, device_id, tokens, event);
                }
                continue;
            }
        };
        let Some(message) = message else { break };
        let text = match message.map_err(|e| e.to_string())? {
            Message::Text(text) => text.to_string(),
            Message::Close(_) => break,
            _ => continue,
        };
        let Ok(value) = serde_json::from_str::<Value>(&text) else { continue };
        if value.get("id").and_then(Value::as_i64) == Some(2)
            && let Some(result) = value.get("result")
        {
            classifier.load(result);
            continue;
        }
        let Some(event) = classifier.handle(&value) else { continue };
        report(base_url, device_id, tokens, event);
    }
    Err("acpmux closed".into())
}

/// Sends one event to the backend in the background.
fn report(base_url: &str, device_id: &str, tokens: &Arc<Tokens>, event: NotifyEvent) {
    let tokens = Arc::clone(tokens);
    let (base_url, device_id) = (base_url.to_owned(), device_id.to_owned());
    tokio::spawn(async move {
        let token = match tokens.access_token().await {
            Ok(token) => token,
            Err(error) => return tracing::warn!("no access token for a push ({error:#})"),
        };
        match ApiClient::new(&base_url, &token).notify(&device_id, &event).await {
            Ok(result) => tracing::info!(kind = event.kind, %result, "push reported"),
            Err(error) => tracing::warn!(kind = event.kind, %error, "push report failed"),
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn watch() -> Value {
        json!({"sessions":[
            {"sessionId":"s1","harness":"claude-code","cwd":"/Users/me/secret-dir/cmuxterm-hq","name":"fix the bug"},
            {"sessionId":"c1","harness":"chief","cwd":"/Users/me"}
        ]})
    }

    #[test]
    fn questions_permissions_and_turns_become_minimized_events() {
        let mut c = Classifier::default();
        c.load(&watch());
        let question = c
            .handle(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":"perm/1","request":{"toolCall":{"_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"API key is sk-123?"}]}}}}}))
            .unwrap();
        assert_eq!(
            question,
            NotifyEvent {
                event_id: "p-perm1".into(),
                kind: "question".into(),
                agent: Some("Claude".into()),
                place: Some("cmuxterm-hq".into()),
                session_id: Some("s1".into()),
            }
        );
        // The JSON sent to the backend carries no prompt, question text or path.
        let body = serde_json::to_string(&question).unwrap();
        assert!(!body.contains("sk-123") && !body.contains("secret-dir") && !body.contains("fix the bug"));
        // The same ask again (a re-watch) is not pushed twice.
        assert!(c.handle(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":"perm/1","request":{}}})).is_none());
        let permission = c
            .handle(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":"p2","request":{"toolCall":{"title":"rm -rf /"}}}}))
            .unwrap();
        assert_eq!(permission.kind, "permission");
        let done = c
            .handle(&json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result","seq":9,"session":{"sessionId":"s1","harness":"claude-code","cwd":"/x/repo","lastTurn":{"turnId":"t9","status":"completed"},"preview":"secret output"}}}))
            .unwrap();
        assert_eq!(
            (done.kind.as_str(), done.event_id.as_str(), done.place.as_deref()),
            ("completed", "t-s1-t9", Some("repo"))
        );
        assert!(!serde_json::to_string(&done).unwrap().contains("secret output"));
        let failed = c
            .handle(&json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result","session":{"sessionId":"s1","lastTurn":{"turnId":"t10","status":"failed"}}}}))
            .unwrap();
        assert_eq!(failed.kind, "failed");
        assert!(c
            .handle(&json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result","session":{"sessionId":"s1","lastTurn":{"turnId":"t11","status":"cancelled"}}}}))
            .is_none());
        let chief = c
            .handle(&json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result","session":{"sessionId":"c1","harness":"chief","lastTurn":{"turnId":"x","status":"completed"}}}}))
            .unwrap();
        assert_eq!((chief.kind.as_str(), chief.agent.as_deref()), ("chief", Some("Chief")));
        // Other record kinds are not pushed.
        assert!(c.handle(&json!({"method":"_acpmux/session_changed","params":{"recordKind":"message","session":{"sessionId":"s1"}}})).is_none());
    }

    fn turn(session: Value, seq: u64) -> Value {
        json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result","seq":seq,"session":session}})
    }

    /// The 2026-10-21 flood: a Chief's compactor slots (`$TMPDIR/optchat-compact-<id>/slot-<k>`,
    /// harness `claude`, tagged `cmux.chief` role `compactor`) finished a turn every few seconds and
    /// each one was pushed as "Claude finished · slot-N".
    #[test]
    fn chief_compactor_sessions_never_push() {
        let mut c = Classifier::default();
        let t0 = Instant::now();
        let compactor = |k: u64, turn: u64| {
            json!({"sessionId":format!("cmp{k}"),"name":format!("optchat-compact-c39c6f72-warm-{k}"),"harness":"claude",
                "cwd":format!("/private/var/folders/T/optchat-compact-c39c6f72/slot-{k}"),
                "tags":{"cmux.chief":"c39c6f72","cmux.chief.role":"compactor"},"shown":false,
                "lastTurn":{"turnId":format!("t{turn}"),"status":"completed"}})
        };
        for turn in 0..25 {
            assert!(
                c.handle_at(&turn_msg(compactor(turn % 4, turn)), t0 + Duration::from_secs(turn * 3))
                    .is_none()
            );
        }
        assert!(c.due(t0 + Duration::from_secs(600)).is_empty(), "nothing held for later either");
        // An untagged compactor is known by its name or preset, as the Mac's quit census does.
        let untagged = json!({"sessionId":"u1","name":"optchat-compact-x-1","harness":"claude","cwd":"/tmp/x",
            "lastTurn":{"turnId":"a","status":"failed"}});
        assert!(c.handle_at(&turn_msg(untagged), t0).is_none());
        let preset = json!({"sessionId":"u2","name":"n","harness":"optchat-compact-x-slot-0","cwd":"/tmp/y",
            "lastTurn":{"turnId":"a","status":"completed"}});
        assert!(c.handle_at(&turn_msg(preset), t0).is_none());
        // Nor does a Chief session's permission ask.
        assert!(c
            .handle_at(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"cmp1","permissionId":"px","request":{}}}), t0)
            .is_none());
    }

    /// A Chief's turn sessions (`cmux.chief`, role `turn`) are how it answers the person: "Chief replied",
    /// once per Chief in the window whatever session each turn ran in; their asks push.
    #[test]
    fn chief_turns_push_as_chief_replied_coalesced_per_chief() {
        let mut c = Classifier::default();
        let t0 = Instant::now();
        let chief_turn = |id: &str, turn: &str| {
            json!({"sessionId":id,"name":format!("optchat-c39c6f72-{id}"),"harness":"claude","cwd":"/Users/me/.cmux/chief",
                "tags":{"cmux.chief":"c39c6f72","cmux.chief.role":"turn"},"lastTurn":{"turnId":turn,"status":"completed"}})
        };
        let first = c.handle_at(&turn_msg(chief_turn("ct1", "a")), t0).unwrap();
        assert_eq!((first.kind.as_str(), first.agent.as_deref()), ("chief", Some("Chief")));
        assert!(c.handle_at(&turn_msg(chief_turn("ct2", "a")), t0 + Duration::from_secs(3)).is_none());
        assert!(c.handle_at(&turn_msg(chief_turn("ct3", "a")), t0 + Duration::from_secs(6)).is_none());
        // The newest held reply goes when the window ends.
        let later = c.due(t0 + TURN_WINDOW);
        assert_eq!(later.iter().map(|e| e.event_id.as_str()).collect::<Vec<_>>(), ["t-ct3-a"]);
        let ask = c
            .handle_at(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"ct1","permissionId":"cq","request":{}}}), t0)
            .unwrap();
        assert_eq!(ask.kind, "permission");
    }

    #[test]
    fn sub_sessions_and_chief_children_do_not_push_a_finished_turn_but_still_ask() {
        let mut c = Classifier::default();
        let t0 = Instant::now();
        let started = json!({"sessionId":"sub1","harness":"claude-code","cwd":"/x/repo","startedBy":"root","depth":1,
            "lastTurn":{"turnId":"a","status":"completed"}});
        assert!(c.handle_at(&turn_msg(started), t0).is_none());
        let spawned = json!({"sessionId":"sub2","harness":"codex","cwd":"/x/repo","spawnedBy":"root",
            "lastTurn":{"turnId":"a","status":"failed"}});
        assert!(c.handle_at(&turn_msg(spawned), t0).is_none());
        let child = json!({"sessionId":"kid","harness":"claude-code","cwd":"/x/repo","tags":{"mux.parent":"/Users/me/.cmux/chief"},
            "lastTurn":{"turnId":"a","status":"completed"}});
        assert!(c.handle_at(&turn_msg(child), t0).is_none());
        // A question from a sub-session still needs the person.
        let ask = c
            .handle_at(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"sub1","permissionId":"q1","request":{"toolCall":{"_meta":{"acpmux":{"question":true}}}}}}), t0)
            .unwrap();
        assert_eq!(ask.kind, "question");
    }

    /// The phone attaches without `visible`, so a link left open after it locks reads as `shown`:
    /// a turn that ends then still pushes (the phone hides a banner for the tab it shows itself).
    #[test]
    fn a_turn_that_ends_while_shown_still_pushes() {
        let mut c = Classifier::default();
        let shown = json!({"sessionId":"s1","harness":"claude-code","cwd":"/x/repo","shown":true,"attached":1,
            "lastTurn":{"turnId":"a","status":"completed"}});
        assert_eq!(c.handle_at(&turn_msg(shown), Instant::now()).unwrap().kind, "completed");
    }

    #[test]
    fn finished_turns_coalesce_per_session_within_the_window() {
        let mut c = Classifier::default();
        let t0 = Instant::now();
        let s = |id: &str, turn: &str, status: &str| json!({"sessionId":id,"harness":"claude-code","cwd":"/x/repo","lastTurn":{"turnId":turn,"status":status}});
        let at = |secs: u64| t0 + Duration::from_secs(secs);
        assert!(c.handle_at(&turn_msg(s("s1", "a", "completed")), t0).is_some());
        // The same session again within the window: held, the newer replacing the older.
        assert!(c.handle_at(&turn_msg(s("s1", "b", "completed")), at(5)).is_none());
        assert!(c.handle_at(&turn_msg(s("s1", "b2", "completed")), at(7)).is_none());
        // An error is its own news, once per window too.
        assert_eq!(c.handle_at(&turn_msg(s("s1", "c", "failed")), at(10)).unwrap().kind, "failed");
        assert!(c.handle_at(&turn_msg(s("s1", "c2", "failed")), at(11)).is_none());
        // Another session is its own.
        assert!(c.handle_at(&turn_msg(s("s2", "a", "completed")), at(5)).is_some());
        assert_eq!(c.next_due(), Some(t0 + TURN_WINDOW));
        assert!(c.due(t0 + TURN_WINDOW - Duration::from_secs(1)).is_empty());
        // When a window ends the newest held turn goes, once.
        let ids = |events: Vec<NotifyEvent>| events.into_iter().map(|e| e.event_id).collect::<Vec<_>>();
        assert_eq!(ids(c.due(t0 + TURN_WINDOW)), ["t-s1-b2"]);
        assert!(c.due(t0 + TURN_WINDOW + Duration::from_secs(1)).is_empty());
        assert_eq!(ids(c.due(at(10) + TURN_WINDOW)), ["t-s1-c2"]);
        assert_eq!(c.next_due(), None);
        // A flushed turn starts a new window; past it the next turn goes at once and a held one is superseded.
        assert!(
            c.handle_at(&turn_msg(s("s1", "d", "completed")), t0 + TURN_WINDOW + Duration::from_secs(5))
                .is_none()
        );
        assert!(
            c.handle_at(&turn_msg(s("s1", "e", "completed")), t0 + TURN_WINDOW * 2 + Duration::from_secs(1))
                .is_some()
        );
        assert_eq!(c.next_due(), None);
        // A held "finished" is dropped once the agent works again or waits on the person.
        assert!(c.handle_at(&turn_msg(s("s3", "a", "completed")), at(100)).is_some());
        assert!(c.handle_at(&turn_msg(s("s3", "b", "completed")), at(101)).is_none());
        let ask = json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s3","permissionId":"q3","request":{}}});
        assert!(c.handle_at(&ask, at(102)).is_some());
        assert!(c.due(at(200)).is_empty());
        assert!(c.handle_at(&turn_msg(s("s4", "a", "completed")), at(100)).is_some());
        assert!(c.handle_at(&turn_msg(s("s4", "b", "completed")), at(101)).is_none());
        let running = json!({"method":"_acpmux/session_changed","params":{"recordKind":"prompt","session":{"sessionId":"s4","harness":"claude-code","cwd":"/x/repo","status":"running"}}});
        assert!(c.handle_at(&running, at(102)).is_none());
        assert!(c.due(at(200)).is_empty());
        // Asks are never coalesced: each one needs an answer.
        for (i, id) in ["p1", "p2", "p3"].iter().enumerate() {
            let ask = json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":id,"request":{}}});
            assert!(c.handle_at(&ask, at(i as u64)).is_some());
        }
    }

    fn turn_msg(session: Value) -> Value {
        turn(session, 1)
    }

    #[test]
    fn ids_and_labels_are_sanitized() {
        assert_eq!(event_id("p", &["a b/c\u{0}d"]), "p-abcd");
        assert_eq!(event_id("t", &[&"x".repeat(100)]).len(), 64);
        assert_eq!(label("a\nb\u{202e}  c", 60), "a b c");
    }
}
