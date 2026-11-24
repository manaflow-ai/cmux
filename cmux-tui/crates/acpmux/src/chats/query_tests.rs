use std::path::PathBuf;

use cmux_chat_index::{ChatEntry, Resume};
use serde_json::json;

use super::*;

const NOW: i64 = 1_800_000_000_000;
const DAY: i64 = 86_400_000;

fn chat(harness: AdapterKind, title: &str, cwd: &str, updated_ms: i64) -> IndexedChat {
    IndexedChat {
        entry: ChatEntry {
            harness,
            session_id: title.to_owned(),
            title: Some(title.to_owned()),
            title_source: None,
            cwd: Some(cwd.to_owned()),
            created_ms: None,
            updated_ms,
            message_count: None,
            source_path: PathBuf::from(format!("/nonexistent/{title}.jsonl")),
            originator: None,
            archived: false,
            resume: Resume::ReadOnly,
        },
        accounts: Vec::new(),
        roots: Vec::new(),
    }
}

/// The titles of `chats` that `query` passes.
fn passing<'a>(query: &str, chats: &'a [IndexedChat]) -> Vec<&'a str> {
    let filter = ChatQuery::from_params_at(&json!({"query": query}), NOW).expect("query");
    chats
        .iter()
        .filter(|chat| filter.matches(chat))
        .filter_map(|chat| chat.entry.title.as_deref())
        .collect()
}

fn chats() -> Vec<IndexedChat> {
    vec![
        chat(AdapterKind::ClaudeCode, "Fix the sidebar", "/Users/leo/cmux", NOW - 3_600_000),
        chat(AdapterKind::Codex, "Sidebar draft", "/Users/leo/cmux/web", NOW - 3 * DAY),
        chat(AdapterKind::Codex, "Release notes", "/Users/leo/blog", NOW - 40 * DAY),
    ]
}

#[test]
fn words_match_in_any_order_in_the_title_or_the_folder() {
    let chats = chats();
    assert_eq!(passing("sidebar FIX", &chats), ["Fix the sidebar"]);
    assert_eq!(passing("cmux sidebar", &chats), ["Fix the sidebar", "Sidebar draft"]);
    // A phrase is its words together.
    assert_eq!(passing("\"the sidebar\"", &chats), ["Fix the sidebar"]);
    assert!(passing("\"sidebar the\"", &chats).is_empty());
}

#[test]
fn since_and_before_narrow_by_when_the_chat_was_last_used() {
    let chats = chats();
    assert_eq!(passing("since:1d", &chats), ["Fix the sidebar"]);
    assert_eq!(passing("since:1w", &chats), ["Fix the sidebar", "Sidebar draft"]);
    assert_eq!(passing("before:1w", &chats), ["Release notes"]);
    assert_eq!(passing("sidebar since:2d", &chats), ["Fix the sidebar"]);
    assert_eq!(passing("since:1mo before:1d", &chats), ["Sidebar draft"]);
}

#[test]
fn harness_folder_title_and_exclusions() {
    let chats = chats();
    assert_eq!(passing("harness:codex", &chats), ["Sidebar draft", "Release notes"]);
    assert_eq!(passing("agent:claude", &chats), ["Fix the sidebar"]);
    assert_eq!(passing("in:cmux/web", &chats), ["Sidebar draft"]);
    assert_eq!(passing("title:cmux", &chats), Vec::<&str>::new());
    assert_eq!(passing("sidebar -draft", &chats), ["Fix the sidebar"]);
    assert_eq!(passing("-cmux", &chats), ["Release notes"]);
}

#[test]
fn the_harness_param_wins_over_the_operator() {
    let params = json!({"query": "harness:codex", "harness": "claude-code"});
    let filter = ChatQuery::from_params_at(&params, NOW).expect("query");
    assert_eq!(filter.harness, Some(AdapterKind::ClaudeCode));
}
