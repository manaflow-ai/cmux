use super::*;
#[tokio::test]
async fn cloud_repo_missing_or_foreign_caller_never_invokes_cli() {
    for caller in [None, Some("other-chat")] {
        for tool in ["list_repos", "add_repo"] {
            let result = call_for_caller(
                caller,
                "own-chat",
                &json!({"name":tool,"arguments":{"repo":"org/repo"}}),
                |_, _| async { panic!("unauthenticated caller reached the CLI") },
            )
            .await;
            assert_eq!(result["isError"], true);
            assert!(
                result["content"][0]["text"].as_str().unwrap().contains("Restart the chat session")
            );
        }
    }
}

#[tokio::test]
async fn cloud_repo_proven_caller_uses_protected_session() {
    let result = call_for_caller(
        Some("own-chat"),
        "own-chat",
        &json!({"name":"add_repo","arguments":{"repo":"org/repo","session":"other-chat"}}),
        |action, request| async move {
            assert_eq!(action, REPO_ADD_ACTION);
            assert_eq!(request["session"], "own-chat");
            Ok(json!({"state":"done","repo":"org/repo","folder":"/home/chats/own-chat/repo"}))
        },
    )
    .await;
    assert_eq!(result["isError"], false);
}

#[test]
fn instructions_state_the_machine_and_its_lifetime() {
    for fact in [
        "Linux virtual machine",
        "until the machine is deleted",
        "push work",
        "no repository",
        "add_repo",
    ] {
        assert!(INSTRUCTIONS.contains(fact), "instructions lack {fact:?}");
    }
}

#[test]
fn retry_shape_is_stable() {
    let mut result = json!({"code":"repo.needs_github","message":"Connect GitHub."});
    enrich_retry(&mut result, "chat-1", "cmux-platform", Some(&json!("main")));
    assert_eq!(result["retry"]["action"], REPO_ADD_ACTION);
    assert_eq!(
        result["retry"]["args"],
        json!({"session":"chat-1","repo":"cmux-platform","ref":"main"})
    );
}
#[test]
fn no_access_retries_the_add_with_no_wait() {
    let mut result = json!({"code":"repo.no_access","org":"acme"});
    enrich_retry(&mut result, "chat-1", "acme/tool", None);
    assert_eq!(
        result["retry"],
        json!({"action": REPO_ADD_ACTION, "args": {"session":"chat-1","repo":"acme/tool"}})
    );
}
#[test]
fn other_errors_are_not_retried() {
    let mut result = json!({"code":"repo.not_found"});
    enrich_retry(&mut result, "chat", "x", None);
    assert!(result.get("retry").is_none());
}
