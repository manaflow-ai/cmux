//! The front desk's receipt (cmuxterm-hq `docs/chief-team.md`, step 1).
//!
//! A message sent while a main-conversation turn works is steered into that
//! turn, which reads it only at its next tool boundary and answers at its
//! end; a turn that waits in one long tool call answers nobody meanwhile
//! ("hello?"). When the turn still runs [`Brain::set_desk_grace`] after
//! such a message, the host answers at once in the desk voice
//! (`voice::DESK`): the turn is busy, with what and for how long, it reads
//! the message next, and which subagents are at work. No model runs, so the
//! receipt comes even when the turn is stuck. At most one per turn; a turn
//! that ends within the grace posts none.

use std::time::{Duration, Instant};

use super::{Brain, Phase, reply_entry};

/// How long a message waits on a running turn before the desk answers
/// (the host's default; `OPTCHAT_DESK_GRACE_SECONDS`, 0 turns it off).
pub const DESK_GRACE: Duration = Duration::from_secs(5);

/// Longest task title a receipt shows per subagent.
const TITLE_CHARS: usize = 40;

/// A receipt waiting for its grace to pass.
#[derive(Clone, Debug)]
pub(super) struct DeskPending {
    at: Instant,
    /// The running turn's key: the receipt is for that turn only.
    pub(super) turn: String,
    /// The seq of the first message it answers (the receipt's key).
    seq: u64,
}

impl Brain {
    /// How long a message waits on a running turn before the desk's
    /// receipt; None: no receipts (the default; the host sets it).
    pub fn set_desk_grace(&mut self, grace: Option<Duration>) {
        self.desk_grace = grace.filter(|g| !g.is_zero());
    }

    /// When the pending receipt is due.
    pub(super) fn desk_due(&self) -> Option<Instant> {
        self.desk.as_ref().map(|d| d.at)
    }

    /// A person's message `seq` of the main conversation arrived while its
    /// turn runs: the receipt is due after the grace, unless this turn has
    /// one already.
    pub(super) fn desk_arm(&mut self, seq: u64) {
        let Some(grace) = self.desk_grace else {
            return;
        };
        if self.phase != Phase::Running || self.desk.is_some() {
            return;
        }
        let Some(turn) = self.state.turn.as_ref().map(|t| t.key.clone()) else {
            return;
        };
        if self.desk_told.as_deref() == Some(turn.as_str()) {
            return;
        }
        self.desk = Some(DeskPending {
            at: Instant::now() + grace,
            turn,
            seq,
        });
    }

    /// The running turn's latest activity line (`run.activity` frames).
    pub(super) fn desk_note_activity(&mut self, turn: &str, live: &[serde_json::Value]) {
        let line = live
            .iter()
            .rev()
            .filter(|f| f["t"] == "run.activity")
            .find_map(|f| f["line"].as_str());
        if let Some(line) = line {
            self.turn_activity = Some((turn.to_owned(), line.to_owned()));
        }
    }

    /// Posts the receipt once it is due and its turn still runs.
    pub(super) fn on_desk_timer(&mut self, now: Instant) {
        if self.desk.as_ref().is_none_or(|d| d.at > now) {
            return;
        }
        let Some(pending) = self.desk.take() else {
            return;
        };
        let running = self.phase == Phase::Running
            && self
                .state
                .turn
                .as_ref()
                .is_some_and(|t| t.key == pending.turn);
        let Some(conversation) = self.state.conversation.clone().filter(|_| running) else {
            return;
        };
        let activity = self
            .turn_activity
            .as_ref()
            .filter(|(turn, _)| *turn == pending.turn)
            .map(|(_, line)| line.as_str());
        let text = receipt(
            activity,
            self.turn_clock.map(|t| t.elapsed()),
            &self.at_work(),
        );
        let key = crate::voice::key(
            crate::voice::DESK,
            &format!("{}:{}", pending.turn, pending.seq),
        );
        if self.trace.is_on() {
            self.trace.emit(
                "desk.receipt",
                serde_json::json!({"turn": pending.turn, "seq": pending.seq, "key": key}),
            );
        }
        self.desk_told = Some(pending.turn);
        self.state
            .outbox
            .push(reply_entry(conversation, &key, &text));
        self.save();
        self.flush_outbox();
    }

    /// The subagents at work now, with their task titles.
    fn at_work(&self) -> Vec<(String, String)> {
        self.state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| s.at_work())
            .map(|s| (s.id.clone(), s.title.clone()))
            .collect()
    }
}

/// The receipt's text: what the turn does and for how long, then the
/// subagents at work (`a3 (overlay polish)`).
pub(super) fn receipt(
    activity: Option<&str>,
    elapsed: Option<Duration>,
    at_work: &[(String, String)],
) -> String {
    let doing: Vec<String> = activity
        .map(str::trim)
        .filter(|a| !a.is_empty())
        .map(str::to_owned)
        .into_iter()
        .chain(elapsed.map(clock))
        .collect();
    let mut text = if doing.is_empty() {
        "Got it. The Chief is busy with a turn and reads your message next.".to_owned()
    } else {
        format!(
            "Got it. The Chief is busy with a turn ({}) and reads your message next.",
            doing.join(", ")
        )
    };
    if !at_work.is_empty() {
        let names: Vec<String> = at_work
            .iter()
            .map(|(id, title)| match short(title) {
                t if t.is_empty() => id.clone(),
                t => format!("{id} ({t})"),
            })
            .collect();
        text.push_str(&format!("\nAt work: {}.", names.join(", ")));
    }
    text
}

/// `12s`, `1m 12s`, `1h 3m`.
fn clock(d: Duration) -> String {
    let s = d.as_secs();
    match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m {}s", s / 60, s % 60),
        _ => format!("{}h {}m", s / 3600, s % 3600 / 60),
    }
}

/// A task title's first line, at most [`TITLE_CHARS`] characters.
fn short(title: &str) -> String {
    let line = title.lines().next().unwrap_or_default().trim();
    if line.chars().count() <= TITLE_CHARS {
        return line.to_owned();
    }
    let cut: String = line.chars().take(TITLE_CHARS - 1).collect();
    format!("{}…", cut.trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_receipt_says_what_the_turn_does_and_who_is_at_work() {
        let at_work = vec![
            ("a3".to_owned(), "Overlay polish".to_owned()),
            ("a7".to_owned(), String::new()),
        ];
        assert_eq!(
            receipt(
                Some("Running git log -1"),
                Some(Duration::from_secs(72)),
                &at_work
            ),
            "Got it. The Chief is busy with a turn (Running git log -1, 1m 12s) and reads your message next.\nAt work: a3 (Overlay polish), a7."
        );
        assert_eq!(
            receipt(None, None, &[]),
            "Got it. The Chief is busy with a turn and reads your message next."
        );
    }

    #[test]
    fn clock_and_titles_stay_short() {
        assert_eq!(clock(Duration::from_secs(9)), "9s");
        assert_eq!(clock(Duration::from_secs(3_780)), "1h 3m");
        let long = "x".repeat(60);
        assert_eq!(short(&long).chars().count(), TITLE_CHARS);
        assert_eq!(short("first line\nsecond"), "first line");
    }
}
