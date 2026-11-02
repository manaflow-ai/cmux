//! Push notifications for Feed-worthy agent events (PROTOCOL.md
//! `POST /v1/devices/:deviceId/notify`, "Push notifications (API 0.13.0)").
//!
//! The notifier holds its own acpmux connection with `_acpmux/watch` (the
//! same events the phone's Feed uses) and reports, for each new question,
//! permission request and finished turn, one event to the backend, which
//! pushes it to the owner's phones. Terminal notifications (OSC 9, 777, 99,
//! `cmux notify`, agent hooks in a terminal) come from the daemon
//! (`notify_terminal.rs`). `CMUX_MOBILE_PUSH=0` turns both off.
//!
//! Content (changed in API 0.13.0 by the person's decision, rich
//! notifications): each event carries what a person needs to act on it from
//! the notification: the question and its options, a permission's title and
//! acpmux options, the session's last lines (`preview`), a Chief reply's first
//! lines, an error's text, and the workspace and tab the session is in
//! (`notify_content.rs`). A permission's title is the tool's own title, which
//! for a shell command is the whole command line, and last lines are what the
//! agent printed: both can name paths and command arguments. Every such text
//! is redacted first (`notify_redact`: tokens, `Bearer` values, `password=`
//! assignments, PEM blocks, high-entropy runs), and the terminal's screen is
//! never sent. Never the person's prompts (a session's `name`). Kinds no phone wants
//! are not sent (`Reporter`, the answer's `wants`).
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
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_mobile_link::api::{ApiClient, NotifyEvent};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;

use crate::auth::Tokens;
use crate::config::AcpmuxTarget;
use crate::notify_content::Places;
use crate::notify_terminal::Wants;

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
    /// Each session's last lines (its `preview`), for the push's `tail`.
    previews: HashMap<String, String>,
    /// Where each session's tab is (the daemon's tree, kept by the terminal watcher).
    places: Option<Arc<Places>>,
}

#[derive(Debug)]
struct TurnGate {
    sent: Instant,
    held: Option<NotifyEvent>,
}

const SEEN_LIMIT: usize = 512;

/// At most one finished-turn push per session in this window.
pub const TURN_WINDOW: Duration = Duration::from_secs(30);

/// A printable label of at most `max` characters: control and bidi
/// characters become spaces, runs of whitespace one space, combining marks
/// past two on one letter are dropped, and a cut label ends with "…" so the
/// end of a long command is never hidden without a sign.
pub fn label(text: &str, max: usize) -> String {
    let hidden = |c: char| {
        c.is_control()
            || matches!(c, '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}')
    };
    let mut marks = 0;
    let cleaned: String = text
        .chars()
        .filter_map(|c| {
            if is_combining_mark(c) {
                marks += 1;
                return (marks <= 2).then_some(c);
            }
            marks = 0;
            Some(if hidden(c) { ' ' } else { c })
        })
        .collect();
    let joined = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    if joined.chars().count() <= max {
        return joined;
    }
    let mut cut: String = joined.chars().take(max.saturating_sub(1)).collect();
    cut.truncate(cut.trim_end().len());
    cut.push('…');
    cut
}

/// Text a person reads (a title, a body, a last line, a question): secrets
/// redacted (`notify_redact`), then cleaned and cut like `label`.
pub fn text_label(text: &str, max: usize) -> String {
    label(&crate::notify_redact::redact(text), max)
}

/// A combining mark (Unicode `Mn` in the common blocks).
fn is_combining_mark(c: char) -> bool {
    matches!(c, '\u{0300}'..='\u{036f}' | '\u{0483}'..='\u{0489}' | '\u{0591}'..='\u{05bd}' | '\u{0610}'..='\u{061a}'
        | '\u{064b}'..='\u{065f}' | '\u{0e31}' | '\u{0e34}'..='\u{0e3a}' | '\u{0e47}'..='\u{0e4e}' | '\u{1ab0}'..='\u{1aff}'
        | '\u{1dc0}'..='\u{1dff}' | '\u{20d0}'..='\u{20ff}' | '\u{fe20}'..='\u{fe2f}')
}

/// An id as it is, when the backend accepts it (`[A-Za-z0-9._:-]{1,max}`);
/// None otherwise: an id changed to fit would name something else.
pub fn valid_id(id: &str, max: usize) -> Option<String> {
    (!id.is_empty()
        && id.len() <= max
        && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-')))
    .then(|| id.to_owned())
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
    /// A classifier that names each session's workspace and tab from `places`.
    pub fn with_places(places: Arc<Places>) -> Self {
        Self { places: Some(places), ..Self::default() }
    }

    /// Sessions from the `_acpmux/watch` result or a later page of its list: labels only, no events.
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
                let request = params.get("request").unwrap_or(&Value::Null);
                let kind = if is_question(request) { "question" } else { "permission" };
                let mut event = self.event(id, kind, session_id);
                event.permission_id = valid_id(permission_id, 128);
                event.questions = crate::notify_content::questions(request);
                if kind == "permission" {
                    event.options = crate::notify_content::permission_options(request);
                }
                let tool_title =
                    request.pointer("/toolCall/title").and_then(Value::as_str).map(|t| text_label(t, 200));
                event.title = event
                    .questions
                    .first()
                    .map(|q| q.question.clone())
                    .or(tool_title)
                    .filter(|t| !t.is_empty());
                event.state = Some("waiting".into());
                Some(event)
            }
            "_acpmux/session_changed" => {
                let session = params.get("session")?;
                if let Some((id, label)) = session_label(session) {
                    if self.sessions.len() >= SESSIONS_LIMIT && !self.sessions.contains_key(&id) {
                        self.sessions.clear();
                        self.previews.clear();
                    }
                    if let Some(preview) = session.get("preview").and_then(Value::as_str) {
                        // Only the end is ever shown: keep at most a few KB.
                        let start = preview.len().saturating_sub(4096);
                        let start =
                            (start..preview.len()).find(|&i| preview.is_char_boundary(i)).unwrap_or(0);
                        self.previews.insert(id.clone(), preview[start..].to_owned());
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
                let known = self.sessions.get(session_id).cloned().unwrap_or_default();
                // A Chief's compactor; a sub-session's or a child's turn: the parent reports.
                if known.internal || known.sub {
                    return None;
                }
                let chief = known.chief;
                let kind = match status {
                    // A stopped turn is the person's own doing: nothing to tell them.
                    Some("cancelled") => return None,
                    Some("failed") => "failed",
                    _ if chief => "chief",
                    _ => "completed",
                };
                let mut event = self.event(id, kind, session_id);
                match kind {
                    "failed" => {
                        event.state = Some("failed".into());
                        event.body = session
                            .pointer("/lastTurn/errorText")
                            .and_then(Value::as_str)
                            .map(|t| text_label(t, 400))
                            .filter(|t| !t.is_empty());
                    }
                    _ => event.state = Some("finished".into()),
                }
                if kind == "chief" {
                    event.conversation_id = known.chief_home.as_deref().map(label_id_text);
                    event.body =
                        self.previews.get(session_id).map(|p| text_label(p, 400)).filter(|t| !t.is_empty());
                }
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
        let place = self.places.as_ref().and_then(|p| p.session(session_id));
        let tail = self.previews.get(session_id).map(|p| crate::notify_content::tail(p)).unwrap_or_default();
        NotifyEvent {
            workspace: place.as_ref().map(|p| p.workspace.clone()),
            workspace_id: place.as_ref().and_then(|p| valid_id(&p.workspace_id, 128)),
            tab_id: place.map(|p| p.tab_id),
            tail,
            event_id,
            kind: kind.into(),
            agent: Some(label.agent).filter(|a| !a.is_empty()),
            place: Some(label.place).filter(|p| !p.is_empty()),
            session_id: Some(label_id(session_id)).filter(|s| !s.is_empty()),
            ..NotifyEvent::default()
        }
    }
}

/// A Chief home id as the phone names a conversation.
fn label_id_text(id: &str) -> String {
    label_id(id)
}

fn label_id(id: &str) -> String {
    id.chars().filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-')).take(128).collect()
}

/// Whether pushes are on (`CMUX_MOBILE_PUSH=0` turns them off).
pub fn enabled() -> bool {
    std::env::var("CMUX_MOBILE_PUSH").map(|v| v.trim() != "0").unwrap_or(true)
}

/// Sends events to the backend, skipping kinds no phone wants (`Wants`).
#[derive(Clone)]
pub struct Reporter {
    base_url: String,
    device_id: String,
    tokens: Arc<Tokens>,
    wants: Arc<Mutex<Wants>>,
    /// Paired phones that gave a push key get the content sealed (`sealed_notify.rs`).
    sealer: Option<Arc<crate::sealed_notify::Sealer>>,
}

impl Reporter {
    pub fn new(base_url: String, device_id: String, tokens: Arc<Tokens>) -> Self {
        Self { base_url, device_id, tokens, wants: Arc::default(), sealer: None }
    }

    /// With the sealer of a supervised hostd.
    pub fn with_sealer(mut self, sealer: Option<Arc<crate::sealed_notify::Sealer>>) -> Self {
        self.sealer = sealer;
        self
    }

    /// Whether a `kind` event would be sent now (the terminal watcher asks before reading the screen).
    pub fn wants(&self, kind: &str) -> bool {
        self.wants.lock().unwrap_or_else(std::sync::PoisonError::into_inner).allows(kind, Instant::now())
    }

    /// Sends one event in the background.
    pub fn send(&self, event: NotifyEvent) {
        if !self.wants(&event.kind) {
            return tracing::debug!(kind = event.kind, "push skipped: no phone wants it");
        }
        let this = self.clone();
        tokio::spawn(async move {
            let token = match this.tokens.access_token().await {
                Ok(token) => token,
                Err(error) => return tracing::warn!("no access token for a push ({error:#})"),
            };
            // Sealed to each paired phone's push key when it gave one (sealed_notify.rs).
            let body = serde_json::to_value(&event).unwrap_or_default();
            let body = match &this.sealer {
                Some(sealer) => sealer.body(body).await,
                None => body,
            };
            match ApiClient::new(&this.base_url, &token).notify_body(&this.device_id, &body).await {
                Ok(result) => {
                    this.wants
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .learn(&result, Instant::now());
                    tracing::info!(kind = event.kind, %result, "push reported");
                }
                Err(error) => tracing::warn!(kind = event.kind, %error, "push report failed"),
            }
        });
    }
}

/// Runs until the process stops: watch acpmux and the daemon's notifications, report events, reconnect.
pub async fn run(
    base_url: String,
    device_id: String,
    tokens: Arc<Tokens>,
    acpmux: AcpmuxTarget,
    daemon_socket: Option<std::path::PathBuf>,
    sealer: Option<Arc<crate::sealed_notify::Sealer>>,
) {
    let reporter = Reporter::new(base_url, device_id, tokens).with_sealer(sealer);
    let places = Arc::new(Places::default());
    if let Some(socket) = daemon_socket {
        tokio::spawn(crate::notify_terminal::run(socket, Arc::clone(&places), reporter.clone()));
    }
    let mut classifier = Classifier::with_places(places);
    let mut backoff = Duration::from_secs(2);
    loop {
        match watch_once(&reporter, &acpmux, &mut classifier).await {
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
                        reporter.send(event);
                    }
                }
                _ => break tokio::time::sleep_until(until).await,
            }
        }
    }
}

async fn watch_once(
    reporter: &Reporter,
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
    let mut waiting = crate::notify_waiting::Waiting::default();
    loop {
        let due = classifier.next_due();
        let deadline = waiting.next_deadline();
        let message = tokio::select! {
            message = source.next() => message,
            () = async {
                match deadline {
                    Some(at) => tokio::time::sleep_until(tokio::time::Instant::from_std(at)).await,
                    None => std::future::pending().await,
                }
            } => return Err("pending-input lookup timed out".into()),
            () = async {
                match due {
                    Some(at) => tokio::time::sleep_until(tokio::time::Instant::from_std(at)).await,
                    None => std::future::pending().await,
                }
            } => {
                for event in classifier.due(Instant::now()) {
                    reporter.send(event);
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
        let (queries, events) = waiting.receive(&value, classifier)?;
        report_and_query(&mut sink, queries, events, |event| reporter.send(event)).await?;
    }
    Err("acpmux closed".into())
}

pub(super) async fn report_and_query<S>(
    sink: &mut S,
    queries: Vec<Value>,
    events: Vec<NotifyEvent>,
    mut report: impl FnMut(NotifyEvent),
) -> Result<(), String>
where
    S: futures_util::Sink<Message> + Unpin,
    S::Error: std::fmt::Display,
{
    // Classification already marked these IDs as seen across reconnects. Hand
    // them to the reporter before any fallible send of the next recovery lookup.
    for event in events {
        report(event);
    }
    for query in queries {
        sink.send(Message::Text(query.to_string().into())).await.map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notify_content::PlaceMap;
    use cmux_mobile_link::api::{NotifyChoice, NotifyQuestion};

    fn watch() -> Value {
        json!({"sessions":[
            {"sessionId":"s1","harness":"claude-code","cwd":"/Users/me/secret-dir/cmuxterm-hq","name":"fix the bug"},
            {"sessionId":"c1","harness":"chief","cwd":"/Users/me"}
        ]})
    }

    #[test]
    fn questions_permissions_and_turns_carry_what_the_person_acts_on() {
        let mut c = Classifier::default();
        c.load(&watch());
        let question = c
            .handle(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":"perm/1","request":{"toolCall":{"title":"Question","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Deploy to staging?","header":"Deploy","options":[{"label":"Yes"},{"label":"No"}]}]}}}}}))
            .unwrap();
        assert_eq!(
            question,
            NotifyEvent {
                event_id: "p-perm1".into(),
                kind: "question".into(),
                agent: Some("Claude".into()),
                place: Some("cmuxterm-hq".into()),
                session_id: Some("s1".into()),
                // "perm/1" is no id the Worker accepts: dropped, never changed.
                permission_id: None,
                title: Some("Deploy to staging?".into()),
                questions: vec![NotifyQuestion {
                    question: "Deploy to staging?".into(),
                    header: Some("Deploy".into()),
                    multi_select: false,
                    allows_other: true,
                    options: vec![
                        NotifyChoice { label: "Yes".into(), description: None },
                        NotifyChoice { label: "No".into(), description: None },
                    ],
                }],
                state: Some("waiting".into()),
                ..NotifyEvent::default()
            }
        );
        // Never the session's path or its name (the person's prompt).
        let body = serde_json::to_string(&question).unwrap();
        assert!(!body.contains("secret-dir") && !body.contains("fix the bug"));
        // The same ask again (a re-watch) is not pushed twice.
        assert!(c.handle(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":"perm/1","request":{}}})).is_none());
        let permission = c
            .handle(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":"p2","request":{"toolCall":{"title":"rm -rf build","rawInput":{"command":"rm -rf build","env":{"TOKEN":"sk-123"}}},"options":[{"optionId":"a1","name":"Allow once","kind":"allow_once"},{"optionId":"a2","name":"Always allow","kind":"allow_always"},{"optionId":"r1","name":"Deny","kind":"reject_once"}]}}}))
            .unwrap();
        assert_eq!(permission.kind, "permission");
        assert_eq!(
            (permission.title.as_deref(), permission.permission_id.as_deref()),
            (Some("rm -rf build"), Some("p2"))
        );
        assert_eq!(
            permission.options.iter().map(|o| (o.id.as_str(), o.kind.as_deref())).collect::<Vec<_>>(),
            [("a1", Some("allow_once")), ("a2", Some("allow_always")), ("r1", Some("reject_once")),]
        );
        assert!(permission.questions.is_empty());
        // Tool arguments beyond the title never leave.
        assert!(!serde_json::to_string(&permission).unwrap().contains("sk-123"));
        let done = c
            .handle(&json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result","seq":9,"session":{"sessionId":"s1","harness":"claude-code","cwd":"/x/repo","lastTurn":{"turnId":"t9","status":"completed"},"preview":"Fixed the flaky test.\nAll 31 pass."}}}))
            .unwrap();
        assert_eq!(
            (done.kind.as_str(), done.event_id.as_str(), done.place.as_deref()),
            ("completed", "t-s1-t9", Some("repo"))
        );
        assert_eq!(done.tail, ["Fixed the flaky test.", "All 31 pass."]);
        assert_eq!(done.state.as_deref(), Some("finished"));
        let failed = c
            .handle(&json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result","session":{"sessionId":"s1","lastTurn":{"turnId":"t10","status":"failed","errorText":"Rate limited\n(429)"}}}}))
            .unwrap();
        assert_eq!(failed.kind, "failed");
        assert_eq!(
            (failed.state.as_deref(), failed.body.as_deref()),
            (Some("failed"), Some("Rate limited (429)"))
        );
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

    #[test]
    fn a_chief_reply_names_its_conversation_and_says_its_first_lines() {
        let mut c = Classifier::default();
        let reply = json!({"sessionId":"ct1","harness":"claude","cwd":"/Users/me/.cmux/chief","preview":"Both branches merged.\nGates are green.",
            "tags":{"cmux.chief":"c39c6f72","cmux.chief.role":"turn"},"lastTurn":{"turnId":"a","status":"completed"}});
        let e = c.handle_at(&turn_msg(reply), Instant::now()).unwrap();
        assert_eq!(e.kind, "chief");
        assert_eq!(e.conversation_id.as_deref(), Some("c39c6f72"));
        assert_eq!(e.body.as_deref(), Some("Both branches merged. Gates are green."));
        assert_eq!(e.tail, ["Both branches merged.", "Gates are green."]);
    }

    #[test]
    fn a_session_in_a_workspace_tab_names_the_workspace_and_tab() {
        let places = Arc::new(Places::default());
        places.set(PlaceMap::from_workspaces(&json!({"data":{"workspaces":[{"key":"ws_a","title":"Release prep","screens":[{"panes":[{"tabs":[
            {"surface":8,"kind":"conversation","conversation":{"agent_session":{"session":"s1","harness":"claude"}}}]}]}]}]}})));
        let mut c = Classifier::with_places(Arc::clone(&places));
        c.load(&watch());
        let e = c
            .handle(&json!({"method":"_acpmux/permission_pending","params":{"sessionId":"s1","permissionId":"p9","request":{"toolCall":{"title":"git push"}}}}))
            .unwrap();
        assert_eq!(
            (e.workspace.as_deref(), e.workspace_id.as_deref(), e.tab_id.as_deref(), e.place.as_deref()),
            (Some("Release prep"), Some("ws_a"), Some("s8"), Some("cmuxterm-hq"))
        );
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
