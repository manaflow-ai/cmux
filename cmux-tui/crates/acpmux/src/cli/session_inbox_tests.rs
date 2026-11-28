use super::*;

#[test]
fn describe_lists_threads_and_messages() {
    assert_eq!(describe(&json!({"threads": []})), "The inbox is empty.");
    let threads = json!({"threads": [{"threadId": "pr:12", "label": "#12", "class": "action", "unread": 2, "count": 3, "from": ["lane-a", "lane-b"], "newestPreview": "merged"}]});
    assert_eq!(
        describe(&threads),
        "#12 (action): 2 unread of 3, from lane-a, lane-b; newest: merged [thread pr:12]"
    );
    let thread = json!({"threadId": "pr:12", "label": "#12", "messages": [{"kind": "blocker", "from": "lane-a", "promptId": "p1", "text": "rebase"}]});
    assert_eq!(
        describe(&thread),
        "Thread #12 (pr:12), newest first:\n\n[blocker] from lane-a, promptId p1:\nrebase"
    );
}
