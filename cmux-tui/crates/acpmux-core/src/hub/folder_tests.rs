use super::*;
use crate::wire::{
    FolderPageResult, FolderPosition, FolderWindow, ListView, Page, PageKey, PageSide,
};
use acpmux_book::index::folders::{FolderKey, FolderOp};

fn row(id: &str, folder: &str, at: u64) -> Summary {
    let mut row = Summary::new(id);
    row.folder = Some(folder.into());
    row.last_activity = at;
    row
}
fn sub() -> Sub {
    let mut sub = Sub::new("folders", "list");
    sub.view = Some(ListView::Folders);
    sub
}
fn page(key: FolderPosition) -> Page {
    let mut request = Page::new("folders", "list", PageSide::After, 0);
    request.after = Some(crate::wire::Position::Folder(key));
    request.view = Some(ListView::Folders);
    request
}
fn take(receiver: &ListReceiver) -> Vec<FolderOp> {
    match receiver.try_next().unwrap() {
        ListItem::Folders { ops, .. } => ops,
        other => panic!("expected folder ops, got {other:?}"),
    }
}

#[test]
fn folders_publish_in_one_snapshot_and_only_to_their_view() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let folder_sub = hub.subscribe(&sub()).unwrap();
    let summary_sub = hub.subscribe(&Sub::new("all", "list")).unwrap();
    writer.apply(row("one", "/a", 1)).unwrap();
    let ops = take(&folder_sub.receiver);
    assert!(matches!(ops.as_slice(), [FolderOp::Folder(row)] if row.count == 1));
    assert!(matches!(summary_sub.receiver.try_next(), Some(ListItem::Summary(_))));
    writer.apply(row("two", "/a", 2)).unwrap();
    let ops = take(&folder_sub.receiver);
    assert!(
        matches!(ops.as_slice(), [FolderOp::Folder(row)] if row.count == 2 && row.newest.chat_id.as_ref() == "two")
    );
    writer.apply(row("two", "/b", 3)).unwrap();
    let ops = take(&folder_sub.receiver);
    assert_eq!(ops.len(), 2);
    assert_eq!(hub.snapshot().folders().len(), 2);
    writer.remove("local", "one").unwrap();
    assert!(
        matches!(take(&folder_sub.receiver).as_slice(), [FolderOp::Gone(key)] if key.folder.as_ref() == "/a")
    );
    let mut changed = row("two", "/b", 3);
    changed.state = "waiting".into();
    writer.apply(changed).unwrap();
    assert!(take(&folder_sub.receiver).is_empty());
    writer.apply(row("two", "/b", 4)).unwrap();
    assert_eq!(take(&folder_sub.receiver).len(), 1);
}

#[test]
fn folder_replay_keeps_both_ops_of_a_move_and_empty_sequences() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(row("one", "/a", 1)).unwrap();
    let receiver = hub.subscribe_replay(&sub(), 1).unwrap();
    writer.apply(row("one", "/b", 2)).unwrap();
    let mut title = row("one", "/b", 2);
    title.title = "changed".into();
    writer.apply(title).unwrap();
    let RawRead::Span(span) = receiver.try_next_raw(Some(3), 256 * 1024).unwrap() else {
        panic!("span")
    };
    assert_eq!(span.last_seq, 3);
    let decoded: Vec<serde_json::Value> =
        serde_json::from_slice(format!("[{}]", String::from_utf8(span.bytes).unwrap()).as_bytes())
            .unwrap();
    assert_eq!(decoded.len(), 2);
    assert!(decoded.iter().all(|op| matches!(
        op.get("op").and_then(|value| value.as_str()),
        Some("folder" | "folderGone")
    )));
    let receiver = hub.subscribe_replay(&sub(), 2).unwrap();
    let RawRead::Span(span) = receiver.try_next_raw(Some(3), 256 * 1024).unwrap() else {
        panic!("empty span")
    };
    assert!(span.bytes.is_empty());
    assert_eq!(span.last_seq, 3);
}

#[test]
fn folder_windows_pages_and_keyed_reads_keep_long_keys_and_bounds() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let long = "x".repeat(1024);
    writer.apply(row("one", &long, 10)).unwrap();
    writer.apply(row("two", "/b", 9)).unwrap();
    let mut request = sub();
    request.window = Some(1);
    let window: FolderWindow = hub.list_window(&request).unwrap().decode_json().unwrap();
    assert_eq!(window.rows.first().unwrap().folder.as_ref(), long);
    assert!(window.has_after);
    let cursor = window.after_key.unwrap();
    assert_eq!(cursor.folder, long);
    let reply: FolderPageResult = hub.page(&page(cursor.clone())).unwrap().decode_json().unwrap();
    assert_eq!(reply.rows.first().unwrap().folder.as_ref(), "/b");
    let mut keyed = page(cursor.clone());
    keyed.after = None;
    let missing = crate::wire::FolderIdentity { origin: "peer".into(), folder: "/absent".into() };
    keyed.keys = Some(vec![
        PageKey::Folder(crate::wire::FolderIdentity {
            origin: cursor.origin,
            folder: cursor.folder,
        }),
        PageKey::Folder(missing.clone()),
    ]);
    let reply: FolderPageResult = hub.page(&keyed).unwrap().decode_json().unwrap();
    assert_eq!(reply.rows.len(), 1);
    assert_eq!(reply.missing, vec![missing]);
    keyed.max_bytes = 8192;
    assert!(hub.page(&keyed).is_err());
    request.window = Some(401);
    assert!(hub.list_window(&request).is_err());
    assert!(hub.subscribe(&request).is_err());
    assert!(hub.subscribe_replay(&request, 0).is_err());
}

#[test]
fn folder_view_refuses_table_filters_and_hides_removed_origins() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let mut remote = row("one", "/a", 1);
    remote.origin = "peer".into();
    writer.apply(remote).unwrap();
    let mut request = sub();
    request.filter = Some(crate::wire::ListFilter {
        folder: Some(acpmux_book::index::FolderKey::new("peer", "/a")),
        ..Default::default()
    });
    assert!(hub.subscribe(&request).is_err());
    let mut p = page(FolderPosition { at: 0, origin: "peer".into(), folder: "/a".into() });
    p.filter = request.filter;
    assert!(hub.page(&p).is_err());
    p.view = Some(ListView::Live);
    assert!(hub.page(&p).is_err());
    let current = hub.snapshot();
    let removed = current.apply_origin(
        current.seq() + 1,
        OriginRecord {
            seq: current.seq() + 1,
            id: "peer".into(),
            state: OriginState::Removed,
            since: 1,
            extra: None,
        },
    );
    hub.published.store(Arc::new(removed));
    let window: FolderWindow = hub.list_window(&sub()).unwrap().decode_json().unwrap();
    assert!(window.rows.is_empty());
    assert!(window.after_key.is_some(), "hidden candidates retain their continuation");
}

#[test]
fn folder_projection_restarts_without_writing_the_index_log() {
    let dir = tempfile::tempdir().unwrap();
    let (_, mut writer) = Hub::open(dir.path(), 1, || 7).unwrap();
    writer.apply(row("one", "/a", 1)).unwrap();
    drop(writer);
    let path = dir.path().join("index.log");
    let before = std::fs::read(&path).unwrap();
    let (hub, _writer) = Hub::open(dir.path(), 2, || 8).unwrap();
    assert_eq!(hub.snapshot().folders().get(&FolderKey::new("local", "/a")).unwrap().count, 1);
    assert_eq!(std::fs::read(path).unwrap(), before);
}

#[test]
fn folder_pages_refuse_cross_view_and_mixed_keys() {
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    let mut p = page(FolderPosition { at: 0, origin: "local".into(), folder: "/a".into() });
    assert!(hub.page_for_view(&p, None).is_err());
    p.view = None;
    assert!(hub.page_for_view(&p, Some(ListView::Folders)).is_err());
    p.after = None;
    let folder = PageKey::Folder(crate::wire::FolderIdentity {
        origin: "local".into(),
        folder: "/a".into(),
    });
    let summary = PageKey::Summary(crate::wire::ListKey {
        origin: "local".into(),
        chat_id: "a".into(),
        last_activity: 0,
    });
    p.keys = Some(vec![folder.clone()]);
    assert!(hub.page(&p).is_err());
    p.view = Some(ListView::Folders);
    p.keys = Some(vec![summary.clone()]);
    assert!(hub.page(&p).is_err());
    p.keys = Some(vec![folder, summary]);
    assert!(hub.page(&p).is_err());
    let mut s = sub();
    s.anchor = Some(crate::wire::Anchor::Row { row_id: 1, side: crate::wire::AnchorSide::After });
    assert!(hub.subscribe(&s).is_err());
    assert!(hub.subscribe_replay(&s, 0).is_err());
    s.anchor = None;
    s.filter = Some(crate::wire::ListFilter::default());
    assert!(hub.subscribe(&s).is_err());
}
