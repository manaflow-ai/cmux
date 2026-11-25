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
fn a_new_daemon_run_drops_every_id_of_the_old_one_under_a_new_epoch() {
    let tabs = Tabs::new("e");
    tabs.offer_image("3", Part::Favicon, b"early".to_vec(), 0, 0, Mime::Png, 1);
    // The first connection is the run the epoch began with: nothing goes.
    assert!(!tabs.daemon_run("unused", Some("1/main/0".into())));
    // The feeder back on that run: nothing goes either.
    assert!(!tabs.daemon_run("unused", Some("1/main/0".into())));
    assert_eq!(tabs.epoch(), "e");
    tabs.set_tabs(vec![tab("1", Kind::Browser, json!({})), tab("3", Kind::Browser, json!({}))]);
    assert_eq!(row(&tabs, "3").favicon_hash, Some(cmux_tab_snapshots::BlobHash::of(b"early")));
    tabs.offer_image("1", Part::Thumb, b"thumb1".to_vec(), 576, 768, Mime::Jpeg, 2);
    tabs.set_screen("1", "old".into());
    // A picture for a surface the old run had not listed yet.
    tabs.offer_image("5", Part::Thumb, b"pending5".to_vec(), 576, 768, Mime::Jpeg, 3);
    let rev = tabs.rev();

    assert!(tabs.daemon_run("e2", Some("1/main/1".into())));
    assert_eq!(tabs.epoch(), "e2");
    assert!(tabs.tab_ids().is_empty());
    assert_eq!(tabs.stored_blobs(), 0);
    assert!(tabs.rev() > rev);
    assert!(tabs.lock().producer.delta_since(rev).is_none(), "no delta crosses the runs");
    // The new run reuses 1 and 5 for other tabs: none of the old pictures,
    // screen or title come back.
    tabs.set_tabs(vec![tab("5", Kind::Terminal, json!({})), tab("1", Kind::Browser, json!({}))]);
    assert_eq!(tabs.tab_ids(), ["5", "1"]);
    let (one, five) = (row(&tabs, "1"), row(&tabs, "5"));
    assert_eq!((one.thumb_hash, one.screen_hash, five.thumb_hash), (None, None, None));
    assert!(!tabs.set_screen("3", "gone".into()), "an old run's tab is not listed");
}

const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3];
const PNG: &[u8] = b"\x89PNG\r\n\x1a\nrest";

fn picture(path: &Path, part: Part) -> PictureFile {
    PictureFile {
        surface: 4,
        part,
        path: path.to_string_lossy().into_owned(),
        w: 576,
        h: 360,
        captured_at_ms: 9,
    }
}

#[tokio::test]
async fn offer_file_reads_a_jpeg_thumb_and_a_png_favicon_by_surface() {
    let dir = tempfile::tempdir().unwrap();
    let (thumb, favicon) = (dir.path().join("4-thumb.jpg"), dir.path().join("4-favicon.png"));
    std::fs::write(&thumb, JPEG).unwrap();
    std::fs::write(&favicon, PNG).unwrap();
    let tabs = Tabs::new("e");
    tabs.set_tabs(vec![tab("4", Kind::Browser, json!({}))]);
    assert!(tabs.offer_file(&picture(&thumb, Part::Thumb)).await);
    assert!(tabs.offer_file(&picture(&favicon, Part::Favicon)).await);
    let r = row(&tabs, "4");
    assert_eq!(r.thumb_hash, Some(cmux_tab_snapshots::BlobHash::of(JPEG)));
    assert_eq!((r.thumb_w, r.thumb_h, r.thumb_mime), (576, 360, Mime::Jpeg));
    assert_eq!(r.favicon_hash, Some(cmux_tab_snapshots::BlobHash::of(PNG)));
}

#[tokio::test]
async fn offer_file_refuses_oversize_wrong_format_missing_links_and_relative_paths() {
    let dir = tempfile::tempdir().unwrap();
    let tabs = Tabs::new("e");
    tabs.set_tabs(vec![tab("4", Kind::Browser, json!({}))]);
    let big = dir.path().join("big.jpg");
    let mut bytes = JPEG.to_vec();
    bytes.resize(MAX_IMAGE_BYTES + 1, 0);
    std::fs::write(&big, bytes).unwrap();
    let gif = dir.path().join("x.gif");
    std::fs::write(&gif, b"GIF89a....").unwrap();
    let empty = dir.path().join("empty.png");
    std::fs::write(&empty, b"").unwrap();
    let good = dir.path().join("good.png");
    std::fs::write(&good, PNG).unwrap();
    let link = dir.path().join("link.png");
    std::os::unix::fs::symlink(&good, &link).unwrap();
    for path in [big, gif, empty, dir.path().join("missing.png"), link, dir.path().to_path_buf()] {
        assert!(!tabs.offer_file(&picture(&path, Part::Favicon)).await, "{}", path.display());
    }
    assert!(!tabs.offer_file(&picture(Path::new("good.png"), Part::Favicon)).await);
    assert_eq!(row(&tabs, "4").favicon_hash, None);
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
fn equal_screen_refresh_emits_no_snapshot_or_row_delta() {
    let tabs = Tabs::new("e");
    tabs.set_tabs(vec![tab("1", Kind::Terminal, json!({})), tab("2", Kind::Terminal, json!({}))]);
    assert!(tabs.set_screen("1", "same".to_owned()));
    let rev = tabs.rev();
    assert!(!tabs.set_screen("1", "same".to_owned()));
    println!("SILENT_DELTA rust_screen_equal before=1 after=0");
    assert_eq!(tabs.rev(), rev);
    let delta = tabs.lock().producer.delta_since(rev).expect("current revision has a delta");
    assert!(delta.changed.is_empty());

    assert!(tabs.set_screen("1", "changed".to_owned()));
    assert_eq!(tabs.rev(), rev + 1);
    let delta = tabs.lock().producer.delta_since(rev).expect("changed row delta");
    println!("SILENT_DELTA rust_screen_changed rows={}", delta.changed.len());
    assert_eq!(delta.changed.len(), 1);
    assert_eq!(delta.changed[0].tab_id, "1");
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
