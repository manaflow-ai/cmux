use super::*;

fn spec(params: Value) -> WindowSpec {
    WindowSpec::from_params(&params).unwrap()
}

fn row(key: &str, title: &str) -> Row {
    (key.to_owned(), json!({"key": key, "title": title}))
}

fn entry(title: &str, cwd: &str, harness: &str) -> cmux_palette_ranker::Entry {
    rank_entry(
        &format!("{harness}:{title}"),
        Some(title),
        "New chat",
        Some(cwd),
        harness,
        Some("/Users/me"),
    )
}

/// The palette's chats page found a chat by its harness and by words anywhere in it (review of
/// #28090: a substring search lost both); the window ranks with the same ranker.
#[test]
fn a_query_finds_chats_by_harness_and_by_words_that_are_not_adjacent() {
    let entries = || {
        vec![
            entry("Fix the flaky build", "/Users/me/cmux", "claude-code"),
            entry("Port the parser", "/Users/me/tools", "codex"),
            entry("Write the docs", "/Users/me/site", "codex"),
        ]
    };
    let mut codex = ranked("codex", entries(), None);
    codex.sort_unstable();
    assert_eq!(codex, vec![1, 2], "a harness name finds that harness's chats");
    assert_eq!(
        ranked("fix build", entries(), None),
        vec![0],
        "two words that are not next to each other"
    );
    assert_eq!(ranked("tools", entries(), None), vec![1], "the folder");
    let untitled = rank_entry("codex:u", None, "New chat", None, "codex", None);
    assert_eq!(
        ranked("new chat", vec![untitled], None),
        vec![0],
        "an untitled chat by the client's word"
    );
}

/// The palette ranked a chat the person chose before above one with the same match.
#[test]
fn a_chat_chosen_before_ranks_first_among_equal_matches() {
    let entries = || {
        vec![
            rank_entry("codex:a", Some("Fix the build"), "New chat", None, "codex", None),
            rank_entry("codex:b", Some("Fix the build"), "New chat", None, "codex", None),
        ]
    };
    assert_eq!(ranked("fix build", entries(), None), vec![0, 1], "no history: the index order");
    let frecency: cmux_palette_ranker::Frecency = serde_json::from_value(json!({
        "entries": {"chat:codex:b": {"score": 3.0, "lastUsed": 990.0}}, "halfLife": 259_200.0
    }))
    .unwrap();
    assert_eq!(
        ranked("fix build", entries(), Some((1_000.0, frecency))),
        vec![1, 0],
        "the chosen chat first"
    );
}

#[test]
fn a_query_window_reports_how_many_matched() {
    let mut state = WindowState::new(spec(json!({"window": "w", "query": "x"})), 0);
    let full = state
        .next(WindowRows {
            rows: vec![row("a:1", "one")],
            has_more: true,
            total: Some(250),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(full["total"], 250);
    let mut plain = WindowState::new(spec(json!({"window": "w"})), 0);
    assert!(plain.next(WindowRows::default()).unwrap().get("total").is_none());
}

#[test]
fn a_spec_needs_its_window_name_and_reads_its_lists() {
    assert!(WindowSpec::from_params(&json!({})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "exclude": "x"})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "topLevel": 1})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "gen": -1})).is_err());
    assert_eq!(spec(json!({"window": "w", "gen": 7})).generation, 7);
    let s = spec(json!({"window": "w", "limit": 3, "exclude": ["a:1"], "keys": ["b:2"]}));
    assert_eq!(s.filter.limit, 3);
    assert!(s.exclude.contains("a:1"));
    assert_eq!(s.keys, Some(vec!["b:2".to_owned()]));
}

#[test]
fn the_first_message_is_full_and_later_ones_carry_only_changed_rows() {
    let mut state = WindowState::new(spec(json!({"window": "w"})), 0);
    let first = WindowRows {
        rows: vec![row("a:1", "one"), row("a:2", "two")],
        has_more: true,
        total: None,
        ..Default::default()
    };
    let full = state.next(first.clone()).unwrap();
    assert_eq!(full["full"], true);
    assert_eq!(full["revision"], 1);
    assert_eq!(full["gen"], 0);
    assert_eq!(full["rows"].as_array().unwrap().len(), 2);
    assert_eq!(state.next(first), None, "nothing new, nothing sent");
    let moved = WindowRows {
        rows: vec![row("a:2", "two"), row("a:1", "one, renamed")],
        has_more: true,
        total: None,
        ..Default::default()
    };
    let diff = state.next(moved).unwrap();
    assert_eq!(diff["full"], false);
    assert_eq!(diff["revision"], 2);
    assert_eq!(diff["keys"], json!(["a:2", "a:1"]));
    assert_eq!(diff["rows"], json!([{"key": "a:1", "title": "one, renamed"}]));
    let more = WindowRows {
        rows: vec![row("a:2", "two"), row("a:1", "one, renamed")],
        has_more: false,
        total: None,
        ..Default::default()
    };
    let diff = state.next(more).unwrap();
    assert_eq!(diff["rows"], json!([]), "only hasMore changed");
    assert_eq!(diff["hasMore"], false);
}

/// A chat's activity change recomputes only the windows that may show it: before, every
/// status, turn and permission record of any session recomputed every window, each reading
/// the whole index.
#[test]
fn only_a_window_that_shows_a_chat_recomputes_for_its_activity() {
    let mut state = WindowState::new(spec(json!({"window": "w", "topLevel": true})), 0);
    assert!(state.shows_activity_of(Some("a:9"), "status", &mut || false), "nothing sent yet");
    let parented = ("a:2".to_owned(), json!({"key": "a:2", "parent": "a:7"}));
    let mut folded = HashSet::new();
    folded.insert("a:5".to_owned());
    state.next(WindowRows {
        rows: vec![row("a:1", "one"), parented],
        has_more: true,
        total: None,
        filling: false,
        folded,
    });
    assert!(state.shows_activity_of(Some("a:1"), "status", &mut || false), "a row it shows");
    assert!(state.shows_activity_of(Some("a:7"), "turn_end", &mut || false), "a row's parent");
    assert!(
        state.shows_activity_of(Some("a:5"), "status", &mut || false),
        "folded or read past the page"
    );
    assert!(
        !state.shows_activity_of(Some("a:9"), "status", &mut || false),
        "a chat past the window"
    );
    assert!(!state.shows_activity_of(None, "status", &mut || false), "a session with no chat");
    assert!(
        state.shows_activity_of(Some("a:9"), "tags", &mut || false),
        "tags may fold or unfold rows"
    );
    assert!(state.shows_activity_of(None, "purged", &mut || false));
    // A refresh that sends nothing still keeps the chats it folded.
    let parented = ("a:2".to_owned(), json!({"key": "a:2", "parent": "a:7"}));
    let same = |folded: HashSet<String>| WindowRows {
        rows: vec![row("a:1", "one"), parented.clone()],
        has_more: true,
        total: None,
        filling: false,
        folded,
    };
    assert_eq!(state.next(same(HashSet::from(["a:6".to_owned()]))), None);
    assert!(state.shows_activity_of(Some("a:6"), "status", &mut || false), "a chat folded since");
    assert!(
        !state.shows_activity_of(Some("a:5"), "status", &mut || false),
        "a chat no longer folded"
    );
    let mut ranked =
        WindowState::new(spec(json!({"window": "q", "topLevel": true, "query": "x"})), 0);
    ranked.next(WindowRows {
        rows: vec![row("a:1", "one")],
        folded: HashSet::from(["a:5".to_owned()]),
        ..Default::default()
    });
    // A ranked window reads every chat's fold: a chat counts when its fold moved.
    assert!(!ranked.shows_activity_of(Some("a:9"), "status", &mut || false), "fold stays");
    assert!(!ranked.shows_activity_of(Some("a:5"), "status", &mut || true), "stays folded");
    assert!(ranked.shows_activity_of(Some("a:9"), "status", &mut || true), "folds");
    assert!(ranked.shows_activity_of(Some("a:5"), "status", &mut || false), "unfolds");
    assert!(ranked.shows_activity_of(Some("a:1"), "status", &mut || false), "a row it shows");
}

#[test]
fn a_replaced_spec_sends_every_row_again_with_a_later_revision() {
    let mut state = WindowState::new(spec(json!({"window": "w"})), 0);
    state.next(WindowRows {
        rows: vec![row("a:1", "one")],
        has_more: false,
        total: None,
        ..Default::default()
    });
    let mut replaced = WindowState::new(spec(json!({"window": "w", "limit": 5})), state.revision());
    let full = replaced
        .next(WindowRows {
            rows: vec![row("a:1", "one")],
            has_more: false,
            total: None,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(full["full"], true);
    assert_eq!(full["revision"], 2);
}
