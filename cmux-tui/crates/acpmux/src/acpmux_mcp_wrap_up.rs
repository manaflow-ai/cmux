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
        "description": "End a turn with the next-step box the person sees under your answer: a short recap of what changed and where things stand and, when the turn leaves them a decision, one question with one or two answer buttons. A button's click is sent as their next message. Call it once, as the turn's last step.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "recap": {"type": "string", "description": format!("Two or three short sentences, at most {MAX_RECAP} characters: what is now true or changed, then where it stands, including what is not done or not verified. One past {RECAP_CEILING} is cut at a sentence end, and the result says so.")},
                "ask": {"type": "string", "description": format!("One short question of at most {MAX_ASK} characters, only when the next move is the person's call. Leave it out when nothing waits on them. A longer one is cut, and the result says so.")},
                "actions": {"type": "array", "items": {"type": "string"}, "description": format!("With ask: one or two answers, a few words each and at most {MAX_ACTION} characters, your pick first (\"Yes, open PR\", \"Not now\"). Each is sent as the person's reply when clicked. Without it a question gets Yes and Not now. Longer ones, or more than {MAX_ACTIONS}, are cut, and the result says so.")},
                "learned": {"type": "array", "items": {"type": "string"}, "description": format!("Only when the person corrected you this turn, or a command failed and a later one worked: up to three one-line facts about this project for its instructions file (\"Use pnpm, not npm.\"), each at most {MAX_FACT} characters. Each is shown to the person to accept or dismiss. Longer ones, extra lines or more than {MAX_LEARNED} facts are cut, and the result says so.")}
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
    let list = |key: &str, what: &str| -> Result<Vec<&str>, String> {
        match args.get(key) {
            None | Some(Value::Null) => Ok(Vec::new()),
            Some(Value::Array(list)) => Ok(list
                .iter()
                .filter_map(|item| item.as_str().map(str::trim).filter(|v| !v.is_empty()))
                .collect()),
            Some(_) => Err(what.to_owned()),
        }
    };
    let mut actions = list("actions", "actions is a list of one or two short strings")?;
    if actions.len() > MAX_ACTIONS {
        notes.push(format!("{} actions given; the first {MAX_ACTIONS} kept", actions.len()));
        actions.truncate(MAX_ACTIONS);
    }
    let actions: Vec<String> = (actions.iter().enumerate())
        .map(|(n, a)| cut(&format!("action {}", n + 1), a, MAX_ACTION, &mut notes))
        .collect();
    if !actions.is_empty() && ask.is_none() {
        return Err("actions answer an ask; add the question, or leave actions out".to_owned());
    }
    let mut learned = list("learned", "learned is a list of up to three short facts")?;
    if learned.len() > MAX_LEARNED {
        notes.push(format!("{} learned facts given; the first {MAX_LEARNED} kept", learned.len()));
        learned.truncate(MAX_LEARNED);
    }
    let learned: Vec<String> = (learned.iter().enumerate())
        .map(|(n, fact)| {
            let what = format!("learned fact {}", n + 1);
            // One line, as the memory inbox keeps it (`memory_inbox::learned_facts`).
            let line = fact.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or_default();
            if line != *fact {
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
            ok(text, shown)
        }
        Err(e) => error_result(e),
    }
}

#[cfg(test)]
#[path = "acpmux_mcp_wrap_up_tests.rs"]
mod tests;
