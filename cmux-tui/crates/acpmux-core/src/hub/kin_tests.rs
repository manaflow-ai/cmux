use super::*;
use crate::wire::{Page, PageResult, Position};
use acpmux_book::index::{DiskSnapshot, ListFilter, SortedSnapshot};
use std::fs;

fn page(filter: ListFilter) -> Page {
    Page {
        sid: "kin".into(),
        stream: "list".into(),
        before: None,
        after: None,
        keys: None,
        view: None,
        max_bytes: crate::wire::MAX_PAGE_BYTES as u32,
        filter: Some(filter),
    }
}

#[test]
fn table_parts_are_page_only_and_readable_from_their_head() {
    let root = RowKey::new("local", "root");
    let mut cold = Summary::new("cold-child");
    cold.parent = Some(root.clone());
    cold.state = "closed".into();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.snap");
    SortedSnapshot::write(&path, &SummaryIndex::new().apply(1, cold)).unwrap();
    let index = SummaryIndex::from_disk(DiskSnapshot::open(&path).unwrap(), 1);
    let (hub, mut writer) = Hub::new(index);
    let mut hot = Summary::new("peer-child");
    hot.origin = "peer".into();
    hot.parent = Some(root.clone());
    hub.submit(hot).unwrap();
    writer.process_batch();
    let mut sub = Sub::new("kin", "list");
    sub.filter = Some(ListFilter::family(root.clone()));
    assert!(matches!(hub.list_window(&sub), Err(HubError::InvalidParams(_))));
    assert!(matches!(hub.subscribe(&sub), Err(HubError::InvalidParams(_))));
    let hot_page: PageResult<Summary> =
        hub.page(&page(ListFilter::family(root.clone()))).unwrap().decode_json().unwrap();
    assert!(hot_page.cold_unread);
    assert_eq!(hot_page.rows.len(), 1);
    assert_eq!(hot_page.rows.first().unwrap().origin, "peer");
    let mut filter = ListFilter::family(root);
    filter.cold = true;
    let frame = hub.page(&page(filter)).unwrap();
    let cold_page: PageResult<Summary> = frame.decode_json().unwrap();
    assert!(!cold_page.cold_unread);
    assert_eq!(cold_page.rows.first().unwrap().chat_id, "cold-child");
    let value: serde_json::Value = frame.decode_json().unwrap();
    assert!(value.get("coldUnread").is_none());
}

#[test]
fn departed_family_cursor_is_a_typed_hub_error_and_before_is_refused() {
    let root = RowKey::new("local", "root");
    let mut child = Summary::new("child");
    child.parent = Some(root.clone());
    let key = wire_key(SortKey::of(&child));
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    hub.submit(child).unwrap();
    writer.process_batch();
    let mut request = page(ListFilter::family(root));
    request.before = Some(Position::List(key.clone()));
    assert!(hub.page(&request).is_err());
    request.before = None;
    request.after = Some(Position::List(key));
    hub.remove("local", "child").unwrap();
    writer.process_batch();
    assert!(matches!(hub.page(&request), Err(HubError::CursorGone)));
}

#[test]
fn every_table_filter_is_refused_on_sub_before_publication() {
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    for filter in [
        ListFilter::family(RowKey::new("local", "root")),
        ListFilter::forks(RowKey::new("local", "root")),
        ListFilter::folder(acpmux_book::index::FolderKey::new("local", "one")),
        ListFilter { cold: true, ..ListFilter::default() },
    ] {
        let mut sub = Sub::new("kin", "list");
        sub.filter = Some(filter);
        assert!(matches!(hub.list_window(&sub), Err(HubError::InvalidParams(_))));
        assert!(matches!(hub.subscribe(&sub), Err(HubError::InvalidParams(_))));
    }
}

#[test]
fn invalid_page_table_combinations_are_parameter_errors() {
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    let root = RowKey::new("local", "root");
    for filter in [
        ListFilter {
            family: Some(root.clone()),
            forks: Some(root.clone()),
            ..ListFilter::default()
        },
        ListFilter {
            family: Some(root.clone()),
            folder: Some(acpmux_book::index::FolderKey::new("local", "one")),
            ..ListFilter::default()
        },
        ListFilter {
            forks: Some(root),
            folder: Some(acpmux_book::index::FolderKey::new("local", "one")),
            ..ListFilter::default()
        },
        ListFilter { cold: true, ..ListFilter::default() },
    ] {
        let mut request = page(filter);
        request.after = Some(Position::List(wire_key(SortKey::of(&Summary::new("anchor")))));
        assert!(matches!(hub.page(&request), Err(HubError::InvalidParams(_))));
    }
}

#[test]
fn restart_hydrates_tables_from_hot_rows_without_appending_log_records() {
    let dir = tempfile::tempdir().unwrap();
    let root = Summary::new("root");
    let mut child = Summary::new("child");
    child.state = "running".into();
    child.parent = Some(root.key());
    child.folder = Some("one".into());
    let full = SummaryIndex::new().apply(1, child);
    SortedSnapshot::write(dir.path().join("index.snap"), &full).unwrap();
    let mut log_bytes = None;
    for boot in [1, 2] {
        let (hub, mut writer) = Hub::open(dir.path(), boot, || boot as u32 + 1).unwrap();
        let before = fs::read(dir.path().join("index.log")).unwrap();
        if let Some(previous) = &log_bytes {
            assert_eq!(previous, &before);
        }
        writer.start_hydration();
        for _ in 0..5 {
            writer.process_batch();
            if writer.hydration.is_none() {
                break;
            }
        }
        assert!(writer.hydration.is_none());
        assert_eq!(hub.snapshot().kin(), full.kin());
        let reply: PageResult<Summary> =
            hub.page(&page(ListFilter::family(root.key()))).unwrap().decode_json().unwrap();
        assert_eq!(reply.rows.len(), 1);
        let after = fs::read(dir.path().join("index.log")).unwrap();
        assert_eq!(before, after);
        log_bytes = Some(after);
    }
}

#[test]
fn live_pages_refuse_every_table_filter_even_with_keys() {
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    for filter in [
        ListFilter::family(RowKey::new("local", "root")),
        ListFilter::forks(RowKey::new("local", "root")),
        ListFilter::folder(acpmux_book::index::FolderKey::new("local", "one")),
        ListFilter { cold: true, ..ListFilter::default() },
    ] {
        let mut request = page(filter);
        request.view = Some(crate::wire::ListView::Live);
        assert!(matches!(hub.page(&request), Err(HubError::InvalidParams(_))));
        request.keys = Some(vec![wire_key(SortKey::of(&Summary::new("key"))).into()]);
        assert!(matches!(hub.page(&request), Err(HubError::InvalidParams(_))));
    }
}
