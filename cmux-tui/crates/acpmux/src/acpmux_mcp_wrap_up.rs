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
pub(super) const STEER: &str = "When you end a turn that did work, call wrap_up as your last \
step: recap says in two or three plain sentences what changed and where things stand, including \
what is not done or not verified. When the turn leaves the person a decision (a choice of \
approach, a go-ahead), add ask, one short question, and actions, one or two answers with your \
pick first; their click comes back as their next message. Leave ask out when nothing waits on \
them. Then end the turn without repeating the recap.";
/// The most answers the box draws.
const MAX_ACTIONS: usize = 2;
/// The longest answer a button takes.
const MAX_ACTION: usize = 80;
/// Bounds that keep the box a box; longer text belongs in the answer.
const MAX_RECAP: usize = 600;
const MAX_ASK: usize = 200;

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "End a turn with the next-step box the person sees under your answer: a short recap of what changed and where things stand and, when the turn leaves them a decision, one question with one or two answer buttons. A button's click is sent as their next message. Call it once, as the turn's last step.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "recap": {"type": "string", "description": "Two or three short sentences: what is now true or changed, then where it stands, including what is not done or not verified."},
                "ask": {"type": "string", "description": "One short question, only when the next move is the person's call. Leave it out when nothing waits on them."},
                "actions": {"type": "array", "items": {"type": "string"}, "maxItems": MAX_ACTIONS, "description": "With ask: one or two answers, a few words each, your pick first (\"Yes, open PR\", \"Not now\"). Each is sent as the person's reply when clicked. Without it a question gets Yes and Not now."}
            },
            "required": ["recap"]
        }
    })
}

/// The call's input checked: a recap, and an ask with its answers when there is one.
pub(super) fn check(args: &Value) -> Result<Value, String> {
    let text =
        |key: &str| args.get(key).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty());
    let recap = text("recap").ok_or("recap is required: two or three sentences on what changed")?;
    if recap.chars().count() > MAX_RECAP {
        return Err(format!(
            "recap is over {MAX_RECAP} characters; keep it to two or three sentences"
        ));
    }
    let ask = text("ask");
    if ask.is_some_and(|a| a.chars().count() > MAX_ASK) {
        return Err(format!("ask is over {MAX_ASK} characters; ask one short question"));
    }
    let actions: Vec<&str> = match args.get("actions") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(list)) => {
            let mut out = Vec::new();
            for item in list {
                let label = item.as_str().map(str::trim).filter(|v| !v.is_empty());
                match label {
                    Some(l) if l.chars().count() <= MAX_ACTION => out.push(l),
                    Some(_) => {
                        return Err(format!("each action is at most {MAX_ACTION} characters"));
                    }
                    None => return Err("actions are short strings".to_owned()),
                }
            }
            out
        }
        Some(_) => return Err("actions is a list of one or two short strings".to_owned()),
    };
    if actions.len() > MAX_ACTIONS {
        return Err(format!("at most {MAX_ACTIONS} actions"));
    }
    if !actions.is_empty() && ask.is_none() {
        return Err("actions answer an ask; add the question, or leave actions out".to_owned());
    }
    Ok(json!({"recap": recap, "ask": ask, "actions": actions}))
}

pub(super) fn call(args: &Value) -> Value {
    match check(args) {
        Ok(shown) => {
            let text = if shown["ask"].is_string() {
                "Shown to the person under your answer, with the question. End your turn now; their answer comes as their next message."
            } else {
                "Shown to the person under your answer. End your turn now."
            };
            ok(text.to_owned(), shown)
        }
        Err(e) => error_result(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_recap_with_an_ask_and_two_answers_is_shown() {
        let shown = check(&json!({"recap": " Done. ", "ask": "Open a PR?", "actions": ["Yes, open PR", "Not now"]}))
            .unwrap();
        assert_eq!(
            shown,
            json!({"recap": "Done.", "ask": "Open a PR?", "actions": ["Yes, open PR", "Not now"]})
        );
        assert_eq!(check(&json!({"recap": "Done."})).unwrap()["ask"], Value::Null);
    }

    #[test]
    fn a_missing_recap_extra_answers_or_answers_without_a_question_are_refused() {
        for bad in [
            json!({}),
            json!({"recap": "  "}),
            json!({"recap": "Done.", "ask": "Open?", "actions": ["a", "b", "c"]}),
            json!({"recap": "Done.", "actions": ["Yes"]}),
            json!({"recap": "Done.", "ask": "Open?", "actions": "Yes"}),
            json!({"recap": "x".repeat(MAX_RECAP + 1)}),
        ] {
            assert!(check(&bad).is_err(), "{bad}");
        }
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
