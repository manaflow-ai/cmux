//! The `acpmux` MCP server's `settings_ask` tool: the agent asks the person for one setting or one
//! connection, and the chat shows that one thing as a small card under the turn, live, styled like
//! the Needs you card. Leo, 2026-11-25: "what about just a simple styled consistently popover for
//! that specific setting? a la something similar to needs you or whatever". The person acts on the
//! card in place (Connect GitHub runs the app's own `accounts.githubConnect`, the same flow as
//! Settings and the failed-call card) and is never sent into Settings to hunt for it.
//!
//! As `wrap_up` does, the tool only checks its input and says so: the call reaches the transcript
//! with its typed input, and the cmux NEXT agent pane draws the card from it (webviews
//! `conversation/settingsAsk.ts`). Nothing is sent and no daemon request is made, so it works the
//! same on every harness and host; the person's click is what acts.

use super::{error_result, ok};
use serde_json::{Value, json};

pub(super) const NAME: &str = "settings_ask";
/// What every chat with the tool is told.
pub(super) const STEER: &str = "When you need the person to connect GitHub (for a repository or an \
org), call settings_ask with target connection:github, connection:github:ORG or \
connection:github:OWNER/REPO: the chat shows a Connect card in place. Do not tell them to open \
Settings.";
/// The longest `why` the card draws.
const MAX_WHY: usize = 160;

/// The targets the card draws, as the tool's description names them.
const TARGETS: &str = "connection:github, connection:github:ORG or connection:github:OWNER/REPO";

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": format!("Ask the person for one connection: the chat shows a small card under your answer with that one control, working in place (no Settings hunt). Targets: {TARGETS}. Then end your turn; the person's click connects, and they come back to this chat."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": format!("What to ask for: {TARGETS}. \"github\" and \"github:ORG\" work too.")},
                "why": {"type": "string", "description": format!("One short line on why you need it, at most {MAX_WHY} characters.")}
            },
            "required": ["target"]
        }
    })
}

/// Other names callers give each field ("eh close enough", as `wrap_up`'s ALIASES).
const ALIASES: &[(&str, &[&str])] = &[
    ("target", &["setting", "connection", "id", "key", "name"]),
    ("why", &["reason", "message", "text"]),
];

/// A GitHub account or org name as GitHub allows it: 1 to 39 letters, digits and inner dashes
/// (webviews githubConnect.ts and AgentPaneRequest+Decoding.swift check the same).
fn is_owner(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=39).contains(&bytes.len())
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'-')
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
}

/// `OWNER/REPO` as GitHub allows it (webviews githubConnect.ts `isGitHubRepo`).
fn is_repo(value: &str) -> bool {
    let Some((owner, name)) = value.split_once('/') else { return false };
    is_owner(owner)
        && (1..=100).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        && name != "."
        && name != ".."
}

/// The card's input from the call's: `{kind: "connection", provider: "github", org?, repo?, why?}`,
/// or why it is not one the card draws.
pub(super) fn check(args: &Value) -> Result<Value, String> {
    let field = |key: &str| -> Option<&str> {
        let names = ALIASES.iter().find(|(f, _)| *f == key).map_or(&[][..], |(_, n)| *n);
        std::iter::once(key).chain(names.iter().copied()).find_map(|k| {
            args.get(k).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty())
        })
    };
    let target = field("target").ok_or(format!("target is required: {TARGETS}"))?;
    let rest = target.strip_prefix("connection:").unwrap_or(target);
    let (provider, scope) = rest.split_once(':').unwrap_or((rest, ""));
    if !provider.eq_ignore_ascii_case("github") {
        return Err(format!(
            "{target} is not one the card draws yet; it draws {TARGETS}. For another setting, name its exact place in Settings in your answer."
        ));
    }
    let scope = scope.trim().trim_start_matches("https://github.com/").trim_end_matches('/');
    let mut shown = serde_json::Map::new();
    shown.insert("kind".into(), json!("connection"));
    shown.insert("provider".into(), json!("github"));
    if !scope.is_empty() {
        if is_repo(scope) {
            shown.insert("repo".into(), json!(scope));
            shown.insert("org".into(), json!(scope.split('/').next().unwrap_or_default()));
        } else if is_owner(scope) {
            shown.insert("org".into(), json!(scope));
        } else {
            return Err(format!("{scope} is not a GitHub org or OWNER/REPO; target is {TARGETS}"));
        }
    }
    if let Some(why) = field("why") {
        let kept: String = why.chars().take(MAX_WHY).collect();
        shown.insert("why".into(), json!(kept));
    }
    Ok(Value::Object(shown))
}

pub(super) fn call(args: &Value) -> Value {
    match check(args) {
        Ok(shown) => {
            let whom = shown["repo"]
                .as_str()
                .or(shown["org"].as_str())
                .map_or(String::new(), |s| format!(" for {s}"));
            ok(
                format!(
                    "A Connect GitHub card{whom} is shown to the person under your answer. End your turn now; when they connect, the chat goes on."
                ),
                shown,
            )
        }
        Err(e) => error_result(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn github_targets_name_an_org_or_a_repository() {
        assert_eq!(
            check(&json!({"target": "connection:github"})).unwrap(),
            json!({"kind": "connection", "provider": "github"})
        );
        assert_eq!(
            check(&json!({"target": "connection:github:manaflow-ai", "why": " Push needs it. "}))
                .unwrap(),
            json!({"kind": "connection", "provider": "github", "org": "manaflow-ai", "why": "Push needs it."})
        );
        assert_eq!(
            check(&json!({"connection": "github:manaflow-ai/cmux"})).unwrap(),
            json!({"kind": "connection", "provider": "github", "org": "manaflow-ai", "repo": "manaflow-ai/cmux"})
        );
        assert_eq!(check(&json!({"target": "GitHub"})).unwrap()["provider"], "github");
    }

    #[test]
    fn other_targets_and_bad_names_are_refused_with_the_way_on() {
        for bad in [
            json!({}),
            json!({"target": "setting:app.theme"}),
            json!({"target": "connection:github:-bad-"}),
            json!({"target": "connection:github:a/.."}),
        ] {
            let e = check(&bad).unwrap_err();
            assert!(e.contains("connection:github"), "{bad}: {e}");
        }
    }

    #[test]
    fn a_long_why_is_cut_never_refused() {
        let why = "x".repeat(400);
        let got = check(&json!({"target": "github", "why": why})).unwrap();
        assert_eq!(got["why"].as_str().unwrap().chars().count(), MAX_WHY);
        assert_eq!(call(&json!({"target": "github:manaflow-ai"}))["isError"], false);
    }
}
