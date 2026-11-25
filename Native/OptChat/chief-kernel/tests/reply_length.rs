//! The reply length gate (Lawrence: "currently i think the responses are
//! generally too long"). A prompt rule alone did not move the median reply
//! (two runs each, Oct 29), so the send tool keeps replies short by splitting
//! them at safe boundaries. An answer the user asked to be long still goes
//! out as one message with `long: true`.

use chief_kernel::replies::{REPLY_MAX_WORDS, length_check, reply_words, split_reply};

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

#[test]
fn an_over_limit_reply_splits_at_sentences() {
    let text = "First point is complete. Second point is complete. Third point is complete.";
    let parts = split_reply(text, 5);
    assert_eq!(
        parts,
        vec![
            "First point is complete.",
            "Second point is complete.",
            "Third point is complete."
        ]
    );
    assert!(parts.iter().all(|part| reply_words(part) <= 5));
}

#[test]
fn a_split_never_breaks_links_or_fenced_code() {
    let text = "The [release note v1.2](https://example.com/a.b) is ready. ```\nfirst line\nsecond line\n``` The follow-up is ready.";
    let parts = split_reply(text, 8);
    assert!(
        parts
            .iter()
            .all(|part| !part.contains("https://example.com/a.b")
                || part.contains("[release note](https://example.com/a.b)"))
    );
    assert!(
        parts
            .iter()
            .any(|part| part.contains("```\nfirst line\nsecond line\n```"))
    );
}

#[test]
fn a_split_keeps_longer_and_tilde_fences_closed() {
    let text = "Intro sentence.\n``````\ncode. Still code.\n```\nstill code.\n``````\nAfter sentence.\n~~~~~\ntilde code.\n~~~\nstill tilde code.\n~~~~~\nFinal sentence.";
    let parts = split_reply(text, 3);
    assert!(
        parts
            .iter()
            .any(|part| part.contains("``````\ncode. Still code.\n```\nstill code.\n``````"))
    );
    assert!(
        parts
            .iter()
            .any(|part| part.contains("~~~~~\ntilde code.\n~~~\nstill tilde code.\n~~~~~"))
    );
}

#[test]
fn a_split_keeps_link_titles_with_sentence_punctuation() {
    let text = "Read [the guide](https://example.com \"First. More details\"). Then continue here.";
    let parts = split_reply(text, 4);
    assert!(
        parts
            .iter()
            .any(|part| part.contains("[the guide](https://example.com \"First. More details\")"))
    );
}

#[test]
fn a_split_keeps_list_items_together() {
    let text = "- first task is done.\n- second task is done.\n- third task is done.";
    let parts = split_reply(text, 20);
    assert_eq!(parts, vec![text]);
    assert!(parts[0].lines().all(|line| !line.trim().is_empty()));
}

#[test]
fn a_long_list_groups_items_without_crossing_the_message_limit() {
    let text = (0..6)
        .map(|n| format!("- task {n} is complete with its checks and review evidence."))
        .collect::<Vec<_>>()
        .join("\n");
    let parts = split_reply(&text, REPLY_MAX_WORDS);
    assert!(
        parts.len() > 1,
        "the list should use several messages: {parts:?}"
    );
    assert!(
        parts
            .iter()
            .all(|part| reply_words(part) <= REPLY_MAX_WORDS)
    );
    let joined = parts.join("\n");
    assert_eq!(joined, text, "list markers and item order stay intact");
}

// Nov 12-19 on Lawrence's Chief: 112 sends refused, most of them a status
// list (one short line per task, as the person asked) or a Before/After
// table of pictures, which the gate counted as prose. The person reads a
// table and a picture as one thing, and a list line by line.

#[test]
fn table_and_picture_rows_count_no_words() {
    let text = "a1133's shots: bookmarks bar and Page Info, light and dark. Check the bar row in both themes.\n\n\
| | Light | Dark |\n|---|---|---|\n\
| Bookmarks bar | ![bookmarks bar, light](/tmp/shots/11-light-the-native-bookmarks-bar.png) | ![bookmarks bar, dark](/tmp/shots/16-dark-the-native-bookmarks-bar.png) |\n\
| Page Info | ![Page Info, light](/tmp/shots/12-light-page-info-open.png) | ![Page Info, dark](/tmp/shots/17-dark-page-info-open.png) |\n\
![the omnibar bubble, light and dark, side by side](/tmp/shots/bubble.png)";
    assert_eq!(reply_words(text), 17);
    assert_eq!(length_check(text, REPLY_MAX_WORDS, false), None);
}

#[test]
fn a_code_span_counts_as_one_word() {
    assert_eq!(
        reply_words("Run `cmux-ci test --setup rust -- cargo test` again."),
        3
    );
}

#[test]
fn a_status_list_of_short_lines_posts_even_when_its_total_is_over_the_limit() {
    let line = |n: usize| {
        format!(
            "- a12{n}: Sidebar toggle motion ~70%, fleet checks running, then it lands on feat-cmux-next today.\n"
        )
    };
    let text: String = (0..6).map(line).collect();
    assert!(
        reply_words(&text) > REPLY_MAX_WORDS,
        "{}",
        reply_words(&text)
    );
    assert_eq!(length_check(&text, REPLY_MAX_WORDS, false), None);
}

#[test]
fn one_long_list_line_is_refused_and_named() {
    let long = "word ".repeat(40);
    let text = format!("- a1091: done, nothing open.\n- a1120: {long}\n");
    let refusal = length_check(&text, REPLY_MAX_WORDS, false).expect("refused");
    assert!(refusal.starts_with("send: refused"), "{refusal}");
    assert!(refusal.contains("line 2"), "{refusal}");
    assert!(refusal.contains("41 words"), "{refusal}");
    assert_eq!(length_check(&text, REPLY_MAX_WORDS, true), None);
}

#[test]
fn prose_beside_a_list_is_judged_on_its_own() {
    let prose = "word ".repeat(REPLY_MAX_WORDS + 1);
    let text = format!("{prose}\n\n- a1: done.\n");
    let refusal = length_check(&text, REPLY_MAX_WORDS, false).expect("refused");
    assert!(
        refusal.contains(&format!("{} words", REPLY_MAX_WORDS + 1)),
        "{refusal}"
    );
}
