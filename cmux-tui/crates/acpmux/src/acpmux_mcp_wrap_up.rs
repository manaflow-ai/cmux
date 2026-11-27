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
mod tests {
    use super::*;

    fn shown(args: Value) -> Value {
        check(&args).unwrap().0
    }

    #[test]
    fn a_recap_with_an_ask_and_two_answers_is_shown() {
        let (got, notes) = check(&json!({"recap": " Done. ", "ask": "Open a PR?", "actions": ["Yes, open PR", "Not now"]}))
            .unwrap();
        assert_eq!(
            got,
            json!({"recap": "Done.", "ask": "Open a PR?", "actions": ["Yes, open PR", "Not now"]})
        );
        assert!(notes.is_empty());
        assert_eq!(shown(json!({"recap": "Done."}))["ask"], Value::Null);
    }

    #[test]
    fn a_missing_recap_answers_without_a_question_or_wrong_types_are_refused() {
        for bad in [
            json!({}),
            json!({"recap": "  "}),
            json!({"recap": "Done.", "actions": ["Yes"]}),
            json!({"recap": "Done.", "learned": 3}),
            json!({"recap": "Done.", "ask": "Open?", "actions": {"a": "Yes"}}),
        ] {
            assert!(check(&bad).is_err(), "{bad}");
        }
    }

    /// Length is never a refusal (tool-call bounces, 2026-11-21): a recap up to the ceiling is
    /// kept whole, a longer one is cut at a sentence end, and the result says so in one line.
    #[test]
    fn a_long_recap_is_kept_whole_or_cut_at_a_sentence_and_said_so() {
        let long = "This sentence is forty characters long. ".repeat(20);
        let long = long.trim_end();
        assert!(long.chars().count() > MAX_RECAP && long.chars().count() <= RECAP_CEILING);
        let (got, notes) = check(&json!({"recap": long})).unwrap();
        assert_eq!((got["recap"].as_str().unwrap(), notes.len()), (long, 0));
        let longer = "This sentence is forty characters long. ".repeat(40);
        let result = call(&json!({"recap": longer}));
        assert_eq!(result["isError"], false, "{result}");
        let recap = result["structuredContent"]["recap"].as_str().unwrap();
        assert!(recap.ends_with("long.") && recap.chars().count() <= RECAP_CEILING, "{recap}");
        let text = result["content"][0]["text"].as_str().unwrap();
        let note = format!(
            "recap trimmed from {} to {} characters",
            longer.trim().chars().count(),
            recap.chars().count()
        );
        assert!(text.ends_with(&format!("{note}.")), "{text}");
        // One unbroken run of words is cut at a space, with an ellipsis.
        let words = "word ".repeat(400);
        let recap = shown(json!({"recap": words}))["recap"].as_str().unwrap().to_owned();
        assert!(recap.ends_with("word…") && recap.chars().count() <= RECAP_CEILING, "{recap}");
    }

    /// Every other bound cuts too: a long ask or answer, a third answer, a long or two-line
    /// fact, a fourth fact; each cut is named.
    #[test]
    fn long_asks_answers_and_facts_are_cut_and_named() {
        let (got, notes) = check(&json!({
            "recap": "Done.",
            "ask": format!("Open {}?", "a PR ".repeat(60)),
            "actions": ["x".repeat(MAX_ACTION + 5), "Not now", "Later"],
            "learned": ["Use pnpm.\nAlso yarn.", "f".repeat(MAX_FACT + 1), "c", "d"],
        }))
        .unwrap();
        assert!(got["ask"].as_str().unwrap().chars().count() <= MAX_ASK);
        assert_eq!(got["actions"].as_array().unwrap().len(), MAX_ACTIONS);
        assert!(got["actions"][0].as_str().unwrap().chars().count() <= MAX_ACTION);
        assert_eq!(got["learned"][0], "Use pnpm.");
        assert!(got["learned"][1].as_str().unwrap().chars().count() <= MAX_FACT);
        assert_eq!(got["learned"].as_array().unwrap().len(), MAX_LEARNED);
        let said = notes.join("; ");
        for part in [
            "ask trimmed from",
            "3 actions given; the first 2 kept",
            "action 1 trimmed from 85 to",
            "4 learned facts given; the first 3 kept",
            "learned fact 1 cut to its first line",
            "learned fact 2 trimmed from 201 to",
        ] {
            assert!(said.contains(part), "{part}: {said}");
        }
        assert_eq!(got["trimmed"], json!(notes));
    }

    #[test]
    fn learned_facts_are_kept_trimmed_and_left_out_when_empty() {
        let kept = shown(json!({"recap": "Done.", "learned": [" Use pnpm, not npm. "]}));
        assert_eq!(kept["learned"], json!(["Use pnpm, not npm."]));
        assert!(shown(json!({"recap": "Done.", "learned": []})).get("learned").is_none());
    }

    /// The schema says each bound in words and carries no maxLength or maxItems, so no harness
    /// refuses a call the tool would take.
    #[test]
    fn the_schema_says_every_bound_and_enforces_none() {
        let tool = tool();
        let props = &tool["inputSchema"]["properties"];
        for (key, max) in
            [("recap", MAX_RECAP), ("ask", MAX_ASK), ("actions", MAX_ACTION), ("learned", MAX_FACT)]
        {
            let said = props[key]["description"].as_str().unwrap();
            assert!(said.contains(&format!("at most {max} characters")), "{key}: {said}");
            assert!(props[key].get("maxLength").is_none() && props[key].get("maxItems").is_none());
            assert!(props[key]["items"].get("maxLength").is_none(), "{key}");
        }
        let at = "x".repeat(RECAP_CEILING);
        assert_eq!(shown(json!({"recap": at}))["recap"], at);
    }

    /// https://github.com/manaflow-ai/cmux/issues/52766: an agent woken by background-command
    /// notices ended seven turns on the same "Can you click the dev build tab in my right split"
    /// ask. The ask's description rules out both: a request to click a tab, and asking again.
    #[test]
    fn the_ask_rules_out_clicking_tabs_and_asking_again() {
        let tool = tool();
        let said = tool["inputSchema"]["properties"]["ask"]["description"].as_str().unwrap();
        for phrase in
            ["Never ask them to click", "focus or capture it yourself", "do not ask it again"]
        {
            assert!(said.contains(phrase), "{phrase}: {said}");
        }
    }

    /// The census of 2026-11-23 (cmuxterm-hq docs/findings/2026-11-23-mcp-tool-error-census.md):
    /// 54 wrap_up calls in 48 h on one VM sent `learned` as one string and were refused "learned
    /// is a list". A string is a list of it (of its lines, or the list a JSON string spells), and
    /// the result says so.
    #[test]
    fn a_string_where_a_list_goes_is_read_as_a_list_and_said_so() {
        let one = call(&json!({"recap": "Done.", "learned": "Use pnpm, not npm."}));
        assert_eq!(one["isError"], false, "{one}");
        assert_eq!(one["structuredContent"]["learned"], json!(["Use pnpm, not npm."]), "{one}");
        let text = one["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("learned given as one string; read as a list of it"), "{text}");
        let lines = shown(json!({"recap": "Done.", "learned": "Use pnpm.\n\n  Rebase first.\n"}));
        assert_eq!(lines["learned"], json!(["Use pnpm.", "Rebase first."]));
        let spelled = shown(json!({"recap": "Done.", "learned": "[\"a\", \"b\"]"}));
        assert_eq!(spelled["learned"], json!(["a", "b"]));
        let asked = shown(json!({"recap": "Done.", "ask": "Merge?", "actions": "Yes"}));
        assert_eq!(asked["actions"], json!(["Yes"]));
        assert!(shown(json!({"recap": "Done.", "learned": "  "})).get("learned").is_none());
    }

    /// cmuxterm-hq#18786: the refused call of 2026-11-21T15:24Z sent `summary`, not `recap`.
    #[test]
    fn summary_and_other_aliases_are_taken_as_their_field_and_said_so() {
        let summary = "The scheduler grant works end to end. In smoke run 44913484985, both Mac jobs ran on cmux18 under per-run labels the scheduler granted.";
        let result = call(&json!({"summary": summary}));
        assert_eq!(result["isError"], false, "{result}");
        assert_eq!(result["structuredContent"]["recap"], summary);
        assert!(result["structuredContent"].get("trimmed").is_none());
        let text = result["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("summary taken as recap"), "{text}");
        assert_eq!(
            shown(
                json!({"message": "Done.", "question": "Open a PR?", "options": ["Yes", "No"], "lessons": ["Use pnpm."]})
            ),
            json!({"recap": "Done.", "ask": "Open a PR?", "actions": ["Yes", "No"], "learned": ["Use pnpm."]})
        );
        // The field itself wins over an alias sent beside it.
        assert_eq!(shown(json!({"recap": "Done.", "summary": "Other."}))["recap"], "Done.");
        assert!(check(&json!({"summary": "  "})).is_err());
    }

    #[test]
    fn typed_actions_are_kept_checked_and_labelled() {
        let got = shown(json!({
            "recap": "Built it.",
            "ask": "Try it on?",
            "actions": [
                {"label": "Try it on", "run": {"customize": "try", "target": "pr:51234", "minutes": 15, "extra": 1}},
                "Not now",
            ],
        }));
        assert_eq!(
            got["actions"],
            json!([
                {"label": "Try it on", "run": {"customize": "try", "target": "pr:51234", "minutes": 15}},
                "Not now"
            ])
        );
        // No label: the verb's own. Keep and revert take no target.
        let got = shown(
            json!({"recap": "x", "ask": "Keep?", "actions": [{"run": {"customize": "keep"}}, {"run": {"customize": "revert"}}]}),
        );
        assert_eq!(got["actions"][0], json!({"label": "Keep", "run": {"customize": "keep"}}));
        assert_eq!(got["actions"][1]["label"], "Revert");
    }

    #[test]
    fn a_run_outside_the_allowlist_is_dropped_and_said_so() {
        let (got, notes) = check(&json!({
            "recap": "x", "ask": "Go?",
            "actions": [{"label": "Do it", "run": {"customize": "try", "target": "--help"}}, {"run": {"customize": "apply"}}],
        }))
        .unwrap();
        assert_eq!(got["actions"], json!(["Do it"]));
        let said = notes.join("; ");
        assert!(
            said.contains("action 1 run dropped") && said.contains("action 2 has no label"),
            "{said}"
        );
    }

    #[test]
    fn the_schema_says_what_a_typed_action_is() {
        let tool = tool();
        let items = &tool["inputSchema"]["properties"]["actions"]["items"]["anyOf"];
        assert_eq!(items[0]["type"], "string");
        assert_eq!(
            items[1]["properties"]["run"]["properties"]["customize"]["enum"],
            json!(["try", "keep", "revert", "go"])
        );
        assert!(
            tool["inputSchema"]["properties"]["actions"]["description"]
                .as_str()
                .unwrap()
                .contains("customize")
        );
    }

    #[test]
    fn the_call_answers_with_what_it_showed() {
        let result = call(&json!({"recap": "Done.", "ask": "Open a PR?"}));
        assert_eq!(result["isError"], false);
        assert_eq!(result["structuredContent"]["ask"], "Open a PR?");
        assert!(result["content"][0]["text"].as_str().unwrap().contains("End your turn now"));
        assert_eq!(call(&json!({}))["isError"], true);
    }
}
