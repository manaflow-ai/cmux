use super::*;

/// `acpmux wait` names what a session waits on the person for. An agent's
/// question (AskUserQuestion, a Codex user-input request) reaches acpmux as a
/// permission request, but it is never shown as one (Leo 2026-10-21).
#[test]
fn a_waiting_question_is_never_shown_as_a_permission() {
    let question = json!({
        "status": "waiting", "pendingPermissions": 1,
        "waitingOn": "question", "waitingPrompt": "Which database should I use?",
    });
    let line = wait_state(&question);
    assert!(!line.contains("permission"), "{line}");
    assert_eq!(line, "asks a question: Which database should I use?");
    let untitled = json!({"status": "waiting", "pendingPermissions": 1, "waitingOn": "question"});
    assert_eq!(wait_state(&untitled), "asks a question");
    assert_eq!(wait_notice("lane", &question), "lane asks a question");
}

#[test]
fn a_tool_permission_and_a_finished_session_read_as_before() {
    let permission =
        json!({"status": "waiting", "pendingPermissions": 2, "waitingOn": "permission"});
    assert_eq!(wait_state(&permission), "waiting for permission (2)");
    assert_eq!(wait_notice("lane", &permission), "lane needs a permission");
    let idle = json!({"status": "idle", "pendingPermissions": 0});
    assert_eq!(wait_state(&idle), "idle");
    assert_eq!(wait_notice("lane", &idle), "lane finished");
}
