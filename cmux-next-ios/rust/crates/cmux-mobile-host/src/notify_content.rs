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

/// At most this many questions, options and last lines travel.
pub const MAX_QUESTIONS: usize = 4;
pub const MAX_OPTIONS: usize = 6;
pub const MAX_TAIL: usize = 6;

/// The questions of an ask (`_acpmux/permission_pending` `request`); empty for a plain permission.
pub fn questions(_request: &Value) -> Vec<NotifyQuestion> {
    Vec::new()
}

/// The acpmux options of a permission request.
pub fn permission_options(_request: &Value) -> Vec<NotifyOption> {
    Vec::new()
}

/// The last non-empty lines of `text`, each cleaned and cut.
pub fn tail(_text: &str) -> Vec<String> {
    Vec::new()
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
    /// From a `list-workspaces` reply.
    pub fn from_workspaces(_reply: &Value) -> Self {
        Self::default()
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
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures");
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
        assert_eq!(multi[0].options.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(), ["macOS", "iOS", "Linux", "Web"]);

        let four = questions(&fixture("pending-4-questions"));
        assert_eq!(four.len(), 4);
    }

    #[test]
    fn codex_questions_keep_free_text() {
        let codex = questions(&fixture("codex-user-input"));
        assert_eq!(codex.len(), 2);
        assert_eq!(codex[0].question, "Which database should the service use?");
        assert_eq!(codex[0].header.as_deref(), Some("Database"));
        assert_eq!(codex[0].options, [
            choice("Postgres", Some("Managed Postgres with point-in-time restore.")),
            choice("SQLite", Some("One file next to the service.")),
        ]);
        assert!(codex[0].allows_other);
        // No options: free text only.
        assert!(codex[1].options.is_empty() && codex[1].allows_other);
    }

    #[test]
    fn acpmux_normalized_and_interactive_questions() {
        let chief = questions(&fixture("chief-asks"));
        assert_eq!(chief[0].question, "Two agents finished. Merge both branches into feat-cmux-next now?");
        assert_eq!(chief[0].header.as_deref(), Some("Deploy"));
        assert_eq!(chief[0].options[0], choice("Merge both", Some("Runs the gates on the merged head first.")));
        // An interactive request: its permission options are the choices, no free text.
        let interactive = questions(&fixture("acp-interactive"));
        assert_eq!(interactive.len(), 1);
        assert_eq!(interactive[0].question, "Continue with the migration on the staging branch?");
        assert_eq!(interactive[0].options.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(), ["Proceed", "Dry run first", "Stop"]);
        assert!(!interactive[0].allows_other);
        // A plain permission is no question.
        assert!(questions(&json!({"toolCall":{"title":"rm -rf build"},"options":[{"optionId":"a","name":"Allow","kind":"allow_once"}]})).is_empty());
    }

    #[test]
    fn questions_and_options_are_cut_to_the_limits() {
        let many: Vec<Value> = (0..9).map(|i| json!({"label": format!("opt {i}\u{202e}"), "description": "d".repeat(500)})).collect();
        let qs: Vec<Value> = (0..7).map(|i| json!({"question": format!("q{i} {}", "x".repeat(400)), "header": "h".repeat(80), "options": many})).collect();
        let parsed = questions(&json!({"toolCall":{"_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":qs}}}));
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
        assert_eq!(permission_options(&request), [
            NotifyOption { id: "allow".into(), label: "Allow once".into(), kind: Some("allow_once".into()) },
            NotifyOption { id: "always".into(), label: "Always allow".into(), kind: Some("allow_always".into()) },
            NotifyOption { id: "deny".into(), label: "Deny".into(), kind: Some("reject_once".into()) },
        ]);
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
        let terminal = Place { workspace_id: "ws_a".into(), workspace: "cmux-next".into(), tab_id: "s7".into(), terminal: true };
        assert_eq!(map.surfaces.get(&7), Some(&terminal));
        assert_eq!(map.sessions.get("sess1").map(|p| (p.tab_id.as_str(), p.terminal)), Some(("s8", false)));
        assert_eq!(map.surfaces.get(&9).map(|p| p.terminal), Some(false));
        // A workspace without a key is `w<id>`, and an untitled one takes its name.
        assert_eq!(map.surfaces.get(&11).map(|p| (p.workspace_id.as_str(), p.workspace.as_str(), p.terminal)), Some(("w4", "Home", true)));
        // A dead terminal still names its place (Restart Shell keeps it).
        assert!(map.surfaces.contains_key(&10));
    }
}
