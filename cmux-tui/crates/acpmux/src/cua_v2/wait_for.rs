//! `wait_for_element`: the bridge's one tool of its own. It reads the
//! window's accessibility tree with the helper's `get_window_state` again
//! and again, until an element matches (or, with `gone`, until none does)
//! or its deadline passes. Agents call it after an action instead of
//! sleeping and taking another screenshot.
//!
//! It is AX-tree only: every check asks `get_window_state` with
//! `include_screenshot: false`, so no screenshot is taken and no vision
//! model runs. The element query is `get_window_state`'s own `query`
//! (upstream's case-insensitive filter, which keeps the matching rows and
//! their ancestors); this module only drops those ancestors and applies an
//! optional `role`. Each check goes through [`super::Helper::request`], so
//! the machine consent check runs for every one, exactly as for a direct
//! `get_window_state` call.
//!
//! Every wait ends: at a match, at an error, or at its deadline
//! (`timeout_ms`, default [`DEFAULT_TIMEOUT_MS`], at most
//! [`MAX_TIMEOUT_MS`]). A timed-out wait answers `isError` with
//! `timed_out: true` and the count the last check saw.

use std::future::Future;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::time::Instant;

/// The tool name agents see.
pub const TOOL: &str = "wait_for_element";
/// The helper tool each check calls.
pub const READ_TOOL: &str = "get_window_state";
/// The wait's deadline when `timeout_ms` is absent.
pub const DEFAULT_TIMEOUT_MS: u64 = 10_000;
/// The longest wait; a larger `timeout_ms` is cut to this. With the last
/// check's [`CHECK_GRACE`] a call ends within 55 s, under the 60 s an MCP
/// client commonly gives one tool call.
pub const MAX_TIMEOUT_MS: u64 = 50_000;
/// The pause between checks when `interval_ms` is absent.
pub const DEFAULT_INTERVAL_MS: u64 = 200;
const MIN_INTERVAL_MS: u64 = 100;
const MAX_INTERVAL_MS: u64 = 1_000;
/// How long one check may run when the deadline is nearer than this, so the
/// last check at the deadline still gets an answer.
const CHECK_GRACE: Duration = Duration::from_secs(5);
/// The most elements a result lists.
const MAX_LISTED: usize = 50;
/// `get_window_state` arguments a wait passes on unchanged.
const PASSED_ON: [&str; 4] = ["pid", "window_id", "max_depth", "max_elements"];

/// The tool's `tools/list` entry.
pub fn definition() -> Value {
    json!({
        "name": TOOL,
        "description": "Wait until an element appears in a window's accessibility tree (or, with gone: true, until none matches), instead of sleeping and taking another screenshot. Checks the tree with get_window_state (no screenshot) every interval_ms until timeout_ms. On a match it returns the matching elements in get_window_state's shape, with element_token values from the newest snapshot, ready for click or type_text. On timeout it returns isError with timed_out: true and the count the last check saw. Pass query (get_window_state's case-insensitive match on an element's role, label or value; like it, only indexed rows count, so a plain text or spinner with no element_index never matches), role, or both.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pid": {"type": "integer", "description": "Target process ID, as for get_window_state."},
                "window_id": {"type": "integer", "description": "Target window ID from list_windows, as for get_window_state."},
                "query": {"type": "string", "description": "get_window_state's query: a case-insensitive match on an element's role, label or value."},
                "role": {"type": "string", "description": "Only elements of this role, for example button or AXButton (case-insensitive; the AX prefix is optional)."},
                "gone": {"type": "boolean", "description": "Wait until no element matches instead. Default false."},
                "timeout_ms": {"type": "integer", "minimum": 0, "maximum": MAX_TIMEOUT_MS, "description": "How long to wait in all. Default 10000; larger values are cut to 50000; 0 checks once."},
                "interval_ms": {"type": "integer", "minimum": MIN_INTERVAL_MS, "maximum": MAX_INTERVAL_MS, "description": "The pause between checks. Default 200."},
                "max_depth": {"type": "integer", "description": "Passed to get_window_state."},
                "max_elements": {"type": "integer", "description": "Passed to get_window_state."}
            },
            "required": ["pid", "window_id"]
        },
        "annotations": {"title": "Wait for an element", "readOnlyHint": true}
    })
}

/// A `tools/list` result with [`definition`] in it, when the helper serves
/// the tool each check calls.
///
/// The bridge answers every call of this name itself, so a helper tool of
/// the same name is never listed: what an agent sees is what runs.
pub fn with_definition(mut list: Value) -> Value {
    let Some(tools) = list.get_mut("tools").and_then(Value::as_array_mut) else {
        return list;
    };
    tools.retain(|tool| tool.get("name").and_then(Value::as_str) != Some(TOOL));
    if tools.iter().any(|tool| tool.get("name").and_then(Value::as_str) == Some(READ_TOOL)) {
        tools.push(definition());
    }
    list
}

/// One wait, from the tool's arguments.
#[derive(Debug, Clone, PartialEq)]
pub struct Wait {
    read_arguments: Value,
    query: Option<String>,
    role: Option<String>,
    gone: bool,
    timeout: Duration,
    interval: Duration,
}

impl Wait {
    /// Reads the tool's arguments; the error is the text for the agent.
    pub fn parse(arguments: &Value) -> Result<Wait, String> {
        let example = r#"{"pid":123,"window_id":4,"query":"Save","role":"button"}"#;
        let object = arguments.as_object().ok_or_else(|| {
            format!("invalid_arguments: {TOOL} takes an object, for example {example}")
        })?;
        for key in ["pid", "window_id"] {
            if !object.get(key).is_some_and(Value::is_i64) {
                return Err(format!(
                    "invalid_arguments: {TOOL} needs {key} as an integer (list_windows names both), for example {example}"
                ));
            }
        }
        let text = |key: &str| -> Result<Option<String>, String> {
            match object.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
                Some(Value::String(s)) => Ok(Some(s.clone())),
                Some(_) => Err(format!("invalid_arguments: {TOOL} takes {key} as a string")),
            }
        };
        let query = text("query")?;
        let role = text("role")?;
        if query.is_none() && role.is_none() {
            return Err(format!(
                "invalid_arguments: {TOOL} needs query, role or both, for example {example}"
            ));
        }
        let gone = match object.get("gone") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(gone)) => *gone,
            Some(_) => {
                return Err(format!("invalid_arguments: {TOOL} takes gone as true or false"));
            }
        };
        let millis = |key: &str, default: u64| -> Result<u64, String> {
            match object.get(key) {
                None | Some(Value::Null) => Ok(default),
                Some(value) => value.as_u64().ok_or_else(|| {
                    format!(
                        "invalid_arguments: {TOOL} takes {key} as a whole number of milliseconds"
                    )
                }),
            }
        };
        let timeout = millis("timeout_ms", DEFAULT_TIMEOUT_MS)?.min(MAX_TIMEOUT_MS);
        let interval =
            millis("interval_ms", DEFAULT_INTERVAL_MS)?.clamp(MIN_INTERVAL_MS, MAX_INTERVAL_MS);
        let mut read = serde_json::Map::new();
        for key in PASSED_ON {
            if let Some(value) = object.get(key) {
                read.insert(key.to_owned(), value.clone());
            }
        }
        if let Some(query) = &query {
            read.insert("query".to_owned(), json!(query));
        }
        // AX tree only: no screenshot, no vision.
        read.insert("include_screenshot".to_owned(), json!(false));
        Ok(Wait {
            read_arguments: Value::Object(read),
            query,
            role,
            gone,
            timeout: Duration::from_millis(timeout),
            interval: Duration::from_millis(interval),
        })
    }

    /// The `get_window_state` arguments of every check.
    pub fn read_arguments(&self) -> &Value {
        &self.read_arguments
    }

    fn describe(&self) -> String {
        match (&self.query, &self.role) {
            (Some(query), Some(role)) => format!("a {role} matching {query:?}"),
            (Some(query), None) => format!("an element matching {query:?}"),
            (None, Some(role)) => format!("a {role}"),
            (None, None) => "an element".to_owned(),
        }
    }
}

/// Where the checks read the tree: the helper in the bridge, a script in tests.
pub trait TreeReader {
    /// One `get_window_state` call; `Err` is the text of a failed call.
    fn read(&mut self, arguments: Value) -> impl Future<Output = Result<Value, String>>;
    /// Called when a check ran out of time mid-call: the connection may
    /// still owe its answer, so the reader must not reuse it.
    fn abandon(&mut self);
}

/// The elements of one `get_window_state` result that match.
///
/// With a query the helper already kept only matching rows and their
/// ancestors, in depth-first order; a row followed by a deeper row is an
/// ancestor and is dropped unless its own role, label or value holds the
/// query too.
pub fn matching(state: &Value, query: Option<&str>, role: Option<&str>) -> Vec<Value> {
    let empty = Vec::new();
    let elements = state.get("elements").and_then(Value::as_array).unwrap_or(&empty);
    let depth =
        |element: Option<&Value>| element.and_then(|e| e.get("depth")).and_then(Value::as_u64);
    let query = query.map(str::to_lowercase);
    let role = role.map(normalized_role);
    elements
        .iter()
        .enumerate()
        .filter(|(at, element)| {
            let hit = match &query {
                None => true,
                Some(query) => {
                    let ancestor =
                        match (depth(Some(element)), depth(elements.get(at.saturating_add(1)))) {
                            (Some(own), Some(next)) => next > own,
                            _ => false,
                        };
                    !ancestor || own_text_holds(element, query)
                }
            };
            hit && role.as_ref().is_none_or(|role| {
                element.get("role").and_then(Value::as_str).map(normalized_role).as_ref()
                    == Some(role)
            })
        })
        .map(|(_, element)| element.clone())
        .collect()
}

fn own_text_holds(element: &Value, query: &str) -> bool {
    ["role", "label", "value"].iter().any(|key| {
        element
            .get(*key)
            .and_then(Value::as_str)
            .is_some_and(|text| text.to_lowercase().contains(query))
    })
}

fn normalized_role(role: &str) -> String {
    let role = role.trim().to_lowercase();
    role.strip_prefix("ax").map(str::to_owned).unwrap_or(role)
}

/// Runs one wait to its end and returns the MCP `tools/call` result.
pub async fn run<R: TreeReader>(wait: &Wait, reader: &mut R) -> Value {
    let started = Instant::now();
    let deadline = started.checked_add(wait.timeout).unwrap_or(started);
    let mut checks: u64 = 0;
    let mut last: Vec<Value> = Vec::new();
    let mut window = Value::Null;
    let mut unanswered = false;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        checks = checks.saturating_add(1);
        let read = tokio::time::timeout(
            remaining.max(CHECK_GRACE),
            reader.read(wait.read_arguments.clone()),
        );
        let result = match read.await {
            Err(_) => {
                // This check has no answer: the count stays the last one's.
                reader.abandon();
                checks = checks.saturating_sub(1);
                unanswered = true;
                break;
            }
            Ok(Err(text)) => return failed(wait, &text, checks, started),
            Ok(Ok(result)) => result,
        };
        if result.get("isError") == Some(&json!(true)) {
            let text = result_text(&result);
            return failed(wait, &format!("{READ_TOOL} failed: {text}"), checks, started);
        }
        let state = result.get("structuredContent").unwrap_or(&result);
        window = json!({"pid": state.get("pid"), "window_id": state.get("window_id")});
        last = matching(state, wait.query.as_deref(), wait.role.as_deref());
        if last.is_empty() == wait.gone {
            return done(wait, &last, &window, checks, started);
        }
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        // Nothing is held across this pause: the reader owns the connection.
        tokio::time::sleep(wait.interval.min(deadline.saturating_duration_since(now))).await;
    }
    timed_out(wait, &last, &window, checks, unanswered, started)
}

fn elapsed_ms(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)
}

fn listed(elements: &[Value]) -> Vec<Value> {
    elements.iter().take(MAX_LISTED).cloned().collect()
}

fn lines(elements: &[Value]) -> String {
    let mut text = String::new();
    for element in elements.iter().take(20) {
        let field = |key: &str| element.get(key).and_then(Value::as_str).unwrap_or_default();
        let index =
            element.get("element_index").map(Value::to_string).unwrap_or_else(|| "-".into());
        text.push_str(&format!("\n- [{index}] {} {:?}", field("role"), field("label")));
        if let Some(token) = element.get("element_token").and_then(Value::as_str) {
            text.push_str(&format!(" element_token={token}"));
        }
    }
    if elements.len() > 20 {
        text.push_str(&format!(
            "\n- … {} more in structuredContent.elements",
            elements.len().saturating_sub(20)
        ));
    }
    text
}

fn done(wait: &Wait, found: &[Value], window: &Value, checks: u64, started: Instant) -> Value {
    let elapsed = elapsed_ms(started);
    let text = if wait.gone {
        format!("no element is {} any more ({elapsed} ms, {checks} checks)", wait.describe())
    } else {
        format!(
            "found {} element(s): {} ({elapsed} ms, {checks} checks){}",
            found.len(),
            wait.describe(),
            lines(found)
        )
    };
    json!({
        "content": [{"type": "text", "text": text}],
        "structuredContent": {
            "timed_out": false,
            "gone": wait.gone,
            "count": found.len(),
            "elements": listed(found),
            "elements_truncated": found.len() > MAX_LISTED,
            "checks": checks,
            "elapsed_ms": elapsed,
            "pid": window.get("pid"),
            "window_id": window.get("window_id"),
        },
    })
}

fn timed_out(
    wait: &Wait,
    last: &[Value],
    window: &Value,
    checks: u64,
    unanswered: bool,
    started: Instant,
) -> Value {
    let elapsed = elapsed_ms(started);
    let timeout = u64::try_from(wait.timeout.as_millis()).unwrap_or(MAX_TIMEOUT_MS);
    let goal = if wait.gone { "to disappear" } else { "to appear" };
    let unanswered_text =
        if unanswered { "; one more check got no answer from the helper in time" } else { "" };
    let text = format!(
        "timed_out: waited {elapsed} ms ({checks} checks) for {} {goal}; the last check saw {} matching element(s){unanswered_text}. Next: get_window_state to look at the window, or {TOOL} again with a larger timeout_ms (at most {MAX_TIMEOUT_MS}).",
        wait.describe(),
        last.len()
    );
    json!({
        "content": [{"type": "text", "text": text}],
        "structuredContent": {
            "timed_out": true,
            "gone": wait.gone,
            "count": last.len(),
            "elements": listed(last),
            "elements_truncated": last.len() > MAX_LISTED,
            "checks": checks,
            "elapsed_ms": elapsed,
            "timeout_ms": timeout,
            "last_check_unanswered": unanswered,
            "pid": window.get("pid"),
            "window_id": window.get("window_id"),
        },
        "isError": true,
    })
}

fn failed(wait: &Wait, text: &str, checks: u64, started: Instant) -> Value {
    let text = format!("{TOOL} stopped while waiting for {}: {text}", wait.describe());
    json!({
        "content": [{"type": "text", "text": text}],
        "structuredContent": {
            "timed_out": false,
            "error": text,
            "checks": checks,
            "elapsed_ms": elapsed_ms(started),
        },
        "isError": true,
    })
}

fn result_text(result: &Value) -> String {
    let texts: Vec<&str> = result
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect();
    if texts.is_empty() { result.to_string() } else { texts.join("\n") }
}

#[cfg(test)]
#[path = "wait_for_tests.rs"]
mod tests;
