//! The Chief's `watch` tool: a promise like "I'll continue when you finish
//! signing in" or "tell me when CI is green" becomes a job. The host runs the
//! command off the turn (`crate::watch`), saves the watch in the host state
//! (`HostState::watches`, so it runs again after a restart) and, when it ends
//! (a line matched `until`, it exited, or it timed out), queues one note
//! `[watch w<N>] <note>: <what happened>` with its last output lines, the
//! same wake path as `sleep` (wakes.rs). The Chief's turn goes on: unlike
//! `sleep`, `watch` does not end it.

use super::{Brain, Source, now_ms};
use crate::state::Watch;
use crate::tools::{WATCH_DEFAULT_SECONDS, WATCHES_KEPT, WatchCall};
use crate::watch::{Ending, Fired};

impl Brain {
    /// The `watch` tool: starts a watch, cancels one (or all), or lists them.
    pub(super) fn watch(&mut self, call: WatchCall) -> Result<String, String> {
        if let Some(which) = call.cancel.as_deref() {
            return Ok(self.cancel_watches(which));
        }
        let Some(command) = call.command else {
            return Ok(self.list_watches());
        };
        if self.state.watches.len() >= WATCHES_KEPT {
            return Err(format!(
                "watch: {WATCHES_KEPT} watches are pending already; cancel one first (watch cancel: w<N> or all)"
            ));
        }
        self.state.last_watch += 1;
        let now = now_ms();
        let seconds = call.timeout_seconds.unwrap_or(WATCH_DEFAULT_SECONDS);
        let watch = Watch {
            id: format!("w{}", self.state.last_watch),
            command,
            until: call.until,
            note: call.note.unwrap_or_default(),
            asked_ms: now,
            deadline_ms: now + seconds * 1000,
        };
        self.state.watches.push(watch.clone());
        self.save();
        self.run_watch(&watch);
        (self.log)(&format!("watch {} started: {}", watch.id, watch.command));
        Ok(format!(
            "outcome: done. watch {} runs off your turn; you wake once when {}, or in {} at the latest. {} watch(es) pending",
            watch.id,
            match &watch.until {
                Some(u) => format!("its output matches `{u}`"),
                None => "the command exits".to_owned(),
            },
            super::wakes::human(seconds),
            self.state.watches.len()
        ))
    }

    /// The saved watches the Chief started, oldest first.
    pub fn pending_watches(&self) -> Vec<Watch> {
        self.state.watches.clone()
    }

    /// Runs every saved watch that does not run yet: at the host's start
    /// (`Brain::run`), so a watch outlives a restart. A deadline that passed
    /// while the host was down fires the watch as timed out at once.
    pub fn rearm_watches(&mut self) {
        let saved: Vec<Watch> = self
            .state
            .watches
            .iter()
            .filter(|w| !self.watch_runs.contains_key(&w.id))
            .cloned()
            .collect();
        for watch in saved {
            (self.log)(&format!("watch {} runs again after a restart", watch.id));
            self.run_watch(&watch);
        }
    }

    fn run_watch(&mut self, watch: &Watch) {
        let tx = self.tx.clone();
        let running = crate::watch::start(watch, now_ms, move |fired| {
            let _ = tx.send(super::Input::WatchFired(Box::new(fired)));
        });
        self.watch_runs.insert(watch.id.clone(), running);
    }

    fn list_watches(&self) -> String {
        if self.state.watches.is_empty() {
            return "outcome: noop. no watches are pending".to_owned();
        }
        let now = now_ms();
        let lines: Vec<String> = self
            .state
            .watches
            .iter()
            .map(|w| {
                format!(
                    "{}: `{}`{}, {} left{}",
                    w.id,
                    w.command,
                    w.until
                        .as_deref()
                        .map(|u| format!(" until `{u}`"))
                        .unwrap_or_default(),
                    super::wakes::human(w.deadline_ms.saturating_sub(now) / 1000),
                    if w.note.is_empty() {
                        String::new()
                    } else {
                        format!(" ({})", w.note)
                    }
                )
            })
            .collect();
        format!(
            "outcome: done. {} watch(es) pending:\n{}",
            lines.len(),
            lines.join("\n")
        )
    }

    fn cancel_watches(&mut self, which: &str) -> String {
        let all = which.eq_ignore_ascii_case("all");
        let gone: Vec<String> = self
            .state
            .watches
            .iter()
            .filter(|w| all || w.id == which)
            .map(|w| w.id.clone())
            .collect();
        if gone.is_empty() {
            return format!("outcome: noop. no pending watch {which}");
        }
        self.state.watches.retain(|w| !gone.contains(&w.id));
        for id in &gone {
            // Dropping the handle kills the watch's process group.
            self.watch_runs.remove(id);
        }
        self.save();
        (self.log)(&format!("watch cancelled: {}", gone.join(", ")));
        format!(
            "outcome: done. cancelled {} watch(es): {}",
            gone.len(),
            gone.join(", ")
        )
    }

    /// A watch ended: its note wakes the Chief, once. A watch cancelled in
    /// the meantime is no longer saved and wakes nobody.
    pub(super) fn watch_fired(&mut self, fired: Fired) {
        let Some(at) = self.state.watches.iter().position(|w| w.id == fired.id) else {
            return;
        };
        let watch = self.state.watches.remove(at);
        self.watch_runs.remove(&watch.id);
        self.save();
        let took = super::wakes::human(now_ms().saturating_sub(watch.asked_ms) / 1000);
        let what = match &fired.ending {
            Ending::Matched(line) => format!(
                "the output matched `{}` after {took}: {line}",
                watch.until.as_deref().unwrap_or_default()
            ),
            Ending::Exited(code) => format!("the command exited with {code} after {took}"),
            Ending::TimedOut => format!(
                "timed out after {took}{}",
                watch
                    .until
                    .as_deref()
                    .map(|u| format!(" with no match for `{u}`"))
                    .unwrap_or_else(|| ", the command still running".to_owned())
            ),
            Ending::Failed(why) => format!("the command could not start: {why}"),
        };
        let note = if watch.note.trim().is_empty() {
            "(no note)".to_owned()
        } else {
            watch.note.trim().to_owned()
        };
        let mut text = format!("[watch {}] {note}: {what}", watch.id);
        if !fired.tail.is_empty() {
            text.push_str("\nLast output:");
            for line in &fired.tail {
                text.push_str("\n  ");
                text.push_str(line);
            }
        }
        text.push_str(&format!(
            "\n(You started it with watch: `{}`.)",
            watch.command
        ));
        (self.log)(&format!("watch {} fired: {what}", watch.id));
        self.queue(text, Source::Note);
    }
}
