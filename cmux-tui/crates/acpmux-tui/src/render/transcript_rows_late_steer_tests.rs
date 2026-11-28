use super::*;

fn user(text: &str, steer: bool) -> Item {
    Item::User { text: text.into(), steer, queued: false }
}
fn said(text: &str) -> Item {
    Item::Assistant { text: text.into() }
}
fn tool(id: &str) -> Item {
    Item::Tool {
        id: id.into(),
        title: format!("Read {id}"),
        kind: "read".into(),
        status: "completed".into(),
        detail: String::new(),
    }
}
fn transcript(items: Vec<Item>, status: &str) -> Transcript {
    let mut t = Transcript::default();
    t.items = items;
    t.status = status.into();
    t
}
fn order(t: &Transcript) -> Vec<usize> {
    late_steers_last(t, (0..t.items.len()).collect(), t.status == "running").0
}
/// The first row, in drawing order, whose text contains each needle.
fn drawn_at(t: &Transcript, needles: &[&str]) -> Vec<usize> {
    let rows = transcript_rows(t, 80, false, false, &Default::default(), &Chrome::dark());
    needles.iter().map(|n| rows.iter().position(|r| r.text.contains(n)).expect(n)).collect()
}

#[test]
fn late_steer_after_the_reply_draws_over_it_once_the_turn_ended() {
    let items = vec![
        user("fix it", false),
        tool("a.rs"),
        said("Fixed it"),
        user("also b", true),
        said("and b too"),
    ];
    let live = transcript(items.clone(), "running");
    assert_eq!(order(&live), vec![0, 1, 2, 3, 4], "a running turn draws as it came");
    let ended = transcript(items, "ready");
    assert_eq!(order(&ended), vec![0, 1, 3, 2, 4]);
    let at = drawn_at(&ended, &["fix it", "Worked", "also b", "Fixed it", "and b too"]);
    assert!(at.windows(2).all(|w| w[0] < w[1]), "prompt, work, steer, reply: {at:?}");
}

#[test]
fn steer_with_a_tool_after_it_keeps_its_order() {
    let t = transcript(
        vec![
            user("fix it", false),
            tool("a.rs"),
            said("Fixed it"),
            user("also b", true),
            tool("b.rs"),
            said("and b too"),
        ],
        "ready",
    );
    assert_eq!(order(&t), (0..6).collect::<Vec<_>>());
}

#[test]
fn turn_without_a_steer_keeps_its_order() {
    let t = transcript(vec![user("fix it", false), tool("a.rs"), said("Fixed it")], "ready");
    assert_eq!(order(&t), vec![0, 1, 2]);
    let at = drawn_at(&t, &["fix it", "Worked", "Fixed it"]);
    assert!(at.windows(2).all(|w| w[0] < w[1]), "{at:?}");
}

fn drawn(t: &Transcript) -> String {
    transcript_rows(t, 80, false, false, &Default::default(), &Chrome::dark())
        .iter()
        .map(|r| r.text.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn a_turn_that_died_on_an_error_reads_failed_after() {
    // cmux#44475: a 429 that ended the turn is not work.
    let mut t = transcript(
        vec![
            user("fix it", false),
            tool("a.rs"),
            Item::Error { text: "API Error: 429 Too Many Requests".into() },
        ],
        "ready",
    );
    t.turn_times = vec![(0, 1_000, Some(16_000))];
    let out = drawn(&t);
    assert!(out.contains("Failed after 15s"), "{out}");
    assert!(!out.contains("Worked for"), "{out}");
    // The error stays in sight under the closed fold.
    assert!(out.contains("429 Too Many Requests"), "{out}");
    // A turn that recovered and answered still worked.
    t.items.push(said("Done after a retry."));
    let out = drawn(&t);
    assert!(out.contains("Worked for 15s"), "{out}");
}

#[test]
fn a_substantive_reply_stays_out_of_the_closed_fold() {
    // cmux#42279: an answer, then a tool and a short receipt; the answer stays in sight.
    let t = transcript(
        vec![
            user("why is it slow", false),
            tool("a.rs"),
            said("The cache is stale, so every read misses."),
            said("Let me check the logs."),
            tool("b.rs"),
            said("I sent it"),
        ],
        "ready",
    );
    let out = drawn(&t);
    assert!(out.contains("The cache is stale"), "{out}");
    assert!(!out.contains("Let me check the logs"), "narration folds: {out}");
    assert!(!out.contains("Read b.rs"), "{out}");
    assert!(out.contains("I sent it"), "{out}");
}

#[test]
fn calls_after_the_final_reply_fold_with_the_work() {
    // cmux#41774, #41537: a finished call and an empty message after the answer fold;
    // the answer is the last reply with words.
    let t = transcript(
        vec![user("fix it", false), tool("a.rs"), said("Fixed it"), tool("b.rs"), said("  ")],
        "ready",
    );
    let out = drawn(&t);
    assert!(out.contains("Fixed it"), "{out}");
    assert!(!out.contains("Read b.rs"), "{out}");
    assert!(!out.contains("Read a.rs"), "{out}");
}
