use super::*;
use std::collections::BTreeMap;

fn row(origin: &str, chat: &str) -> RowKey {
    RowKey::new(origin, chat)
}

fn entry(origin: &str, folder: &str, chat: &str, at: u64, count: u32) -> FolderEntry {
    FolderEntry::new(origin, folder, Some(row(origin, chat)), at, count)
}

#[test]
fn newest_first_and_equal_update_is_silent() {
    let folders = Folders::new();
    let (folders, first) = folders.apply(entry("local", "/a", "one", 2, 1)).unwrap();
    assert!(matches!(first, Some(FolderOp::Folder(_))));
    let (_, equal) = folders.apply(entry("local", "/a", "one", 2, 1)).unwrap();
    assert!(equal.is_none());
    let (folders, _) = folders.apply(entry("local", "/b", "two", 4, 1)).unwrap();
    let page = folders.window(10, MAX_FOLDER_PAGE_BYTES).unwrap();
    assert_eq!(page.rows.iter().map(|row| row.folder.as_ref()).collect::<Vec<_>>(), ["/b", "/a"]);
}

#[test]
fn moving_newest_updates_order_and_leaving_emits_gone() {
    let (folders, _) = Folders::new().apply(entry("local", "/a", "one", 2, 1)).unwrap();
    let (folders, op) = folders.apply(entry("local", "/a", "two", 3, 2)).unwrap();
    assert!(matches!(op, Some(FolderOp::Folder(_))));
    let (folders, gone) = folders.apply(FolderEntry::new("local", "/a", None, 0, 0)).unwrap();
    assert!(matches!(gone, Some(FolderOp::Gone(_))));
    assert!(folders.is_empty());
}

#[test]
fn cursor_pages_are_stable_and_bounded() {
    let (folders, _) = Folders::new().apply(entry("local", "/a", "one", 3, 1)).unwrap();
    let (folders, _) = folders.apply(entry("local", "/b", "two", 2, 1)).unwrap();
    let first = folders.window(1, MAX_FOLDER_PAGE_BYTES).unwrap();
    assert!(first.has_after);
    let next = folders.page_after(first.after_key.as_ref(), 1, MAX_FOLDER_PAGE_BYTES).unwrap();
    assert_eq!(next.rows.len(), 1);
    assert!(!next.has_after);
    assert!(next.has_before);
}

#[test]
fn origin_filter_and_inclusive_anchor_follow_list_rules() {
    let (folders, _) = Folders::new().apply(entry("local", "/a", "one", 3, 1)).unwrap();
    let (folders, _) = folders.apply(entry("peer", "/b", "two", 2, 1)).unwrap();
    let filter = ListFilter { origin: Some("peer".into()), ..ListFilter::default() };
    let page = folders
        .read_page(None, FolderReadSide::After, false, 10, MAX_FOLDER_PAGE_BYTES, Some(&filter))
        .unwrap();
    assert_eq!(page.rows.len(), 1);
    assert_eq!(page.rows[0].origin.as_ref(), "peer");
    let anchor = FolderCursor::new(2, page.rows[0].key());
    let inclusive = folders
        .read_page(
            Some(&anchor),
            FolderReadSide::After,
            true,
            1,
            MAX_FOLDER_PAGE_BYTES,
            Some(&filter),
        )
        .unwrap();
    assert_eq!(inclusive.rows[0].key(), anchor.key);
}

#[test]
fn page_bounds_and_byte_budget_are_refused() {
    let (folders, _) = Folders::new().apply(entry("local", "/a", "one", 1, 1)).unwrap();
    assert!(folders.window(MAX_FOLDER_ROWS + 1, MAX_FOLDER_PAGE_BYTES).is_err());
    assert!(folders.window(1, 1).is_err());
}

#[test]
fn ties_page_in_both_directions_and_byte_budget_stops_after_one() {
    let (folders, _) = Folders::new().apply(entry("local", "/a", "a", 7, 1)).unwrap();
    let (folders, _) = folders.apply(entry("local", "/b", "b", 7, 1)).unwrap();
    let (folders, _) = folders.apply(entry("local", "/c", "c", 7, 1)).unwrap();
    let first = folders.window(1, MAX_FOLDER_PAGE_BYTES).unwrap();
    let second = folders.page_after(first.after_key.as_ref(), 1, MAX_FOLDER_PAGE_BYTES).unwrap();
    let before =
        folders.page_before(second.before_key.as_ref().unwrap(), 1, MAX_FOLDER_PAGE_BYTES).unwrap();
    assert_eq!(before.rows[0].key(), first.rows[0].key());
    let row_bytes = first.rows[0].encoded_len() + 1;
    let bounded = folders.window(3, row_bytes).unwrap();
    assert_eq!(bounded.rows.len(), 1);
    assert!(bounded.has_after);
}

#[test]
fn oversized_keys_and_invalid_counts_are_refused() {
    assert!(
        Folders::new()
            .apply(FolderEntry::new(
                "o".repeat(MAX_FIELD_BYTES + 1),
                "/f",
                Some(row("o", "c")),
                1,
                1
            ))
            .is_err()
    );
    assert!(
        Folders::new()
            .apply(FolderEntry::new(
                "local",
                &*"f".repeat(MAX_FOLDER_BYTES + 1),
                Some(row("local", "c")),
                1,
                1
            ))
            .is_err()
    );
    assert!(Folders::new().apply(FolderEntry::new("local", "/f", None, 1, 1)).is_err());
    assert!(
        Folders::new()
            .apply(FolderEntry::new("local", "/f", Some(row("local", "c")), 1, 0))
            .is_err()
    );
}

#[test]
fn before_cursor_whose_row_left_still_reads_prior_candidates() {
    let (folders, _) = Folders::new().apply(entry("local", "/a", "a", 3, 1)).unwrap();
    let (folders, _) = folders.apply(entry("local", "/b", "b", 2, 1)).unwrap();
    let cursor = FolderCursor::new(2, FolderKey::new("local", "/b"));
    let (folders, _) = folders.apply(FolderEntry::new("local", "/b", None, 0, 0)).unwrap();
    let page = folders.page_before(&cursor, 1, MAX_FOLDER_PAGE_BYTES).unwrap();
    assert_eq!(page.rows[0].folder.as_ref(), "/a");
}

#[test]
fn filtered_candidates_consume_limit_and_keep_continuation() {
    let folders = (0..2_000).fold(Folders::new(), |folders, n| {
        folders
            .apply(entry("local", &format!("/folder-{n:04}"), "chat", n as u64 + 1, 1))
            .unwrap()
            .0
    });
    let filter = ListFilter { origin: Some("peer".into()), ..ListFilter::default() };
    let visits = std::cell::Cell::new(0);
    let page = folders
        .read_page_visible(
            None,
            FolderReadSide::After,
            false,
            (20, MAX_FOLDER_PAGE_BYTES),
            Some(&filter),
            |_| {
                visits.set(visits.get() + 1);
                true
            },
        )
        .unwrap();
    assert_eq!(visits.get(), 20, "hidden candidates consume the same bound");
    assert!(page.rows.is_empty());
    assert_eq!(page.bytes_read, 0);
    assert!(page.after_key.is_some());
    assert!(page.has_after);
}

#[test]
fn hidden_prefix_preserves_continuation_before_an_oversized_matching_row() {
    let (folders, _) = Folders::new().apply(entry("hidden", "/a", "a", 2, 1)).unwrap();
    let (folders, _) = folders.apply(entry("visible", "/b", "b", 1, 1)).unwrap();
    let filter = ListFilter { origin: Some("visible".into()), ..ListFilter::default() };
    let page = folders.read_page(None, FolderReadSide::After, false, 20, 1, Some(&filter)).unwrap();
    assert!(page.rows.is_empty());
    assert!(page.has_after);
    let cursor = page.after_key.unwrap();
    assert_eq!(cursor.key.origin.as_ref(), "hidden");
    assert!(
        folders
            .read_page(Some(&cursor), FolderReadSide::After, false, 20, 1, Some(&filter))
            .is_err()
    );
}

#[test]
fn ten_thousand_random_updates_match_rebuild_from_entries() {
    let mut seed = 0x5f_u64;
    let mut folders = Folders::new();
    let mut model = BTreeMap::<FolderKey, FolderEntry>::new();
    for step in 0..10_000 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        let origin = if seed & 1 == 0 { "local" } else { "peer" };
        let folder = format!("/folder-{}", (seed >> 8) % 17);
        let key = FolderKey::new(origin, folder.clone());
        let entry = if seed & 8 == 0 {
            FolderEntry::new(origin, folder, None, 0, 0)
        } else {
            FolderEntry::new(
                origin,
                folder,
                Some(RowKey::new(origin, format!("chat-{}", (seed >> 16) % 41))),
                step as u64 + 1,
                ((seed >> 24) % 5 + 1) as u32,
            )
        };
        folders = folders.apply(entry.clone()).unwrap().0;
        if entry.newest.is_some() {
            model.insert(key, entry);
        } else {
            model.remove(&key);
        }
        let rebuilt = model
            .values()
            .cloned()
            .try_fold(Folders::new(), |view, entry| view.apply(entry).map(|(view, _)| view))
            .unwrap();
        let actual =
            folders.iter().map(|row| (row.key(), row.as_ref().clone())).collect::<Vec<_>>();
        let expected =
            rebuilt.iter().map(|row| (row.key(), row.as_ref().clone())).collect::<Vec<_>>();
        assert_eq!(actual, expected, "mismatch at random step {step}");
    }
}

#[test]
fn folder_bound_is_kept_whole() {
    let folder = "f".repeat(MAX_FOLDER_BYTES);
    let (folders, op) = Folders::new().apply(entry("local", &folder, "one", 1, 1)).unwrap();
    assert!(op.is_some());
    let row = folders.iter().next().expect("row");
    assert_eq!(row.folder.len(), MAX_FOLDER_BYTES);
}
