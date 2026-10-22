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
//! - a kind no phone wants (`Wants`).

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_mobile_link::api::NotifyEvent;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

use crate::notify::{Reporter, label};
use crate::notify_content::{PlaceMap, Places, tail};

/// An agent hook's and the terminal's own notification this close on one tab are one event.
pub const ECHO_WINDOW: Duration = Duration::from_secs(10);
/// How long a `wants` answer stands before a kind it left out is tried again.
pub const WANTS_TTL: Duration = Duration::from_secs(60);

/// Turns daemon `notification` events into `terminal` pushes.
#[derive(Debug, Default)]
pub struct TerminalClassifier {
    seen: HashSet<u64>,
    order: VecDeque<u64>,
    /// Per surface: the last pushed notification's source and time.
    last: HashMap<u64, (String, Instant)>,
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
        if let Some(surface) = surface {
            // An agent hook's and the terminal's own notification for one event.
            let echo = self.last.get(&surface).is_some_and(|(last, at)| {
                now.saturating_duration_since(*at) <= ECHO_WINDOW
                    && last != source
                    && matches!((last.as_str(), source), ("agent", "terminal") | ("terminal", "agent"))
            });
            if echo {
                return None;
            }
            self.last.insert(surface, (source.to_owned(), now));
            if self.last.len() > SEEN_LIMIT {
                self.last.retain(|_, (_, at)| now.saturating_duration_since(*at) <= ECHO_WINDOW);
            }
        }
        let text =
            |key: &str| event.get(key).and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty());
        let title = text("title").map(|t| label(t, 200)).filter(|t| !t.is_empty());
        let body = [text("subtitle"), text("body")]
            .into_iter()
            .flatten()
            .map(|t| label(t, 400))
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
            .map(|p| p.workspace_id.clone())
            .or_else(|| text("workspace_id").map(|w| label(w, 128)));
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
        let Some(mut push) = classifier.handle_at(&value, places, Instant::now()) else { continue };
        if !reporter.wants(&push.kind) {
            continue;
        }
        let surface = value.get("surface").and_then(Value::as_u64);
        if let (Some(surface), true) = (surface, push.tab_id.is_some())
            && let Ok(reply) = query(socket, "read-screen", Some(surface)).await
        {
            let text = reply.pointer("/data/text").and_then(Value::as_str).unwrap_or("");
            push.tail = tail(text);
        }
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
        // Two OSC notifications in a row are two events.
        assert!(
            c.handle_at(&event(14, Some(7), "terminal"), &places(), t0 + Duration::from_secs(62)).is_some()
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
        // A question from a terminal program (not an agent hook) is never taken as one.
        let mut osc = event(52, Some(7), "terminal");
        osc["question"] = hook["question"].clone();
        let e = c.handle_at(&osc, &places(), Instant::now() + Duration::from_secs(40)).unwrap();
        assert_eq!(e.kind, "terminal");
        assert!(e.questions.is_empty());
    }
}
