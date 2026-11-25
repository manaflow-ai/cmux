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
fn is_default(key: &str, v: &Value) -> bool {
    match key {
        "endedAt" | "exitCode" | "signal" | "outputError" | "startedBy" => v.is_null(),
        "resultLine" => v == &json!(false),
        "notify" => v == &json!(true),
        "keptFromByte" => v == &json!(0),
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

    /// `status` is `state`'s near miss (as `runing` is `running`'s): it picks exactly the page
    /// `state` picks, and the answer says it was read that way. It used to go to the daemon,
    /// which does not read it either, so the call answered an unfiltered page.
    #[test]
    fn status_picks_the_page_state_picks_and_says_so() {
        let (by_status, text) =
            page(json!({"status": "running", "limit": 5})).apply(listed(10), NOW);
        let (by_state, _) = page(json!({"state": "running", "limit": 5})).apply(listed(10), NOW);
        assert_eq!(by_status, by_state);
        let ids: Vec<&str> = by_status["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["t9", "t7", "t5", "t3", "t1"]);
        assert_eq!(
            by_status["total"],
            json!(5),
            "the filter ran, so the page is not the whole list"
        );
        assert!(text.ends_with("(key \"status\" read as \"state\")"), "{text}");
        // A near-miss key takes the state's own near-miss reading too, and both are said.
        let (s, text) = page(json!({"status": "runing"})).apply(listed(4), NOW);
        assert_eq!(s["total"], json!(2));
        assert!(text.contains("(key \"status\" read as \"state\")"), "{text}");
        assert!(text.contains("(state \"runing\" read as \"running\")"), "{text}");
        // A near miss is not read over a key the call already gave.
        let (s, text) = page(json!({"status": "running", "state": "failed"})).apply(listed(8), NOW);
        assert_eq!(s["total"], json!(2), "state failed stands: {text}");
    }

    /// A key that is nobody's near miss is named in the answer, not quietly passed on: a filter
    /// the call thought it set and did not is worse than a page it knows is unfiltered.
    #[test]
    fn an_unknown_key_is_named_not_ignored() {
        let (s, text) = page(json!({"nonsense": "running", "limit": 2})).apply(listed(6), NOW);
        assert_eq!(s["total"], json!(6), "nothing was filtered");
        assert!(
            text.ends_with(
                "(\"nonsense\" is not one of state, limit, offset, full, all, so it picked nothing)"
            ),
            "{text}"
        );
        let mut args = json!({"nonsense": 1, "sessionId": "s", "all": true});
        let taken = Page::take(&mut args).unwrap();
        assert_eq!(
            args,
            json!({"sessionId": "s", "all": true}),
            "the daemon's keys stay, the stray one goes"
        );
        assert_eq!(taken.notes.len(), 1, "{:?}", taken.notes);
    }

    /// A row as the daemon builds it (`hub/bg_tasks.rs` `bg_view`): the chat's session and
    /// folder on every one, `summary` and `status` read off the row itself, and the fields a
    /// task that has not ended leaves null or at their default.
    fn as_the_daemon_lists(n: usize) -> Value {
        let tasks: Vec<Value> = (0..n)
            .map(|i| {
                json!({"id": format!("t{i}"), "sessionId": "00000000-0000-4000-8000-000000000001",
                    "cwd": "/tmp/checkout/one-chat", "command": "cargo test",
                    "description": "run the suite", "notify": true, "resultLine": false,
                    "state": "running", "pid": 2_990_758 + i, "startedAt": NOW - 7_200_000,
                    "endedAt": Value::Null, "exitCode": Value::Null, "signal": Value::Null,
                    "totalBytes": 0, "keptFromByte": 0, "tail": "", "outputError": Value::Null,
                    "startedBy": Value::Null,
                    "summary": "Background command running: run the suite", "status": "running"})
            })
            .collect();
        json!({"tasks": tasks, "otherOwners": 0})
    }

    /// A row carries neither what every row of the page shares nor a fact read off the row: the
    /// chat's `sessionId` and `cwd` are the page's, once, and `summary`, `status` and the null or
    /// default fields are gone, so a 30-row page is well under half the bytes it used to be.
    /// A `full` page is unchanged — it is the one that asks for everything.
    #[test]
    fn a_listing_row_carries_neither_what_every_row_shares_nor_what_it_derives() {
        let (s, _) = page(json!({})).apply(as_the_daemon_lists(30), NOW);
        let rows = s["tasks"].as_array().unwrap();
        assert_eq!(rows.len(), 30);
        for row in rows {
            let o = row.as_object().unwrap();
            for key in [
                "sessionId",
                "cwd",
                "summary",
                "status",
                "endedAt",
                "exitCode",
                "signal",
                "outputError",
                "startedBy",
                "keptFromByte",
                "notify",
                "resultLine",
                "tail",
            ] {
                assert!(!o.contains_key(key), "{key} is still on the row: {row}");
            }
            // What the caller cannot derive stays.
            for key in ["id", "command", "description", "state", "pid", "startedAt", "totalBytes"] {
                assert!(o.contains_key(key), "{key} was dropped: {row}");
            }
        }
        assert_eq!(s["sessionId"], json!("00000000-0000-4000-8000-000000000001"));
        assert_eq!(s["cwd"], json!("/tmp/checkout/one-chat"));
        let before = as_the_daemon_lists(30)["tasks"].to_string().len();
        let after = s["tasks"].to_string().len()
            + s["sessionId"].to_string().len()
            + s["cwd"].to_string().len();
        assert!(after * 2 < before, "{after} of {before} bytes: less than half was cut");
        // full: true is the call that asks for everything, and still gets it.
        let (whole, _) = page(json!({"full": true})).apply(as_the_daemon_lists(2), NOW);
        assert_eq!(whole["tasks"], as_the_daemon_lists(2)["tasks"]);
        assert!(whole.get("sessionId").is_none(), "nothing hoisted out of a full page");
    }

    /// A task that prints its own outcome keeps the `summary` that labels its last line and
    /// drops the `lastLine`: one of the two, never both, and never neither.
    #[test]
    fn a_result_line_task_keeps_its_summary_and_not_the_line_under_it() {
        let mut listed = as_the_daemon_lists(1);
        listed["tasks"][0]["resultLine"] = json!(true);
        listed["tasks"][0]["lastLine"] = json!("Checks of o/r#3 failed: build");
        listed["tasks"][0]["summary"] = json!("Checks of o/r#3 failed: build");
        let (s, _) = page(json!({})).apply(listed, NOW);
        let row = s["tasks"][0].as_object().unwrap();
        assert_eq!(row.get("summary"), Some(&json!("Checks of o/r#3 failed: build")));
        assert!(!row.contains_key("lastLine"), "{:?}", row);
        assert_eq!(row.get("resultLine"), Some(&json!(true)), "not the default, so it stays");
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
