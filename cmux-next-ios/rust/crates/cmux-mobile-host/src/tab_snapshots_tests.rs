use super::*;

fn tab(id: &str, kind: Kind, raw: Value) -> ListedTab {
    ListedTab { id: id.to_owned(), title: format!("T{id}"), kind, cols: 80, rows: 24, raw }
}

fn row(tabs: &Tabs, id: &str) -> cmux_tab_snapshots::Row {
    let state = tabs.lock();
    state.producer.rows().iter().find(|r| r.tab_id == id).cloned().unwrap()
}

#[test]
fn offer_image_sets_the_favicon_and_thumb_of_a_listed_tab() {
    let tabs = Tabs::new("e");
    tabs.set_tabs(vec![tab("1", Kind::Browser, json!({}))]);
    let rev = tabs.rev();
    assert!(tabs.offer_image("1", Part::Favicon, b"fav".to_vec(), 0, 0, Mime::Png, 5));
    assert!(tabs.offer_image("1", Part::Thumb, b"thumb".to_vec(), 576, 768, Mime::Jpeg, 6));
    let r = row(&tabs, "1");
    assert_eq!(r.favicon_hash, Some(cmux_tab_snapshots::BlobHash::of(b"fav")));
    assert_eq!(r.thumb_hash, Some(cmux_tab_snapshots::BlobHash::of(b"thumb")));
    assert_eq!((r.thumb_w, r.thumb_h, r.thumb_mime), (576, 768, Mime::Jpeg));
    assert_eq!(tabs.rev(), rev + 2);
    // The same bytes again are no change.
    assert!(!tabs.offer_image("1", Part::Thumb, b"thumb".to_vec(), 576, 768, Mime::Jpeg, 7));
}

#[test]
fn offer_image_refuses_bad_input_and_keeps_pictures_for_tabs_not_listed_yet() {
    let tabs = Tabs::new("e");
    assert!(!tabs.offer_image("1", Part::Favicon, Vec::new(), 0, 0, Mime::Png, 1));
    assert!(!tabs.offer_image("1", Part::Favicon, b"x".to_vec(), 0, 0, Mime::ScreenText, 1));
    assert!(!tabs.offer_image("1", Part::Thumb, vec![0; MAX_IMAGE_BYTES + 1], 1, 1, Mime::Jpeg, 1));
    assert!(!tabs.offer_image("2", Part::Favicon, b"early".to_vec(), 0, 0, Mime::Png, 1));
    assert!(tabs.tab_ids().is_empty());
    tabs.set_tabs(vec![tab("2", Kind::Browser, json!({}))]);
    assert_eq!(row(&tabs, "2").favicon_hash, Some(cmux_tab_snapshots::BlobHash::of(b"early")));
}

#[test]
fn set_tabs_orders_removes_and_keeps_screens() {
    let tabs = Tabs::new("e");
    tabs.set_tabs(vec![tab("1", Kind::Terminal, json!({})), tab("2", Kind::Browser, json!({}))]);
    assert!(tabs.set_screen("1", "$ ls".to_owned()));
    assert!(!tabs.set_screen("9", "nope".to_owned()));
    tabs.offer_image("2", Part::Favicon, b"f".to_vec(), 0, 0, Mime::Png, 1);
    tabs.set_tabs(vec![tab("3", Kind::Browser, json!({})), tab("1", Kind::Terminal, json!({}))]);
    assert_eq!(tabs.tab_ids(), ["3", "1"]);
    let r = row(&tabs, "1");
    assert_eq!((r.screen_cols, r.screen_rows), (80, 24));
    assert_eq!(r.screen_hash, Some(cmux_tab_snapshots::BlobHash::of(b"$ ls")));
    // The closed tab's pictures are gone with it.
    assert!(tabs.lock().pictures.is_empty());
    let rev = tabs.rev();
    assert!(!tabs.set_tabs(vec![tab("3", Kind::Browser, json!({})), tab("1", Kind::Terminal, json!({}))]));
    assert_eq!(tabs.rev(), rev);
}

#[test]
fn exposure_hides_tabs_of_blocked_chats_and_everything_when_unavailable() {
    let tabs = Tabs::new("e");
    tabs.set_tabs(vec![
        tab("1", Kind::Agent, json!({"agent_session": "s-blocked"})),
        tab("2", Kind::Agent, json!({"agent_session": "s-ok"})),
        tab("3", Kind::Terminal, json!({"session": "s-blocked"})),
    ]);
    let mut exposure = SessionExposure { configured: true, ..SessionExposure::default() };
    exposure.blocked.insert("s-blocked".to_owned());
    assert_eq!(tabs.hidden(&exposure), Some(HashSet::from(["1".to_owned()])));
    assert_eq!(tabs.hidden(&SessionExposure::default()), Some(HashSet::new()));
    let off = SessionExposure { available: false, ..SessionExposure::default() };
    assert_eq!(tabs.hidden(&off), None);
    let filter = row_filter(None);
    assert!(!filter.passes("2"));
}

#[test]
fn listed_tabs_reads_the_tree_in_order() {
    let reply = json!({"ok": true, "data": {"workspaces": [{"screens": [{"panes": [
        {"tabs": [
            {"surface": 7, "kind": "pty", "title": "", "name": "zsh", "size": {"cols": 120, "rows": 40}},
            {"surface": 8, "kind": "browser", "title": "Docs"},
        ]},
        {"tabs": [{"surface": 9, "kind": "conversation", "title": "Chat"}, {"kind": "pty"}]},
    ]}]}]}});
    let tabs = listed_tabs(&reply);
    let short: Vec<_> =
        tabs.iter().map(|t| (t.id.as_str(), t.title.as_str(), t.kind.clone(), t.cols, t.rows)).collect();
    assert_eq!(
        short,
        [
            ("7", "zsh", Kind::Terminal, 120, 40),
            ("8", "Docs", Kind::Browser, 0, 0),
            ("9", "Chat", Kind::Agent, 0, 0),
        ]
    );
}

#[test]
fn truncate_keeps_char_boundaries() {
    assert_eq!(truncate("héllo".to_owned(), 2), "h");
    assert_eq!(truncate("abc".to_owned(), 8), "abc");
}
