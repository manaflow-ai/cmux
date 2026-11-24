use super::*;
use std::path::Path;

fn all_facts() -> Vec<Facts> {
    (0u8..8)
        .map(|bits| Facts {
            forks: bits & 1 != 0,
            turn_before: bits & 2 != 0,
            steer: bits & 4 != 0,
        })
        .collect()
}

/// Leo's screenshot: a prompt the agent has read, its turn running, offered Edit. Read offers no
/// edit of any kind, whatever the chat can fork.
#[test]
fn a_read_prompt_never_edits() {
    for facts in all_facts() {
        let shown = actions(Stage::Read, facts);
        assert!(!shown.contains(&Action::EditAndResend), "{facts:?}");
        assert!(!shown.contains(&Action::EditInPlace), "{facts:?}");
        assert!(!shown.contains(&Action::Cancel), "{facts:?}");
    }
}

/// The ✕ shows only while nothing has read the prompt.
#[test]
fn cancel_only_before_anything_read_it() {
    for stage in STAGES {
        for facts in all_facts() {
            if actions(stage, facts).contains(&Action::Cancel) {
                assert!(matches!(stage, Stage::Queued | Stage::SteerWaiting), "{stage:?}");
            }
        }
    }
}

/// Edit in place only where the prompt waits unread (or never got there); edit and resend only
/// after its turn ended, with a turn before it, never for a steer.
#[test]
fn edit_means_what_it_says() {
    for stage in STAGES {
        for facts in all_facts() {
            let shown = actions(stage, facts);
            if shown.contains(&Action::EditInPlace) {
                assert!(matches!(stage, Stage::Queued | Stage::Failed), "{stage:?}");
            }
            if shown.contains(&Action::EditAndResend) {
                assert_eq!(stage, Stage::Answered);
                assert!(facts.forks && facts.turn_before && !facts.steer, "{facts:?}");
            }
        }
    }
    let answered = Facts { forks: true, turn_before: true, steer: false };
    assert!(actions(Stage::Answered, answered).contains(&Action::EditAndResend));
}

/// No stage offers an action twice, and no stage offers both kinds of edit.
#[test]
fn each_stage_offers_one_edit_at_most() {
    for stage in STAGES {
        for facts in all_facts() {
            let shown = actions(stage, facts);
            let mut seen = shown.clone();
            seen.dedup();
            assert_eq!(seen.len(), shown.len(), "{stage:?}");
            assert!(
                !(shown.contains(&Action::EditInPlace) && shown.contains(&Action::EditAndResend))
            );
        }
    }
}

/// Answered is the end; every other stage after the composer can be reached from it.
#[test]
fn every_stage_is_reachable() {
    let mut reached = vec![Stage::Composing];
    let mut at = 0;
    while let Some(stage) = reached.get(at).copied() {
        for to in next(stage) {
            if !reached.contains(to) {
                reached.push(*to);
            }
        }
        at += 1;
    }
    for stage in STAGES {
        assert!(reached.contains(&stage) || stage == Stage::HeldInInbox, "{stage:?} unreachable");
    }
    assert!(next(Stage::Answered).is_empty());
}

/// `prompt_lifecycle.json` is this table: the agent pane's test reads it.
#[test]
fn prompt_lifecycle_json_is_the_table() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("prompt_lifecycle.json");
    let want = format!("{}\n", serde_json::to_string_pretty(&table()).unwrap_or_default());
    if std::env::var_os("BLESS").is_some() {
        std::fs::write(&path, &want).unwrap_or_default();
    }
    let have = std::fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(
        have, want,
        "prompt_lifecycle.json is stale: BLESS=1 cargo test -p acpmux-core prompt_lifecycle"
    );
}
