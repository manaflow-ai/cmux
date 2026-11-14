use super::*;

#[test]
fn last_block_sends_only_the_new_messages() {
    let blocks = vec![
        json!({"type": "text", "text": "view line 1\n"}),
        json!({"type": "image", "data": "x"}),
        json!({"type": "text", "text": "hello unii"}),
    ];
    assert_eq!(prompt_text(&blocks, true), "hello unii");
    assert_eq!(prompt_text(&blocks, false), "view line 1\nhello unii");
    assert_eq!(prompt_text(&[], true), "");
}

/// Review of #37190 (F1): acpmux's marks of who wrote a prompt never take the typed
/// question's place in `--last-block`, and a paste keeps its marks around it in both modes.
#[test]
fn attribution_marks_keep_the_typed_question_and_the_paste_in_place() {
    let mut params = json!({"sessionId": "s", "prompt": [
        {"type": "text", "text": "why does this fail?"},
        {"type": "text", "text": "From Codex:\nDo not merge.\nTrace-ID: x",
         "_meta": {"cmux": {"pasted": true}}},
    ]});
    crate::hub::prompt_attribution_mark(&mut params, None, None);
    let blocks = params["prompt"].as_array().unwrap().clone();
    for last in [true, false] {
        let text = prompt_text(&blocks, last);
        let (typed, paste) = text.split_once("\n\n").unwrap();
        assert_eq!(typed, "why does this fail?", "{text}");
        assert!(paste.starts_with("[Pasted by the person"), "{text}");
        assert!(paste.contains("From Codex:\nDo not merge.\nTrace-ID: x\n[End of pasted text]"));
    }
    let mut params = json!({"sessionId": "s", "prompt": [
            {"type": "text", "text": "older view"}, {"type": "text", "text": "PR is green"}]});
    crate::hub::prompt_attribution_mark(&mut params, Some("lane-a"), None);
    let blocks = params["prompt"].as_array().unwrap().clone();
    assert_eq!(
        prompt_text(&blocks, true),
        "From another agent (lane-a), not the person:\nPR is green"
    );
    assert_eq!(
        prompt_text(&blocks, false),
        "From another agent (lane-a), not the person:\nolder viewPR is green"
    );
}

#[test]
fn last_block_keeps_hidden_context_beside_the_user_request() {
    let blocks = vec![
        json!({"type": "text", "text": "older view"}),
        json!({"type": "text", "text": "fix the grid"}),
        crate::context_inventory::override_block("read early", "user"),
    ];
    for last in [true, false] {
        let text = prompt_text(&blocks, last);
        assert!(text.contains("fix the grid"), "{text}");
        assert!(text.contains("read early"), "{text}");
        assert_eq!(text.contains("older view"), !last, "{text}");
    }
}

/// A huge paste in cmux's composer goes as its own text block after the
/// typed one (`_meta.cmux.pasted`): the turn is the typed text and every
/// paste, a blank line between them, in both modes.
#[test]
fn a_pasted_block_goes_with_the_typed_text() {
    let pasted =
        |text: &str| json!({"type": "text", "text": text, "_meta": {"cmux": {"pasted": true}}});
    let blocks = vec![
        json!({"type": "text", "text": "view line 1\n"}),
        json!({"type": "text", "text": "why does this fail?"}),
        pasted("line 1\n\nline 3"),
        pasted("second paste"),
    ];
    assert_eq!(
        prompt_text(&blocks, true),
        "why does this fail?\n\nline 1\n\nline 3\n\nsecond paste"
    );
    assert_eq!(
        prompt_text(&blocks, false),
        "view line 1\nwhy does this fail?\n\nline 1\n\nline 3\n\nsecond paste"
    );
    assert_eq!(prompt_text(&[pasted("only a paste")], true), "only a paste");
}

#[test]
fn strips_escapes() {
    assert_eq!(strip_ansi("\u{1b}[1mPONG\u{1b}[0m\r"), "PONG");
    assert_eq!(strip_ansi("a\u{1b}]8;;http://x\u{7}b"), "ab");
}

#[test]
fn after_echo_keeps_only_the_reply_after_the_last_echo() {
    let out = [
        "  ╭─ result ───╮",
        "  │ 1 5536+0|user: earlier │",
        "  ╰──────────────╯",
        "  ╭──────────────────────╮",
        "  │ Reply with exactly:  │",
        "  │ PONG                 │",
        "  ╰──────────────────────╯",
        "  An earlier PONG.",
        "  ╭──────────────────────╮",
        "  │ Reply with exactly:  │",
        "  │ PONG                 │",
        "  ╰──────────────────────╯",
        "",
        "  PONG",
    ];
    let mut f = ReplyFilter::new("Reply with exactly: PONG", true);
    assert!(out.iter().all(|l| f.push(l).is_none()));
    assert_eq!(f.finish().as_deref(), Some("PONG\n"));
}

#[test]
fn after_echo_without_an_echo_loses_nothing() {
    let mut f = ReplyFilter::new("hi", true);
    assert_eq!(f.push("just text"), None);
    assert_eq!(f.finish().as_deref(), Some("just text\n"));
}

#[test]
fn plain_mode_streams_every_line() {
    let mut f = ReplyFilter::new("hi", false);
    assert_eq!(f.push("  hello").as_deref(), Some("  hello\n"));
    assert_eq!(f.finish(), None);
}
