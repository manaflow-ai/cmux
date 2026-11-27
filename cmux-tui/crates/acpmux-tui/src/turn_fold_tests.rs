use super::*;

fn transcript(items: Vec<Item>, status: &str) -> Transcript {
    let mut t = Transcript::default();
    t.items = items;
    t.status = status.into();
    t
}

#[test]
fn a_later_answered_turn_clears_the_error_card() {
    let user = |s: &str| Item::User { text: s.into(), steer: false, queued: false };
    let err = Item::Error { text: "API Error: 500".into() };
    let said = |s: &str| Item::Assistant { text: s.into() };
    let mut t = transcript(vec![user("a"), err.clone(), user("continue")], "running");
    assert!(!superseded_error(&t, 1), "the next turn is still running");
    t.items.push(said("Done."));
    assert!(!superseded_error(&t, 1), "running: not complete yet");
    t.status = "ready".into();
    assert!(superseded_error(&t, 1));
    // A later turn that failed too supersedes nothing; the latest error stays.
    let t = transcript(vec![user("a"), err.clone(), user("again"), err.clone()], "ready");
    assert!(!superseded_error(&t, 1) && !superseded_error(&t, 3));
    // A steer is not a later turn.
    let steer = Item::User { text: "s".into(), steer: true, queued: false };
    let t = transcript(vec![user("a"), err, steer, said("ok")], "ready");
    assert!(!superseded_error(&t, 1));
}

#[test]
fn short_progress_narration_folds() {
    for note in [
        "Let me check the logs.",
        "Running the tests.",
        "I'm reading `client.ts` next.",
        "Let me look. Checking the config.",
        "Both builds are still running.",
        "Checking the failed jobs.",
        "Waiting...",
    ] {
        assert!(!is_takeaway(note), "{note}");
    }
}

#[test]
fn a_finding_stays_in_sight() {
    for reply in [
        // turns.ts tests (#42279, #42466).
        "Running two tasks is faster than one.",
        "Let me check; the cache is stale.",
        "Let me check. The cache is stale.",
        "Checking the cache found no errors.",
        "Running both takes 2 s.",
        "Reading it showed the bug.",
        "The fix is in.",
        "Should I push it?",
        "- one\n- two",
        "See [the PR](https://x).",
        "First.\n\nSecond.",
        "Let me check. Then run. Then read.",
        &"x".repeat(161),
    ] {
        assert!(is_takeaway(reply), "{reply}");
    }
    assert!(!is_takeaway("   "));
}

#[test]
fn splits_sentences_like_the_gui() {
    assert_eq!(
        sentences("Let me check. The cache is stale."),
        ["Let me check", "The cache is stale"]
    );
    assert_eq!(sentences("Reading a.rs now"), ["Reading a.rs now"]);
    assert_eq!(sentences("Wait... ok!"), ["Wait", "ok"]);
}
