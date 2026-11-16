use super::background_cause::Causes;
use std::collections::VecDeque;

/// One running background turn.
#[derive(Debug, Clone)]
pub struct Running {
    pub id: String,
    pub trigger: &'static str,
    pub text: String,
    /// Its reply outgrew [`TEXT_KEPT`]: not quiet, whatever the kept part says.
    pub long: bool,
    /// A permission or structured question needs the person's attention.
    pub attention: bool,
}

/// A session's background-turn state, read and written by its tap.
#[derive(Debug, Default)]
pub struct BackgroundTurns {
    /// What the next `system/init` with no acpmux turn was started by, if a line said so.
    pub hint: Option<&'static str>,
    /// A `system/init` with no acpmux turn came, and what started it: the turn starts at its
    /// first word or tool call (a harness that only says `system/init`, as at its start, ran
    /// none).
    pub pending: Option<(&'static str, u64)>,
    pub running: Option<Running>,
    /// Reply message ids of background turns, newest last.
    pub messages: VecDeque<String>,
    /// The tasks started and the notifications heard: a turn's `cause`.
    pub causes: Causes,
    /// An adopted host's replay is being read while the chat's log has an acpmux turn open
    /// ([`Hub::hold_adopted_turn`]): its model work is that turn's, which adoption rebuilds
    /// only once the replay is in the log, never a turn the person did not start.
    pub adopted_turn: bool,
}

const SHORT_LINE: usize = 160;
const TEXT_KEPT: usize = 4 * SHORT_LINE;
const WORK: [&str; 4] = ["agent_message_chunk", "agent_thought_chunk", "tool_call", "plan"];
const MESSAGES_KEPT: usize = 256;

pub fn is_quiet(text: &str) -> bool {
    let text = text.trim();
    let lines = text.lines().filter(|l| !l.trim().is_empty()).count();
    lines <= 1 && text.chars().count() <= SHORT_LINE && !text.contains('?') && !text.contains("://")
}

impl BackgroundTurns {
    /// A raw Claude line, before it is logged. Returns the records to log first.
    pub fn on_line(
        &mut self,
        method: &str,
        line: &Value,
        acpmux_turn: bool,
        seq: u64,
    ) -> Vec<Value> {
        let mut out = Vec::new();
        if method == "claude.system.task_started" || !acpmux_turn {
            self.causes.on_line(method, line);
        }
        match method {
            "claude.system.task_notification" if !acpmux_turn => {
                self.hint = Some("task_notification");
            }
            "claude.command_lifecycle"
                if !acpmux_turn && line.get("state").and_then(Value::as_str) == Some("started") =>
            {
                self.hint = Some("scheduled");
            }
            "claude.system.init" if !acpmux_turn && self.running.is_none() => {
                self.pending = Some((self.hint.take().unwrap_or("system"), seq));
            }
            m if m.starts_with("claude.result") => {
                self.hint = None;
                self.pending = None;
                out.extend(self.end("result"));
            }
            _ => {}
        }
        out
    }

    /// An own update of the chat (not a subagent's), before it is logged. Returns the
    /// `started` record to log first, when it is the first sign of a pending turn.
    pub fn on_update(&mut self, update: &Value, acpmux_turn: bool, seq: u64) -> Option<Value> {
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        let mut started = None;
        if acpmux_turn {
            self.pending = None;
            self.causes.clear();
        } else if WORK.contains(&kind) && self.running.is_none() {
            // Model work with no acpmux turn is Claude Code's own turn. Its `system/init` may
            // have come before this daemon started (a restart, an adopted host): what started
            // it is then unknown.
            let (trigger, seq) = self.pending.take().unwrap_or(("system", seq));
            let id = format!("bg-{seq}");
            let mut record = json!({"state": "started", "id": id, "trigger": trigger});
            if let Some(cause) = self.causes.take().filter(|_| trigger == "task_notification")
                && let Some(fields) = record.as_object_mut()
            {
                fields.insert("cause".into(), cause);
            }
            started = Some(record);
            self.running =
                Some(Running { id, trigger, text: String::new(), long: false, attention: false });
        }
        let Some(running) = self.running.as_mut() else { return started };
        if kind != "agent_message_chunk" {
            return started;
        }
        if let Some(id) = update.get("messageId").and_then(Value::as_str)
            && self.messages.back().map(String::as_str) != Some(id)
        {
            self.messages.push_back(id.to_owned());
            while self.messages.len() > MESSAGES_KEPT {
                self.messages.pop_front();
            }
        }
        if let Some(text) = update.pointer("/content/text").and_then(Value::as_str) {
            if running.long || running.text.len() + text.len() > TEXT_KEPT {
                running.long = true;
            } else {
                running.text.push_str(text);
            }
        }
        started
    }

    /// Ends the running one, if any: its `ended` record.
    pub fn end(&mut self, reason: &str) -> Option<Value> {
        self.pending = None;
        let r = self.running.take()?;
        Some(json!({
            "state": "ended", "id": r.id, "trigger": r.trigger,
            "quiet": !r.attention && !r.long && is_quiet(&r.text), "reason": reason,
        }))
    }

    /// Whether a reply message is a background turn's.
    pub fn owns_message(&self, id: &str) -> bool {
        self.messages.iter().any(|m| m == id)
    }
}
