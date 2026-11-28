use super::*;

fn refusal(code: &str) -> AutoCloudError {
    AutoCloudError::http(409, code, "refused")
}

/// The error's `data.reason`.
fn reason(error: &RpcError) -> Option<&str> {
    error.data.as_ref()?.get("reason")?.as_str()
}

#[test]
fn a_refused_move_reads_as_one_plain_sentence_with_the_stores_code() {
    let cases = [
        ("auto.no_machine", MoveTo::Cloud, "there is no Cloud machine"),
        ("auto.no_laptop", MoveTo::Local, "this computer is not ready"),
        ("auto.not_copied", MoveTo::Cloud, "does not have a copy"),
    ];
    for (code, to, words) in cases {
        let error = move_error(&refusal(code), to);
        assert!(error.message.starts_with("This chat was not moved to "), "{}", error.message);
        assert!(error.message.contains(words), "{}", error.message);
        assert!(error.message.ends_with("It stays where it is."), "{}", error.message);
        assert_eq!(reason(&error), Some(code));
        for word in ["lease", "epoch", "give", "wish", "auto."] {
            assert!(!error.message.contains(word), "{}", error.message);
        }
    }
    let off = move_error(&refusal("auto.off"), MoveTo::Cloud);
    assert!(off.message.contains("runs on this computer only"), "{}", off.message);
    let silent = move_error(&AutoCloudError::transport("no network"), MoveTo::Local);
    assert!(silent.message.contains("did not answer"), "{}", silent.message);
    assert_eq!(reason(&silent), Some("auto.unreachable"));
}

#[test]
fn a_chat_the_cloud_has_not_answered_for_is_not_moved_and_can_be_asked_again() {
    let error = HolderHandle::cloud_did_not_answer();
    assert_eq!(
        error.message,
        "This chat was not moved to the Cloud: the Cloud did not answer; try again. It stays \
             where it is."
    );
    assert_eq!(reason(&error), Some("auto.unreachable"));
    let retryable = error.data.as_ref().and_then(|data| data.get("retryable"));
    assert_eq!(retryable, Some(&json!(true)));
    assert!(!error.message.contains("Set it to Auto or Cloud"), "{}", error.message);
}
