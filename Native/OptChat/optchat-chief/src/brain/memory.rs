//! The brain's side of the memory files (memory_files.rs): the store every
//! turn's `<chief-memory>` block reads, and the self-paced check-ins
//! (check_in.rs) that wake the Chief on its open loops.

use std::sync::Arc;

use super::{Brain, Phase, Queued, Source};
use crate::check_in::{CloseWhen, Mode};
use crate::tools::WakeCall;

/// A turn that only notes started (a check-in, a follow-up, a sleep wake, a
/// watch): its outcome and cost go in a `wake_runs` row.
#[derive(Clone, Debug, Default)]
pub(super) struct WakeRunState {
    pub id: String,
    pub started_at: i64,
    /// The earliest planned time of the wakes that started it.
    pub scheduled_at: Option<i64>,
    /// What it posted: its last send or reply, else the turn's final text.
    pub result: String,
    pub reasons: Vec<String>,
    /// `nothing` or `ask`, with its text, when the Chief chose one.
    pub outcome: Option<(String, String)>,
    /// Something was posted in the run (send, reply, ask).
    pub posted: bool,
    pub limit: Option<f64>,
    /// The loops of the follow-ups that woke it.
    pub loops: Vec<String>,
}

/// The note tags that make a turn a wake run.
const WAKE_TAGS: [&str; 5] = [
    "[check-in]",
    "[follow-up]",
    "[follow-up ",
    "[wake]",
    "[watch ",
];

impl Brain {
    /// The memory files every turn's `<chief-memory>` block comes from.
    pub fn set_memory_files(&mut self, files: Arc<crate::memory_files::MemoryFiles>) {
        self.check_in_last = files.meta(CHECK_IN_KEY);
        self.wake_settings = files.wake_settings();
        self.memory_files = Some(files);
    }

    /// The self-paced check-in mode (check_in.rs).
    pub fn set_check_ins(&mut self, mode: crate::check_in::Mode) {
        self.check_ins = mode;
    }

    /// The check-in mode in force: the person's setting, else the host's.
    fn check_in_mode(&self) -> Mode {
        self.wake_settings.mode.unwrap_or(self.check_ins)
    }

    /// When the next check-in slot comes, on the brain's clock (None: off,
    /// or no memory files). At most 5 minutes away, so the wall clock is read
    /// again after the Mac slept (`Instant` stops in sleep).
    pub(super) fn next_check_in(&self) -> Option<std::time::Instant> {
        self.memory_files.as_ref()?;
        let now = chrono::Local::now().fixed_offset();
        // Today's slot not taken yet (the host started after it): now.
        if let Some(slot) = crate::check_in::current_slot(self.check_in_mode(), now)
            && self.check_in_last.as_deref() != Some(slot.as_str())
        {
            return Some(std::time::Instant::now());
        }
        let at = crate::check_in::next_slot(self.check_in_mode(), now)?;
        let wait = (at - now).to_std().ok()?.min(CHECK_IN_RECHECK);
        Some(std::time::Instant::now() + wait)
    }

    /// At a check-in slot not taken yet: wakes the Chief with its open loops,
    /// or takes the slot quietly when there are none. The slot is taken in
    /// memory first, so a store that fails never wakes the Chief twice.
    pub(super) fn fire_check_in(&mut self) {
        let Some(files) = self.memory_files.clone() else {
            return;
        };
        let now = chrono::Local::now().fixed_offset();
        let Some(slot) = crate::check_in::current_slot(self.check_in_mode(), now) else {
            return;
        };
        if self.check_in_last.as_deref() == Some(slot.as_str()) {
            return;
        }
        self.check_in_last = Some(slot.clone());
        if let Err(e) = files.put_meta(CHECK_IN_KEY, &slot) {
            (self.log)(&format!(
                "check-in {slot}: not saved ({e}); it may come again after a restart"
            ));
        }
        if crate::check_in::in_quiet(self.wake_settings.quiet.as_deref(), now) {
            (self.log)(&format!(
                "check-in {slot}: in the person's quiet hours, no wake"
            ));
            return;
        }
        // Loops whose pull request merged close first (one `gh` call per such
        // loop, off the brain thread); then the check-in sees what is left.
        let prs: Vec<(String, String)> = files
            .loops()
            .into_iter()
            .flat_map(|r| {
                crate::check_in::close_conditions(&r.body)
                    .into_iter()
                    .filter_map(move |c| match c {
                        CloseWhen::PrMerged(pr) => Some((r.path.clone(), pr)),
                        _ => None,
                    })
            })
            .collect();
        if prs.is_empty() {
            self.check_in_ready(slot);
            return;
        }
        let tx = self.tx.clone();
        let log = self.log.clone();
        let slot_again = slot.clone();
        let spawned = std::thread::Builder::new()
            .name("check-in-prs".into())
            .spawn(move || {
                let merged: Vec<(String, String)> = prs
                    .into_iter()
                    .filter(|(_, pr)| {
                        pr_merged(pr).unwrap_or_else(|e| {
                            log(&format!("check-in: {pr}: {e}"));
                            false
                        })
                    })
                    .collect();
                let _ = tx.send(super::Input::CheckInReady { slot, merged });
            });
        if let Err(e) = spawned {
            (self.log)(&format!(
                "check-in: no thread for the PR check ({e}); checking in without it"
            ));
            self.check_in_ready(slot_again);
        }
    }

    /// The check-in after its PR check: closes the merged loops, then wakes
    /// the Chief with the loops left (none: no wake).
    pub(super) fn check_in_ready(&mut self, slot: String) {
        let Some(files) = self.memory_files.clone() else {
            return;
        };
        let loops: Vec<String> = files
            .loops()
            .iter()
            .map(crate::memory_files::index_line)
            .collect();
        if loops.is_empty() {
            (self.log)(&format!("check-in {slot}: no open loops, no wake"));
            return;
        }
        (self.log)(&format!(
            "check-in {slot}: {} open loop(s), waking",
            loops.len()
        ));
        let text = crate::check_in::note(&loops, &slot);
        // The slot's own time, for the wake run's `scheduled_at`.
        let planned = chrono::NaiveDateTime::parse_from_str(&slot, "%Y-%m-%d %H:%M")
            .ok()
            .and_then(|n| {
                use chrono::TimeZone;
                chrono::Local.from_local_datetime(&n).earliest()
            })
            .map(|t| t.timestamp_millis());
        if let Some(at) = planned {
            self.wake_planned.insert(text.clone(), at);
        }
        self.queue(text, Source::Note);
    }

    /// `merged`: (loop path, PR) pairs the check found merged.
    pub(super) fn close_merged(&mut self, merged: &[(String, String)]) {
        for (path, pr) in merged {
            self.close_loop(path, &format!("{pr} merged"));
        }
    }

    /// Closes every open loop whose `Closes when:` names `cond`.
    pub(super) fn close_loops(&mut self, cond: &CloseWhen, why: &str) {
        let Some(files) = self.memory_files.clone() else {
            return;
        };
        for row in files.loops() {
            if crate::check_in::close_conditions(&row.body).contains(cond) {
                self.close_loop(&row.path, why);
            }
        }
    }

    /// Removes loop `path` (its text stays in the history) and logs a note
    /// the next turn reads.
    fn close_loop(&mut self, path: &str, why: &str) {
        let Some(files) = self.memory_files.clone() else {
            return;
        };
        match files.remove(path, &format!("host:{why}"), false) {
            Ok(a) if a.starts_with("outcome: done") => {
                (self.log)(&format!("loop {path} closed: {why}"));
                let _ = self.chat.append(
                    optchat_core::Kind::Note,
                    &format!("[loop closed] {path}: {why}"),
                );
            }
            Ok(_) => {}
            Err(e) => (self.log)(&format!("closing loop {path}: {e}")),
        }
    }

    /// The wake tools: `follow_up`, `follow_ups`, `check_ins`, `nothing`, `ask`.
    pub(super) fn wake_tool(&mut self, call: WakeCall) -> Result<String, String> {
        match call {
            WakeCall::FollowUp {
                note,
                at,
                within,
                loop_path,
                for_person,
            } => {
                let now = chrono::Local::now().fixed_offset();
                let due = crate::check_in::follow_up_due(now, at.as_deref(), within.as_deref())?;
                if due <= now {
                    return Err(format!(
                        "follow_up: {} is not in the future (now is {})",
                        due.format("%a %Y-%m-%d %H:%M"),
                        now.format("%a %Y-%m-%d %H:%M")
                    ));
                }
                let quiet = self.wake_settings.quiet.clone();
                let moved = if for_person {
                    due
                } else {
                    crate::check_in::after_quiet(quiet.as_deref(), due)
                };
                let at_ms = moved.timestamp_millis().max(0) as u64;
                let id = crate::check_in::follow_up_id(&note, at_ms, loop_path.as_deref());
                if self
                    .state
                    .wakes
                    .iter()
                    .any(|w| w.id.as_deref() == Some(id.as_str()))
                {
                    return Ok(format!("outcome: noop. follow-up {id} is set already"));
                }
                if self.state.wakes.len() >= FOLLOW_UPS_KEPT {
                    return Err(format!(
                        "follow_up: {FOLLOW_UPS_KEPT} wakes are pending; cancel some with follow_ups"
                    ));
                }
                self.state.wakes.push(crate::state::Wake {
                    at_ms,
                    asked_ms: super::now_ms(),
                    note,
                    until_event: false,
                    id: Some(id.clone()),
                    loop_path,
                    for_person,
                });
                self.state.wakes.sort_by_key(|w| w.at_ms);
                self.save();
                let when = moved.format("%a %Y-%m-%d %H:%M");
                Ok(if moved != due {
                    format!(
                        "outcome: done. follow-up {id} set for {when} (moved out of the person's quiet hours {}); your turn goes on",
                        quiet.unwrap_or_default()
                    )
                } else {
                    format!("outcome: done. follow-up {id} set for {when}; your turn goes on")
                })
            }
            WakeCall::FollowUps { cancel } => {
                if let Some(id) = cancel {
                    let before = self.state.wakes.len();
                    if id == "all" {
                        self.state.wakes.retain(|w| w.id.is_none());
                    } else {
                        self.state
                            .wakes
                            .retain(|w| w.id.as_deref() != Some(id.as_str()));
                    }
                    let n = before - self.state.wakes.len();
                    self.save();
                    return Ok(format!(
                        "outcome: {}. cancelled {n} follow-up(s)",
                        if n > 0 { "done" } else { "noop" }
                    ));
                }
                let lines: Vec<String> = self
                    .state
                    .wakes
                    .iter()
                    .map(|w| {
                        let when = chrono::DateTime::from_timestamp_millis(w.at_ms as i64)
                            .map(|t| {
                                t.with_timezone(&chrono::Local)
                                    .format("%a %Y-%m-%d %H:%M")
                                    .to_string()
                            })
                            .unwrap_or_default();
                        format!(
                            "- {} {when}: {}{}",
                            w.id.as_deref().unwrap_or("sleep"),
                            w.note,
                            w.loop_path
                                .as_deref()
                                .map(|p| format!(" (loop {p})"))
                                .unwrap_or_default()
                        )
                    })
                    .collect();
                Ok(if lines.is_empty() {
                    "No follow-ups or wakes pending.".to_owned()
                } else {
                    lines.join("\n")
                })
            }
            WakeCall::CheckIns {
                mode,
                quiet,
                cost_limit_millis,
            } => {
                let cost_limit_usd = cost_limit_millis.map(|m| m as f64 / 1000.0);
                let changed = mode.is_some() || quiet.is_some() || cost_limit_usd.is_some();
                let mut s = self.wake_settings.clone();
                if let Some(m) = mode {
                    s.mode = Some(Mode::parse(Some(&m)));
                }
                if let Some(q) = quiet {
                    s.quiet = (q != "off").then_some(q);
                }
                if let Some(l) = cost_limit_usd {
                    s.cost_limit_usd = (l > 0.0).then_some(l);
                }
                if changed {
                    if let Some(files) = &self.memory_files {
                        files.put_wake_settings(&s)?;
                    }
                    self.wake_settings = s.clone();
                }
                let mut out = format!(
                    "outcome: {}. {}",
                    if changed { "done" } else { "noop" },
                    s.describe(self.check_ins)
                );
                if let Some(files) = &self.memory_files
                    && let Ok(runs) = files.wake_runs(5)
                    && !runs.is_empty()
                {
                    out.push_str("\nLast wake runs:");
                    for r in runs {
                        let when = chrono::DateTime::from_timestamp_millis(r.started_at)
                            .map(|t| {
                                t.with_timezone(&chrono::Local)
                                    .format("%a %H:%M")
                                    .to_string()
                            })
                            .unwrap_or_default();
                        out.push_str(&format!(
                            "\n- {when} {} -> {}{}{}",
                            r.wake_reasons,
                            r.outcome,
                            r.cost_usd.map(|c| format!(", ${c:.3}")).unwrap_or_default(),
                            if r.state == "succeeded" {
                                String::new()
                            } else {
                                format!(", {} ({})", r.state, r.reason)
                            }
                        ));
                    }
                }
                Ok(out)
            }
            WakeCall::Nothing { reason } => {
                if self.phase != Phase::Running {
                    return Ok("outcome: noop. no turn is running".to_owned());
                }
                self.refuse_unanswered("nothing")?;
                let Some(run) = self.wake_run.as_mut() else {
                    return Err("nothing: only a wake run (a [check-in], [follow-up], [wake] or [watch] turn) may end with nothing; answer the person's message".into());
                };
                run.outcome = Some(("nothing".into(), reason));
                self.end_turn_by_tool("nothing");
                Ok("outcome: done. nothing is posted; the turn ends now".to_owned())
            }
            WakeCall::Ask { question } => {
                if self.phase != Phase::Running {
                    return Err("ask: no turn is running".into());
                }
                if self.wake_run.is_none() {
                    return Err("ask: only a wake run (a [check-in], [follow-up], [wake] or [watch] turn) ends with ask; in a person's turn, put the question in your reply".into());
                }
                self.refuse_unanswered("ask")?;
                let posted = self.send(crate::tools::SendCall {
                    text: Some(format!("**Needs you:** {question}")),
                    attachments: Vec::new(),
                    reply_to: None,
                    long: true,
                })?;
                if let Some(run) = self.wake_run.as_mut() {
                    run.outcome = Some(("ask".into(), question));
                }
                self.end_turn_by_tool("ask");
                Ok(format!(
                    "{posted}; the turn ends now and their answer comes back as a message"
                ))
            }
        }
    }

    /// At a turn's start: a wake run when only wake notes started it. Returns
    /// its cost budget when the person set a limit.
    pub(super) fn begin_wake_run(
        &mut self,
        items: &[Queued],
        key: &str,
        codex: bool,
    ) -> Option<crate::turn::Budget> {
        self.wake_run = None;
        // The planned times of this turn's wake notes, taken out of the map.
        // A note that left the queue another way (steered into a running
        // turn, delivered at its tool boundary) is dropped here too, so the
        // map holds only notes still queued.
        let planned: Option<i64> = items
            .iter()
            .filter_map(|q| self.wake_planned.remove(&q.text))
            .min();
        let queued: std::collections::HashSet<&str> =
            self.queue.iter().map(|q| q.text.as_str()).collect();
        self.wake_planned
            .retain(|text, _| queued.contains(text.as_str()));
        // The resume of a cut wake run (only its resume item): the same run.
        // A cut run that a person's message joined ends here as `cut`.
        if let Some(run) = self.cut_wake_run.take() {
            if !items.is_empty()
                && items
                    .iter()
                    .all(|q| matches!(q.source, Source::Resume { .. }))
            {
                let limit = run.limit;
                self.wake_run = Some(run);
                return limit.and_then(|l| self.budget(l, key, codex));
            }
            self.record_run(
                &run,
                "cut",
                String::new(),
                String::new(),
                None,
                "cancelled",
                "superseded",
            );
        }
        let wake_only = !items.is_empty()
            && items.iter().all(|q| {
                matches!(q.source, Source::Note) && WAKE_TAGS.iter().any(|t| q.text.starts_with(t))
            });
        if !wake_only {
            return None;
        }
        let reasons: Vec<String> = items
            .iter()
            .map(|q| {
                let first = q.text.lines().next().unwrap_or("");
                first.chars().take(80).collect()
            })
            .collect();
        let limit = self.wake_settings.limit();
        self.wake_run = Some(WakeRunState {
            id: key.to_owned(),
            started_at: chrono::Utc::now().timestamp_millis(),
            scheduled_at: planned,
            result: String::new(),
            reasons,
            outcome: None,
            posted: false,
            limit,
            loops: items
                .iter()
                .filter_map(|q| follow_up_loop(&q.text))
                .collect(),
        });
        self.budget(limit?, key, codex)
    }

    /// A cost budget of `limit` dollars, priced at this Chief's measured
    /// rates (read at most once an hour, off the hot path of later turns).
    /// None: no measured rate yet, or the turn runs on codex, whose token
    /// counts arrive only at its end; then the limit is checked when it ends.
    fn budget(&mut self, limit: f64, key: &str, codex: bool) -> Option<crate::turn::Budget> {
        if codex {
            (self.log)(&format!(
                "wake run {key}: codex reports its use at the end; its ${limit:.2} limit is checked then"
            ));
            return None;
        }
        let fresh = self
            .rates
            .as_ref()
            .is_some_and(|(at, _)| at.elapsed() < std::time::Duration::from_secs(3600));
        if !fresh {
            let root = self.memory_files.as_ref()?.path().parent()?.to_owned();
            self.rates = Some((std::time::Instant::now(), crate::usage::rates(&root, 30)));
        }
        let rates = self.rates.as_ref()?.1.clone();
        // An unknown model is priced at the dearest measured one: a run
        // stops early rather than late.
        let fallback = rates.values().copied().fold(0.0, f64::max);
        if fallback <= 0.0 {
            (self.log)(&format!(
                "wake run {key}: no measured price yet; its ${limit:.2} limit is checked after it ends"
            ));
            return None;
        }
        Some(crate::turn::Budget {
            limit_usd: limit,
            rates,
            fallback,
        })
    }

    /// Writes one wake run's row.
    #[allow(clippy::too_many_arguments)]
    fn record_run(
        &self,
        run: &WakeRunState,
        outcome: &str,
        result: String,
        outcome_text: String,
        cost: Option<f64>,
        state: &str,
        reason: &str,
    ) {
        if let Some(files) = &self.memory_files
            && let Err(e) = files.record_wake_run(&crate::memory_files::WakeRun {
                id: run.id.clone(),
                started_at: run.started_at,
                scheduled_at: run.scheduled_at,
                wake_reasons: run.reasons.join("; "),
                outcome: outcome.to_owned(),
                result,
                outcome_text,
                cost_usd: cost,
                limit_usd: run.limit,
                state: state.to_owned(),
                reason: reason.to_owned(),
            })
        {
            (self.log)(&format!("wake run {}: not recorded ({e})", run.id));
        }
    }

    /// A person's message joined the running wake run: no cost limit now.
    pub(super) fn lift_wake_budget(&mut self) {
        if let Some(run) = self.wake_run.as_mut()
            && run.limit.take().is_some()
        {
            self.interrupt.lift_budget();
            (self.log)(&format!(
                "wake run {}: a person's message came; its cost limit is lifted",
                run.id
            ));
        }
    }

    /// Something was posted in the running turn (send, reply).
    pub(super) fn wake_run_posted(&mut self, text: &str) {
        if let Some(run) = self.wake_run.as_mut() {
            run.posted = true;
            if !text.trim().is_empty() {
                run.result = text.trim().to_owned();
            }
        }
    }

    /// At a turn's end: the wake run's row, its loops closed when it sent or
    /// asked, and a note when its cost limit stopped it.
    pub(super) fn end_wake_run(&mut self, outcome: &crate::turn::TurnOutcome, final_posted: bool) {
        let Some(run) = self.wake_run.take() else {
            return;
        };
        // `outcome_text`: nothing's reason or ask's question; `result`: what
        // a send posted (its last post, else the turn's final text).
        let (kind, text) = match run.outcome.clone() {
            Some(o) => o,
            None if run.posted || final_posted => ("send".to_owned(), String::new()),
            None => ("none".to_owned(), String::new()),
        };
        let result = if kind == "send" {
            if run.result.is_empty() && final_posted {
                outcome.reply.as_deref().unwrap_or("").trim().to_owned()
            } else {
                run.result.clone()
            }
        } else {
            String::new()
        };
        let cost = outcome.stats.cost;
        let over = match (run.limit, outcome.budget_stopped, cost) {
            (Some(_), Some(_), _) => Some("cost limit"),
            (Some(l), None, Some(c)) if c > l => Some("over its cost limit after it ended"),
            _ => None,
        };
        if let Some(why) = over {
            let note = format!(
                "[cost limit] The wake run ({}) {} at about ${:.3} of its ${:.2} limit.",
                run.reasons.join("; "),
                if outcome.budget_stopped.is_some() {
                    "was stopped"
                } else {
                    "ended"
                },
                outcome.budget_stopped.or(cost).unwrap_or(0.0),
                run.limit.unwrap_or(0.0)
            );
            (self.log)(&format!("{note} ({why})"));
            let _ = self.chat.append(optchat_core::Kind::Note, &note);
        }
        if matches!(kind.as_str(), "send" | "ask") {
            for path in &run.loops {
                if let Some(files) = &self.memory_files
                    && let Ok(Some(row)) = files.get(path)
                    && crate::check_in::close_conditions(&row.body)
                        .contains(&CloseWhen::FollowUpSent)
                {
                    self.close_loop(path, "its follow-up was sent");
                }
            }
        }
        // The spec's run state: a run the cost limit stopped is cancelled
        // (reason cost_limit), one that failed says why, else it succeeded.
        let (state, reason) = if outcome.budget_stopped.is_some() {
            ("cancelled", "cost_limit".to_owned())
        } else if let Some(e) = outcome.error.as_deref().filter(|e| !e.trim().is_empty()) {
            (
                "failed",
                format!("error: {}", e.trim().chars().take(200).collect::<String>()),
            )
        } else {
            ("succeeded", String::new())
        };
        self.record_run(&run, &kind, result, text, cost, state, &reason);
        self.trace.emit(
            "chief.wake_run",
            serde_json::json!({"id": run.id, "outcome": kind, "cost_usd": cost, "limit_usd": run.limit, "state": state, "reason": reason}),
        );
    }

    /// The `<chief-memory>` block of the turn starting now (the whole block
    /// in the owner's turn, the loops only in another person's) and whether
    /// the last turn read the same block (a kept session then has it).
    pub(super) fn turn_memory_block(&mut self) -> (Option<String>, bool) {
        let block = self.memory_files.as_ref().and_then(|files| {
            if self.turn_ask {
                files.outside_block()
            } else {
                files.block()
            }
        });
        let same = block.is_some() && block == self.last_memory_block;
        self.last_memory_block = block.clone();
        (block, same)
    }
}

/// The loop a follow-up note names in its first token (`[follow-up
/// loops/x.md] note`); the host writes that token before the note text.
pub(super) fn follow_up_loop(text: &str) -> Option<String> {
    let rest = text.strip_prefix("[follow-up ")?;
    let (path, _) = rest.split_once(']')?;
    (path.starts_with("loops/") && crate::memory_files::writable(path)).then(|| path.to_owned())
}

/// Whether pull request `OWNER/REPO#N` is merged: one `gh` call, at most
/// 20 s (its own thread; this one waits on a channel).
fn pr_merged(pr: &str) -> Result<bool, String> {
    if !crate::check_in::valid_pr(pr) {
        return Err("not OWNER/REPO#N".into());
    }
    let (repo, n) = pr.split_once('#').ok_or("not OWNER/REPO#N")?;
    let child = std::process::Command::new("gh")
        .args([
            "pr", "view", n, "-R", repo, "--json", "state", "-q", ".state",
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("gh: {e}"))?;
    // A reader thread sends gh's output when gh exits. A waiter thread owns
    // the child: it kills it when this side gives up after 20 s, and reaps
    // it in either case (when this side drops its end), so no pid is reused
    // and no child is left unreaped.
    let mut child = child;
    let stdout = child.stdout.take();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("check-in-gh-out".into())
        .spawn(move || {
            let mut s = String::new();
            if let Some(mut so) = stdout {
                use std::io::Read;
                let _ = so.read_to_string(&mut s);
            }
            let _ = tx.send(s);
        })
        .map_err(|e| {
            let _ = child.kill();
            let _ = child.wait();
            format!("gh: {e}")
        })?;
    let (kill_tx, kill_rx) = std::sync::mpsc::channel::<()>();
    let reaper = std::thread::Builder::new()
        .name("check-in-gh".into())
        .spawn(move || {
            if kill_rx.recv().is_ok() {
                let _ = child.kill();
            }
            let _ = child.wait();
        });
    if let Err(e) = reaper {
        return Err(format!("gh: {e}"));
    }
    match rx.recv_timeout(std::time::Duration::from_secs(20)) {
        Ok(out) => {
            drop(kill_tx);
            Ok(out.trim() == "MERGED")
        }
        Err(_) => {
            let _ = kill_tx.send(());
            Err("gh timed out".into())
        }
    }
}

/// Most follow-ups and wakes pending at once.
const FOLLOW_UPS_KEPT: usize = 64;

/// Where the last taken check-in slot is kept.
const CHECK_IN_KEY: &str = "check_in.last";
/// The longest wait before the check-in clock is read again.
const CHECK_IN_RECHECK: std::time::Duration = std::time::Duration::from_secs(300);
