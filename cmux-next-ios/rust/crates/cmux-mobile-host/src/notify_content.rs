//! What a push carries so a person can act on it from the notification
//! (PROTOCOL.md "Push notifications (API 0.13.0)"): an ask's questions and
//! options, the session's last lines, and where the session or terminal is
//! (its workspace and tab, from the daemon's `list-workspaces`).
//!
//! Questions mirror `Packages/Shared/CmuxAgentQuestion` (`AgentQuestion+Permission.swift`),
//! the parser the phone's Feed uses, shape for shape.

use std::collections::HashMap;
use std::sync::Mutex;

use cmux_mobile_link::api::{NotifyChoice, NotifyOption, NotifyQuestion};
use serde_json::Value;

use crate::notify::{label, text_label, valid_id};

/// At most this many questions, options and last lines travel.
pub const MAX_QUESTIONS: usize = 4;
pub const MAX_OPTIONS: usize = 6;
pub const MAX_TAIL: usize = 6;

/// Per-field limits (code points), as the Worker cuts them.
const QUESTION_MAX: usize = 200;
const HEADER_MAX: usize = 30;
const CHOICE_MAX: usize = 60;
const DESCRIPTION_MAX: usize = 120;
const LINE_MAX: usize = 160;

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str).filter(|t| !t.trim().is_empty())
}

fn cut(value: &Value, key: &str, max: usize) -> Option<String> {
    text(value, key).map(|t| label(t, max)).filter(|t| !t.is_empty())
}

/// Text a person reads (a question, a description, a title): redacted too.
/// Option labels stay `cut`: the phone matches them against the Mac's own.
fn cut_text(value: &Value, key: &str, max: usize) -> Option<String> {
    text(value, key).map(|t| text_label(t, max)).filter(|t| !t.is_empty())
}

fn choices(options: Option<&Value>, label_key: &str, detail_key: &str) -> Vec<NotifyChoice> {
    options
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|o| {
            Some(NotifyChoice {
                label: cut(o, label_key, CHOICE_MAX)?,
                description: cut_text(o, detail_key, DESCRIPTION_MAX),
            })
        })
        .take(MAX_OPTIONS)
        .collect()
}

/// The questions of an ask (`_acpmux/permission_pending` `request`); empty for a plain permission.
/// Precedence as the phone's parser: acpmux's normalized question, Claude Code's
/// AskUserQuestion, a Codex user-input request, then an interactive request whose
/// permission options are the choices.
pub fn questions(request: &Value) -> Vec<NotifyQuestion> {
    let tool_call = request.get("toolCall").unwrap_or(&Value::Null);
    let items = tool_call.pointer("/_meta/acpmux/question/items").and_then(Value::as_array);
    if let Some(items) = items.filter(|i| !i.is_empty()) {
        let parsed: Vec<_> = items
            .iter()
            .filter_map(|item| {
                Some(NotifyQuestion {
                    question: cut_text(item, "prompt", QUESTION_MAX)?,
                    header: cut(item, "header", HEADER_MAX),
                    multi_select: item.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
                    allows_other: item.get("allowsOther").and_then(Value::as_bool).unwrap_or(true),
                    options: choices(item.get("options"), "label", "detail"),
                })
            })
            .take(MAX_QUESTIONS)
            .collect();
        if !parsed.is_empty() {
            return parsed;
        }
    }
    let raw = tool_call.pointer("/rawInput/questions").and_then(Value::as_array).cloned().unwrap_or_default();
    let claude = tool_call.pointer("/_meta/claude/tool").and_then(Value::as_str) == Some("AskUserQuestion");
    let codex = tool_call.pointer("/_meta/codex").is_some() || raw.iter().any(|q| text(q, "id").is_some());
    if claude || (!raw.is_empty() && !codex) {
        return raw
            .iter()
            .filter_map(|q| {
                Some(NotifyQuestion {
                    question: cut_text(q, "question", QUESTION_MAX)?,
                    header: cut(q, "header", HEADER_MAX),
                    multi_select: q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
                    allows_other: true,
                    options: choices(q.get("options"), "label", "description"),
                })
            })
            .take(MAX_QUESTIONS)
            .collect();
    }
    if codex {
        return raw
            .iter()
            .filter_map(|q| {
                let options = choices(q.get("options"), "label", "description");
                let other = q.get("isOther").and_then(Value::as_bool).unwrap_or(options.is_empty());
                Some(NotifyQuestion {
                    question: cut_text(q, "question", QUESTION_MAX)?,
                    header: cut(q, "header", HEADER_MAX),
                    multi_select: q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
                    allows_other: other || options.is_empty(),
                    options,
                })
            })
            .take(MAX_QUESTIONS)
            .collect();
    }
    let interactive = tool_call.pointer("/_meta/acpmux/interactive").and_then(Value::as_bool) == Some(true)
        || tool_call.pointer("/_meta/claude/interactive").and_then(Value::as_bool) == Some(true);
    let options = permission_options(request);
    if !interactive || options.is_empty() {
        return Vec::new();
    }
    vec![NotifyQuestion {
        question: cut_text(tool_call, "title", QUESTION_MAX).unwrap_or_default(),
        header: None,
        multi_select: false,
        allows_other: false,
        options: options.into_iter().map(|o| NotifyChoice { label: o.label, description: None }).collect(),
    }]
}

/// The acpmux options of a permission request.
pub fn permission_options(request: &Value) -> Vec<NotifyOption> {
    request
        .get("options")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|o| {
            // An id the Worker would refuse is dropped, never changed: the
            // phone answers with it, and acpmux must know it.
            let id = valid_id(text(o, "optionId")?, 64)?;
            Some(NotifyOption {
                label: cut(o, "name", CHOICE_MAX).unwrap_or_else(|| label(&id, CHOICE_MAX)),
                kind: text(o, "kind").map(|k| label(k, 32)),
                id,
            })
        })
        .take(MAX_OPTIONS)
        .collect()
}

/// The last non-empty lines of `text`, each cleaned and cut.
pub fn tail(text: &str) -> Vec<String> {
    let lines: Vec<String> =
        text.lines().map(|l| text_label(l, LINE_MAX)).filter(|l| !l.is_empty()).collect();
    lines[lines.len().saturating_sub(MAX_TAIL)..].to_vec()
}

/// Where a tab is: its workspace and the phone's tab id.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Place {
    pub workspace_id: String,
    pub workspace: String,
    pub tab_id: String,
    /// A terminal tab (`pty`, `remote-terminal`), not an agent chat or a page.
    pub terminal: bool,
}

/// The daemon's tabs by acpmux session (agent chat tabs) and by surface.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PlaceMap {
    pub sessions: HashMap<String, Place>,
    pub surfaces: HashMap<u64, Place>,
}

impl PlaceMap {
    /// From a `list-workspaces` reply (the phone's `DaemonTree` reads the same
    /// shape: a workspace is its `key`, else `w<id>`; its title, else its name).
    pub fn from_workspaces(reply: &Value) -> Self {
        let mut map = Self::default();
        let data = reply.get("data").unwrap_or(reply);
        let empty = Vec::new();
        let list = |v: &Value, key: &str| v.get(key).and_then(Value::as_array).unwrap_or(&empty).clone();
        for ws in list(data, "workspaces") {
            let Some(id) = text(&ws, "key")
                .map(str::to_owned)
                .or_else(|| ws.get("id").and_then(Value::as_u64).map(|n| format!("w{n}")))
            else {
                continue;
            };
            let title =
                cut(&ws, "title", 60).or_else(|| cut(&ws, "name", 60)).unwrap_or_else(|| "Workspace".into());
            for screen in list(&ws, "screens") {
                for pane in list(&screen, "panes") {
                    for tab in list(&pane, "tabs") {
                        let Some(surface) = tab.get("surface").and_then(Value::as_u64) else { continue };
                        let kind = tab.get("kind").and_then(Value::as_str).unwrap_or("");
                        let place = Place {
                            workspace_id: id.clone(),
                            workspace: title.clone(),
                            tab_id: format!("s{surface}"),
                            terminal: matches!(kind, "pty" | "remote-terminal"),
                        };
                        if let Some(session) =
                            tab.pointer("/conversation/agent_session/session").and_then(Value::as_str)
                        {
                            map.sessions.insert(session.to_owned(), place.clone());
                        }
                        map.surfaces.insert(surface, place);
                    }
                }
            }
        }
        map
    }
}

/// The latest `PlaceMap`, shared by the acpmux and terminal notifiers.
#[derive(Debug, Default)]
pub struct Places(Mutex<PlaceMap>);

impl Places {
    pub fn set(&self, map: PlaceMap) {
        *self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = map;
    }

    pub fn session(&self, session_id: &str) -> Option<Place> {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).sessions.get(session_id).cloned()
    }

    /// Whether a daemon event's `surface` (if any) has a known place.
    pub fn has_surface(&self, event: &Value) -> bool {
        event.get("surface").and_then(Value::as_u64).is_none_or(|s| self.surface(s).is_some())
    }

    pub fn surface(&self, surface: u64) -> Option<Place> {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).surfaces.get(&surface).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The phone's own question fixtures (CmuxAgentQuestion), so both sides read the same shapes.
    fn fixture(name: &str) -> Value {
        let dir = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures"
        );
        let text = std::fs::read_to_string(format!("{dir}/{name}.request.json")).unwrap();
        serde_json::from_str::<Value>(&text).unwrap()["request"].clone()
    }

    fn choice(label: &str, description: Option<&str>) -> NotifyChoice {
        NotifyChoice { label: label.into(), description: description.map(Into::into) }
    }

    #[test]
    fn claude_single_and_multi_select_questions() {
        let single = questions(&fixture("pending-single"));
        assert_eq!(single.len(), 1);
        assert_eq!(single[0].question, "Which auth method should the API use?");
        assert_eq!(single[0].header.as_deref(), Some("Auth method"));
        assert!(!single[0].multi_select && single[0].allows_other);
        assert_eq!(single[0].options[0].label, "OAuth 2.0");
        assert!(single[0].options[0].description.as_deref().unwrap().starts_with("Delegated sign-in"));

        let multi = questions(&fixture("pending-multi"));
        assert!(multi[0].multi_select);
        assert_eq!(
            multi[0].options.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(),
            ["macOS", "iOS", "Linux", "Web"]
        );

        let four = questions(&fixture("pending-4-questions"));
        assert_eq!(four.len(), 4);
    }

    #[test]
    fn codex_questions_keep_free_text() {
        let codex = questions(&fixture("codex-user-input"));
        assert_eq!(codex.len(), 2);
        assert_eq!(codex[0].question, "Which database should the service use?");
        assert_eq!(codex[0].header.as_deref(), Some("Database"));
        assert_eq!(
            codex[0].options,
            [
                choice("Postgres", Some("Managed Postgres with point-in-time restore.")),
                choice("SQLite", Some("One file next to the service.")),
            ]
        );
        assert!(codex[0].allows_other);
        // No options: free text only.
        assert!(codex[1].options.is_empty() && codex[1].allows_other);
    }

    #[test]
    fn acpmux_normalized_and_interactive_questions() {
        let chief = questions(&fixture("chief-asks"));
        assert_eq!(chief[0].question, "Two agents finished. Merge both branches into feat-cmux-next now?");
        assert_eq!(chief[0].header.as_deref(), Some("Deploy"));
        assert_eq!(
            chief[0].options[0],
            choice("Merge both", Some("Runs the gates on the merged head first."))
        );
        // An interactive request: its permission options are the choices, no free text.
        let interactive = questions(&fixture("acp-interactive"));
        assert_eq!(interactive.len(), 1);
        assert_eq!(interactive[0].question, "Continue with the migration on the staging branch?");
        assert_eq!(
            interactive[0].options.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(),
            ["Proceed", "Dry run first", "Stop"]
        );
        assert!(!interactive[0].allows_other);
        // A plain permission is no question.
        assert!(questions(&json!({"toolCall":{"title":"rm -rf build"},"options":[{"optionId":"a","name":"Allow","kind":"allow_once"}]})).is_empty());
    }

    #[test]
    fn questions_and_options_are_cut_to_the_limits() {
        let many: Vec<Value> = (0..9)
            .map(|i| json!({"label": format!("opt {i}\u{202e}"), "description": "d".repeat(500)}))
            .collect();
        let qs: Vec<Value> = (0..7).map(|i| json!({"question": format!("q{i} {}", "x".repeat(400)), "header": "h".repeat(80), "options": many})).collect();
        let parsed = questions(
            &json!({"toolCall":{"_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":qs}}}),
        );
        assert_eq!(parsed.len(), MAX_QUESTIONS);
        assert_eq!(parsed[0].options.len(), MAX_OPTIONS);
        assert_eq!(parsed[0].question.chars().count(), 200);
        assert_eq!(parsed[0].header.as_deref().unwrap().chars().count(), 30);
        assert_eq!(parsed[0].options[0].label, "opt 0");
        assert_eq!(parsed[0].options[0].description.as_deref().unwrap().chars().count(), 120);
    }

    #[test]
    fn permission_options_keep_ids_and_kinds() {
        let request = json!({"options":[
            {"optionId":"allow","name":"Allow once","kind":"allow_once"},
            {"optionId":"always","name":"Always allow","kind":"allow_always"},
            {"optionId":"deny","name":"Deny","kind":"reject_once"},
            {"name":"no id"}
        ]});
        assert_eq!(
            permission_options(&request),
            [
                NotifyOption {
                    id: "allow".into(),
                    label: "Allow once".into(),
                    kind: Some("allow_once".into())
                },
                NotifyOption {
                    id: "always".into(),
                    label: "Always allow".into(),
                    kind: Some("allow_always".into())
                },
                NotifyOption { id: "deny".into(), label: "Deny".into(), kind: Some("reject_once".into()) },
            ]
        );
        // A missing name reads as its id.
        assert_eq!(permission_options(&json!({"options":[{"optionId":"x"}]}))[0].label, "x");
    }

    #[test]
    fn tail_is_the_last_lines() {
        let text = "one\n\n  two  \nthree\nfour\nfive\nsix\nseven\u{0007}\n";
        assert_eq!(tail(text), ["two", "three", "four", "five", "six", "seven"]);
        assert_eq!(tail(&"y".repeat(400))[0].chars().count(), 160);
        assert!(tail(" \n ").is_empty());
    }

    #[test]
    fn places_from_the_daemon_tree() {
        let reply = json!({"ok":true,"data":{"workspaces":[
            {"key":"ws_a","title":"cmux-next","name":"ws","screens":[{"panes":[{"id":1,"tabs":[
                {"surface":7,"kind":"pty","cwd":"/Users/me/secret"},
                {"surface":8,"kind":"conversation","conversation":{"agent_session":{"session":"sess1","harness":"claude"}}},
                {"surface":9,"kind":"browser","url":"https://x"},
                {"surface":10,"kind":"pty","dead":true}
            ]}]}]},
            {"id":4,"name":"Home","kind":"home","screens":[{"panes":[{"tabs":[{"surface":11,"kind":"remote-terminal"}]}]}]}
        ]}});
        let map = PlaceMap::from_workspaces(&reply);
        let terminal = Place {
            workspace_id: "ws_a".into(),
            workspace: "cmux-next".into(),
            tab_id: "s7".into(),
            terminal: true,
        };
        assert_eq!(map.surfaces.get(&7), Some(&terminal));
        assert_eq!(map.sessions.get("sess1").map(|p| (p.tab_id.as_str(), p.terminal)), Some(("s8", false)));
        assert_eq!(map.surfaces.get(&9).map(|p| p.terminal), Some(false));
        // A workspace without a key is `w<id>`, and an untitled one takes its name.
        assert_eq!(
            map.surfaces.get(&11).map(|p| (p.workspace_id.as_str(), p.workspace.as_str(), p.terminal)),
            Some(("w4", "Home", true))
        );
        // A dead terminal still names its place (Restart Shell keeps it).
        assert!(map.surfaces.contains_key(&10));
    }
}
