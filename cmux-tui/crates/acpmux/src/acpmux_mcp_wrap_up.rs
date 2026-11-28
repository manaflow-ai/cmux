//! The `acpmux` MCP server's `wrap_up` tool: the agent's own end-of-turn box. The agent calls it
//! as the last step of a turn with a two- or three-sentence `recap` of what changed and where
//! things stand and, when the turn leaves the person a decision, one short `ask` with one or two
//! `actions` (the answers, drawn as buttons). The call reaches the chat's transcript as an
//! ordinary ACP tool call with its typed input, and the cmux NEXT agent pane draws it as the
//! next-step box under the answer (webviews `conversation/wrapUp.ts`); a click sends that answer
//! as the person's next prompt. The tool itself only checks the input and says so: nothing is
//! sent and no daemon request is made, so it works the same on every harness and host.
//! Leo, 2026-11-03, watching Claude Code Desktop's next-step box: "yo wtf i want this kind of
//! feature in cmux-next too".

use super::{error_result, ok};
use serde_json::{Value, json};

pub(super) const NAME: &str = "wrap_up";
/// What every chat with the tool is told: when to call it and how.
pub(super) const STEER: &str = "When a turn did work, call wrap_up as your last step: a two or \
three sentence recap including what is not done or verified; ask and actions only when a decision \
waits on the person; learned only after a correction or a failed then working command. Then end \
the turn without repeating the recap.";
/// The most answers the box draws.
const MAX_ACTIONS: usize = 2;
/// The longest answer a button takes.
const MAX_ACTION: usize = 80;
/// Bounds that keep the box a box; longer text belongs in the answer. Each field's description
/// carries its bound, so a caller sees it before it calls; none is a `maxLength`, because a
/// length is never a refusal: a longer field is trimmed and the result says so in one line
/// (tool-call bounces, 2026-11-21: 18 wrap_up calls in 24 h on one VM were re-sent whole after
/// "recap is over 600 characters"). The box draws the call's own input, so nothing is lost there.
const MAX_RECAP: usize = 600;
/// A recap up to this long is kept whole; past it, it is cut at a sentence end at most this long.
const RECAP_CEILING: usize = 1200;
const MAX_ASK: usize = 200;
/// The most facts a turn offers (`memory_inbox.rs`), and the longest one.
pub(crate) const MAX_LEARNED: usize = 3;
pub(crate) const MAX_FACT: usize = 200;

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "Finish with a recap below your answer. An answer button sends the person's next message; a {label, run} answer runs cmux customize try, keep, revert or go.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "recap": {"type": "string", "description": format!("Two or three sentences: changes, verification, unfinished work; at most {MAX_RECAP} characters (trimmed above {RECAP_CEILING}).")},
                "ask": {"type": "string", "description": format!("Only a decision the person must make, at most {MAX_ASK} characters. Never ask them to click or switch tabs: focus or capture it yourself. An unanswered one still waits: do not ask it again.")},
                "actions": {"type": "array", "items": {"anyOf": [{"type": "string"}, {"type": "object", "properties": {"label": {"type": "string"}, "run": {"type": "object", "properties": {"customize": {"type": "string", "enum": ["try", "keep", "revert", "go"]}, "target": {"type": "string", "description": "pr:N, branch:B, sha:S, dir:PATH or a profile; go: the pr:N tried on."}, "minutes": {"type": "integer", "description": "How long it stays on, 1 to 240."}}, "required": ["customize"]}}, "required": ["run"]}]}, "description": format!("With ask, up to {MAX_ACTIONS} buttons of at most {MAX_ACTION} characters, preferred first (default Yes, Not now). After a customization, run {{customize: \"try\", target: \"pr:123\", minutes: 15}} tries it on (the card then offers Keep and Revert, and Go for a pr:N: merge-ready at the head seen); or customize keep or revert.")},
                "learned": {"type": "array", "items": {"type": "string"}, "description": format!("After a correction or a failed then working command: up to {MAX_LEARNED} one-line project facts to accept, at most {MAX_FACT} characters each.")}
            },
            "required": ["recap"]
        }
    })
}

/// `text` at most `max` characters: whole when it fits, else cut at the last sentence end that
/// fits (when one ends past half of `max`), else at the last space, with an ellipsis.
fn trim_to(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    // Character counts, not byte offsets, so no cut can land inside a character.
    let chars: Vec<char> = text.chars().collect();
    let half = max / 2;
    // The last `n` (a count of characters kept) whose last character ends a sentence and whose
    // next one is a space.
    let sentence_end = (half.saturating_add(1)..=max).rev().find(|&n| {
        let mut pair = chars.iter().skip(n.saturating_sub(1));
        matches!(pair.next(), Some('.' | '!' | '?'))
            && pair.next().is_some_and(|c| c.is_whitespace())
    });
    if let Some(n) = sentence_end {
        return chars.iter().take(n).collect();
    }
    let room = max.saturating_sub(1);
    let space = (half.saturating_add(1)..room)
        .rev()
        .find(|&n| chars.get(n).is_some_and(|c| c.is_whitespace()));
    let kept: String = chars.iter().take(space.unwrap_or(room)).collect();
    format!("{}…", kept.trim_end())
}

/// Other names callers give each field, taken as that field when it is missing ("eh close
/// enough"): cmuxterm-hq#18786, 14 wrap_up calls in 7 days on one VM sent `summary` and were
/// refused with "recap is required". Leo, 2026-11-20: "Like we need a bunch of synonyms for
/// code for you guys where it just goes 'eh close enough' and works".
const ALIASES: &[(&str, &[&str])] = &[
    ("recap", &["summary", "message", "text", "result"]),
    ("ask", &["question"]),
    ("actions", &["options", "buttons", "answers"]),
    ("learned", &["lessons", "facts"]),
];

/// ARGS with each alias moved to its field when that field is missing, and one line per alias
/// taken (`summary taken as recap`).
fn canonical(args: &Value) -> (Value, Vec<String>) {
    let Some(map) = args.as_object() else {
        return (args.clone(), Vec::new());
    };
    let mut map = map.clone();
    let mut said = Vec::new();
    for (field, names) in ALIASES {
        if map.get(*field).is_some_and(|v| !v.is_null()) {
            continue;
        }
        if let Some((name, value)) = names
            .iter()
            .find_map(|name| map.get(*name).filter(|v| !v.is_null()).map(|v| (*name, v.clone())))
        {
            map.remove(name);
            map.insert((*field).to_owned(), value);
            said.push(format!("{name} taken as {field}"));
        }
    }
    (Value::Object(map), said)
}

/// A typed `run` of an action, checked against `customize_run`'s allowlist and cut to its own
/// keys, or why it is not allowed.
fn typed_run(run: &Value) -> Result<Value, String> {
    crate::customize_run::argv(run)?;
    let mut out = serde_json::Map::new();
    for key in ["customize", "target", "minutes"] {
        if let Some(v) = run.get(key).filter(|v| !v.is_null()) {
            out.insert(key.to_owned(), v.clone());
        }
    }
    Ok(Value::Object(out))
}

/// The call's input checked: a recap, and an ask with its answers when there is one. A field
/// past its bound is cut (`trim_to`), never refused; each cut is one line of the second value.
/// A field sent under another name (ALIASES) is taken as that field.
pub(super) fn check(args: &Value) -> Result<(Value, Vec<String>), String> {
    let (args, _) = canonical(args);
    let args = &args;
    let text =
        |key: &str| args.get(key).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty());
    let mut notes = Vec::new();
    let cut = |what: &str, value: &str, max: usize, notes: &mut Vec<String>| {
        let kept = trim_to(value, max);
        if kept != value {
            notes.push(format!(
                "{what} trimmed from {} to {} characters",
                value.chars().count(),
                kept.chars().count()
            ));
        }
        kept
    };
    let recap = text("recap").ok_or("recap is required: two or three sentences on what changed")?;
    let recap = cut("recap", recap, RECAP_CEILING, &mut notes);
    let ask = text("ask").map(|a| cut("ask", a, MAX_ASK, &mut notes));
    let list = |key: &str, what: &str, notes: &mut Vec<String>| -> Result<Vec<String>, String> {
        let items = |list: &[Value]| -> Vec<String> {
            list.iter()
                .filter_map(|item| item.as_str().map(str::trim).filter(|v| !v.is_empty()))
                .map(str::to_owned)
                .collect()
        };
        match args.get(key) {
            None | Some(Value::Null) => Ok(Vec::new()),
            Some(Value::Array(list)) => Ok(items(list)),
            // One string where a list goes is a list of it ("eh close enough"): the census of
            // 2026-11-23 (cmuxterm-hq docs/findings/2026-11-23-mcp-tool-error-census.md) counted
            // 54 wrap_up calls in 48 h on one VM refused "learned is a list". A string that is a
            // JSON list (`"[\"a\", \"b\"]"`) is read as that list.
            Some(Value::String(s)) if s.trim().is_empty() => Ok(Vec::new()),
            Some(Value::String(s)) => {
                let parsed = serde_json::from_str::<Vec<Value>>(s.trim()).ok();
                // Otherwise each non-empty line is one item: a fact per line, as a list holds them.
                let lines: Vec<String> = (s.lines().map(str::trim))
                    .filter(|l| !l.is_empty())
                    .map(str::to_owned)
                    .collect();
                notes.push(match (&parsed, lines.len()) {
                    (Some(_), _) => format!("{key} given as a JSON string; read as its list"),
                    (None, 1) => format!("{key} given as one string; read as a list of it"),
                    (None, n) => {
                        format!("{key} given as one string; read as a list of its {n} lines")
                    }
                });
                Ok(parsed.map_or(lines, |list| items(&list)))
            }
            Some(_) => Err(what.to_owned()),
        }
    };
    // An answer is a string, or `{label, run}` where `run` is a typed customize request
    // (`customize_run.rs`) the card runs on a click. A run that is not allowed is dropped, and the
    // button stays an ordinary answer.
    let mut actions: Vec<Value> = match args.get("actions") {
        Some(Value::Array(list)) => list
            .iter()
            .filter_map(|item| match item {
                Value::Object(_) => Some(item.clone()),
                other => other.as_str().map(str::trim).filter(|v| !v.is_empty()).map(|v| json!(v)),
            })
            .collect(),
        _ => list("actions", "actions is a list of one or two short answers", &mut notes)?
            .into_iter()
            .map(|a| json!(a))
            .collect(),
    };
    if actions.len() > MAX_ACTIONS {
        notes.push(format!("{} actions given; the first {MAX_ACTIONS} kept", actions.len()));
        actions.truncate(MAX_ACTIONS);
    }
    let actions: Vec<Value> = (actions.iter().enumerate())
        .filter_map(|(n, a)| {
            let what = format!("action {}", n + 1);
            let Some(object) = a.as_object() else {
                return Some(json!(cut(&what, a.as_str()?, MAX_ACTION, &mut notes)));
            };
            let run = object.get("run").map(typed_run);
            let verb = |run: &Value| match run["customize"].as_str() {
                Some("try") => "Try it on",
                Some("keep") => "Keep",
                Some("go") => "Go",
                _ => "Revert",
            };
            let label = object
                .get("label")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|v| !v.is_empty());
            match (label, run) {
                (label, Some(Ok(run))) => {
                    let label = label.map_or_else(
                        || verb(&run).to_owned(),
                        |l| cut(&what, l, MAX_ACTION, &mut notes),
                    );
                    Some(json!({"label": label, "run": run}))
                }
                (Some(label), run) => {
                    if let Some(Err(why)) = run {
                        notes.push(format!("{what} run dropped: {why}"));
                    }
                    Some(json!(cut(&what, label, MAX_ACTION, &mut notes)))
                }
                (None, _) => {
                    notes.push(format!("{what} has no label and no allowed run; dropped"));
                    None
                }
            }
        })
        .collect();
    if !actions.is_empty() && ask.is_none() {
        return Err("actions answer an ask; add the question, or leave actions out".to_owned());
    }
    let mut learned = list("learned", "learned is a list of up to three short facts", &mut notes)?;
    if learned.len() > MAX_LEARNED {
        notes.push(format!("{} learned facts given; the first {MAX_LEARNED} kept", learned.len()));
        learned.truncate(MAX_LEARNED);
    }
    let learned: Vec<String> = (learned.iter().enumerate())
        .map(|(n, fact)| {
            let what = format!("learned fact {}", n + 1);
            // One line, as the memory inbox keeps it (`memory_inbox::learned_facts`).
            let line = fact.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or_default();
            if line != fact.as_str() {
                notes.push(format!("{what} cut to its first line"));
            }
            cut(&what, line, MAX_FACT, &mut notes)
        })
        .collect();
    let mut shown = serde_json::Map::new();
    shown.insert("recap".into(), json!(recap));
    shown.insert("ask".into(), json!(ask));
    shown.insert("actions".into(), json!(actions));
    if !learned.is_empty() {
        shown.insert("learned".into(), json!(learned));
    }
    if !notes.is_empty() {
        shown.insert("trimmed".into(), json!(notes));
    }
    Ok((Value::Object(shown), notes))
}

/// The box the call draws, from the call's own input: what `code_mode.rs` records as a folded
/// call's `shown`, because the answer below does not echo it back (RFD 0087, 2026-11-24).
pub fn box_of(args: &Value) -> Option<Value> {
    check(args).ok().map(|(shown, _)| shown)
}

pub(super) fn call(args: &Value) -> Value {
    let (_, said) = canonical(args);
    match check(args) {
        Ok((shown, mut notes)) => {
            notes.splice(0..0, said);
            let text = if shown["ask"].is_string() {
                "Shown to the person under your answer, with the question. End your turn now; their answer comes as their next message."
            } else {
                "Shown to the person under your answer. End your turn now."
            };
            let text = if notes.is_empty() {
                text.to_owned()
            } else {
                format!("{text}\n{}.", notes.join("; "))
            };
            // The answer carries no copy of the recap, ask, actions or facts: every drawer of the
            // box reads the call's own input (webviews `conversation/wrapUp.ts`,
            // `wrap_up_suggestion.rs`, `code_mode.rs` through `box_of`), so echoing them back
            // only spends the agent's context on what it just sent. 91% of a wrap-up answer's
            // bytes were that echo (RFD 0087, cmuxterm-hq#22593). What is left is what the agent
            // cannot see from its own call: that the box was drawn, and with what in it; the
            // trims are named in the text above.
            let receipt = json!({
                "drawn": true,
                "question": shown["ask"].is_string(),
                "answers": shown["actions"].as_array().map_or(0, Vec::len),
                "facts": shown.get("learned").and_then(Value::as_array).map_or(0, Vec::len),
            });
            ok(text, receipt)
        }
        Err(e) => error_result(e),
    }
}

#[cfg(test)]
#[path = "acpmux_mcp_wrap_up_tests.rs"]
mod tests;
