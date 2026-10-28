//! A subagent's transcript replayed as the updates a pane draws (`agent_transcript.rs`). The
//! lines are trimmed from a Claude Code 2.1.309 workflow agent's `agent-<id>.jsonl`.

use super::agent_transcript::replay;
use super::*;

fn lines() -> Vec<Value> {
    vec![
        json!({"type": "user", "isSidechain": true, "message": {"role": "user", "content": "Fix the typo in a.txt"}}),
        json!({"type": "assistant", "message": {"id": "msg_1", "role": "assistant", "content": [
            {"type": "text", "text": "Fixing it."},
            {"type": "tool_use", "id": "toolu_e1", "name": "Edit",
             "input": {"file_path": "/w/a.txt", "old_string": "teh", "new_string": "the"}}]}}),
        json!({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_e1", "content": "The file /w/a.txt has been updated."}]}}),
        json!({"type": "assistant", "message": {"id": "msg_2", "role": "assistant", "content": [
            {"type": "text", "text": "Done."}]}}),
    ]
}

fn kinds(updates: &[Value]) -> Vec<&str> {
    updates.iter().filter_map(|u| u["sessionUpdate"].as_str()).collect()
}

#[tokio::test]
async fn a_transcript_replays_as_its_prompt_steps_and_answer() {
    let pages = replay(&lines(), 0, true).await;
    assert_eq!(pages.len(), 4);
    assert_eq!(pages[0][0]["content"]["text"], "Fix the typo in a.txt");
    assert_eq!(kinds(&pages[0]), vec!["user_message_chunk"]);
    assert!(kinds(&pages[1]).contains(&"agent_message_chunk"), "{:?}", pages[1]);
    assert!(kinds(&pages[1]).contains(&"tool_call"), "{:?}", pages[1]);
    assert!(kinds(&pages[2]).contains(&"tool_call_update"), "{:?}", pages[2]);
    assert_eq!(pages[3][0]["content"]["text"], "Done.");
}

/// A page that starts after the call still pairs its result with it: the earlier lines are
/// replayed, and only the page's own lines answer.
#[tokio::test]
async fn a_page_keeps_what_its_earlier_lines_started() {
    let whole = replay(&lines(), 0, true).await;
    let page = replay(&lines(), 2, true).await;
    assert_eq!(page.len(), 2);
    assert_eq!(page[0], whole[2], "the result reads as it does with its call on the same page");
    assert_eq!(page[1], whole[3]);
    assert!(page.iter().flatten().all(|u| u["sessionUpdate"] != "user_message_chunk"));
}

/// Lines that do not start at the transcript's first line (a page past the replayed window, a
/// transcript read from its end) have no prompt to show.
#[tokio::test]
async fn lines_from_the_middle_have_no_prompt() {
    let pages = replay(&lines(), 0, false).await;
    assert!(pages.iter().flatten().all(|u| u["sessionUpdate"] != "user_message_chunk"));
    assert_eq!(pages[3][0]["content"]["text"], "Done.");
}
