//! `bg_list`'s page (`acpmux_mcp_bg.rs`): the newest tasks first, one compact line each, and a
//! last line that says how many more there are and the argument that lists them. A chat keeps
//! every task it ever started, each with the tail of its output, so the whole list grew past
//! what a harness takes in one result (tool-call bounces, 2026-11-21: a bare `bg_list` answered
//! 395,433 characters, which Claude Code wrote to a file for the agent to read again, 6 times in
//! 24 h on one VM). `limit`, `offset` and `state` pick the page; `full` adds each task's whole
//! command and output tail; `all` still widens it to other callers' tasks.

use serde_json::{Value, json};

/// The tasks a bare call lists, and the most any call does.
const LIMIT: usize = 30;
const MAX_LIMIT: usize = 500;
/// How much of a task's command (with its description) a compact line keeps.
const COMMAND_CHARS: usize = 100;
/// What `state` takes: a task's own state, or its outcome (`bg_run::outcome`).
const STATES: [&str; 7] = ["running", "exited", "stopped", "killed", "lost", "ok", "failed"];

/// The page a call asks for, taken out of its arguments (the daemon lists the whole chat).
#[derive(Debug, PartialEq)]
pub(super) struct Page {
    limit: usize,
    offset: usize,
    state: Option<&'static str>,
    full: bool,
    /// What the call's arguments were read as, when not as given (a misspelt state).
    notes: Vec<String>,
}

impl Page {
    pub(super) fn take(params: &mut Value) -> Result<Self, String> {
        let Some(p) = params.as_object_mut() else {
            return Err("arguments must be an object".into());
        };
        let mut notes = Vec::new();
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
        let page: Vec<Value> = page.into_iter().map(|t| self.trimmed(t)).collect();
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

    /// A task as the structured page carries it: without its tail and with its command cut,
    /// unless `full`.
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
        }
        t
    }
}

fn task_state(t: &Value) -> &str {
    t.get("state").and_then(Value::as_str).unwrap_or_default()
}

/// `text` on one line, at most `max` characters, with an ellipsis when cut.
fn cut(text: &str, max: usize) -> String {
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
mod tests {
    use super::*;

    const NOW: u64 = 10_000_000_000;

    /// `n` tasks oldest first, as the daemon lists them, each with a long command and tail.
    fn listed(n: usize) -> Value {
        let tasks: Vec<Value> = (0..n)
            .map(|i| {
                json!({"id": format!("t{i}"), "state": if i % 2 == 0 { "exited" } else { "running" },
                    "exitCode": if i % 2 == 0 { json!(i % 4) } else { Value::Null },
                    "startedAt": NOW - 7_200_000, "endedAt": if i % 2 == 0 { json!(NOW - 60_000) } else { Value::Null },
                    "command": format!("cargo test {}", "x".repeat(5000)), "tail": "y".repeat(1024)})
            })
            .collect();
        json!({"tasks": tasks, "otherOwners": 0})
    }

    fn page(args: Value) -> Page {
        let mut args = args;
        let page = Page::take(&mut args).unwrap();
        assert!(args.get("limit").is_none() && args.get("state").is_none(), "{args}");
        page
    }

    /// A bare call over a chat of 1,000 tasks answers the newest 30, one short line each, and a
    /// last line naming the rest and how to see them; the whole result stays small.
    #[test]
    fn a_bare_list_is_the_newest_thirty_compact_lines() {
        let (structured, text) = page(json!({})).apply(listed(1000), NOW);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 31, "{text}");
        assert!(
            lines[0].starts_with("t999  [running]  started 2h ago  cargo test x"),
            "{}",
            lines[0]
        );
        assert!(lines[1].starts_with("t998  [exited (exit 2)]  ended 1m ago  "), "{}", lines[1]);
        assert!(lines[..30].iter().all(|l| l.chars().count() < 180), "{text}");
        assert!(
            lines[30].starts_with("970 older tasks not shown: offset: 30 lists the next 30;"),
            "{}",
            lines[30]
        );
        assert_eq!(structured["tasks"].as_array().unwrap().len(), 30);
        assert_eq!(
            (structured["total"].clone(), structured["more"].clone()),
            (json!(1000), json!(970))
        );
        assert!(structured["tasks"][0].get("tail").is_none());
        let size = text.len() + structured.to_string().len();
        assert!(size < 20_000, "{size} characters");
    }

    /// offset, limit and state pick the page; full brings back command and tail; a misspelt
    /// state is read as its one close match and said so; a bad one is refused with the choices.
    #[test]
    fn offset_limit_state_and_full_pick_the_page() {
        let (s, text) = page(json!({"offset": 990, "limit": "20"})).apply(listed(1000), NOW);
        assert_eq!(s["tasks"].as_array().unwrap().len(), 10);
        assert_eq!(s["tasks"][9]["id"], "t0");
        assert!(!text.contains("not shown"), "{text}");
        let (s, text) = page(json!({"state": "runing", "limit": 5})).apply(listed(10), NOW);
        let ids: Vec<&str> =
            s["tasks"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["t9", "t7", "t5", "t3", "t1"]);
        assert!(text.ends_with("(state \"runing\" read as \"running\")"), "{text}");
        let (s, _) = page(json!({"state": "failed"})).apply(listed(8), NOW);
        let ids: Vec<&str> =
            s["tasks"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["t6", "t2"], "exit codes 2 and 2 failed; 0 is ok");
        let (s, text) = page(json!({"full": true, "limit": 1})).apply(listed(2), NOW);
        assert_eq!(s["tasks"][0]["tail"].as_str().unwrap().len(), 1024);
        assert!(text.contains(&"y".repeat(1024)));
        assert_eq!(page(json!({"limit": 9999})).limit, MAX_LIMIT);
        assert!(Page::take(&mut json!({"state": "zzzzzzzz"})).is_err());
        assert!(Page::take(&mut json!({"limit": "many"})).is_err());
        let (_, text) = page(json!({"state": "lost"})).apply(listed(3), NOW);
        assert_eq!(text, "No lost tasks.");
    }

    #[test]
    fn ages_and_cuts() {
        assert_eq!(
            [age(5_000), age(120_000), age(7_200_000), age(200_000_000)],
            ["5s", "2m", "2h", "2d"]
        );
        assert_eq!(cut("a\n  b", 10), "a b");
        assert_eq!(cut("abcdefghij", 5), "abcd…");
    }
}
