//! `bg_list`'s page (`acpmux_mcp_bg.rs`): the newest tasks first, one compact line each, and a
//! last line that says how many more there are and the argument that lists them. A chat keeps
//! every task it ever started, each with the tail of its output, so the whole list grew past
//! what a harness takes in one result (tool-call bounces, 2026-11-21: a bare `bg_list` answered
//! 395,433 characters, which Claude Code wrote to a file for the agent to read again, 6 times in
//! 24 h on one VM). `limit`, `offset` and `state` pick the page; `full` adds each task's whole
//! command and output tail; `all` still widens it to other callers' tasks.
//!
//! A row carries only what the caller cannot work out: the chat's `sessionId` and `cwd` are the
//! same on every task, so the page says each once, and `summary`, `status` and the fields a task
//! leaves null or at their default are left off ([`Page::trimmed`]).

use serde_json::{Map, Value, json};

/// The tasks a bare call lists, and the most any call does.
const LIMIT: usize = 30;
const MAX_LIMIT: usize = 500;
/// How much of a task's command (with its description) a compact line keeps.
pub(super) const COMMAND_CHARS: usize = 100;
/// What `state` takes: a task's own state, or its outcome (`bg_run::outcome`).
const STATES: [&str; 7] = ["running", "exited", "stopped", "killed", "lost", "ok", "failed"];
/// The keys a call picks its page with, in the order a hint lists them.
const KEYS: [&str; 5] = ["state", "limit", "offset", "full", "all"];
/// The keys the daemon or the server itself reads, which are not a page's and not a mistake.
const PASSED_ON: [&str; 4] = ["sessionId", "callerSubagent", "description", "_meta"];
/// Row fields every task of one chat carries the same value for: the page says each once.
const SHARED: [&str; 2] = ["sessionId", "cwd"];

/// The page a call asks for, taken out of its arguments (the daemon lists the whole chat).
#[derive(Debug, PartialEq)]
pub(super) struct Page {
    limit: usize,
    offset: usize,
    state: Option<&'static str>,
    full: bool,
    /// What the call's arguments were read as, when not as given (a misspelt state or key).
    notes: Vec<String>,
}

impl Page {
    pub(super) fn take(params: &mut Value) -> Result<Self, String> {
        let Some(p) = params.as_object_mut() else {
            return Err("arguments must be an object".into());
        };
        let mut notes = Vec::new();
        Self::read_near_miss_keys(p, &mut notes);
        let number = |v: Option<Value>, key: &str| -> Result<Option<usize>, String> {
            match v {
                None | Some(Value::Null) => Ok(None),
                Some(Value::Number(n)) if n.as_u64().is_some() => {
                    Ok(n.as_u64().and_then(|n| usize::try_from(n).ok()))
                }
                Some(Value::String(s)) if s.trim().parse::<usize>().is_ok() => {
                    Ok(s.trim().parse().ok())
                }
                Some(other) => Err(format!("{key} is a whole number of tasks, not {other}")),
            }
        };
        let mut limit = number(p.remove("limit"), "limit")?.unwrap_or(LIMIT).max(1);
        if limit > MAX_LIMIT {
            notes.push(format!("limit {limit} read as {MAX_LIMIT}, the most one call lists"));
            limit = MAX_LIMIT;
        }
        let offset = number(p.remove("offset"), "offset")?.unwrap_or(0);
        let full = p.remove("full").is_some_and(|v| v == json!(true));
        let state = match p.remove("state") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) if s.trim().is_empty() => None,
            Some(Value::String(s)) => {
                let given = s.trim().to_ascii_lowercase();
                match STATES.iter().find(|&&k| k == given) {
                    Some(&k) => Some(k),
                    None => match crate::mcp_hint::nearest(&given, STATES) {
                        Some(k) => {
                            notes.push(format!("state {given:?} read as {k:?}"));
                            Some(k)
                        }
                        None => {
                            return Err(format!("state is one of {}", STATES.join(", ")));
                        }
                    },
                }
            }
            Some(other) => {
                return Err(format!("state is one of {}, not {other}", STATES.join(", ")));
            }
        };
        Ok(Self { limit, offset, state, full, notes })
    }

    /// A key no argument has, read as the page key it is a near miss for (`status` for `state`,
    /// as a misspelt state value is read as the state it means), else named in the answer and
    /// dropped. Both used to go to the daemon, which does not read them either, so
    /// `{"status": "running"}` quietly answered a whole unfiltered page that looked like one.
    fn read_near_miss_keys(p: &mut Map<String, Value>, notes: &mut Vec<String>) {
        let strange: Vec<String> = (p.keys())
            .filter(|k| !KEYS.contains(&k.as_str()) && !PASSED_ON.contains(&k.as_str()))
            .cloned()
            .collect();
        for key in strange {
            let meant = crate::mcp_hint::nearest(&key, KEYS).filter(|k| !p.contains_key(*k));
            let value = p.remove(&key).unwrap_or(Value::Null);
            match meant {
                Some(k) => {
                    notes.push(format!("key {key:?} read as {k:?}"));
                    p.insert(k.to_owned(), value);
                }
                None => notes.push(format!(
                    "{key:?} is not one of {}, so it picked nothing",
                    KEYS.join(", ")
                )),
            }
        }
    }

    /// The daemon's whole list as this page: the structured result, its tasks newest first and
    /// trimmed unless `full`, with `total` (after the state filter), `offset`, `limit` and `more`
    /// (older ones past the page); and the text, one line per task, then what is left out.
    pub(super) fn apply(&self, mut r: Value, now_ms: u64) -> (Value, String) {
        let tasks = match r.get_mut("tasks").map(Value::take) {
            Some(Value::Array(tasks)) => tasks,
            _ => Vec::new(),
        };
        let matching: Vec<Value> = (tasks.into_iter().rev())
            .filter(|t| {
                self.state.is_none_or(|s| task_state(t) == s || crate::bg_run::outcome(t).1 == s)
            })
            .collect();
        let total = matching.len();
        let page: Vec<Value> = matching.into_iter().skip(self.offset).take(self.limit).collect();
        let more = total.saturating_sub(self.offset + page.len());
        let mut lines: Vec<String> = page.iter().map(|t| self.line(t, now_ms)).collect();
        let mut page: Vec<Value> = page.into_iter().map(|t| self.trimmed(t)).collect();
        let shared = self.hoisted(&mut page);
        let what = self.state.map_or(String::new(), |s| format!(" {s}"));
        if total == 0 && self.state.is_some() {
            lines.push(format!("No{what} tasks."));
        } else if page.is_empty() && total > 0 {
            lines.push(format!("No{what} tasks past offset {}; there are {total}.", self.offset));
        }
        if more > 0 {
            let next = self.offset + page.len();
            lines.push(format!(
                "{more} older{what} task{} not shown: offset: {next} lists the next {}; limit (up to {MAX_LIMIT}), state ({}) and all: true pick others; full: true adds each one's output tail.",
                if more == 1 { "" } else { "s" },
                self.limit.min(more),
                STATES.join(", ")
            ));
        }
        lines.extend(self.notes.iter().map(|n| format!("({n})")));
        if let Some(o) = r.as_object_mut() {
            for (key, value) in shared {
                o.insert(key, value);
            }
            o.insert("tasks".into(), json!(page));
            o.insert("total".into(), json!(total));
            o.insert("offset".into(), json!(self.offset));
            o.insert("limit".into(), json!(self.limit));
            o.insert("more".into(), json!(more));
        }
        (r, lines.join(if self.full { "\n\n" } else { "\n" }))
    }

    /// One task: id, state and exit, age, and its description and command, cut; with `full`, the
    /// whole command and its output tail under it.
    fn line(&self, t: &Value, now_ms: u64) -> String {
        let s = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or_default();
        let int = |k: &str| t.get(k).and_then(Value::as_i64);
        let end = match (int("exitCode"), int("signal")) {
            (Some(code), _) => format!(" (exit {code})"),
            (_, Some(signal)) => format!(" (signal {signal})"),
            _ => String::new(),
        };
        let at = |k: &str| t.get(k).and_then(Value::as_u64);
        let age = match (at("endedAt"), at("startedAt")) {
            (Some(ended), _) => format!("ended {} ago", age(now_ms.saturating_sub(ended))),
            (None, Some(started)) => format!("started {} ago", age(now_ms.saturating_sub(started))),
            _ => String::new(),
        };
        let what = match s("description") {
            "" => s("command").to_owned(),
            d => format!("{d}: {}", s("command")),
        };
        let what = if self.full { what } else { cut(&what, COMMAND_CHARS) };
        let by = t.get("startedBy").filter(|v| v.is_object()).map_or(String::new(), |sub| {
            format!("  (started by {})", crate::hub::bg_owner_words(Some(sub)))
        });
        let line = format!("{}  [{}{end}]  {age}  {what}{by}", s("id"), task_state(t));
        if self.full { format!("{line}\n{}", s("tail").trim_end()) } else { line }
    }

    /// A task as the structured page carries it: without its tail, with its command cut, and
    /// without what the row only repeats, unless `full`. A row used to carry 713 bytes of which
    /// about two fifths were the same fact twice (measured over 3,742 rows in 224 answers,
    /// 2026-11-24: `summary` 14.3% of a page's bytes, `sessionId` 7.4%, `cwd` 3.8%, `status`
    /// 2.2%, and the null or default `outputError`, `resultLine`, `startedBy`, `signal`,
    /// `keptFromByte`, `notify` 2.0-2.8% each), so a 30-row page spent thousands of tokens
    /// saying what the caller already had. `summary` and `status` are
    /// [`crate::bg_run::outcome`] read off the row's own `state`, `exitCode` and `description`,
    /// which the text line prints; a task that prints its own outcome keeps the `summary` and
    /// drops the `lastLine` it labels, so neither is lost.
    fn trimmed(&self, mut t: Value) -> Value {
        if self.full {
            return t;
        }
        if let Some(o) = t.as_object_mut() {
            o.remove("tail");
            if let Some(command) = o.get("command").and_then(Value::as_str) {
                let short = cut(command, COMMAND_CHARS * 2);
                o.insert("command".into(), json!(short));
            }
            o.remove("status");
            match o.get("lastLine").and_then(Value::as_str) {
                Some(line) if !line.trim().is_empty() => o.remove("lastLine"),
                _ => o.remove("summary"),
            };
            o.retain(|k, v| !is_default(k, v));
        }
        t
    }

    /// The [`SHARED`] fields out of every row and into the page once, when the page's rows all
    /// agree on one (they are one chat's tasks, so they do); a row that differs keeps its own.
    fn hoisted(&self, page: &mut [Value]) -> Vec<(String, Value)> {
        if self.full || page.is_empty() {
            return Vec::new();
        }
        let mut shared = Vec::new();
        for key in SHARED {
            let first = page[0].get(key).cloned().unwrap_or(Value::Null);
            if first.is_null() || page.iter().any(|t| t.get(key) != Some(&first)) {
                continue;
            }
            for t in page.iter_mut() {
                if let Some(o) = t.as_object_mut() {
                    o.remove(key);
                }
            }
            shared.push((key.to_owned(), first));
        }
        shared
    }
}

/// A row field whose value is the one every task starts with, so the row says nothing by
/// carrying it: an end that has not happened (`endedAt`, `exitCode`, `signal`), a spool that
/// did not fail (`outputError`), the lead agent (`startedBy`), no output dropped
/// (`keptFromByte`), and `notify` and `resultLine` as `bg_start` leaves them.
pub(super) fn is_default(key: &str, v: &Value) -> bool {
    match key {
        "endedAt" | "exitCode" | "signal" | "outputError" | "startedBy" => v.is_null(),
        "resultLine" => v == &json!(false),
        "notify" => v == &json!(true),
        "keptFromByte" | "skippedBytes" => v == &json!(0),
        _ => false,
    }
}

fn task_state(t: &Value) -> &str {
    t.get("state").and_then(Value::as_str).unwrap_or_default()
}

/// `text` on one line, at most `max` characters, with an ellipsis when cut.
pub(super) fn cut(text: &str, max: usize) -> String {
    let one: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one.chars().count() <= max {
        return one;
    }
    let head: String = one.chars().take(max.saturating_sub(1)).collect();
    format!("{}…", head.trim_end())
}

/// A span in its largest whole unit: 45s, 12m, 3h, 2d.
fn age(ms: u64) -> String {
    let s = ms / 1000;
    match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m", s / 60),
        3600..86_400 => format!("{}h", s / 3600),
        _ => format!("{}d", s / 86_400),
    }
}

#[cfg(test)]
#[path = "acpmux_mcp_bg_list_tests.rs"]
mod tests;
