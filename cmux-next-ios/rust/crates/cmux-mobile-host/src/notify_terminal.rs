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

use cmux_mobile_link::api::NotifyEvent;
use serde_json::Value;

use crate::notify_content::Places;

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

impl TerminalClassifier {
    /// One daemon event line; `Some` when it should be pushed. `tail` is filled by the caller.
    pub fn handle_at(&mut self, _event: &Value, _places: &Places, _now: Instant) -> Option<NotifyEvent> {
        None
    }
}

/// The kinds the owner's phones want from this Mac (the notify answer's `wants`).
#[derive(Debug, Default)]
pub struct Wants {
    known: Option<(HashSet<String>, Instant)>,
}

impl Wants {
    /// Whether to send `kind` at `now`: unknown, wanted, or the answer is older than `WANTS_TTL`.
    pub fn allows(&self, _kind: &str, _now: Instant) -> bool {
        true
    }

    /// A notify answer arrived at `now`.
    pub fn learn(&mut self, _answer: &Value, _now: Instant) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notify_content::{Place, PlaceMap};
    use serde_json::json;

    fn places() -> Places {
        let places = Places::default();
        let mut map = PlaceMap::default();
        let place = |tab: &str, terminal: bool| Place { workspace_id: "ws_a".into(), workspace: "cmux-next".into(), tab_id: tab.into(), terminal };
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
        assert!(c.handle_at(&event(41, Some(7), "terminal"), &places(), Instant::now() + ECHO_WINDOW * 2).is_none());
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
        assert!(c.handle_at(&event(11, Some(7), "terminal"), &places(), t0 + Duration::from_secs(2)).is_none());
        // Either order.
        assert!(c.handle_at(&event(12, Some(7), "terminal"), &places(), t0 + Duration::from_secs(60)).is_some());
        assert!(c.handle_at(&hook_n(13), &places(), t0 + Duration::from_secs(61)).is_none());
        // Two OSC notifications in a row are two events.
        assert!(c.handle_at(&event(14, Some(7), "terminal"), &places(), t0 + Duration::from_secs(62)).is_some());
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
}
