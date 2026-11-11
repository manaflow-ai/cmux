//! The `acpmux` MCP server's `wrap_up` tool: the agent's own end-of-turn box. The agent calls it
//! as the last step of a turn with a two- or three-sentence `recap` of what changed and where
//! things stand and, when the turn leaves the person a decision, one short `ask` with one or two
//! `actions` (the answers, drawn as buttons). A turn that finished something the person can try adds
//! `try` (one page or command, drawn as a Try button), `verify` (what to check once it runs) and
//! `report` (the HTML report), so every finished task has a direct way to try it, not only its
//! artifact (Aziz, 2026-11-09: "theres a direct way for me to try out and verify its work in
//! addition to the artifact"). The call reaches the chat's transcript as an
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
them. When the person corrected you this turn, or a command failed and a later one worked, add \
learned: at most three short facts about this project worth keeping in its instructions file \
(\"Use pnpm, not npm.\", \"Tests need DATABASE_URL set.\"); the person accepts or dismisses each. \
Leave learned out otherwise. When the turn finished a task the person can try (a build, a page, a \
command), add try: {label, url or command} to launch it with one click (a tagged build's Tag \
Opener URL http://127.0.0.1:17320/<tag>, a preview or TestFlight URL, or a command to run in a \
terminal), verify: up to five short steps saying what to check and what they should see, and \
report: the path or URL of the HTML report. Then end the turn without repeating the recap.";
/// The most answers the box draws.
const MAX_ACTIONS: usize = 2;
/// The longest answer a button takes.
const MAX_ACTION: usize = 80;
/// Bounds that keep the box a box; longer text belongs in the answer.
const MAX_RECAP: usize = 600;
const MAX_ASK: usize = 200;
/// The most facts a turn offers (`memory_inbox.rs`), and the longest one.
pub(crate) const MAX_LEARNED: usize = 3;
pub(crate) const MAX_FACT: usize = 200;
/// The Try launcher (`try`): a button label and one target, a page or a command.
const MAX_TRY_LABEL: usize = 60;
const MAX_TRY_URL: usize = 2000;
const MAX_TRY_COMMAND: usize = 500;
/// The Verify steps: what the person checks once it launched.
pub(crate) const MAX_VERIFY: usize = 5;
const MAX_VERIFY_STEP: usize = 200;
/// The report artifact: a file path or a web address.
const MAX_REPORT: usize = 2000;

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "End a turn with the next-step box the person sees under your answer: a short recap of what changed and where things stand and, when the turn leaves them a decision, one question with one or two answer buttons. A button's click is sent as their next message. Call it once, as the turn's last step.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "recap": {"type": "string", "description": "Two or three short sentences: what is now true or changed, then where it stands, including what is not done or not verified."},
                "ask": {"type": "string", "description": "One short question, only when the next move is the person's call. Leave it out when nothing waits on them."},
                "actions": {"type": "array", "items": {"type": "string"}, "maxItems": MAX_ACTIONS, "description": "With ask: one or two answers, a few words each, your pick first (\"Yes, open PR\", \"Not now\"). Each is sent as the person's reply when clicked. Without it a question gets Yes and Not now."},
                "learned": {"type": "array", "items": {"type": "string"}, "maxItems": MAX_LEARNED, "description": "Only when the person corrected you this turn, or a command failed and a later one worked: up to three one-line facts about this project for its instructions file (\"Use pnpm, not npm.\"). Each is shown to the person to accept or dismiss."},
                "try": {"type": "object", "description": "When the turn finished something the person can try: the Try button that launches it. Give url (a tagged build's Tag Opener http://127.0.0.1:17320/<tag>, a preview or TestFlight page) or command (one shell line run in a new terminal), not both.", "properties": {
                    "label": {"type": "string", "description": "The button's few words (\"Open try-agent-work build\"); default Try it."},
                    "url": {"type": "string", "description": "An http or https address opened in a browser tab."},
                    "command": {"type": "string", "description": "One shell line run in a new terminal in the chat's folder."}
                }},
                "verify": {"type": "array", "items": {"type": "string"}, "maxItems": MAX_VERIFY, "description": "With try: up to five short steps, what to do and what the person should see (\"Pin a tab: it keeps its title and shows a pin.\")."},
                "report": {"type": "string", "description": "The path or URL of the task's HTML report, drawn as a Report link."}
            },
            "required": ["recap"]
        }
    })
}

/// The call's input checked: a recap, and an ask with its answers when there is one.
pub(crate) fn check(args: &Value) -> Result<Value, String> {
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
    let learned: Vec<&str> = match args.get("learned") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(list)) => {
            let mut out = Vec::new();
            for item in list {
                match item.as_str().map(str::trim).filter(|v| !v.is_empty()) {
                    Some(f) if f.chars().count() <= MAX_FACT && !f.contains('\n') => out.push(f),
                    _ => {
                        return Err(format!(
                            "each learned fact is one line of at most {MAX_FACT} characters"
                        ));
                    }
                }
            }
            out
        }
        Some(_) => return Err("learned is a list of up to three short facts".to_owned()),
    };
    if learned.len() > MAX_LEARNED {
        return Err(format!("at most {MAX_LEARNED} learned facts"));
    }
    let try_it = match args.get("try") {
        None | Some(Value::Null) => None,
        Some(Value::Object(t)) => Some(check_try(t)?),
        Some(_) => return Err("try is an object: {label, url} or {label, command}".to_owned()),
    };
    let verify: Vec<&str> = match args.get("verify") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(list)) => {
            let mut out = Vec::new();
            for item in list {
                match item.as_str().map(str::trim).filter(|v| !v.is_empty()) {
                    Some(step) if step.chars().count() <= MAX_VERIFY_STEP && plain_line(step) => {
                        out.push(step);
                    }
                    _ => {
                        return Err(format!(
                            "each verify step is one line of at most {MAX_VERIFY_STEP} characters"
                        ));
                    }
                }
            }
            out
        }
        Some(_) => return Err("verify is a list of up to five short steps".to_owned()),
    };
    if verify.len() > MAX_VERIFY {
        return Err(format!("at most {MAX_VERIFY} verify steps"));
    }
    let report = text("report");
    if report.is_some_and(|r| r.chars().count() > MAX_REPORT || !plain_line(r)) {
        return Err(format!("report is one path or URL of at most {MAX_REPORT} characters"));
    }
    let mut shown = serde_json::Map::new();
    shown.insert("recap".into(), json!(recap));
    shown.insert("ask".into(), json!(ask));
    shown.insert("actions".into(), json!(actions));
    if !learned.is_empty() {
        shown.insert("learned".into(), json!(learned));
    }
    if let Some(try_it) = try_it {
        shown.insert("try".into(), try_it);
    }
    if !verify.is_empty() {
        shown.insert("verify".into(), json!(verify));
    }
    if let Some(report) = report {
        shown.insert("report".into(), json!(report));
    }
    Ok(Value::Object(shown))
}

/// One line with no control character (C0, DEL, C1), line or paragraph separator, or bidi
/// formatting character. A Try command is typed into a terminal: a carriage return, Ctrl-U, an
/// escape sequence or a bidi override could make the line that runs differ from the one shown.
pub(crate) fn plain_line(text: &str) -> bool {
    !text.chars().any(|c| {
        matches!(c as u32, 0..=0x1F | 0x7F..=0x9F | 0x2028 | 0x2029 | 0x200E | 0x200F | 0x061C
            | 0x202A..=0x202E | 0x2066..=0x2069)
    })
}

/// The Try launcher checked: a label (Try it when none) and exactly one target, an http(s) page
/// or one shell line. Where it runs is the person's click: the Mac opens the page in a browser
/// tab or the command in a new terminal; a phone opens a page and only shows a command.
fn check_try(t: &serde_json::Map<String, Value>) -> Result<Value, String> {
    let field = |key: &str| t.get(key).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty());
    let label = field("label").unwrap_or("Try it");
    if label.chars().count() > MAX_TRY_LABEL || !plain_line(label) {
        return Err(format!("try.label is a few words, at most {MAX_TRY_LABEL} characters"));
    }
    match (field("url"), field("command")) {
        (Some(url), None) => {
            let lower = url.to_ascii_lowercase();
            if !(lower.starts_with("http://") || lower.starts_with("https://"))
                || url.chars().count() > MAX_TRY_URL
                || url.chars().any(char::is_whitespace)
            {
                return Err("try.url is one http or https address".to_owned());
            }
            Ok(json!({"label": label, "url": url}))
        }
        (None, Some(command)) => {
            if command.chars().count() > MAX_TRY_COMMAND || !plain_line(command) {
                return Err(format!(
                    "try.command is one shell line of at most {MAX_TRY_COMMAND} characters"
                ));
            }
            Ok(json!({"label": label, "command": command}))
        }
        (Some(_), Some(_)) => Err("try takes url or command, not both".to_owned()),
        (None, None) => Err("try needs url or command".to_owned()),
    }
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
            json!({"recap": "Done.", "learned": ["a", "b", "c", "d"]}),
            json!({"recap": "Done.", "learned": ["two\nlines"]}),
            json!({"recap": "Done.", "learned": "Use pnpm."}),
        ] {
            assert!(check(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn learned_facts_are_kept_trimmed_and_left_out_when_empty() {
        let shown = check(&json!({"recap": "Done.", "learned": [" Use pnpm, not npm. "]})).unwrap();
        assert_eq!(shown["learned"], json!(["Use pnpm, not npm."]));
        assert!(check(&json!({"recap": "Done.", "learned": []})).unwrap().get("learned").is_none());
    }

    #[test]
    fn a_try_with_verify_steps_and_a_report_is_shown_checked() {
        let shown = check(&json!({
            "recap": "Done.",
            "try": {"label": " Open build ", "url": "http://127.0.0.1:17320/try-agent-work"},
            "verify": [" Finish a task: the row shows Try. "],
            "report": "/tmp/report.html"
        }))
        .unwrap();
        assert_eq!(
            shown["try"],
            json!({"label": "Open build", "url": "http://127.0.0.1:17320/try-agent-work"})
        );
        assert_eq!(shown["verify"], json!(["Finish a task: the row shows Try."]));
        assert_eq!(shown["report"], "/tmp/report.html");
        let command = check(&json!({"recap": "Done.", "try": {"command": "make demo"}})).unwrap();
        assert_eq!(command["try"], json!({"label": "Try it", "command": "make demo"}));
        let plain = check(&json!({"recap": "Done."})).unwrap();
        assert!(plain.get("try").is_none() && plain.get("verify").is_none());
    }

    #[test]
    fn a_try_without_one_safe_target_is_refused() {
        for bad in [
            json!({"recap": "Done.", "try": "http://x"}),
            json!({"recap": "Done.", "try": {"label": "Go"}}),
            json!({"recap": "Done.", "try": {"url": "https://a", "command": "ls"}}),
            json!({"recap": "Done.", "try": {"url": "javascript:alert(1)"}}),
            json!({"recap": "Done.", "try": {"url": "file:///etc/passwd"}}),
            json!({"recap": "Done.", "try": {"command": "ls\nrm -rf x"}}),
            json!({"recap": "Done.", "try": {"command": "echo hi\rrm -rf x"}}),
            json!({"recap": "Done.", "try": {"command": "rm -rf x\u{15}echo safe"}}),
            json!({"recap": "Done.", "try": {"command": "ls \u{1b}[2K"}}),
            json!({"recap": "Done.", "try": {"command": "ls \u{202e}fdp.txt"}}),
            json!({"recap": "Done.", "try": {"label": "Go\u{85}now", "url": "https://a"}}),
            json!({"recap": "Done.", "verify": ["a", "b", "c", "d", "e", "f"]}),
            json!({"recap": "Done.", "verify": ["two\nlines"]}),
            json!({"recap": "Done.", "report": "a\nb"}),
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
