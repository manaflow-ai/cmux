use super::*;

#[test]
fn search_text_prints_each_chat_with_its_snippet_and_what_was_left_out() {
    let found = json!({"ready": true, "enabled": true, "unreadable": 1,
        "nextCursor": "k1.2", "hits": [
        {"chat": {"key": "codex:a", "title": "Bump\nit"}, "role": "answer", "snippet": "…to 1.2…"},
        {"chat": {"key": "claude-code:b", "title": null}, "role": "prompt", "snippet": "bump"},
    ]});
    assert_eq!(
        search_text(&found),
        "codex:a  Bump it\n    answer: …to 1.2…\nclaude-code:b  (untitled)\n    prompt: bump\n\
             (1 chats could not be read)\n(the first 2 found; raise --limit for more)\n"
    );
    let none = json!({"ready": true, "enabled": true, "hits": [], "nextCursor": null});
    assert_eq!(search_text(&none), "no chat says that\n");
}
