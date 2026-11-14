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
    assert!(folder_sub.receiver.try_next().is_none());
    writer.apply(row("two", "/b", 4)).unwrap();
    assert_eq!(take(&folder_sub.receiver).len(), 1);
}

#[test]
fn folder_move_is_one_counter_step_and_reconnect_is_always_a_window() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(row("one", "/a", 1)).unwrap();
    let subscription = hub.subscribe(&sub()).unwrap();
    writer.apply(row("one", "/b", 2)).unwrap();
    let mut title = row("one", "/b", 2);
    title.title = "changed".into();
    writer.apply(title).unwrap();
    let RawRead::Span(span) = subscription.receiver.try_next_raw(None, 256 * 1024).unwrap() else {
        panic!("span")
    };
    assert_eq!(span.last_seq, subscription.cursor + 1);
    let decoded: Vec<serde_json::Value> =
        serde_json::from_slice(format!("[{}]", String::from_utf8(span.bytes).unwrap()).as_bytes())
            .unwrap();
    assert_eq!(decoded.len(), 2);
    assert!(
        decoded
            .iter()
            .all(|op| op.get("seq").and_then(serde_json::Value::as_u64) == Some(span.last_seq))
    );
    assert!(subscription.receiver.try_next().is_none());
    let mut reconnect = sub();
    reconnect.cursor = Some(crate::wire::Cursor(u64::MAX));
    reconnect.edition = Some(u32::MAX);
    let fresh = hub.subscribe(&reconnect).unwrap();
    let window: FolderWindow = fresh.window.decode_json().unwrap();
    assert_eq!(window.cursor, span.last_seq);
    assert_eq!(
        window.rows,
        hub.snapshot().folders().iter().map(|row| row.as_ref().clone()).collect::<Vec<_>>()
    );
    assert!(hub.subscribe_replay(&reconnect, 1).is_err());
    writer.apply(row("one", "/b", 4)).unwrap();
    writer.apply(row("one", "/b", 5)).unwrap();
    let RawRead::Span(span) = fresh.receiver.try_next_raw(None, 256 * 1024).unwrap() else {
        panic!("fresh folder subscribers replay the retained tail")
    };
    let decoded: Vec<serde_json::Value> =
        serde_json::from_slice(format!("[{}]", String::from_utf8(span.bytes).unwrap()).as_bytes())
            .unwrap();
    assert_eq!(decoded.len(), 2);
    let seqs: Vec<u64> = decoded
        .iter()
        .map(|op| op.get("seq").and_then(serde_json::Value::as_u64).unwrap())
        .collect();
    assert_eq!(seqs, vec![span.last_seq - 1, span.last_seq]);
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
    // Like summary keys, explicit identities are looked up independently of
    // the cursor walk's origin filter. No requested identity disappears.
    keyed.filter = Some(crate::wire::ListFilter {
        origin: Some("another-origin".into()),
        ..Default::default()
    });
    let filtered: FolderPageResult = hub.page(&keyed).unwrap().decode_json().unwrap();
    assert_eq!(filtered, reply);
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

#[tokio::test]
async fn folders_wait_for_the_complete_startup_head_and_propagate_failure() {
    use acpmux_book::index::SortedSnapshot;
    let dir = tempfile::tempdir().unwrap();
    let mut initial = SummaryIndex::new();
    for n in 0..300 {
        initial = initial.apply(n + 1, row(&format!("chat-{n}"), &format!("/folder-{n}"), n));
    }
    SortedSnapshot::write(dir.path().join("index.snap"), &initial).unwrap();
    let (hub, mut writer) = Hub::open(dir.path(), 1, || 7).unwrap();
    let hub = Arc::new(hub);
    let mut request = sub();
    request.window = Some(400);
    assert!(hub.list_window(&sub()).is_err());
    while writer.hydration.is_some() {
        writer.process_batch();
    }
    hub.wait_hydrated().await.unwrap();
    let window: FolderWindow = hub.subscribe(&request).unwrap().window.decode_json().unwrap();
    assert_eq!(window.rows.len(), 300);
    assert_eq!(window.cursor, 1, "startup sends no folder ops");
    let page_request = page(window.after_key.unwrap());
    writer.hydrated.send_replace(disk::HydrationState::Failed);
    assert!(hub.page_for_view(&page_request, Some(ListView::Folders)).is_err());
}

#[test]
fn folder_origin_events_use_the_folder_counter_and_cleanup_keeps_the_list_seq() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let mut remote = row("one", "/a", 1);
    remote.origin = "peer".into();
    writer.apply(remote).unwrap();
    let subscription = hub.subscribe(&sub()).unwrap();
    writer.origin("peer", OriginState::Removed, 2).unwrap();
    assert!(matches!(subscription.receiver.try_next(), Some(ListItem::Origin { seq, origin })
        if seq == subscription.cursor + 1 && origin.state == OriginState::Removed));
    let seq = hub.snapshot().seq();
    writer.advance_origins(256);
    assert_eq!(hub.snapshot().seq(), seq);
    assert!(subscription.receiver.try_next().is_none());
    let window: FolderWindow = hub.list_window(&sub()).unwrap().decode_json().unwrap();
    assert!(window.rows.is_empty());
}

#[test]
fn folder_subscriber_copy_matches_hot_rows_after_10k_changes_and_eviction_batches() {
    use std::collections::BTreeMap;
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let subscription = hub.subscribe(&sub()).unwrap();
    let mut held = BTreeMap::new();
    let mut random = 0x5f158_u64;
    for step in 0..10_000_u64 {
        random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
        let id = format!("chat-{}", (random >> 32) % 40);
        match random % 5 {
            0 => {
                writer.remove("local", &id).unwrap();
            }
            1 => {
                // A compaction's covered rows can leave without a log record.
                let current = hub.snapshot();
                let mut next = current.as_ref().clone();
                let mut touched = std::collections::BTreeSet::new();
                for row in current.iter().take(3) {
                    touched.insert(acpmux_book::index::FolderKey::of(row).unwrap());
                    next.evict_compacted(&row.key());
                }
                let ops = folders::changed_folders(&current, &next, touched);
                writer.publish_folder_index(next, &ops);
            }
            _ => {
                writer.apply(row(&id, &format!("/f-{}", random % 7), step)).unwrap();
            }
        }
        if let Some(item) = subscription.receiver.try_next() {
            let ListItem::Folders { ops, .. } = item else { panic!("one bounded change per step") };
            for op in ops {
                match op {
                    FolderOp::Folder(row) => {
                        held.insert(row.key(), row.as_ref().clone());
                    }
                    FolderOp::Gone(key) => {
                        held.remove(&key);
                    }
                }
            }
        }
        assert!(hub.folder_state.lock().unwrap().retained_bytes() <= 64 * 1024);
        let index = hub.snapshot();
        let mut model = BTreeMap::<FolderKey, (SortKey, RowKey, u32)>::new();
        for row in index.iter() {
            let key = FolderKey::new(row.origin.as_str(), row.folder.as_ref().unwrap().as_str());
            let sort = SortKey::of(row);
            let entry = model.entry(key).or_insert((sort.clone(), row.key(), 0));
            if sort < entry.0 {
                entry.0 = sort;
                entry.1 = row.key();
            }
            entry.2 += 1;
        }
        assert_eq!(held.len(), model.len(), "step {step}");
        for (key, (sort, newest, count)) in model {
            let actual = held.get(&key).unwrap();
            assert_eq!(
                (&actual.newest, actual.at, actual.count),
                (&newest, sort.last_activity, count),
                "step {step}"
            );
        }
    }
}

#[test]
fn folder_tail_replays_unread_steps_in_one_frame() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(row("one", "/a", 1)).unwrap();
    let subscription = hub.subscribe(&sub()).unwrap();
    for at in 2..102 {
        writer.apply(row("one", "/a", at)).unwrap();
    }
    let RawRead::Span(span) = subscription.receiver.try_next_raw(None, 256 * 1024).unwrap() else {
        panic!("expected retained folder tail")
    };
    let decoded: Vec<serde_json::Value> =
        serde_json::from_slice(format!("[{}]", String::from_utf8(span.bytes).unwrap()).as_bytes())
            .unwrap();
    assert_eq!(decoded.len(), 100);
    assert!(decoded.windows(2).all(|ops| {
        ops[1].get("seq").and_then(serde_json::Value::as_u64)
            == ops[0].get("seq").and_then(serde_json::Value::as_u64).map(|seq| seq + 1)
    }));
    assert!(subscription.receiver.try_next_raw(None, 256 * 1024).is_none());
}

#[test]
fn keyed_folder_pages_reserve_bytes_for_unanswered_identities() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let mut keys = Vec::new();
    for n in 0..10 {
        let folder = format!("/{}-{n}", "x".repeat(900));
        writer.apply(row(&format!("chat-{n}"), &folder, n)).unwrap();
        keys.push(crate::wire::FolderIdentity { origin: "local".into(), folder });
    }
    let key_bytes =
        keys.iter().map(|key| serde_json::to_vec(key).unwrap().len() + 1).sum::<usize>();
    let first = keys.first().unwrap();
    let first_row = hub
        .snapshot()
        .folders()
        .get(&FolderKey::new(first.origin.as_str(), first.folder.as_str()))
        .unwrap();
    let extra_row_bytes = first_row.encoded_len() - serde_json::to_vec(first).unwrap().len();
    let mut request = page(FolderPosition { at: 0, origin: "local".into(), folder: "/a".into() });
    request.after = None;
    let encoded_sid = serde_json::to_vec(&request.sid).unwrap();
    request.max_bytes = (8192 + encoded_sid.len() + key_bytes + extra_row_bytes) as u32;
    request.keys = Some(keys.iter().cloned().map(PageKey::Folder).collect());
    let frame = hub.page(&request).unwrap();
    assert!(frame.encoded_len() <= request.max_bytes as usize);
    let reply: FolderPageResult = frame.decode_json().unwrap();
    assert_eq!(reply.rows.len(), 1);
    assert_eq!(reply.rest, keys.into_iter().skip(1).collect::<Vec<_>>());
}

#[test]
fn oversized_folder_step_clears_the_tail_atomically() {
    for count in [70, 300] {
        let (hub, writer) = Hub::new(SummaryIndex::new());
        let subscription = hub.subscribe(&sub()).unwrap();
        let mut next = SummaryIndex::new();
        for n in 0..count {
            next = next
                .apply(n + 1, row(&format!("chat-{n}"), &format!("{}-{n}", "x".repeat(1000)), n));
        }
        let ops = next.folders().iter().cloned().map(FolderOp::Folder).collect::<Vec<_>>();
        writer.publish_folder_index(next, &ops);
        assert_eq!(hub.folder_state.lock().unwrap().retained_bytes(), 0);
        assert!(matches!(
            subscription.receiver.try_next_raw(None, 256 * 1024),
            Some(RawRead::Lagged)
        ));
        assert_eq!(hub.snapshot().folders().len(), count as usize);
    }
}

#[test]
fn folder_tail_byte_bound_never_splits_a_move() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(row("one", "/a", 1)).unwrap();
    let subscription = hub.subscribe(&sub()).unwrap();
    writer.apply(row("one", "/b", 2)).unwrap();
    let RawRead::Span(span) = subscription.receiver.try_next_raw(None, 256 * 1024).unwrap() else {
        panic!("move")
    };
    subscription.receiver.reposition(subscription.cursor);
    assert!(matches!(
        subscription.receiver.try_next_raw(None, span.bytes.len() - 1),
        Some(RawRead::Lagged)
    ));
    subscription.receiver.reposition(subscription.cursor);
    let RawRead::Span(exact) = subscription.receiver.try_next_raw(None, span.bytes.len()).unwrap()
    else {
        panic!("whole move")
    };
    assert_eq!(exact.bytes, span.bytes);
    assert_eq!(exact.last_seq, span.last_seq);
}
