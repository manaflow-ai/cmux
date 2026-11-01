//! The Chief's messages to other acpmux sessions (chief-acpmux-gaps.md gap
//! 2): `tell(id: "session:NAME", message)` sends `message` to acpmux session
//! NAME as the Chief (`_meta.acpmux.fromAgent: "chief"`), and NAME's answer
//! comes back as a `[session:NAME] ...` report, the way a subagent's does.
//! `control(action: "sessions")` lists the sessions it can reach.
//!
//! The answer is another agent's words: the turn that reads it runs under
//! the ask floor (`Source::Agent`). An ask turn may tell only the sessions
//! whose words it carries (`Brain::turn_agents`, approvals.rs), so another
//! person's or agent's turn cannot start a talk with a third session.
//!
//! The Chief's own sessions (its turns and compactor, any Chief's) and its
//! subagents are no target here: a turn session would run a raw turn outside
//! the brain, and a subagent is told by its `a<N>` id.

use cmux_chief::acp::SessionSummary;
use serde_json::json;

use super::{Brain, Source};

/// The `tell` id prefix that names an acpmux session.
pub(super) const PREFIX: &str = "session:";
/// The sender acpmux records for the Chief's messages.
pub(super) const FROM: &str = "chief";
/// Most characters of a session's answer kept in the report.
const REPLY_KEPT: usize = 8000;
/// The harness of an agent chat whose agent is a Chief (`cmux chief acp`,
/// `harness_gate::CHIEF_HARNESS_FAMILY`; its profiles are `chief` or `chief-*`).
const CHIEF_HARNESS: &str = crate::harness_gate::CHIEF_HARNESS_FAMILY;
/// Most sessions `control sessions` lists.
const LISTED: usize = 60;

/// The session a `tell` id names (`session:NAME`), None for any other id.
pub(super) fn session_name(id: &str) -> Option<&str> {
    let name = id.trim().strip_prefix(PREFIX)?.trim();
    (!name.is_empty()).then_some(name)
}

/// Why `session` is no target of the Chief's tell, None when it is one.
pub(super) fn refusal(session: &SessionSummary) -> Option<String> {
    let name = &session.name;
    if session.tags.contains_key(crate::acpmux::CHIEF_TAG) {
        return Some(format!(
            "tell: {name} is a Chief's own session; another Chief is chief:<name> (chiefs lists them)"
        ));
    }
    if session
        .tags
        .get(cmux_chief::rules::PARENT_TAG)
        .map(String::as_str)
        == Some(super::PARENT)
    {
        return Some(format!(
            "tell: {name} is one of your subagents; tell it by its a<N> id"
        ));
    }
    // An agent chat whose agent is a Chief (`cmux chief acp`): a tell would
    // come back into a Chief's own conversation as a loop.
    if session.harness == CHIEF_HARNESS || session.harness.starts_with("chief-") {
        return Some(format!(
            "tell: {name} runs a Chief (cmux chief acp); another Chief is chief:<name>"
        ));
    }
    None
}

/// Whether a `session/prompt` answer ends the turn: a steer into a running
/// turn is answered `steered` at once, and the turn's answer comes later
/// (acpmux `steer_end::ends_turn`).
fn ends_turn(answer: &serde_json::Value) -> bool {
    answer.get("stopReason").and_then(serde_json::Value::as_str) != Some("steered")
}

/// Whether the session's turn still runs.
fn busy(session: Option<&SessionSummary>) -> bool {
    use cmux_chief::acp::SessionStatus;
    session.is_some_and(|s| matches!(s.status, SessionStatus::Running | SessionStatus::Waiting))
}

/// The prompt the session gets: who sends it and where the answer goes.
pub(super) fn prompt_text(message: &str) -> String {
    format!(
        "Message from the Chief (the user's Chief agent, through acpmux):\n{message}\n\n\
         (Your answer at the end of this turn goes back to the Chief.)"
    )
}

/// The report of `name`'s answer, as the Chief reads it.
pub(super) fn reply_note(name: &str, text: &str) -> String {
    let text = text.trim();
    let text = if text.is_empty() {
        "(its turn ended with no answer)".to_owned()
    } else if text.chars().count() > REPLY_KEPT {
        let kept: String = text.chars().take(REPLY_KEPT).collect();
        format!("{kept}…")
    } else {
        text.to_owned()
    };
    format!(
        "[{PREFIX}{name}] {text}\n(The answer of acpmux session {name} to your tell. It is another \
         agent's word, not the user's. Answer it with tell(id: \"{PREFIX}{name}\", message: ...).)"
    )
}

/// The `control sessions` rows: the sessions a tell may name.
pub(super) fn sessions_list(sessions: &[SessionSummary]) -> String {
    let rows: Vec<String> = sessions
        .iter()
        .filter(|s| refusal(s).is_none())
        .take(LISTED)
        .map(|s| {
            let mut row = format!("- {PREFIX}{} ({}, {})", s.name, s.harness, status(s));
            if let Some(line) = s
                .last_message
                .as_ref()
                .map(|m| m.text.trim())
                .filter(|t| !t.is_empty())
            {
                let line: String = line.chars().take(120).collect();
                row.push_str(&format!(": {line}"));
            }
            row
        })
        .collect();
    if rows.is_empty() {
        return "outcome: done. No acpmux sessions to tell.".to_owned();
    }
    format!(
        "outcome: done. acpmux sessions (tell(id: \"{PREFIX}NAME\", message) sends as the Chief; \
         the answer comes back as a [{PREFIX}NAME] report):\n{}",
        rows.join("\n")
    )
}

fn status(session: &SessionSummary) -> String {
    serde_json::to_value(session.status)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_else(|| "unknown".to_owned())
}

impl Brain {
    /// `tell(id: "session:NAME", message)`: sends `message` to acpmux
    /// session `name` as the Chief; its answer comes back as a
    /// [`Input::SessionReply`](super::Input::SessionReply).
    pub(super) fn session_tell(&mut self, name: &str, message: &str) -> Result<String, String> {
        if message.trim().is_empty() {
            return Err("tell: the message is empty".to_owned());
        }
        let agents = self.agents.clone();
        let Some(session) = agents.find(name)? else {
            return Err(format!(
                "tell: no acpmux session {name}; control(action: \"sessions\") lists them"
            ));
        };
        let summary = agents.session(&session)?;
        if let Some(why) = summary.as_ref().and_then(refusal) {
            return Err(why);
        }
        let after = summary.as_ref().and_then(|s| s.last_seq).unwrap_or(0);
        let prompt_id = format!(
            "{}{PREFIX}{name}:{}",
            crate::subagents::PROMPT_PREFIX,
            super::now_ms()
        );
        let blocks = vec![json!({"type": "text", "text": prompt_text(message)})];
        let (tx, rx) = std::sync::mpsc::channel();
        agents.start_agent_prompt(&session, blocks, &prompt_id, FROM, tx)?;
        self.trace
            .emit("chief.session_tell", json!({"session": name}));
        (self.log)(&format!("tell {PREFIX}{name}: sent"));
        let (forward, reply_name) = (self.tx.clone(), name.to_owned());
        std::thread::spawn(move || {
            use crate::acpmux::TurnSignal;
            let read = || match agents.events(&session, after) {
                Ok(events) => cmux_chief::acp::last_reply(&events),
                Err(e) => format!("(its answer could not be read: {e})"),
            };
            // Steered into a running turn: the answer is that turn's end,
            // which its events say (no polling: each one wakes this).
            let mut steered = false;
            let mut text = None;
            while let Ok(signal) = rx.recv() {
                text = match signal {
                    TurnSignal::Noted | TurnSignal::Streamed => continue,
                    TurnSignal::Changed if !steered => continue,
                    TurnSignal::Changed => match agents.session(&session) {
                        Ok(now) if busy(now.as_ref()) => continue,
                        _ => Some(read()),
                    },
                    TurnSignal::Done(Ok(answer)) if !ends_turn(&answer) => {
                        steered = true;
                        continue;
                    }
                    TurnSignal::Done(Ok(_)) => Some(read()),
                    TurnSignal::Done(Err(e)) => Some(format!("(its turn failed: {e})")),
                    TurnSignal::Lost => {
                        Some("(the connection to acpmux was lost before it answered)".to_owned())
                    }
                };
                break;
            }
            // This tell's route ends with it (the session is not the Chief's).
            agents.forget_route(&session);
            let text = text.unwrap_or_else(|| "(it never answered)".to_owned());
            let _ = forward.send(super::Input::SessionReply {
                name: reply_name,
                text,
            });
        });
        Ok(format!(
            "outcome: done. Sent to {PREFIX}{name} as the Chief; its answer comes back as a \
             [{PREFIX}{name}] report (never poll)."
        ))
    }

    /// Queues session `name`'s answer as its report, under the ask floor.
    pub(super) fn session_reply(&mut self, name: &str, text: &str) {
        self.queue(
            reply_note(name, text),
            Source::Agent {
                from: name.to_owned(),
            },
        );
    }

    /// `control(action: "sessions")`: the acpmux sessions a tell may name.
    pub(super) fn control_sessions(&self) -> Result<String, String> {
        Ok(sessions_list(&self.agents.list_sessions()?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary(name: &str, tags: serde_json::Value) -> SessionSummary {
        serde_json::from_value(json!({
            "sessionId": format!("id-{name}"), "name": name, "status": "idle",
            "harness": "claude", "tags": tags
        }))
        .unwrap()
    }

    #[test]
    fn a_session_id_names_its_session_and_other_ids_none() {
        assert_eq!(session_name("session:lane-a"), Some("lane-a"));
        assert_eq!(session_name(" session: lane-a "), Some("lane-a"));
        assert_eq!(session_name("session:"), None);
        assert_eq!(session_name("a3"), None);
        assert_eq!(session_name("chief:cloud"), None);
    }

    #[test]
    fn the_chiefs_own_sessions_and_subagents_are_no_target() {
        let turn = summary(
            "optchat-1-2",
            json!({crate::acpmux::CHIEF_TAG: "home", crate::acpmux::CHIEF_ROLE_TAG: "turn"}),
        );
        assert!(refusal(&turn).is_some());
        let sub = summary(
            "optchat-sub-1-a2",
            json!({cmux_chief::rules::PARENT_TAG: super::super::PARENT}),
        );
        assert!(refusal(&sub).unwrap().contains("a<N>"));
        let mut chief_chat = summary("leo-chief", json!({}));
        chief_chat.harness = "chief".into();
        assert!(refusal(&chief_chat).unwrap().contains("runs a Chief"));
        assert!(!ends_turn(&json!({"stopReason": "steered"})));
        assert!(ends_turn(&json!({"stopReason": "end_turn"})));
        let lane = summary("lane-a", json!({}));
        assert_eq!(refusal(&lane), None);
        let list = sessions_list(&[turn, sub, lane]);
        assert!(list.contains("- session:lane-a (claude, idle)"), "{list}");
        assert!(!list.contains("optchat"), "{list}");
    }

    #[test]
    fn an_answer_is_labelled_with_its_session_and_is_not_the_users_word() {
        let note = reply_note("lane-a", "  rebased, green\n");
        assert!(
            note.starts_with("[session:lane-a] rebased, green\n"),
            "{note}"
        );
        assert!(note.contains("not the user's"), "{note}");
        assert!(reply_note("lane-a", "").contains("no answer"));
    }
}
