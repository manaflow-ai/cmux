//! Terminal notifications as pushes (kind `terminal`, PROTOCOL.md "Push
//! notifications (API 0.13.0)"): OSC 9, OSC 777 and OSC 99 desktop
//! notifications a program prints in a cmux terminal, `cmux notify`, and an
//! agent hook's notification on a terminal tab (Codex or Claude Code running
//! in a terminal, which acpmux never sees).
//!
//! The watcher holds its own connection to the app's daemon socket and
//! `subscribe`s: each `notification` event is one candidate, and every tree
//! change re-reads `list-workspaces` for the places (`notify_content::Places`)
//! both notifiers name. Not pushed:
//! - a notification on an agent chat tab: acpmux's events push it (`notify.rs`);
//! - one whose poster asked for no banner (`desktop: false`);
//! - a `daemon`-sourced one (the daemon's own bookkeeping);
//! - the second of an agent hook's and the terminal's own notification on the
//!   same tab within `ECHO_WINDOW` (Codex posts both for one event);
//! - a kind no phone wants (`Wants`);
//! - more than one per tab in `TERMINAL_SURFACE_GAP`, or more than
//!   `TERMINAL_PER_MINUTE` in a minute in all: a program that loops OSC 9 must
//!   not bury the asks (PR #24156 review M3).
//!
//! A terminal push carries the program's own title and body (redacted), never
//! the terminal's screen: until payloads are sealed (PR B) the screen, which
//! shows the prompt's folder and whatever a command printed, stays on the Mac
//! (review M2).
//!
//! A terminal agent's question (an agent hook's notification carrying the daemon's
//! `question`: Claude Code AskUserQuestion, Codex `request_user_input`) pushes as kind
//! `question` with its options, as an acpmux question does.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_mobile_link::api::NotifyEvent;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

use crate::notify::{Reporter, text_label, valid_id};
use crate::notify_content::{PlaceMap, Places};

/// An agent hook's and the terminal's own notification this close on one tab are one event.
pub const ECHO_WINDOW: Duration = Duration::from_secs(10);
/// How long a `wants` answer stands before a kind it left out is tried again:
/// a phone that just turned a kind on gets it within this.
pub const WANTS_TTL: Duration = Duration::from_secs(15);
/// At most one terminal push per tab in this window.
pub const TERMINAL_SURFACE_GAP: Duration = Duration::from_secs(10);
/// At most this many terminal pushes a minute from this Mac.
pub const TERMINAL_PER_MINUTE: usize = 10;

/// The same question this soon after it was pushed is that ask told again (Claude Code
/// posts PreToolUse and PermissionRequest for one AskUserQuestion, in either order).
pub const QUESTION_REPEAT_WINDOW: Duration = Duration::from_secs(30);

/// A terminal question's push id: `q-` and the 64-bit FNV-1a, in hex, of its prompts and
/// option labels (`prompt \u{1} label \u{2} label ...`, questions joined by `\u{0}`).
/// None when it asks nothing.
pub fn question_event_id(question: &Value) -> Option<String> {
    let questions = question.get("questions")?.as_array()?;
    let text = questions
        .iter()
        .filter_map(|q| {
            let prompt = q.get("question")?.as_str()?;
            let labels: Vec<&str> = q
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|o| o.get("label").and_then(Value::as_str))
                .collect();
            Some(format!("{prompt}\u{1}{}", labels.join("\u{2}")))
        })
        .collect::<Vec<_>>()
        .join("\u{0}");
    if text.is_empty() {
        return None;
    }
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        hash = (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3);
    }
    Some(format!("q-{hash:016x}"))
}

/// Turns daemon `notification` events into `terminal` pushes.
#[derive(Debug, Default)]
pub struct TerminalClassifier {
    seen: HashSet<u64>,
    order: VecDeque<u64>,
    /// Per surface: the last pushed notification's source and time.
    last: HashMap<u64, (String, Instant)>,
    /// When the pushes of the last minute went.
    sent: VecDeque<Instant>,
    /// Terminal questions pushed lately, by their event id: Claude Code fires two hooks
    /// for one AskUserQuestion, and the daemon posts each.
    asked_at: HashMap<(Option<u64>, String), Instant>,
}

const SEEN_LIMIT: usize = 512;

impl TerminalClassifier {
    fn first_time(&mut self, id: u64) -> bool {
        if !self.seen.insert(id) {
            return false;
        }
        self.order.push_back(id);
        if self.order.len() > SEEN_LIMIT
            && let Some(old) = self.order.pop_front()
        {
            self.seen.remove(&old);
        }
        true
    }

    /// One daemon event line; `Some` when it should be pushed. `tail` is filled by the caller.
    pub fn handle_at(&mut self, event: &Value, places: &Places, now: Instant) -> Option<NotifyEvent> {
        if event.get("event").and_then(Value::as_str) != Some("notification") {
            return None;
        }
        let id = event.get("notification").and_then(Value::as_u64)?;
        let source = event.get("source").and_then(Value::as_str).unwrap_or("cli");
        if source == "daemon" || event.get("desktop").and_then(Value::as_bool) == Some(false) {
            return None;
        }
        let surface = event.get("surface").and_then(Value::as_u64);
        let place = surface.and_then(|s| places.surface(s));
        match (&place, source) {
            // An agent chat tab: acpmux's events push it.
            (Some(p), _) if !p.terminal => return None,
            // An agent hook on a tab the tree does not show (yet): it may be an agent chat's.
            (None, "agent") if surface.is_some() => return None,
            _ => {}
        }
        if !self.first_time(id) {
            return None;
        }
        // A terminal agent's question (an agent hook only; a program's output never makes
        // one): the same questions the acpmux path sends, so the phone answers it alike. An
        // ask is never held back by the limits below, which are for programs that loop OSC 9.
        let questions = (source == "agent")
            .then(|| event.get("question"))
            .flatten()
            .map(terminal_questions)
            .unwrap_or_default();
        let ask = !questions.is_empty();
        if let Some(surface) = surface {
            // An agent hook's and the terminal's own notification for one event.
            let echo = self.last.get(&surface).is_some_and(|(last, at)| {
                now.saturating_duration_since(*at) <= ECHO_WINDOW
                    && last != source
                    && matches!((last.as_str(), source), ("agent", "terminal") | ("terminal", "agent"))
            });
            // A question is never an echo: the terminal's own alert ("asks a question", an
            // OSC program status) often comes first and carries no options.
            if echo && !ask {
                return None;
            }
            if !ask
                && self
                    .last
                    .get(&surface)
                    .is_some_and(|(_, at)| now.saturating_duration_since(*at) < TERMINAL_SURFACE_GAP)
            {
                return None;
            }
        }
        while self
            .sent
            .front()
            .is_some_and(|at| now.saturating_duration_since(*at) >= Duration::from_secs(60))
        {
            self.sent.pop_front();
        }
        if !ask {
            if self.sent.len() >= TERMINAL_PER_MINUTE {
                return None;
            }
            self.sent.push_back(now);
        }
        if let Some(surface) = surface {
            self.last.insert(surface, (source.to_owned(), now));
            if self.last.len() > SEEN_LIMIT {
                self.last.retain(|_, (_, at)| now.saturating_duration_since(*at) <= ECHO_WINDOW);
            }
        }
        let text =
            |key: &str| event.get(key).and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty());
        let title = text("title").map(|t| text_label(t, 200)).filter(|t| !t.is_empty());
        let body = [text("subtitle"), text("body")]
            .into_iter()
            .flatten()
            .map(|t| text_label(t, 400))
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join(" · ");
        let level = event.get("level").and_then(Value::as_str).unwrap_or("info");
        let agent = if source == "agent" {
            title.as_deref().and_then(hook_agent).unwrap_or("Your agent")
        } else {
            "Terminal"
        };
        let state = match level {
            "error" => "failed",
            "warning" => "waiting",
            _ => "notified",
        };
        let workspace_id = place
            .as_ref()
            .and_then(|p| valid_id(&p.workspace_id, 128))
            .or_else(|| text("workspace_id").and_then(|w| valid_id(w, 128)));
        if ask {
            // Named by what it asks (its prompts and option labels, which both of Claude
            // Code's hooks for one AskUserQuestion carry, in either order): one push per
            // question, and the phone answers a notification only while that very question
            // is pending on its tab (TerminalFeed.Entry.eventID computes the same key).
            let event_id = event.get("question").and_then(question_event_id)?;
            let key = (surface, event_id.clone());
            if self
                .asked_at
                .get(&key)
                .is_some_and(|at| now.saturating_duration_since(*at) < QUESTION_REPEAT_WINDOW)
            {
                return None;
            }
            self.asked_at.insert(key, now);
            if self.asked_at.len() > SEEN_LIMIT {
                self.asked_at.retain(|_, at| now.saturating_duration_since(*at) < QUESTION_REPEAT_WINDOW);
            }
            return Some(NotifyEvent {
                event_id,
                kind: "question".into(),
                agent: Some(agent.into()),
                place: place.as_ref().map(|p| p.workspace.clone()),
                workspace: place.as_ref().map(|p| p.workspace.clone()),
                workspace_id,
                tab_id: place.map(|p| p.tab_id),
                notification_id: Some(id.to_string()),
                title: Some(questions[0].question.clone()),
                questions,
                state: Some("waiting".into()),
                ..NotifyEvent::default()
            });
        }
        Some(NotifyEvent {
            event_id: format!("n-{id}"),
            kind: "terminal".into(),
            agent: Some(agent.into()),
            place: place.as_ref().map(|p| p.workspace.clone()),
            workspace: place.as_ref().map(|p| p.workspace.clone()),
            workspace_id,
            tab_id: place.map(|p| p.tab_id),
            notification_id: Some(id.to_string()),
            title,
            body: Some(body).filter(|b| !b.is_empty()),
            state: Some(state.into()),
            replyable: Some(event.get("reply").and_then(Value::as_bool).unwrap_or(false)),
            ..NotifyEvent::default()
        })
    }
}

/// The questions of the daemon's `question` (`{harness, questions}`, the tool's input), read
/// by the parser the acpmux path uses: as a Claude AskUserQuestion or a Codex request.
fn terminal_questions(question: &Value) -> Vec<cmux_mobile_link::api::NotifyQuestion> {
    let meta = match question.get("harness").and_then(Value::as_str) {
        Some("codex") => serde_json::json!({"codex": {}}),
        _ => serde_json::json!({"claude": {"tool": "AskUserQuestion"}}),
    };
    let request = serde_json::json!({"toolCall": {"_meta": meta, "rawInput": {
        "questions": question.get("questions").cloned().unwrap_or(Value::Null)}}});
    crate::notify_content::questions(&request)
}

/// The agent an agent hook names first in its title ("Codex needs approval").
fn hook_agent(title: &str) -> Option<&'static str> {
    let first = title.split_whitespace().next()?.to_ascii_lowercase();
    Some(match first.as_str() {
        "claude" => "Claude",
        "codex" => "Codex",
        "gemini" => "Gemini",
        "opencode" => "OpenCode",
        "cursor" => "Cursor",
        "amp" => "Amp",
        "copilot" => "Copilot",
        _ => return None,
    })
}

/// The kinds the owner's phones want from this Mac (the notify answer's `wants`).
#[derive(Debug, Default)]
pub struct Wants {
    known: Option<(HashSet<String>, Instant)>,
}

impl Wants {
    /// Whether to send `kind` at `now`: unknown, wanted, or the answer is older than `WANTS_TTL`.
    pub fn allows(&self, kind: &str, now: Instant) -> bool {
        match &self.known {
            Some((kinds, at)) if now.saturating_duration_since(*at) < WANTS_TTL => kinds.contains(kind),
            _ => true,
        }
    }

    /// A notify answer arrived at `now`.
    pub fn learn(&mut self, answer: &Value, now: Instant) {
        let Some(kinds) = answer.get("wants").and_then(Value::as_array) else { return };
        self.known = Some((kinds.iter().filter_map(Value::as_str).map(str::to_owned).collect(), now));
    }
}

/// Runs until the process stops: subscribe to the daemon at `socket`, keep
/// `places` current, and report terminal notifications. Reconnects with backoff
/// (the app's daemon may not be up yet).
pub async fn run(socket: PathBuf, places: Arc<Places>, reporter: Reporter) {
    let mut classifier = TerminalClassifier::default();
    let mut backoff = Duration::from_secs(2);
    loop {
        match watch_once(&socket, &places, &reporter, &mut classifier).await {
            Ok(()) => backoff = Duration::from_secs(2),
            Err(reason) => {
                tracing::debug!(reason, "terminal push watch ended");
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        }
        tokio::time::sleep(backoff).await;
    }
}

async fn watch_once(
    socket: &Path,
    places: &Arc<Places>,
    reporter: &Reporter,
    classifier: &mut TerminalClassifier,
) -> Result<(), String> {
    let stream = UnixStream::connect(socket).await.map_err(|e| e.to_string())?;
    let (read, mut write) = stream.into_split();
    write
        .write_all(b"{\"cmd\":\"subscribe\",\"id\":\"cmux-mobile-push\"}\n")
        .await
        .map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(read);
    tracing::info!("terminal push watch started");
    // The tree is read again after a change, one read at a time (a burst of changes is one read).
    let (dirty_tx, mut dirty_rx) = mpsc::channel::<()>(1);
    let refresher = {
        let (socket, places) = (socket.to_path_buf(), Arc::clone(places));
        tokio::spawn(async move {
            while dirty_rx.recv().await.is_some() {
                match query(&socket, "list-workspaces", None).await {
                    Ok(reply) => places.set(PlaceMap::from_workspaces(&reply)),
                    Err(error) => tracing::debug!(error, "list-workspaces for push places failed"),
                }
            }
        })
    };
    let _ = dirty_tx.try_send(());
    let result = loop {
        let mut line = Vec::new();
        match reader.read_until(b'\n', &mut line).await {
            Ok(0) => break Ok(()),
            Err(e) => break Err(e.to_string()),
            Ok(_) => {}
        }
        let Ok(value) = serde_json::from_slice::<Value>(&line) else { continue };
        let event = value.get("event").and_then(Value::as_str).unwrap_or("");
        if event == "overflow" {
            break Err("subscription overflowed".into());
        }
        if event == "tree-changed"
            || ["workspace-", "screen-", "pane-", "tab-"].iter().any(|p| event.starts_with(p))
        {
            let _ = dirty_tx.try_send(());
            continue;
        }
        if event == "notification" && !places.has_surface(&value) {
            // A tab the tree does not show yet (just opened): read it first.
            if let Ok(reply) = query(socket, "list-workspaces", None).await {
                places.set(PlaceMap::from_workspaces(&reply));
            }
        }
        let Some(push) = classifier.handle_at(&value, places, Instant::now()) else { continue };
        if !reporter.wants(&push.kind) {
            continue;
        }
        // No screen read: the screen stays on the Mac until payloads are sealed (module doc).
        reporter.send(push);
    };
    refresher.abort();
    result
}

/// One request on a fresh connection to the daemon (at most 3 s): its reply.
async fn query(socket: &Path, command: &str, surface: Option<u64>) -> Result<Value, String> {
    let mut request = serde_json::json!({"cmd": command, "id": "cmux-mobile-push-q"});
    if let Some(surface) = surface {
        request["surface"] = surface.into();
    }
    let read = async {
        let stream = UnixStream::connect(socket).await.map_err(|e| e.to_string())?;
        let (read, mut write) = stream.into_split();
        write.write_all(format!("{request}\n").as_bytes()).await.map_err(|e| e.to_string())?;
        let mut reader = BufReader::new(read);
        loop {
            let mut line = Vec::new();
            if reader.read_until(b'\n', &mut line).await.map_err(|e| e.to_string())? == 0 {
                return Err("closed".to_owned());
            }
            let Ok(value) = serde_json::from_slice::<Value>(&line) else { continue };
            if value.get("id").and_then(Value::as_str) == Some("cmux-mobile-push-q") {
                return if value.get("ok").and_then(Value::as_bool) == Some(false) {
                    Err(value.get("error").map(Value::to_string).unwrap_or_default())
                } else {
                    Ok(value)
                };
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(3), read).await.map_err(|_| "timed out".to_owned())?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notify_content::{Place, PlaceMap};
    use serde_json::json;

    fn places() -> Places {
        let places = Places::default();
        let mut map = PlaceMap::default();
        let place = |tab: &str, terminal: bool| Place {
            workspace_id: "ws_a".into(),
            workspace: "cmux-next".into(),
            tab_id: tab.into(),
            terminal,
        };
        map.surfaces.insert(7, place("s7", true));
        map.surfaces.insert(8, place("s8", false));
        places.set(map);
        places
    }

    fn event(n: u64, surface: Option<u64>, source: &str) -> Value {
        json!({"event":"notification","notification":n,"title":"Build done","subtitle":"","body":"All 12 targets\u{0007} passed",
            "level":"info","surface":surface,"workspace_id":null,"source":source,"desktop":true,"reply":false})
    }

    #[test]
    fn an_osc_notification_becomes_a_terminal_push() {
        let mut c = TerminalClassifier::default();
        let e = c.handle_at(&event(41, Some(7), "terminal"), &places(), Instant::now()).unwrap();
        assert_eq!(
            e,
            NotifyEvent {
                event_id: "n-41".into(),
                kind: "terminal".into(),
                agent: Some("Terminal".into()),
                workspace: Some("cmux-next".into()),
                place: Some("cmux-next".into()),
                workspace_id: Some("ws_a".into()),
                tab_id: Some("s7".into()),
                notification_id: Some("41".into()),
                title: Some("Build done".into()),
                body: Some("All 12 targets passed".into()),
                state: Some("notified".into()),
                replyable: Some(false),
                ..NotifyEvent::default()
            }
        );
        // Each notification once (a resubscribe never repeats one).
        assert!(
            c.handle_at(&event(41, Some(7), "terminal"), &places(), Instant::now() + ECHO_WINDOW * 2)
                .is_none()
        );
    }

    #[test]
    fn cli_notifications_and_replies() {
        let mut c = TerminalClassifier::default();
        let mut e = event(1, Some(7), "cli");
        e["reply"] = json!(true);
        e["subtitle"] = json!("main");
        let pushed = c.handle_at(&e, &places(), Instant::now()).unwrap();
        assert_eq!(pushed.replyable, Some(true));
        // The subtitle leads the body.
        assert_eq!(pushed.body.as_deref(), Some("main · All 12 targets passed"));
        // A workspace-level `cmux notify` (no terminal) still pushes, with its workspace.
        let mut ws = event(2, None, "cli");
        ws["workspace_id"] = json!("ws_b");
        let pushed = c.handle_at(&ws, &places(), Instant::now()).unwrap();
        assert_eq!((pushed.workspace_id.as_deref(), pushed.tab_id.as_deref()), (Some("ws_b"), None));
    }

    #[test]
    fn what_is_not_pushed() {
        let mut c = TerminalClassifier::default();
        let now = Instant::now();
        // An agent chat tab: acpmux pushes it.
        assert!(c.handle_at(&event(1, Some(8), "agent"), &places(), now).is_none());
        assert!(c.handle_at(&event(2, Some(8), "terminal"), &places(), now).is_none());
        // No banner wanted.
        let mut quiet = event(3, Some(7), "cli");
        quiet["desktop"] = json!(false);
        assert!(c.handle_at(&quiet, &places(), now).is_none());
        // The daemon's own.
        assert!(c.handle_at(&event(4, Some(7), "daemon"), &places(), now).is_none());
        // An agent hook on an unknown tab may be an agent chat's: not pushed.
        assert!(c.handle_at(&event(5, Some(99), "agent"), &places(), now).is_none());
        // Other events.
        assert!(c.handle_at(&json!({"event":"tree-changed"}), &places(), now).is_none());
    }

    #[test]
    fn an_agent_hook_in_a_terminal_pushes_once_with_its_echo() {
        let mut c = TerminalClassifier::default();
        let t0 = Instant::now();
        let mut hook = event(10, Some(7), "agent");
        hook["title"] = json!("Codex needs approval");
        hook["level"] = json!("warning");
        let pushed = c.handle_at(&hook, &places(), t0).unwrap();
        assert_eq!((pushed.agent.as_deref(), pushed.state.as_deref()), (Some("Codex"), Some("waiting")));
        // Codex's own OSC 9 for the same event: not again.
        assert!(
            c.handle_at(&event(11, Some(7), "terminal"), &places(), t0 + Duration::from_secs(2)).is_none()
        );
        // Either order.
        assert!(
            c.handle_at(&event(12, Some(7), "terminal"), &places(), t0 + Duration::from_secs(60)).is_some()
        );
        assert!(c.handle_at(&hook_n(13), &places(), t0 + Duration::from_secs(61)).is_none());
        // Two OSC notifications in a row are two events, once the tab's gap is over.
        assert!(
            c.handle_at(&event(14, Some(7), "terminal"), &places(), t0 + Duration::from_secs(62)).is_none()
        );
        assert!(
            c.handle_at(&event(16, Some(7), "terminal"), &places(), t0 + Duration::from_secs(72)).is_some()
        );
        // Past the window both push.
        assert!(c.handle_at(&hook_n(15), &places(), t0 + Duration::from_secs(120)).is_some());
    }

    fn hook_n(n: u64) -> Value {
        let mut hook = event(n, Some(7), "agent");
        hook["title"] = json!("Codex finished");
        hook
    }

    #[test]
    fn an_error_level_is_failed() {
        let mut c = TerminalClassifier::default();
        let mut e = event(1, Some(7), "terminal");
        e["level"] = json!("error");
        assert_eq!(c.handle_at(&e, &places(), Instant::now()).unwrap().state.as_deref(), Some("failed"));
    }

    #[test]
    fn wants_filters_for_a_minute_then_asks_again() {
        let mut w = Wants::default();
        let t0 = Instant::now();
        assert!(w.allows("terminal", t0), "unknown: send");
        w.learn(&json!({"sent":1,"wants":["question","permission","completed","chief"]}), t0);
        assert!(!w.allows("terminal", t0 + Duration::from_secs(5)));
        assert!(w.allows("question", t0 + Duration::from_secs(5)));
        // Past the TTL the next one goes, and its answer is the new word.
        assert!(w.allows("terminal", t0 + WANTS_TTL));
        // An answer without `wants` (an older Worker) changes nothing.
        w.learn(&json!({"sent":1}), t0 + WANTS_TTL);
        assert!(w.allows("terminal", t0 + WANTS_TTL));
        w.learn(&json!({"wants":["terminal"]}), t0 + WANTS_TTL);
        assert!(!w.allows("failed", t0 + WANTS_TTL));
    }

    /// Claude Code fires PreToolUse and PermissionRequest for one AskUserQuestion, and the
    /// daemon posts a notification for each (review B2): the question pushes once, named by
    /// its tool use, so the phone matches an answer to it and the Worker collapses repeats.
    #[test]
    fn one_terminal_question_pushes_once_named_by_its_tool_use() {
        let mut c = TerminalClassifier::default();
        let t0 = Instant::now();
        let ask = |n: u64, tool: &str| {
            let mut hook = event(n, Some(7), "agent");
            hook["title"] = json!("Claude asked a question");
            hook["question"] = json!({"harness":"claude","tool_use_id":tool,"questions":[
                {"question":"Which branch?","multiSelect":false,"options":[{"label":"main"},{"label":"dev"}]}]});
            hook
        };
        let first = c.handle_at(&ask(70, "toolu_A1"), &places(), t0).expect("the question pushes");
        // Named by what it asks (the phone computes the same: TerminalFeed.Entry.eventID).
        assert_eq!(first.event_id, "q-16b02b79af1ebede");
        assert!(c.handle_at(&ask(71, "toolu_A1"), &places(), t0 + Duration::from_millis(200)).is_none());
        // Another question is new.
        let mut other = ask(72, "toolu_B2");
        other["question"]["questions"][0]["question"] = json!("Which tag?");
        assert!(c.handle_at(&other, &places(), t0 + Duration::from_secs(1)).is_some());
    }

    /// Live (Claude Code 2.1.309): the PermissionRequest hook of an AskUserQuestion carries
    /// no `tool_use_id`, so its notification names no tool use. The same questions on the
    /// same tab as the pushed one are that ask, not a new push.
    #[test]
    fn the_second_hook_without_a_tool_use_id_is_the_same_question() {
        let mut c = TerminalClassifier::default();
        let t0 = Instant::now();
        let ask = |n: u64, tool: Option<&str>| {
            let mut hook = event(n, Some(7), "agent");
            hook["title"] = json!("Claude asked a question");
            let mut q = json!({"harness":"claude","questions":[
                {"question":"Which branch next?","multiSelect":false,"options":[{"label":"main"},{"label":"dev"}]}]});
            if let Some(tool) = tool {
                q["tool_use_id"] = json!(tool);
            }
            hook["question"] = q;
            hook
        };
        assert_eq!(
            c.handle_at(&ask(1, Some("toolu_X")), &places(), t0).unwrap().event_id,
            "q-396d98c066fa8647"
        );
        assert!(c.handle_at(&ask(3, None), &places(), t0 + Duration::from_millis(300)).is_none());
        // Either order (the hooks are detached): the one without a tool use first.
        let mut d = TerminalClassifier::default();
        assert_eq!(d.handle_at(&ask(5, None), &places(), t0).unwrap().event_id, "q-396d98c066fa8647");
        assert!(d.handle_at(&ask(6, Some("toolu_X")), &places(), t0 + Duration::from_millis(30)).is_none());
        // On another tab, or after the agent moved on (a while later), it is a new push.
        let mut later = ask(4, None);
        later["notification"] = json!(4);
        assert!(
            c.handle_at(&later, &places(), t0 + QUESTION_REPEAT_WINDOW + Duration::from_secs(1)).is_some()
        );
    }

    /// Claude Code reports its own "asks a question" program status (an OSC the terminal
    /// posts) before its hook's notification arrives with the question. The question is not
    /// that OSC's echo: it still pushes, with its options (found live on the termq rig: the
    /// phone only ever got "claude-code asks a question").
    #[test]
    fn a_question_after_the_terminals_own_alert_still_pushes() {
        let mut c = TerminalClassifier::default();
        let t0 = Instant::now();
        let mut osc = event(60, Some(7), "terminal");
        osc["title"] = json!("claude-code asks a question");
        osc["level"] = json!("warning");
        assert!(c.handle_at(&osc, &places(), t0).is_some());
        let mut hook = event(61, Some(7), "agent");
        hook["title"] = json!("Claude asked a question");
        hook["question"] = json!({"harness":"claude","questions":[
            {"question":"Which branch?","header":"Branch","multiSelect":false,
             "options":[{"label":"main"},{"label":"dev"},{"label":"release"}]}]});
        let e = c.handle_at(&hook, &places(), t0 + Duration::from_secs(1)).expect("the question pushes");
        assert_eq!(e.kind, "question");
        assert_eq!(e.questions[0].options.len(), 3);
        // A hook without a question is still that OSC's echo.
        assert!(c.handle_at(&hook_n(62), &places(), t0 + Duration::from_secs(2)).is_none());
    }

    /// A terminal agent's AskUserQuestion (the daemon's `question`, cmux-tui
    /// `agent_hook_question.rs`) pushes as a question with its options, so the phone gets
    /// option buttons and the long-press rows; its tab opens on a tap.
    #[test]
    fn a_terminal_agent_question_pushes_as_a_question() {
        let mut c = TerminalClassifier::default();
        let mut hook = event(50, Some(7), "agent");
        hook["title"] = json!("Claude asked a question");
        hook["body"] = json!("AskUserQuestion");
        hook["level"] = json!("warning");
        hook["question"] = json!({"harness":"claude","tool_use_id":"toolu_1","questions":[
            {"question":"Which branch?","header":"Branch","multiSelect":false,
             "options":[{"label":"main","description":"the default"},{"label":"dev"},{"label":"release"}]},
            {"question":"Which checks?","header":"Checks","multiSelect":true,"options":[{"label":"lint"},{"label":"tests"}]}]});
        let e = c.handle_at(&hook, &places(), Instant::now()).unwrap();
        assert_eq!(e.kind, "question");
        assert_eq!(e.agent.as_deref(), Some("Claude"));
        assert_eq!(e.tab_id.as_deref(), Some("s7"));
        assert_eq!(e.notification_id.as_deref(), Some("50"));
        assert_eq!(e.state.as_deref(), Some("waiting"));
        // The question, not the tool name, is the title.
        assert_eq!(e.title.as_deref(), Some("Which branch?"));
        assert_eq!(e.body, None);
        let questions = e.questions;
        assert_eq!(questions.len(), 2);
        assert_eq!(questions[0].options.len(), 3);
        assert_eq!(questions[0].options[0].description.as_deref(), Some("the default"));
        assert!(questions[1].multi_select);
        assert!(questions[0].allows_other);
        // A Codex one keeps its own Other rule.
        let mut codex = event(51, Some(7), "agent");
        codex["title"] = json!("Codex asked a question");
        codex["question"] = json!({"harness":"codex","questions":[{"id":"d","question":"Deploy?","isOther":false,
            "options":[{"label":"yes"},{"label":"no"}]}]});
        let e = c.handle_at(&codex, &places(), Instant::now() + Duration::from_secs(20)).unwrap();
        assert_eq!(e.kind, "question");
        assert!(!e.questions[0].allows_other);
        // Another question right after another push on the same tab is not held back by the
        // tab limit (the same question again is: `one_terminal_question_pushes_once_named_by_its_tool_use`).
        let mut again = hook.clone();
        again["notification"] = json!(53);
        again["question"]["questions"][0]["question"] = json!("Which tag?");
        assert_eq!(
            c.handle_at(&again, &places(), Instant::now() + Duration::from_secs(21)).unwrap().kind,
            "question"
        );
        // A question from a terminal program (not an agent hook) is never taken as one.
        let mut osc = event(52, Some(7), "terminal");
        osc["question"] = hook["question"].clone();
        let e = c.handle_at(&osc, &places(), Instant::now() + Duration::from_secs(40)).unwrap();
        assert_eq!(e.kind, "terminal");
        assert!(e.questions.is_empty());
    }
}
