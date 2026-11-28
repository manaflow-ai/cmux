//! What the running turn's live line says, in the GUI chat's words. Leo, 2026-11-24: "in terminals
//! and guis alike perhaps terminal simply needs to also have the fixes and enhancements".
//!
//! - cmux#55784 (`turns.ts` `compactPrompt`): a /compact turn reads "Compacting conversation" from
//!   its first frame, never "Working".
//! - cmux#50146 (`liveWait.ts`): past SILENT_MS with nothing heard and nothing in flight, the line
//!   names what it waits on ("Waiting on the model after: Read a.rs"), never a bare "Working".

use acpmux::transcript::{Item, Transcript};
use std::cell::RefCell;
use std::collections::HashMap;

/// Silence this long reads as a wait (Thinking.tsx `SILENT_MS`).
pub(crate) const SILENT_MS: u64 = 10_000;

/// The live turn's prompt, by the turn the transcript last started.
fn live_prompt(t: &Transcript) -> Option<usize> {
    let (at, _, None) = t.turn_times.last()? else { return None };
    Some(*at)
}

/// The live turn is a /compact (typed, or a Compact button's).
pub(crate) fn compacting(t: &Transcript) -> bool {
    let Some(Item::User { text, .. }) = live_prompt(t).and_then(|i| t.items.get(i)) else {
        return false;
    };
    let text = text.trim_start();
    text.strip_prefix("/compact")
        .is_some_and(|rest| rest.chars().next().is_none_or(char::is_whitespace))
}

/// What the line waits on, as `liveWait.ts` `waitingLabel` words it.
fn wait_words(t: &Transcript) -> String {
    let start = live_prompt(t).map_or(0, |i| i + 1);
    let turn = t.items.get(start..).unwrap_or_default();
    let heard =
        |x: &Item| matches!(x, Item::Assistant { .. } | Item::Thought { .. } | Item::Tool { .. });
    if !turn.iter().any(heard) {
        return "Waiting on the model's first reply".into();
    }
    let last = turn.iter().rev().find(|x| {
        !matches!(x, Item::Status { .. } | Item::Stderr { .. } | Item::User { queued: true, .. })
    });
    match last {
        Some(Item::User { steer: true, .. }) => {
            "Waiting on the model to read your queued message".into()
        }
        Some(Item::Tool { title, .. }) if !title.trim().is_empty() => {
            format!("Waiting on the model after: {}", title.trim())
        }
        _ => "Waiting on the model's next step".into(),
    }
}

thread_local! {
    /// When each live turn (by its start ms) last heard an event, keyed by the event seq it saw.
    static HEARD: RefCell<HashMap<u64, (u64, usize, u64)>> = RefCell::new(HashMap::new());
}

/// When the live turn last heard anything: the first frame that saw its latest event.
fn heard_at(t: &Transcript, now: u64) -> u64 {
    let Some((_, start, None)) = t.turn_times.last() else { return now };
    let key = (t.last_seq, t.items.len());
    HEARD.with(|h| {
        let mut h = h.borrow_mut();
        if h.len() > 64 {
            h.clear();
        }
        let e = h.entry(*start).or_insert((key.0, key.1, *start));
        if (e.0, e.1) != key {
            *e = (key.0, key.1, now);
        }
        e.2
    })
}

/// The wait the line names now, or None while something is in flight or was heard lately.
pub(crate) fn waiting(t: &Transcript, now: u64) -> Option<String> {
    let heard = heard_at(t, now);
    waiting_since(t, heard, now)
}

pub(crate) fn waiting_since(t: &Transcript, heard: u64, now: u64) -> Option<String> {
    let busy = t.active_tools > 0
        || t.active_terminals > 0
        || t.activity.as_deref().is_some_and(|a| !a.is_empty())
        || t.note.is_some();
    (!busy && !compacting(t) && now.saturating_sub(heard) >= SILENT_MS).then(|| wait_words(t))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user(s: &str, steer: bool) -> Item {
        Item::User { text: s.into(), steer, queued: false }
    }
    fn tool(title: &str) -> Item {
        Item::Tool {
            id: "1".into(),
            title: title.into(),
            kind: "read".into(),
            status: "completed".into(),
            detail: String::new(),
        }
    }
    fn live(items: Vec<Item>) -> Transcript {
        let mut t = Transcript::default();
        t.items = items;
        t.status = "running".into();
        t.turn_times = vec![(0, 1_000, None)];
        t
    }

    #[test]
    fn a_compact_turn_reads_compacting() {
        assert!(compacting(&live(vec![user("/compact", false)])));
        assert!(compacting(&live(vec![user("  /compact keep the plan", false)])));
        assert!(!compacting(&live(vec![user("/compactor", false)])));
        assert!(!compacting(&live(vec![user("fix it", false)])));
        let mut ended = live(vec![user("/compact", false)]);
        ended.turn_times = vec![(0, 1_000, Some(2_000))];
        assert!(!compacting(&ended), "an ended turn is not live");
    }

    #[test]
    fn names_what_it_waits_on_after_silence() {
        let t = live(vec![user("fix it", false)]);
        assert_eq!(waiting_since(&t, 1_000, 5_000), None, "heard lately");
        assert_eq!(
            waiting_since(&t, 1_000, 11_000).as_deref(),
            Some("Waiting on the model's first reply")
        );
        let t = live(vec![user("fix it", false), tool("Read a.rs")]);
        assert_eq!(
            waiting_since(&t, 0, 20_000).as_deref(),
            Some("Waiting on the model after: Read a.rs")
        );
        let t = live(vec![user("fix it", false), tool("Read a.rs"), user("also b", true)]);
        assert_eq!(
            waiting_since(&t, 0, 20_000).as_deref(),
            Some("Waiting on the model to read your queued message")
        );
        let t = live(vec![user("fix it", false), Item::Assistant { text: "ok".into() }]);
        assert_eq!(
            waiting_since(&t, 0, 20_000).as_deref(),
            Some("Waiting on the model's next step")
        );
    }

    #[test]
    fn never_waits_while_a_call_runs_or_compacts() {
        let mut t = live(vec![user("fix it", false), tool("Read a.rs")]);
        t.active_tools = 1;
        assert_eq!(waiting_since(&t, 0, 60_000), None);
        t.active_tools = 0;
        t.activity = Some("Editing a.rs".into());
        assert_eq!(waiting_since(&t, 0, 60_000), None);
        assert_eq!(waiting_since(&live(vec![user("/compact", false)]), 0, 60_000), None);
    }

    #[test]
    fn heard_at_moves_with_each_event() {
        let mut t = live(vec![user("fix it", false)]);
        t.turn_times = vec![(0, 777_000, None)];
        t.last_seq = 5;
        assert_eq!(heard_at(&t, 780_000), 777_000, "the turn's start until an event comes");
        t.last_seq = 6;
        assert_eq!(heard_at(&t, 790_000), 790_000);
        assert_eq!(heard_at(&t, 799_000), 790_000);
    }
}
