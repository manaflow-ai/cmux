//! The Chief's `stop` and `sleep` tools (plans/cmux-next/chief-tools-DESIGN.md).
//!
//! `stop` ends the running turn at once, the way `chief.stop` does (the
//! turn's runner sends `session/cancel` once no tool call runs), but as the
//! Chief's own choice: its final text is not posted, it is not a failure and
//! it is never cut and retried, and it still closes its messages.
//!
//! `sleep` ends the turn the same way and saves a wake (`HostState::wakes`):
//! when it is due the brain queues a note `[wake] <note>`, which starts a
//! normal turn. The brain's own timer wakes it (`Brain::next_wake`); nothing
//! polls. A wake with `until_event` is dropped when a turn for a user message
//! or a subagent report starts first.

use std::time::{Duration, Instant};

use super::{Brain, Phase, Source, now_ms};
use crate::state::{WAKES_KEPT, Wake};
use crate::tools::SleepCall;

impl Brain {
    /// The `stop` tool: ends the running turn; a noop outside one.
    pub(super) fn stop_turn(&mut self) -> Result<String, String> {
        if self.phase != Phase::Running {
            return Ok("outcome: noop. no turn is running".to_owned());
        }
        self.refuse_unanswered("stop")?;
        self.refuse_landed_untold("stop")?;
        self.end_turn_by_tool("stop");
        Ok("outcome: done. the turn ends now; nothing more is posted".to_owned())
    }

    /// `stop` and `sleep` while a person message this turn saw has no reply:
    /// refused, so the turn replies now instead of a retry turn later
    /// (reply_ledger.rs). A tapback counts as the reply.
    pub(super) fn refuse_unanswered(&self, tool: &str) -> Result<(), String> {
        let open = self.unanswered_in_turn();
        if open.is_empty() {
            return Ok(());
        }
        let main = self.state.conversation.clone().unwrap_or_default();
        let names: Vec<String> = open
            .iter()
            .map(|a| {
                let line = self
                    .chat
                    .logged_id(&format!("{main}#{}", a.seq))
                    .map(|id| format!("line {id}"))
                    .unwrap_or_else(|| format!("message {}", a.id));
                format!("{line} \"{}\"", a.preview)
            })
            .collect();
        Err(format!(
            "{tool}: refused, the user's {} no reply yet: {}. Reply first in words (send, reply, or your final text), or react when it only acknowledges; then {tool}.",
            if names.len() == 1 {
                "message has"
            } else {
                "messages have"
            },
            names.join(", ")
        ))
    }

    /// The running turn saw a subagent's landed report (with a range) and
    /// posted nothing naming it: `stop`/`sleep` is refused once, naming it,
    /// so the person hears it in this turn, not a later one (landed_told.rs).
    /// A second call goes through.
    fn refuse_landed_untold(&mut self, tool: &str) -> Result<(), String> {
        if self.landed_refused {
            return Ok(());
        }
        // The loop guard refuses every send now: telling is impossible until
        // the person writes, and that turn carries it (budget_hold.rs).
        if self.budget_held() {
            return Ok(());
        }
        let untold: Vec<String> = self
            .turn_landed
            .iter()
            .filter(|(id, _)| !super::outcome_ledger::names(&self.turn_posts, id))
            .map(|(id, range)| format!("{id} ({range})"))
            .collect();
        if untold.is_empty() {
            return Ok(());
        }
        self.landed_refused = true;
        Err(format!(
            "{tool}: refused once, this turn saw landed work it has not told: {}. Tell the person in one line each (send), with the range; then {tool}. A second {tool} goes through.",
            untold.join(", ")
        ))
    }

    /// The running turn posted `text` (`send`, `reply`).
    pub(super) fn posted_in_turn(&mut self, text: &str) {
        if self.state.turn.is_some() {
            self.turn_posts.push_str(text);
            self.turn_posts.push('\n');
        }
    }

    /// Report `r` (its text `text`) went into the running turn: a landed
    /// range in it is owed to the person in this turn.
    pub(super) fn saw_report(&mut self, r: &crate::state::SpawnRef, text: &str) {
        let Some(range) = landed_range(text) else {
            return;
        };
        for (id, _) in &r.subs {
            if !self.turn_landed.iter().any(|(i, _)| i == id) {
                self.turn_landed.push((id.clone(), range.clone()));
            }
        }
    }

    /// Marks the running turn as ended by the Chief's own tool and asks its
    /// runner to stop the session.
    pub(super) fn end_turn_by_tool(&mut self, tool: &str) {
        if self.tool_stopped {
            return;
        }
        self.tool_stopped = true;
        // The Chief ended its own turn after its last tool: the session is at
        // a clean point, so the next turn may go on in it (turn.rs, kept).
        self.interrupt.request_own();
        (self.log)(&format!("the Chief called {tool}: ending the running turn"));
    }

    /// The `sleep` tool: saves a wake (or clears them all for 0 seconds) and
    /// ends the running turn.
    pub(super) fn sleep(&mut self, call: SleepCall) -> Result<String, String> {
        if self.phase == Phase::Running && call.seconds > 0 {
            self.refuse_unanswered("sleep")?;
            self.refuse_landed_untold("sleep")?;
        }
        // Follow-ups (follow_up) are not sleep wakes: follow_ups cancels them.
        let sleeps = self.state.wakes.iter().filter(|w| w.id.is_none()).count();
        if call.seconds == 0 {
            self.state.wakes.retain(|w| w.id.is_some());
            self.save();
            return Ok(format!("outcome: done. cleared {sleeps} pending wake(s)"));
        }
        if sleeps >= WAKES_KEPT {
            return Err(format!(
                "sleep: {WAKES_KEPT} wakes are pending already; clear them with sleep(0) first"
            ));
        }
        let now = now_ms();
        let wake = Wake {
            at_ms: now + call.seconds * 1000,
            asked_ms: now,
            note: call.note.unwrap_or_default(),
            until_event: call.until.as_deref() == Some("event"),
            id: None,
            loop_path: None,
            for_person: false,
        };
        self.state.wakes.push(wake);
        self.state.wakes.sort_by_key(|w| w.at_ms);
        self.save();
        let running = self.phase == Phase::Running;
        if running {
            self.end_turn_by_tool("sleep");
        }
        Ok(format!(
            "outcome: done. waking in {}{}; {} wake(s) pending{}",
            human(call.seconds),
            if call.until.as_deref() == Some("event") {
                " or at the next message or report"
            } else {
                ""
            },
            self.state.wakes.len(),
            if running { "; the turn ends now" } else { "" }
        ))
    }

    /// The wakes the Chief asked for with `sleep`, soonest first.
    pub fn pending_wakes(&self) -> Vec<Wake> {
        self.state.wakes.clone()
    }

    /// When the next wake is due, on the brain's clock.
    pub(super) fn next_wake(&self) -> Option<Instant> {
        let at = self.state.wakes.first()?.at_ms;
        let now = now_ms();
        Some(Instant::now() + Duration::from_millis(at.saturating_sub(now)))
    }

    /// Fires every wake due at `now_ms` (wall clock, ms since the epoch):
    /// each queues its note, which starts a turn.
    pub fn fire_wakes_at(&mut self, now_ms: u64) {
        // A follow-up the Chief set for itself that comes due in the
        // person's quiet hours (set or changed after it) moves to their end.
        let quiet = self.wake_settings.quiet.clone();
        if quiet.is_some() {
            let mut moved = false;
            for w in self
                .state
                .wakes
                .iter_mut()
                .filter(|w| w.at_ms <= now_ms && w.id.is_some() && !w.for_person)
            {
                let at = chrono::DateTime::from_timestamp_millis(now_ms as i64)
                    .map(|t| t.with_timezone(&chrono::Local).fixed_offset());
                if let Some(at) = at
                    && crate::check_in::in_quiet(quiet.as_deref(), at)
                {
                    w.at_ms = crate::check_in::after_quiet(quiet.as_deref(), at)
                        .timestamp_millis()
                        .max(0) as u64;
                    moved = true;
                }
            }
            if moved {
                self.state.wakes.sort_by_key(|w| w.at_ms);
                self.save();
            }
        }
        let due: Vec<Wake> = self
            .state
            .wakes
            .iter()
            .filter(|w| w.at_ms <= now_ms)
            .cloned()
            .collect();
        if due.is_empty() {
            return;
        }
        self.state.wakes.retain(|w| w.at_ms > now_ms);
        self.save();
        for wake in due {
            let late = now_ms.saturating_sub(wake.at_ms) / 1000;
            let asked = (wake.at_ms.saturating_sub(wake.asked_ms)) / 1000;
            let note = if wake.note.trim().is_empty() {
                "(no note)".to_owned()
            } else {
                wake.note.trim().to_owned()
            };
            let late_text = if late > 60 {
                format!(", {} late: the host was not running", human(late))
            } else {
                String::new()
            };
            let text = match &wake.id {
                // A follow-up (memory.rs): its loop is closed when this run
                // ends with send or ask and the loop says so.
                Some(id) => {
                    let when = chrono::DateTime::from_timestamp_millis(wake.at_ms as i64)
                        .map(|t| {
                            t.with_timezone(&chrono::Local)
                                .format("%a %Y-%m-%d %H:%M")
                                .to_string()
                        })
                        .unwrap_or_default();
                    // The loop goes in the first token, which the host
                    // writes before the note's own text (memory.rs reads it).
                    let tag = match &wake.loop_path {
                        Some(p) => format!("[follow-up {p}]"),
                        None => "[follow-up]".to_owned(),
                    };
                    format!("{tag} {note}\n(Your follow-up {id}, set for {when}{late_text}.)")
                }
                None => format!(
                    "[wake] {note}\n(You asked for this wake with sleep({asked}){late_text}.)"
                ),
            };
            (self.log)(&format!("a wake is due: {note}"));
            // Its planned time, for the wake run's `scheduled_at` (memory.rs).
            self.wake_planned.insert(text.clone(), wake.at_ms as i64);
            self.queue(text, Source::Note);
        }
    }

    /// A turn starts for `items`: a user message or a report replaces every
    /// `until: event` wake.
    pub(super) fn drop_event_wakes(&mut self, by_event: bool) {
        if !by_event || !self.state.wakes.iter().any(|w| w.until_event) {
            return;
        }
        self.state.wakes.retain(|w| !w.until_event);
        (self.log)("a message or report came first: dropping the until-event wakes");
    }
}

/// `90 s`, `5 min`, `2 h 5 min`.
pub(super) fn human(seconds: u64) -> String {
    match seconds {
        s if s < 120 => format!("{s} s"),
        s if s < 3600 => format!("{} min", s / 60),
        s if s % 3600 / 60 == 0 => format!("{} h", s / 3600),
        s => format!("{} h {} min", s / 3600, s % 3600 / 60),
    }
}

/// The landed range a report names (`1a2b3c4d..5e6f7a8b`), when it says it
/// landed (sub_watch `landed`).
fn landed_range(text: &str) -> Option<String> {
    if !crate::sub_watch::landed(text) {
        return None;
    }
    let sha = |w: &str| {
        (7..=40).contains(&w.len())
            && w.chars().all(|c| c.is_ascii_hexdigit())
            && w.chars().any(|c| c.is_ascii_digit())
    };
    text.split(|c: char| !(c.is_ascii_alphanumeric() || c == '.'))
        .find_map(|w| {
            let (a, b) = w.split_once("..")?;
            let b = b.trim_start_matches('.');
            (sha(a) && sha(b)).then(|| format!("{a}..{b}"))
        })
}
