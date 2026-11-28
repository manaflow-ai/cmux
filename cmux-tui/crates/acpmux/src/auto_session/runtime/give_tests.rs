use super::*;

#[test]
fn a_move_that_did_not_happen_is_told_in_plain_words() {
    let stuck = not_moved_text(MoveTo::Cloud, Declined::Stuck);
    assert!(stuck.starts_with("This chat was not moved to the Cloud: the turn"), "{stuck}");
    let refused = not_moved_text(MoveTo::Local, Declined::Refused);
    assert!(refused.contains("your computer") && refused.contains("standing by"), "{refused}");
    for text in [stuck, refused, not_moved_text(MoveTo::Cloud, Declined::TooLarge)] {
        for word in ["lease", "epoch", "give", "wish", "auto."] {
            assert!(!text.contains(word), "{text}");
        }
    }
}
