use super::*;

fn state(busy: bool) -> Value {
    json!({"$": "state", "busy": busy})
}

#[test]
fn resolves_the_hosted_server_and_the_unii_token_file() {
    let e = Endpoint::resolve(&Options::default(), None, None, Some("/Users/me".into())).unwrap();
    assert_eq!(e.base, "https://uniichat.com");
    assert_eq!(e.ws, "wss://uniichat.com");
    assert_eq!(e.token_file, PathBuf::from("/Users/me/.unii/uniichat.com/token"));
}

#[test]
fn resolves_a_self_hosted_server_with_its_port() {
    let e = Endpoint::resolve(
        &Options::default(),
        Some("http://127.0.0.1:8788/".into()),
        Some("/tmp/u".into()),
        None,
    )
    .unwrap();
    assert_eq!(e.base, "http://127.0.0.1:8788");
    assert_eq!(e.ws, "ws://127.0.0.1:8788");
    assert_eq!(e.token_file, PathBuf::from("/tmp/u/127.0.0.1:8788/token"));
    let flag = Options { url: Some("https://x.dev".into()), ..Options::default() };
    let e = Endpoint::resolve(&flag, Some("http://y".into()), None, Some("/h".into())).unwrap();
    assert_eq!(e.host, "x.dev");
    assert!(
        Endpoint::resolve(
            &Options { url: Some("ftp://x".into()), ..Options::default() },
            None,
            None,
            Some("/h".into())
        )
        .is_err()
    );
}

#[test]
fn a_missing_sign_in_says_how_to_set_up() {
    let e = Endpoint::resolve(&Options::default(), None, Some("/nonexistent-unii".into()), None)
        .unwrap();
    let err = e.token().unwrap_err();
    assert!(err.contains("not signed in to uniichat.com"), "{err}");
    assert!(err.contains("unii login"), "{err}");
    assert!(err.contains("install.sh"), "{err}");
}

#[test]
fn sends_the_last_text_block_unless_whole() {
    let blocks = vec![
        json!({"type": "text", "text": "view "}),
        json!({"type": "image", "data": "aGk=", "mimeType": "image/png"}),
        json!({"type": "text", "text": "new"}),
    ];
    assert_eq!(prompt_text(&blocks, false), "new");
    assert_eq!(prompt_text(&blocks, true), "view new");
    assert_eq!(prompt_images(&blocks), vec![b"hi".to_vec()]);
    let (body, sizes) = say_body("new", &prompt_images(&blocks));
    assert_eq!(body, b"hinew");
    assert_eq!(sizes, "2");
    assert_eq!(say_body("x", &[]).1, "");
}

/// A huge paste in cmux's composer goes as its own text block after the
/// typed one (`_meta.cmux.pasted`): the message is the typed text and
/// every paste, a blank line between them, never the paste alone.
#[test]
fn a_pasted_block_goes_with_the_typed_text() {
    let pasted =
        |text: &str| json!({"type": "text", "text": text, "_meta": {"cmux": {"pasted": true}}});
    let blocks = vec![
        json!({"type": "text", "text": "view "}),
        json!({"type": "text", "text": "why does this fail?"}),
        pasted("the log"),
    ];
    assert_eq!(prompt_text(&blocks, false), "why does this fail?\n\nthe log");
    assert_eq!(prompt_text(&blocks, true), "view why does this fail?\n\nthe log");
    assert_eq!(prompt_text(&[pasted("only a paste")], false), "only a paste");
}

#[test]
fn streams_deltas_once_and_ends_when_idle() {
    let mut t = Turn::new(false);
    t.hear(&state(true));
    t.taken();
    assert_eq!(
        t.hear(&json!({"$": "delta", "kind": "mind", "text": "hm"})),
        vec![Out::Thought("hm".into())]
    );
    assert_eq!(
        t.hear(&json!({"$": "delta", "kind": "unii", "text": "Hel"})),
        vec![Out::Message("Hel".into())]
    );
    assert_eq!(
        t.hear(&json!({"$": "delta", "kind": "unii", "text": "lo"})),
        vec![Out::Message("lo".into())]
    );
    // The logged entry repeats what streamed: nothing new goes out.
    assert_eq!(t.hear(&json!({"$": "entry", "id": 9, "kind": "unii", "text": "Hello"})), vec![]);
    assert_eq!(t.ended(), None);
    t.hear(&state(false));
    assert_eq!(t.ended(), Some(Ended::Done));
}

#[test]
fn an_entry_never_streamed_goes_out_whole() {
    let mut t = Turn::new(false);
    t.taken();
    t.hear(&state(true));
    assert_eq!(
        t.hear(&json!({"$": "entry", "kind": "unii", "text": "Hi"})),
        vec![Out::Message("Hi".into())]
    );
    // A second message of the same turn, after a blank line.
    assert_eq!(
        t.hear(&json!({"$": "delta", "kind": "unii", "text": "More", "fresh": true})),
        vec![Out::Message("\n\nMore".into())]
    );
}

#[test]
fn tool_calls_show_and_complete() {
    let mut t = Turn::new(false);
    t.taken();
    assert_eq!(
        t.hear(&json!({"$": "entry", "kind": "tool", "text": "shell: ls\nmore"})),
        vec![Out::ToolStart { id: "unii-tool-1".into(), title: "shell: ls".into() }]
    );
    assert_eq!(
        t.hear(&json!({"$": "entry", "kind": "echo", "text": "a b"})),
        vec![Out::ToolDone { id: "unii-tool-1".into(), text: "a b".into() }]
    );
}

#[test]
fn a_turn_with_only_a_note_fails_with_it() {
    let mut t = Turn::new(false);
    t.taken();
    t.hear(&state(true));
    t.hear(&json!({"$": "entry", "kind": "note", "text": "out of credit"}));
    t.hear(&state(false));
    assert_eq!(t.ended(), Some(Ended::Failed("UniiChat: out of credit".into())));
}

#[test]
fn subagent_events_and_a_busy_chat_before_the_message_do_not_end_the_turn() {
    let mut t = Turn::new(true);
    assert_eq!(t.hear(&json!({"$": "delta", "agent": "a1", "kind": "unii", "text": "x"})), vec![]);
    t.hear(&state(false));
    // Not taken yet: an earlier turn ending is not this one.
    assert_eq!(t.ended(), None);
    t.taken();
    // Taken while idle and nothing ran yet: still waiting.
    assert_eq!(t.ended(), None);
    t.hear(&state(true));
    t.hear(&state(false));
    assert_eq!(t.ended(), Some(Ended::Done));
}

#[test]
fn a_rejoin_sends_only_what_went_past_the_stream() {
    let mut t = Turn::new(false);
    t.taken();
    t.hear(&state(true));
    t.hear(&json!({"$": "delta", "kind": "unii", "text": "Hel"}));
    let live = json!({"$": "live", "live": [{"kind": "unii", "text": "Hello"}]});
    assert_eq!(t.hear(&live), vec![Out::Message("lo".into())]);
    assert_eq!(t.hear(&live), vec![]);
}
