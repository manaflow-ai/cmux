//! The reply length gate (Lawrence: "currently i think the responses are
//! generally too long"). A prompt rule alone did not move the median reply
//! (two runs each, Oct 29), so the send tool checks the length: the first
//! send of a turn over the limit is refused with its word count, and Chief
//! cuts it itself (so no fact is changed by another model); a second send
//! posts as is, so a long answer the user asked for still goes out.

use chief_kernel::replies::{REPLY_MAX_WORDS, length_check, reply_words};

#[test]
fn a_link_counts_as_its_text_not_its_url() {
    let text = "a12 landed [3e1f0a2..9b7c4d1](https://github.com/manaflow-ai/cmux/compare/3e1f0a2...9b7c4d1) on feat-cmux-next.";
    assert_eq!(reply_words(text), 5);
}

#[test]
fn a_short_reply_passes() {
    assert_eq!(
        length_check(
            "Sidebar alignment ~90%: a845 lands it.",
            REPLY_MAX_WORDS,
            false
        ),
        None
    );
}

#[test]
fn the_first_long_reply_of_a_turn_is_refused_with_its_count_then_the_second_posts() {
    let long = "word ".repeat(REPLY_MAX_WORDS + 20);
    let refusal = length_check(&long, REPLY_MAX_WORDS, false).expect("refused");
    assert!(refusal.starts_with("send: refused"), "{refusal}");
    assert!(
        refusal.contains(&format!("{} words", REPLY_MAX_WORDS + 20)),
        "{refusal}"
    );
    assert!(refusal.contains(&REPLY_MAX_WORDS.to_string()), "{refusal}");
    assert_eq!(
        length_check(&long, REPLY_MAX_WORDS, true),
        None,
        "the second send posts"
    );
}

#[test]
fn a_limit_of_zero_turns_the_gate_off() {
    assert_eq!(length_check(&"word ".repeat(500), 0, false), None);
}
