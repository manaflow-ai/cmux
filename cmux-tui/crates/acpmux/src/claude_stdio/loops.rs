//! Claude Code's /loop as the chat's goal, in the `_meta.goal` of a `session_info_update`: the
//! field Codex's persisted goal uses (`hub/permissions.rs` keeps it on the session, the pane's
//! goal strip draws it).
//!
//! Claude Code 2.1.310 runs a loop through its own tools: a self-paced /loop calls ScheduleWakeup
//! (`delaySeconds`, `reason`, `prompt`; `stop: true` ends it) every turn, and its result names the
//! wakeup's time (`scheduledFor`, epoch ms); an interval /loop calls CronCreate (`cron`, `prompt`,
//! `recurring`, default true), whose result names the job (`id`, `humanSchedule`, `nextFireAt`),
//! and CronDelete (`id`) ends it. The goal is the newest loop still armed: `kind: "loop"`, its
//! prompt as `objective` (empty with `autonomous` for an autonomous /loop's sentinel), and
//! `nextRunAt`, `reason` or `schedule` where Claude said them. A one-shot cron is a reminder, not
//! a loop. Claude's loops live in its process (session crons and the pending wakeup), so its exit
//! clears the goal. Nothing can stop a loop from outside the turn (Claude Code has no control
//! request for it), so the goal carries no command.
//!
//! The goal also lists every armed loop's timer (`timers`: `{"at", "recurring"}` each, `at` its
//! next fire in Unix ms where Claude said one), not only the shown loop's: Claude holds them in
//! its process, so its machine must be up when one is due (`hub/agent_timer.rs`, wake kind 4 of
//! the pause-resume lane).
//!
//! A durable cron (`CronCreate` with `durable: true`) outlives its process: Claude keeps it in
//! the project's `.claude/scheduled_tasks.json` and a resumed process fires it again, but the
//! resumed process never calls CronCreate, so before this acpmux knew no timer after the first
//! hibernate and put the chat to sleep again 7 minutes after each wake. A 2-hour coordinator cron
//! (`53 1-23/2 * * *`) then fired at none of 01:53Z and 03:53Z on 2026-11-26: the chat was asleep
//! (01:47Z-02:54Z, 03:18Z-04:43Z) and the report came only at the next unrelated prompt. Each
//! `init` (`inbound.rs`) now reads that file and arms the recurring durable tasks this
//! conversation created ([`Translator::durable_loops`]), so the chat stays up for them as for a
//! cron it created in this process.

use super::*;
use crate::no_panic::JsonExt;

const WAKEUP: &str = "ScheduleWakeup";
const CRON_CREATE: &str = "CronCreate";
const CRON_DELETE: &str = "CronDelete";
/// The prompts an autonomous /loop passes instead of the person's (Claude Code's `loop.md` sentinels).
const AUTONOMOUS: [&str; 2] = ["<<loop.md>>", "<<loop.md-dynamic>>"];
/// The key of the one pending wakeup: each ScheduleWakeup supersedes the last.
const WAKEUP_KEY: &str = "wakeup";

/// The loop tools' calls until their results, and the loops armed, oldest first.
#[derive(Default)]
pub(super) struct Loops {
    calls: HashMap<String, (&'static str, Value)>,
    armed: Vec<(String, Value)>,
    /// The keys armed from `.claude/scheduled_tasks.json` (`durable_loops`), not a CronCreate this
    /// process made: a task gone from the file disarms.
    durable: HashSet<String>,
}

/// The recurring durable tasks `session` created, from a `scheduled_tasks.json`'s text, as
/// `(key, goal)`: aged-out tasks (`createdAt + maxAgeMs` past `now`) and one-shots are left out
/// (a one-shot is a reminder, not a loop).
pub(super) fn durable_tasks(text: &str, session: &str, now: u64) -> Vec<(String, Value)> {
    let Ok(file) = serde_json::from_str::<Value>(text) else { return Vec::new() };
    let Some(tasks) = file.get("tasks").and_then(Value::as_array) else { return Vec::new() };
    tasks
        .iter()
        .filter(|t| t.get("createdBySessionId").and_then(Value::as_str) == Some(session))
        .filter(|t| t.get("recurring").and_then(Value::as_bool) == Some(true))
        .filter(|t| {
            let created = t.get("createdAt").and_then(Value::as_u64);
            let age = t.get("maxAgeMs").and_then(Value::as_u64);
            !matches!((created, age), (Some(c), Some(a)) if c.saturating_add(a) <= now)
        })
        .filter_map(|t| {
            let id = t.get("id").and_then(Value::as_str)?;
            let mut goal = json!({"kind": "loop", "status": "active"});
            objective(&mut goal, t.get("prompt").and_then(Value::as_str).unwrap_or(""));
            if let Some(cron) = t.get("cron").and_then(Value::as_str) {
                goal.set("schedule", json!(cron));
            }
            Some((format!("cron:{id}"), goal))
        })
        .collect()
}

impl Loops {
    /// The newest loop still armed, with every armed loop's timer (`timers`, module docs).
    fn shown(&self) -> Value {
        let Some((_, goal)) = self.armed.last() else { return Value::Null };
        let timers: Vec<Value> = self
            .armed
            .iter()
            .map(|(key, goal)| {
                let mut timer = json!({"recurring": key.starts_with("cron:")});
                if let Some(at) = goal.get("nextRunAt").and_then(Value::as_u64) {
                    timer.set("at", json!(at));
                }
                timer
            })
            .collect();
        let mut goal = goal.clone();
        goal.set("timers", json!(timers));
        goal
    }

    fn arm(&mut self, key: String, goal: Value) {
        self.armed.retain(|(k, _)| *k != key);
        self.armed.push((key, goal));
    }

    fn disarm(&mut self, key: &str) -> bool {
        self.durable.remove(key);
        let before = self.armed.len();
        self.armed.retain(|(k, _)| k != key);
        self.armed.len() != before
    }
}

fn goal_update(goal: Value) -> Value {
    json!({"sessionUpdate": "session_info_update", "_meta": {"goal": goal}})
}

/// The loop's words: its prompt without the `/loop ` that re-enters the skill.
fn objective(goal: &mut Value, prompt: &str) {
    let prompt = prompt.trim();
    if AUTONOMOUS.contains(&prompt) {
        goal.set("objective", json!(""));
        goal.set("autonomous", json!(true));
    } else {
        let words = prompt.strip_prefix("/loop ").map(str::trim).unwrap_or(prompt);
        goal.set("objective", json!(words));
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl Translator {
    /// Holds a loop tool's input until its result (`inbound.rs`, the main line's `tool_use`).
    pub(super) async fn note_loop_call(&self, id: &str, name: &str, input: &Value) {
        let tool = match name {
            WAKEUP => WAKEUP,
            CRON_CREATE => CRON_CREATE,
            CRON_DELETE => CRON_DELETE,
            _ => return,
        };
        self.loops.lock().await.calls.insert(id.to_owned(), (tool, input.clone()));
    }

    /// The goal update a loop tool's result makes, when it changed which loop is shown.
    pub(super) async fn loop_result(
        &self,
        id: &str,
        is_err: bool,
        result: Option<&Value>,
    ) -> Option<Value> {
        let mut loops = self.loops.lock().await;
        let (tool, input) = loops.calls.remove(id)?;
        if is_err {
            return None;
        }
        let before = loops.shown();
        let data = result.cloned().unwrap_or(Value::Null);
        match tool {
            WAKEUP if input.get("stop") == Some(&Value::Bool(true)) => {
                loops.disarm(WAKEUP_KEY);
            }
            WAKEUP => {
                let mut goal = json!({"kind": "loop", "status": "active"});
                objective(&mut goal, input.get("prompt").and_then(Value::as_str).unwrap_or(""));
                if let Some(reason) = input.get("reason").and_then(Value::as_str).map(str::trim)
                    && !reason.is_empty()
                {
                    goal.set("reason", json!(reason));
                }
                // The result's time; an older Claude Code that names none: the delay, clamped as
                // Claude clamps it (to [60, 3600] s).
                let at =
                    data.get("scheduledFor").and_then(Value::as_u64).filter(|at| *at > 0).or_else(
                        || {
                            let delay = input.get("delaySeconds").and_then(Value::as_f64)?;
                            Some(now_ms() + (delay.clamp(60.0, 3600.0) * 1000.0) as u64)
                        },
                    );
                if let Some(at) = at {
                    goal.set("nextRunAt", json!(at));
                }
                loops.arm(WAKEUP_KEY.to_owned(), goal);
            }
            CRON_CREATE => {
                let recurring = data
                    .get("recurring")
                    .or_else(|| input.get("recurring"))
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                let job = data.get("id").and_then(Value::as_str)?;
                if !recurring {
                    return None;
                }
                let mut goal = json!({"kind": "loop", "status": "active"});
                objective(&mut goal, input.get("prompt").and_then(Value::as_str).unwrap_or(""));
                if let Some(schedule) = data.get("humanSchedule").and_then(Value::as_str) {
                    goal.set("schedule", json!(schedule));
                }
                if let Some(at) = data.get("nextFireAt").and_then(Value::as_u64) {
                    goal.set("nextRunAt", json!(at));
                }
                loops.arm(format!("cron:{job}"), goal);
            }
            CRON_DELETE => {
                let job = input.get("id").and_then(Value::as_str)?;
                if !loops.disarm(&format!("cron:{job}")) {
                    return None;
                }
            }
            _ => return None,
        }
        let after = loops.shown();
        (after != before).then(|| goal_update(after))
    }

    /// The goal update the durable tasks this conversation created make (module docs), from
    /// Claude's `init` line: its `cwd` and `session_id`. A task armed already (a CronCreate this
    /// process made) keeps its goal; one gone from the file since the last read disarms.
    pub(super) async fn durable_loops(&self, cwd: &str, session: &str) -> Option<Value> {
        let path = Path::new(cwd).join(".claude").join("scheduled_tasks.json");
        // No file: no durable task (an unreadable one keeps what was armed).
        let tasks = match std::fs::read_to_string(&path) {
            Ok(text) => durable_tasks(&text, session, now_ms()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(_) => return None,
        };
        let mut loops = self.loops.lock().await;
        let before = loops.shown();
        let gone: Vec<String> =
            loops.durable.iter().filter(|k| !tasks.iter().any(|(t, _)| t == *k)).cloned().collect();
        for key in gone {
            loops.disarm(&key);
        }
        for (key, goal) in tasks {
            if !loops.armed.iter().any(|(k, _)| *k == key) {
                loops.armed.push((key.clone(), goal));
                loops.durable.insert(key);
            }
        }
        let after = loops.shown();
        (after != before).then(|| goal_update(after))
    }

    /// Claude's exit ended its loops: the goal update that clears them, when any was armed.
    pub(super) async fn end_loops(&self) -> Option<Message> {
        let mut loops = self.loops.lock().await;
        loops.calls.clear();
        loops.durable.clear();
        if loops.armed.is_empty() {
            return None;
        }
        loops.armed.clear();
        Some(Message::notification(
            method::SESSION_UPDATE,
            json!({"sessionId": self.acp_session_id, "update": goal_update(Value::Null)}),
        ))
    }
}
