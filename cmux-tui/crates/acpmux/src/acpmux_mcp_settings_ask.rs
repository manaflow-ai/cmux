//! The `acpmux` MCP server's `settings_ask` tool: the agent asks the person for one setting or one
//! connection, and the chat shows that one thing as a small card under the turn, live, styled like
//! the Needs you card. Leo, 2026-11-25: "what about just a simple styled consistently popover for
//! that specific setting? a la something similar to needs you or whatever". The person acts on the
//! card in place (Connect GitHub runs the app's own `accounts.githubConnect`, the same flow as
//! Settings and the failed-call card) and is never sent into Settings to hunt for it.
//!
//! Any other setting comes back as its link (Leo, ask-073fa3e7ff: "agents need to be able to easily
//! open these up say maybe in either your current focused pane or a nearby one right next to your
//! tab. just give me the link for now"): `setting:terminal/fontSize` (or `cmux://settings/...`)
//! returns `cmux://settings/terminal/fontSize`, which the agent writes in its answer; the chat draws
//! it as a link and a click opens that exact setting in the window's Settings tab (DeepLink
//! `settingsRoute`, whose shapes are its own).
//!
//! As `wrap_up` does, the tool only checks its input and says so: the call reaches the transcript
//! with its typed input, and the cmux NEXT agent pane draws the card from it (webviews
//! `conversation/settingsAsk.ts`). Nothing is sent and no daemon request is made, so it works the
//! same on every harness and host; the person's click is what acts.

use super::{error_result, ok};
use serde_json::{Value, json};

pub(super) const NAME: &str = "settings_ask";
/// What every chat with the tool is told.
/// The tool's description carries the targets; this only says to use it.
pub(super) const STEER: &str = "To get a GitHub or other service connection or any setting from the person, call \
settings_ask (a card or a link opens that one control) instead of telling them to open Settings.";
/// The longest `why` the card draws.
const MAX_WHY: usize = 160;

/// The targets the card draws, as the tool's description names them.
const TARGETS: &str = "connection:github, connection:github:ORG, connection:github:OWNER/REPO, or connection:SERVICE for a service in cmux's connections catalog (linear, sentry, notion, atlassian, vercel, slack, stripe, ...)";
/// The other targets, which come back as a link.
const LINKS: &str = "setting:SECTION or setting:SECTION/KEY (for example setting:terminal/fontSize), or a cmux://settings/... link";

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": format!("Ask the person for one connection: the chat shows a small card under your answer with that one control, working in place (no Settings hunt). Targets: {TARGETS}. Then end your turn; the person's click connects, and they come back to this chat. For any other setting, target {LINKS}: you get back its link to write in your answer, and a click opens that exact setting."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": format!("What to ask for: {TARGETS}, or {LINKS}. \"github\" and \"github:ORG\" work too.")},
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

/// A cmux connections catalog name (cmux-platform `Catalog.ts`, `[a-z0-9-]`, as webviews
/// serviceConnect.ts checks): 1 to 40 lowercase letters, digits and inner dashes.
fn is_service(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=40).contains(&bytes.len())
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
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
    let target = field("target").ok_or(format!("target is required: {TARGETS}, or {LINKS}"))?;
    if let Some(link) = setting_link(target) {
        let mut shown = serde_json::Map::new();
        shown.insert("kind".into(), json!("link"));
        shown.insert("link".into(), json!(link?));
        if let Some(why) = field("why") {
            shown.insert("why".into(), json!(why.chars().take(MAX_WHY).collect::<String>()));
        }
        return Ok(Value::Object(shown));
    }
    let prefixed = target.strip_prefix("connection:");
    let rest = prefixed.unwrap_or(target);
    let (provider, scope) = rest.split_once(':').unwrap_or((rest, ""));
    // A catalog service (`connection:linear`): the card connects it through Settings > Connections'
    // own flow. Only with the `connection:` prefix; it takes no scope.
    let service = provider.trim().to_ascii_lowercase();
    if prefixed.is_some() && service != "github" && scope.is_empty() && is_service(&service) {
        let mut shown = serde_json::Map::new();
        shown.insert("kind".into(), json!("connection"));
        shown.insert("provider".into(), json!(service));
        if let Some(why) = field("why") {
            shown.insert("why".into(), json!(why.chars().take(MAX_WHY).collect::<String>()));
        }
        return Ok(Value::Object(shown));
    }
    if !provider.eq_ignore_ascii_case("github") {
        return Err(format!(
            "{target} is not one the card draws; it draws {TARGETS}. For another setting, target {LINKS}."
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

/// The `cmux://settings` link a `setting:` target (or a settings link) names, an error for a malformed
/// one, or nil for a connection target. Segments are letters, digits and `-._~`, as the app's
/// settings links pass them on (DeepLink `settingsPassThrough`).
fn setting_link(target: &str) -> Option<Result<String, String>> {
    let lower = target.to_ascii_lowercase();
    let path =
        if let Some(rest) = lower.strip_prefix("setting:").or(lower.strip_prefix("settings:")) {
            &target[target.len() - rest.len()..]
        } else {
            let rest = ["cmux://settings", "cmux-nightly://settings", "cmux-dev://settings"]
                .iter()
                .find_map(|p| lower.strip_prefix(p))?;
            if !(rest.is_empty() || rest.starts_with('/')) {
                return None;
            }
            &target[target.len() - rest.len()..]
        };
    let segments: Vec<&str> =
        path.trim().split(['/', '>']).map(str::trim).filter(|s| !s.is_empty()).collect();
    let ok = segments.iter().all(|s| {
        s.len() <= 80
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~'))
    });
    if !ok || segments.len() > 6 {
        return Some(Err(format!(
            "{target} is not a settings place; target is {TARGETS}, or {LINKS}"
        )));
    }
    Some(Ok(if segments.is_empty() {
        "cmux://settings".into()
    } else {
        format!("cmux://settings/{}", segments.join("/"))
    }))
}

pub(super) fn call(args: &Value) -> Value {
    match check(args) {
        Ok(shown) if shown["kind"] == "link" => {
            let link = shown["link"].as_str().unwrap_or_default().to_owned();
            ok(
                format!(
                    "Write this link in your answer: {link}. The chat draws it as a link, and the person's click opens that exact setting in Settings."
                ),
                shown,
            )
        }
        Ok(shown) if shown["provider"] != "github" => {
            let service = shown["provider"].as_str().unwrap_or_default().to_owned();
            ok(
                format!(
                    "A Connect {service} card is shown to the person under your answer. End your turn now; when they connect, the chat goes on."
                ),
                shown,
            )
        }
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
    fn catalog_service_targets_name_the_service() {
        assert_eq!(
            check(&json!({"target": "connection:linear", "why": "The issue is in Linear."}))
                .unwrap(),
            json!({"kind": "connection", "provider": "linear", "why": "The issue is in Linear."})
        );
        // Lowercased, as catalog names are.
        assert_eq!(
            check(&json!({"target": "connection:Linear"})).unwrap(),
            json!({"kind": "connection", "provider": "linear"})
        );
        assert_eq!(
            check(&json!({"connection": "connection:cloudflare-docs"})).unwrap()["provider"],
            "cloudflare-docs"
        );
        for bad in [
            "connection:-bad",
            "connection:bad-",
            "connection:li near",
            "connection:linear:team",
            "linear",
        ] {
            assert!(check(&json!({"target": bad})).is_err(), "{bad}");
        }
        assert_eq!(
            check(&json!({"target": "connection:github"})).unwrap(),
            json!({"kind": "connection", "provider": "github"})
        );
        let said = call(&json!({"target": "connection:sentry"}));
        assert!(said.to_string().contains("Connect sentry card"), "{said}");
    }

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
            json!({"target": "setting:app theme"}),
            json!({"target": "ftp://settings/x"}),
            json!({"target": "connection:github:-bad-"}),
            json!({"target": "connection:github:a/.."}),
        ] {
            let e = check(&bad).unwrap_err();
            assert!(e.contains("connection:github"), "{bad}: {e}");
        }
    }

    #[test]
    fn a_setting_comes_back_as_its_link() {
        assert_eq!(
            check(&json!({"target": "setting:terminal/terminal.fontSize", "why": "Bigger text"}))
                .unwrap(),
            json!({"kind": "link", "link": "cmux://settings/terminal/terminal.fontSize", "why": "Bigger text"})
        );
        assert_eq!(
            check(&json!({"setting": "Settings: models > add"})).unwrap()["link"],
            "cmux://settings/models/add"
        );
        assert_eq!(
            check(&json!({"target": "cmux-nightly://settings/cloud/claude"})).unwrap()["link"],
            "cmux://settings/cloud/claude"
        );
        assert_eq!(
            check(&json!({"target": "cmux://settings"})).unwrap()["link"],
            "cmux://settings"
        );
        let said = call(&json!({"target": "setting:accounts/machines"}));
        assert_eq!(said["isError"], false);
        assert!(said.to_string().contains("cmux://settings/accounts/machines"), "{said}");
    }

    #[test]
    fn a_long_why_is_cut_never_refused() {
        let why = "x".repeat(400);
        let got = check(&json!({"target": "github", "why": why})).unwrap();
        assert_eq!(got["why"].as_str().unwrap().chars().count(), MAX_WHY);
        assert_eq!(call(&json!({"target": "github:manaflow-ai"}))["isError"], false);
    }
}
