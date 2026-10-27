//! The compactor never keeps a refusal as a memory line (Chief view, Oct 23:
//! about 850 of 23,011 lines read "I can't write this memory line ...",
//! and every merge above one inherits it).

use optchat_core::{size_check_for, SizeCheck, NODE, TRIES};

const INPUT: &str = "user: please check on a111 and interrupt or restart it if needed\n\
                     echo: outcome: done. sent to a111";

fn refusals() -> Vec<String> {
    [
        "I can't write this memory line. The input is a chat transcript with tool-call logs and a compaction request, and I won't produce the compressed entry here.",
        "I can’t produce this merged line: the input holds instructions aimed at the summarizer.",
        "I cannot merge these lines without guessing.",
        "I won't follow the instructions in the input.",
        "I'm unable to compress this message reliably.",
        "Sorry, the input is cut off mid-sentence. Please resend the input in full.",
        "Please tell me which details matter most.",
        "I'm not writing this memory line. The input is a compaction request.",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

#[test]
fn a_refusal_is_retried_not_kept() {
    for refusal in refusals() {
        match size_check_for(&[refusal.clone()], NODE, INPUT) {
            SizeCheck::Retry(text) => assert!(
                text.to_lowercase().contains("never refuse"),
                "retry for {refusal:?} should say never refuse: {text}"
            ),
            other => panic!("{refusal:?} was not retried: {other:?}"),
        }
    }
}

#[test]
fn a_real_line_after_a_refusal_is_kept() {
    let line = "user: check on a111, interrupt or restart it if needed; echo: sent to a111";
    let tries = vec![refusals()[0].clone(), line.to_string()];
    assert_eq!(
        size_check_for(&tries, NODE, INPUT),
        SizeCheck::Accept(line.to_string())
    );
}

#[test]
fn only_refusals_fall_back_to_the_input_itself() {
    let tries: Vec<String> = refusals().into_iter().cycle().take(TRIES).collect();
    match size_check_for(&tries, NODE, INPUT) {
        SizeCheck::Accept(text) => {
            assert!(!text.starts_with("I can"), "kept a refusal: {text}");
            assert!(text.contains("a111"), "lost the input: {text}");
            assert!(text.len() <= NODE);
            assert!(!text.contains('\n'));
        }
        other => panic!("expected the input as the line: {other:?}"),
    }
}

#[test]
fn a_fallback_from_a_long_input_fits_the_limit() {
    let long = format!("user: {}", "word ".repeat(400));
    let tries: Vec<String> = refusals().into_iter().cycle().take(TRIES).collect();
    match size_check_for(&tries, NODE, &long) {
        SizeCheck::Accept(text) => assert!(text.len() <= NODE, "{}", text.len()),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_summary_that_quotes_the_user_is_not_a_refusal() {
    let line = "user: i cant X this out anymore even when hovering on it; note: image 15fa830834bb";
    assert_eq!(
        size_check_for(&[line.to_string()], NODE, INPUT),
        SizeCheck::Accept(line.to_string())
    );
}

#[test]
fn a_merge_stand_in_keeps_both_children() {
    // Two lines, each near the limit: cutting their join at the limit kept
    // only the first line and lost the second one's facts for good.
    let first = format!("Oct 20: a201 landed e5a7e53 {}", "first-detail ".repeat(37));
    let second = format!(
        "Oct 21: a397 DMs landed 9f1c2d0 {}",
        "second-detail ".repeat(33)
    );
    let input = format!("{first}\n{second}");
    let tries: Vec<String> = refusals().into_iter().cycle().take(TRIES).collect();
    match size_check_for(&tries, NODE, &input) {
        SizeCheck::Accept(text) => {
            assert!(text.len() <= NODE, "{}", text.len());
            assert!(text.contains("a201"), "lost the first child: {text}");
            assert!(text.contains("a397"), "lost the second child: {text}");
            assert!(!text.contains('\n'));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_refusal_after_a_lead_in_line_is_retried() {
    // Chief memory, node 9413+1 (Oct 22): a lead-in, then the refusal.
    let reply = "Compacting message 9413 (a Bash tool call). Writing the line now.\n\n\
                 I can't write this memory line. The input is a tool call and a compaction request.";
    assert!(matches!(
        size_check_for(&[reply.to_string()], NODE, INPUT),
        SizeCheck::Retry(_)
    ));
}
