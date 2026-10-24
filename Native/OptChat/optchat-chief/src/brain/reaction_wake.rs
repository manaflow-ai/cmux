//! Whether a user's reaction on a Chief message wakes the Chief (a416,
//! Lawrence 2026-10-21 msg 9070: "it should sometimes cause a turn tho...
//! maybe it should go through a cheap model first to determine if it should
//! start a turn. we need to be careful to avoid that i do reaction on ur
//! message, you start typing indicator, then stop typing indicator since i
//! reacted to something trivial").
//!
//! A reaction someone else puts on one of the Chief's own messages waits
//! `DEBOUNCE` (quick swaps are one decision, on the last reaction), then a
//! cheap classifier (Claude Haiku by default, `ReactionJudge`) answers
//! `WAKE: reason` or `SKIP: reason` off the brain thread. Nothing a person
//! can see of a turn (the typing dots, a turn) happens before it says wake:
//! the decision is logged as a note (`reaction <glyph> <name> from <who> on
//! your message: <first line> — wake: <reason>` or `— no wake: <reason>`),
//! and only a wake then queues a note that starts a turn like any other. A
//! failure, an answer that is neither, or no answer in `JUDGE_TIMEOUT` is no
//! wake.
//!
//! Settings, read at each decision: this Chief's engine.json
//! (`reactions_can_wake`, `classifier_harness`, `classifier_model`,
//! `classifier_prompt`; the Chief sets them with `chief engine set`, the app
//! with chief.engine.set) over the user's cmux.json
//! (`chief.reactionsCanWake`, `chief.reactionClassifier.harness|model|prompt`)
//! over the defaults (on, the host's Claude route, `DEFAULT_MODEL`,
//! `DEFAULT_PROMPT`). Off, or with no classifier (the Messages API route), a
//! reaction is a quiet note.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_chief::rules::message_text;
use cmux_conversation::{Message, Reaction};
use serde_json::Value;

use super::{Input, Source};
use crate::engine::EngineChoice;

/// The classifier's model when nothing sets one: Claude Haiku.
pub const DEFAULT_MODEL: &str = "claude-haiku-5-5";

/// How long reactions on one message settle before their one decision.
pub const DEBOUNCE: Duration = Duration::from_millis(1500);

/// How long a decision waits for the classifier; then it is no wake.
pub const JUDGE_TIMEOUT: Duration = Duration::from_secs(20);

/// The longest part of the Chief's message the classifier reads.
const MESSAGE_CHARS: usize = 2000;

/// The classifier's instructions when nothing sets a prompt of its own.
pub const DEFAULT_PROMPT: &str = "You decide whether a reaction (a tapback or an emoji) that the user put on a message from their assistant, the Chief, asks the Chief to act now.\n\
WAKE when the reaction answers, questions or changes something the message asks or proposes: a question mark on a question, plan or proposal; a thumbs down or dislike on a plan, a change or a decision; a thumbs up, love or emphasis on a message that asks the user to approve, choose or decide (\"Needs you\", \"Should I...\", \"reply X or Y\", a question to the user).\n\
SKIP when the reaction only acknowledges: a thumbs up, love, laugh or emphasis on a status line, a report, a summary, a finished task or a greeting.\n\
When unsure, SKIP.\n\
Answer with exactly one line: WAKE: <short reason> or SKIP: <short reason>.";

/// One classifier question: the harness (None: the host's Claude route),
/// the model, and the whole prompt text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JudgeAsk {
    pub harness: Option<String>,
    pub model: String,
    pub prompt: String,
}

/// The cheap model that answers `WAKE: reason` or `SKIP: reason`; a call
/// blocks (the brain calls it on a thread of its own).
pub trait ReactionJudge: Send + Sync {
    fn judge(&self, ask: &JudgeAsk) -> Result<String, String>;
}

/// The settings in force for one decision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReactionWakeConfig {
    /// A reaction may wake the Chief (else it is a quiet note).
    pub can_wake: bool,
    /// The classifier's harness; None: the host's Claude route.
    pub harness: Option<String>,
    pub model: String,
    pub prompt: String,
}

impl ReactionWakeConfig {
    /// `choice` (this Chief's engine.json) over `user` (the user's cmux.json)
    /// over the defaults; an empty string is unset.
    pub fn resolve(choice: &EngineChoice, user: Option<&Value>) -> ReactionWakeConfig {
        let get = |key: &str| user.and_then(|d| crate::agent_memory::settings::value(d, key));
        let text = |key: &str| {
            get(key)
                .and_then(|v| v.as_str().map(str::trim).map(str::to_owned))
                .filter(|s| !s.is_empty())
        };
        let own = |v: &Option<String>| {
            v.as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        };
        ReactionWakeConfig {
            can_wake: choice
                .reactions_can_wake
                .or_else(|| get("chief.reactionsCanWake").and_then(|v| v.as_bool()))
                .unwrap_or(true),
            harness: own(&choice.classifier_harness)
                .or_else(|| text("chief.reactionClassifier.harness")),
            model: own(&choice.classifier_model)
                .or_else(|| text("chief.reactionClassifier.model"))
                .unwrap_or_else(|| DEFAULT_MODEL.to_owned()),
            prompt: own(&choice.classifier_prompt)
                .or_else(|| text("chief.reactionClassifier.prompt"))
                .unwrap_or_else(|| DEFAULT_PROMPT.to_owned()),
        }
    }
}

/// What the classifier's answer means.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Wake(String),
    Skip(String),
}

/// `WAKE: reason` / `SKIP: reason` on the answer's first line that names one
/// (any case, markup around it allowed); anything else is no wake.
pub fn verdict(answer: Result<&str, &str>) -> Verdict {
    let text = match answer {
        Ok(text) => text,
        Err(e) => return Verdict::Skip(format!("the classifier failed ({e})")),
    };
    for line in text.lines() {
        let line = line
            .trim()
            .trim_matches(|c: char| c == '*' || c == '`' || c == '"');
        for (word, wake) in [("WAKE", true), ("SKIP", false)] {
            let Some(head) = line.get(..word.len()) else {
                continue;
            };
            if !head.eq_ignore_ascii_case(word) {
                continue;
            }
            let reason = line[word.len()..]
                .trim_start_matches([':', '-', ' ', '—'])
                .trim();
            let reason = if reason.is_empty() {
                "no reason given".to_owned()
            } else {
                reason.chars().take(200).collect()
            };
            return if wake {
                Verdict::Wake(reason)
            } else {
                Verdict::Skip(reason)
            };
        }
    }
    let shown: String = text.trim().chars().take(80).collect();
    Verdict::Skip(format!("the classifier gave no WAKE or SKIP ({shown:?})"))
}

/// A message whose reactions wait for the debounce.
pub(super) struct Pending {
    message: Message,
    due: Instant,
}

/// A decision the classifier is working on.
pub(super) struct Judging {
    id: u64,
    key: String,
    line: String,
    deadline: Instant,
}

/// The brain's reaction-wake state.
#[derive(Default)]
pub(super) struct State {
    judge: Option<Arc<dyn ReactionJudge>>,
    debounce: Option<Duration>,
    wake_override: Option<bool>,
    user_settings: Option<Option<Value>>,
    /// By message seq.
    pending: BTreeMap<u64, Pending>,
    /// By message seq: the one decision in flight for each message.
    judging: HashMap<u64, Judging>,
    /// Reaction keys decided in this host (the log's keyed notes hold the rest).
    decided: HashSet<String>,
    next_id: u64,
}

impl State {
    /// A decision is in flight: its answer is an input still to come.
    pub(super) fn busy(&self) -> bool {
        !self.judging.is_empty()
    }

    /// The next debounce end or classifier deadline.
    pub(super) fn due(&self) -> Option<Instant> {
        self.pending
            .values()
            .map(|p| p.due)
            .chain(self.judging.values().map(|j| j.deadline))
            .min()
    }
}

impl super::Brain {
    /// The classifier (the host's acpmux one-shot session; tests a fake).
    pub fn set_reaction_judge(&mut self, judge: Arc<dyn ReactionJudge>) {
        self.reaction_wake.judge = Some(judge);
    }

    /// How long reactions settle before one decision (default `DEBOUNCE`).
    pub fn set_reaction_debounce(&mut self, wait: Duration) {
        self.reaction_wake.debounce = Some(wait);
    }

    /// `reactions_can_wake` over every setting (tests).
    pub fn set_reaction_wake_override(&mut self, on: Option<bool>) {
        self.reaction_wake.wake_override = on;
    }

    /// The user's settings document in place of cmux.json (tests).
    pub fn set_reaction_user_settings(&mut self, doc: Option<Value>) {
        self.reaction_wake.user_settings = Some(doc);
    }

    /// The settings for a decision now (engine.json and cmux.json read now,
    /// so a change applies to the next reaction).
    pub(super) fn reaction_config(&self) -> ReactionWakeConfig {
        let choice = self
            .settings
            .engine_file
            .as_deref()
            .map(crate::engine::load)
            .unwrap_or_default();
        self.reaction_config_for(&choice)
    }

    /// `choice` (this Chief's engine.json) over the user's cmux.json, read now.
    pub(super) fn reaction_config_for(&self, choice: &EngineChoice) -> ReactionWakeConfig {
        let user = match &self.reaction_wake.user_settings {
            Some(doc) => doc.clone(),
            None => std::env::var_os("HOME").and_then(|home| {
                crate::agent_memory::settings::document(std::path::Path::new(&home))
            }),
        };
        let mut config = ReactionWakeConfig::resolve(choice, user.as_ref());
        if let Some(on) = self.reaction_wake.wake_override {
            config.can_wake = on;
        }
        config
    }

    /// A Chief message of the main conversation whose reactions changed: a
    /// quiet note per reaction when reactions cannot wake, else one decision
    /// after the debounce (each change restarts it).
    pub(super) fn on_chief_reactions(&mut self, main: &str, message: &Message) {
        if message.retracted_at.is_some() {
            self.reaction_wake.pending.remove(&message.seq);
            return;
        }
        if self.reaction_wake.judge.is_none() || !self.reaction_config().can_wake {
            self.note_reactions(main, message);
            return;
        }
        let wait = self.reaction_wake.debounce.unwrap_or(DEBOUNCE);
        self.reaction_wake.pending.insert(
            message.seq,
            Pending {
                message: message.clone(),
                due: Instant::now() + wait,
            },
        );
    }

    /// The note key and line of reaction `r` on `message`.
    pub(super) fn reaction_line(
        &self,
        main: &str,
        message: &Message,
        r: &Reaction,
    ) -> (String, String) {
        let (label, tag) = super::replies::reaction_label(&r.kind);
        let who = self
            .summary
            .as_ref()
            .and_then(|s| s.participants.iter().find(|p| p.id == r.author))
            .map(|p| p.display_name.trim().to_owned())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| r.author.clone());
        let first_line = message_text(message)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or_default()
            .chars()
            .take(120)
            .collect::<String>();
        (
            format!(
                "{main}#{}:reaction:{}:{}:{tag}",
                message.seq, r.author, r.part_index
            ),
            format!("reaction {label} from {who} on your message: {first_line}"),
        )
    }

    /// Debounces that ended start their decision; decisions past their
    /// deadline are no wake.
    pub(super) fn reaction_timer(&mut self, now: Instant) {
        let late: Vec<u64> = self
            .reaction_wake
            .judging
            .iter()
            .filter(|(_, j)| j.deadline <= now)
            .map(|(seq, _)| *seq)
            .collect();
        for seq in late {
            if let Some(j) = self.reaction_wake.judging.remove(&seq) {
                let secs = JUDGE_TIMEOUT.as_secs();
                self.reaction_decided(
                    &j.key,
                    &j.line,
                    Verdict::Skip(format!("the classifier did not answer in {secs} s")),
                );
            }
        }
        let due: Vec<u64> = self
            .reaction_wake
            .pending
            .iter()
            .filter(|(_, p)| p.due <= now)
            .map(|(seq, _)| *seq)
            .collect();
        for seq in due {
            if let Some(p) = self.reaction_wake.pending.remove(&seq) {
                self.judge_reactions(p.message, now);
            }
        }
    }

    /// One decision on the newest undecided reaction of `message`.
    fn judge_reactions(&mut self, message: Message, now: Instant) {
        let Some(main) = self.state.conversation.clone() else {
            return;
        };
        let Some(judge) = self.reaction_wake.judge.clone() else {
            return;
        };
        let me = self.settings.membership.participant.clone();
        let newest = message
            .reactions
            .iter()
            .filter(|r| r.author != me)
            .map(|r| (r, self.reaction_line(&main, &message, r)))
            .filter(|(_, (key, _))| {
                !self.reaction_wake.decided.contains(key) && self.chat.logged_id(key).is_none()
            })
            .last()
            .map(|(r, line)| (r.clone(), line));
        let Some((reaction, (key, line))) = newest else {
            return;
        };
        let config = self.reaction_config();
        let (label, _) = super::replies::reaction_label(&reaction.kind);
        let text: String = message_text(&message).chars().take(MESSAGE_CHARS).collect();
        let ask = JudgeAsk {
            harness: config.harness.clone(),
            model: config.model.clone(),
            prompt: format!(
                "{}\n\nThe Chief's message:\n<<<\n{text}\n>>>\n\nThe user's reaction: {label}",
                config.prompt
            ),
        };
        self.reaction_wake.next_id += 1;
        let id = self.reaction_wake.next_id;
        // A newer reaction on a message still being decided replaces the
        // decision: the older answer is dropped when it comes.
        self.reaction_wake.judging.insert(
            message.seq,
            Judging {
                id,
                key,
                line,
                deadline: now + JUDGE_TIMEOUT,
            },
        );
        let tx = self.tx.clone();
        let seq = message.seq;
        let spawned = std::thread::Builder::new()
            .name("optchat-reaction-judge".into())
            .spawn(move || {
                let answer = judge.judge(&ask);
                let _ = tx.send(Input::ReactionJudged { seq, id, answer });
            });
        if let Err(e) = spawned
            && let Some(j) = self.reaction_wake.judging.remove(&seq)
        {
            self.reaction_decided(
                &j.key,
                &j.line,
                Verdict::Skip(format!("the classifier did not start ({e})")),
            );
        }
    }

    /// The classifier's answer for decision `id` of message `seq`.
    pub(super) fn reaction_judged(&mut self, seq: u64, id: u64, answer: Result<String, String>) {
        let current = self
            .reaction_wake
            .judging
            .get(&seq)
            .is_some_and(|j| j.id == id);
        if !current {
            return;
        }
        let Some(j) = self.reaction_wake.judging.remove(&seq) else {
            return;
        };
        let verdict = verdict(answer.as_deref().map_err(String::as_str));
        self.reaction_decided(&j.key, &j.line, verdict);
    }

    /// Logs the decision as a note; a wake then queues the turn.
    fn reaction_decided(&mut self, key: &str, line: &str, verdict: Verdict) {
        self.reaction_wake.decided.insert(key.to_owned());
        let note = match &verdict {
            Verdict::Wake(reason) => format!("{line} — wake: {reason}"),
            Verdict::Skip(reason) => format!("{line} — no wake: {reason}"),
        };
        (self.log)(&note);
        let entry = optchat_host::NewMessage {
            key: Some(key.to_owned()),
            ..optchat_host::NewMessage::new(optchat_core::Kind::Note, &note)
        };
        if let Err(e) = self.chat.append_with(&[entry], |_| Vec::new()) {
            (self.log)(&format!("logging a reaction decision failed: {e}"));
        }
        if let Verdict::Wake(reason) = verdict {
            self.queue_in(
                None,
                format!("The reaction noted above asks for you ({reason}): act on it."),
                Vec::new(),
                Source::Note,
            );
        }
    }
}
