//! Contract tests for the hot/cold kin and folder pagers.

use super::*;

fn row(id: &str, activity: u64) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = activity;
    row
}

fn parent(mut row: Summary, parent: &Summary) -> Summary {
    row.parent = Some(parent.key());
    row
}

fn fork(mut row: Summary, source: &Summary) -> Summary {
    row.fork_of = Some(ForkOf { key: source.key(), seq: 1 });
    row
}

fn cold(rows: &[Summary]) -> (tempfile::TempDir, SummaryIndex) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("index.snap");
    let mut full = SummaryIndex::new();
    for (seq, row) in rows.iter().enumerate() {
        full = full.apply(seq as u64 + 1, row.clone());
    }
    SortedSnapshot::write(&path, &full).unwrap();
    let disk = DiskSnapshot::open(&path).unwrap().unwrap();
    (dir, SummaryIndex::from_disk(Some(disk), 1))
}

fn ids(page: &IndexPage) -> Vec<&str> {
    page.rows.iter().map(|row| row.chat_id.as_str()).collect()
}

fn scan_after(
    index: &SummaryIndex,
    filter: &ListFilter,
    limit: usize,
    max_bytes: usize,
) -> (Vec<String>, usize, usize, usize) {
    let mut anchor = None;
    let mut found = Vec::new();
    let mut pages = 0;
    let mut rows_read = 0;
    let mut parent_steps = 0;
    loop {
        let page = index
            .read_page(anchor.as_ref(), ReadSide::After, false, limit, max_bytes, Some(filter))
            .unwrap();
        pages += 1;
        rows_read += page.rows_read;
        parent_steps += page.parent_steps;
        found.extend(page.rows.iter().map(|row| row.chat_id.clone()));
        if !page.has_after {
            return (found, pages, rows_read, parent_steps);
        }
        let next = page.after_key.expect("a continued page must expose its physical cursor");
        assert_ne!(anchor.as_ref(), Some(&next), "continuation must make progress");
        anchor = Some(next);
        assert!(pages < 512, "pager did not terminate");
    }
}

fn invalid_filter(mut filter: ListFilter) {
    let index = SummaryIndex::new();
    assert!(index.read_page(None, ReadSide::After, false, 2, 4096, Some(&filter)).is_err());
    filter.cold = true;
    assert!(index.read_page(None, ReadSide::After, false, 2, 4096, Some(&filter)).is_err());
}

#[test]
fn hot_family_is_preorder_without_fork_tail_and_has_stable_cursors() {
    let root = row("root", 1);
    let a = parent(row("a", 10), &root);
    let a1 = parent(row("a1", 1000), &a);
    let a2 = parent(row("a2", 900), &a);
    let b = parent(row("b", 20), &root);
    let b1 = parent(row("b1", 800), &b);
    let fork_descendant = parent(fork(row("fork", 700), &root), &root);
    let fork_tail = fork(row("tail", 600), &root);
    let detached = parent(row("detached", 500), &row("elsewhere", 1));
    let a_anchor = a.clone();
    let mut index = SummaryIndex::new();
    for (seq, item) in
        [a, a1, a2, b, b1, fork_descendant, fork_tail, detached].into_iter().enumerate()
    {
        index = index.apply(seq as u64 + 1, item);
    }
    let filter = ListFilter::family(root.key());
    let page =
        index.read_page(None, ReadSide::After, false, 20, 256 * 1024, Some(&filter)).unwrap();
    assert_eq!(ids(&page), ["a", "a1", "a2", "b", "b1", "fork"]);
    assert!(
        page.rows.iter().all(|row| { serde_json::to_value(row).unwrap().get("depth").is_none() })
    );
    assert!(!page.cold_unread);

    assert!(index.read_page(None, ReadSide::Before, false, 2, 4096, Some(&filter)).is_err());
    assert!(index.read_page(None, ReadSide::Around, false, 2, 4096, Some(&filter)).is_err());

    let mut stale = SortKey::of(&a_anchor);
    stale.last_activity = 9_999;
    let continued = index
        .read_page(Some(&stale), ReadSide::After, false, 20, 256 * 1024, Some(&filter))
        .unwrap();
    assert_eq!(ids(&continued), ["a1", "a2", "b", "b1", "fork"]);

    let missing = SortKey::of(&row("missing", 50));
    let error = index
        .read_page(Some(&missing), ReadSide::After, false, 2, 4096, Some(&filter))
        .err()
        .expect("missing cursor must be rejected");
    assert!(error.to_string().contains("cursor_gone"));
    let detached_key = SortKey::of(&row("detached", 500));
    let error = index
        .read_page(Some(&detached_key), ReadSide::After, false, 2, 4096, Some(&filter))
        .err()
        .expect("detached cursor must be rejected");
    assert!(error.to_string().contains("cursor_gone"));

    let leaf = parent(row("leaf", 2), &root);
    let leaf_key = SortKey::of(&leaf);
    let index = index.apply(99, leaf).remove_row(100, &RowKey::new("local", "leaf")).unwrap();
    let error = index
        .read_page(Some(&leaf_key), ReadSide::After, false, 2, 4096, Some(&filter))
        .err()
        .expect("evicted cursor must be rejected");
    assert!(error.to_string().contains("cursor_gone"));
}

#[test]
fn forks_are_rowkey_ranges_and_family_and_forks_are_distinct_answers() {
    let root = row("root", 0);
    let mut first = parent(fork(row("fork-a", 1), &root), &root);
    first.last_activity = 1;
    let second = fork(row("fork-b", 2), &root);
    let unrelated = row("other", 3);
    let mut index = SummaryIndex::new();
    for (seq, item) in [first.clone(), second.clone(), unrelated].into_iter().enumerate() {
        index = index.apply(seq as u64 + 1, item);
    }
    let filter = ListFilter::forks(root.key());
    let first_page =
        index.read_page(None, ReadSide::After, false, 1, 256 * 1024, Some(&filter)).unwrap();
    assert_eq!(ids(&first_page), ["fork-a"]);
    assert!(first_page.has_after);
    let second_page = index
        .read_page(
            first_page.after_key.as_ref(),
            ReadSide::After,
            false,
            1,
            256 * 1024,
            Some(&filter),
        )
        .unwrap();
    assert_eq!(ids(&second_page), ["fork-b"]);
    assert!(!second_page.has_after);
    let before = index
        .read_page(
            Some(&SortKey::of(&second)),
            ReadSide::Before,
            false,
            1,
            256 * 1024,
            Some(&filter),
        )
        .unwrap();
    assert_eq!(ids(&before), ["fork-a"]);

    let family = index
        .read_page(
            None,
            ReadSide::After,
            false,
            10,
            256 * 1024,
            Some(&ListFilter::family(root.key())),
        )
        .unwrap();
    assert_eq!(ids(&family), ["fork-a"]);

    let removed = index.remove_row(100, &first.key()).unwrap();
    let after_departed = removed
        .read_page(Some(&SortKey::of(&first)), ReadSide::After, false, 1, 4096, Some(&filter))
        .unwrap();
    assert_eq!(ids(&after_departed), ["fork-b"]);

    let (_dir, cold_index) = cold(&[first, second, row("not-a-fork", 3)]);
    let mut cold_filter = ListFilter::forks(root.key());
    cold_filter.cold = true;
    let cold_page = cold_index
        .read_page(None, ReadSide::After, false, 10, 256 * 1024, Some(&cold_filter))
        .unwrap();
    assert_eq!(ids(&cold_page), ["fork-b", "fork-a"]);
    assert!(cold_page.rows.iter().all(|row| row.chat_id != "not-a-fork"));

    invalid_filter({
        let mut filter = ListFilter::family(root.key());
        filter.forks = Some(root.key());
        filter
    });
    invalid_filter({
        let mut filter = ListFilter::family(root.key());
        filter.folder = Some(FolderKey::new("local", "one"));
        filter
    });
    invalid_filter({
        let mut filter = ListFilter::forks(root.key());
        filter.folder = Some(FolderKey::new("local", "one"));
        filter
    });
    let cold_alone = ListFilter { cold: true, ..ListFilter::default() };
    assert!(
        SummaryIndex::new()
            .read_page(None, ReadSide::After, false, 2, 4096, Some(&cold_alone))
            .is_err()
    );
}

#[test]
fn cold_family_uses_only_hot_ancestry_and_bounds_cycles() {
    let root = row("root", 1);
    let direct = parent(row("direct", 10), &root);
    let disk_parent = parent(row("disk-parent", 20), &root);
    let disk_child = parent(row("disk-child", 30), &disk_parent);
    let forked = fork(row("forked", 40), &root);

    let mut hot_parent = root.clone();
    let mut hot_chain = Vec::new();
    for n in 0..64 {
        let next = parent(row(&format!("hot-{n:02}"), 100 + n), &hot_parent);
        hot_chain.push(next.clone());
        hot_parent = next;
    }
    let chain_leaf = parent(row("chain-leaf", 200), &hot_parent);
    let mut too_deep_parent = root.clone();
    let mut too_deep = Vec::new();
    for n in 0..65 {
        let next = parent(row(&format!("too-deep-{n:02}"), 300 + n), &too_deep_parent);
        too_deep.push(next.clone());
        too_deep_parent = next;
    }
    let too_deep_leaf = parent(row("too-deep-leaf", 400), &too_deep_parent);
    let mut cycle_a = row("cycle-a", 500);
    let mut cycle_b = row("cycle-b", 501);
    cycle_a.parent = Some(cycle_b.key());
    cycle_b.parent = Some(cycle_a.key());
    let cycle_leaf = parent(row("cycle-leaf", 502), &cycle_a);

    let disk_rows =
        vec![direct, disk_parent, disk_child, forked, chain_leaf, too_deep_leaf, cycle_leaf];
    let (_dir, mut index) = cold(&disk_rows);
    // The complete hot chains are intentionally installed after the snapshot;
    // a disk row may use them, but a disk parent may not resolve another disk row.
    for (seq, row) in hot_chain.into_iter().enumerate() {
        index = index.apply(seq as u64 + 1, row);
    }
    for (seq, row) in too_deep.into_iter().enumerate() {
        index = index.apply(seq as u64 + 100, row);
    }
    index = index.apply(200, cycle_a).apply(201, cycle_b);

    let mut filter = ListFilter::family(root.key());
    filter.cold = true;
    let (found, _pages, _reads, steps) = scan_after(&index, &filter, 2, 256 * 1024);
    assert!(found.contains(&"direct".to_owned()));
    assert!(found.contains(&"chain-leaf".to_owned()));
    assert!(!found.contains(&"disk-child".to_owned()));
    assert!(!found.contains(&"forked".to_owned()));
    assert!(!found.contains(&"too-deep-leaf".to_owned()));
    assert!(!found.contains(&"cycle-leaf".to_owned()));
    assert!(steps <= 64 * 20, "parent walk must stay bounded");
}

#[test]
fn family_pages_scan_two_thousand_rows_once_with_bounded_reads() {
    let root = row("root", 0);
    let mut index = SummaryIndex::new();
    for n in 0..2000 {
        let child = parent(row(&format!("child-{n:04}"), n as u64), &root);
        index = index.apply(n as u64 + 1, child);
    }
    let filter = ListFilter::family(root.key());
    let (found, pages, rows_read, parent_steps) = scan_after(&index, &filter, 50, 256 * 1024);
    let unique: std::collections::HashSet<_> = found.iter().collect();
    assert_eq!(found.len(), 2000);
    assert_eq!(unique.len(), 2000);
    assert_eq!(pages, 40);
    assert!(rows_read <= 2000 + 40 * (1 + 64));
    assert!(parent_steps <= 40 * 64);
    assert!(rows_read + parent_steps < 4600);
}

#[test]
fn hot_and_cold_pages_are_separate_and_signal_remaining_cold_rows() {
    let mut old = row("old", 100);
    old.folder = Some("one".to_owned());
    let (_dir, mut index) = cold(&[old]);
    let mut hot_a = row("hot-a", 20);
    hot_a.folder = Some("one".to_owned());
    let mut hot_b = row("hot-b", 10);
    hot_b.folder = Some("one".to_owned());
    index = index.apply(2, hot_a).apply(3, hot_b);
    let filter = ListFilter::folder(FolderKey::new("local", "one"));
    let page = index.read_page(None, ReadSide::After, false, 1, 256 * 1024, Some(&filter)).unwrap();
    assert_eq!(ids(&page), ["hot-a"]);
    assert!(page.has_after, "has_after is about hot rows for a hot table");
    let last = index
        .read_page(page.after_key.as_ref(), ReadSide::After, false, 1, 256 * 1024, Some(&filter))
        .unwrap();
    assert_eq!(ids(&last), ["hot-b"]);
    assert!(!last.has_after);
    assert!(last.cold_unread, "a nonempty snapshot remains after the hot last page");

    let mut cold_filter = filter;
    cold_filter.cold = true;
    let cold_page =
        index.read_page(None, ReadSide::After, false, 10, 256 * 1024, Some(&cold_filter)).unwrap();
    assert_eq!(ids(&cold_page), ["old"]);
    assert!(!cold_page.rows.iter().any(|row| row.chat_id.starts_with("hot-")));
}

#[test]
fn filtered_cold_continuations_and_shadowed_rows_make_progress() {
    let mut unrelated = row("unrelated", 100);
    unrelated.folder = Some("other".to_owned());
    let mut match_one = row("match-one", 90);
    match_one.folder = Some("one".to_owned());
    let mut match_two = row("match-two", 80);
    match_two.folder = Some("one".to_owned());
    let (_dir, index) = cold(&[unrelated, match_one, match_two]);
    let mut filter = ListFilter::folder(FolderKey::new("local", "one"));
    filter.cold = true;
    let (found, pages, _, _) = scan_after(&index, &filter, 1, 4 * 1024);
    assert_eq!(found, ["match-one", "match-two"]);
    assert!(pages >= 2, "a filtered physical piece still needs continuation");

    let mut old = row("shadowed", 50);
    old.folder = Some("one".to_owned());
    let (_dir, index) = cold(&[old.clone()]);
    let mut replacement = old;
    replacement.last_activity = 60;
    let index = index.apply(2, replacement);
    let mut cold_filter = ListFilter::folder(FolderKey::new("local", "one"));
    cold_filter.cold = true;
    let cold_page =
        index.read_page(None, ReadSide::After, false, 10, 256 * 1024, Some(&cold_filter)).unwrap();
    assert!(cold_page.rows.is_empty(), "the disk generation is shadowed by the hot row");
    let hot_page = index
        .read_page(
            None,
            ReadSide::After,
            false,
            10,
            256 * 1024,
            Some(&ListFilter::folder(FolderKey::new("local", "one"))),
        )
        .unwrap();
    assert_eq!(ids(&hot_page), ["shadowed"]);
}

#[test]
fn folder_ranges_are_exclusive_in_both_directions_and_honor_departed_anchors() {
    let mut newest = row("newest", 30);
    newest.folder = Some("one".to_owned());
    let mut middle = row("middle", 20);
    middle.folder = Some("one".to_owned());
    let mut oldest = row("oldest", 10);
    oldest.folder = Some("one".to_owned());
    let mut index = SummaryIndex::new();
    for (seq, row) in [newest, middle.clone(), oldest].into_iter().enumerate() {
        index = index.apply(seq as u64 + 1, row);
    }
    let filter = ListFilter::folder(FolderKey::new("local", "one"));
    let anchor = SortKey::of(&middle);
    let before = index
        .read_page(Some(&anchor), ReadSide::Before, false, 10, 256 * 1024, Some(&filter))
        .unwrap();
    assert_eq!(ids(&before), ["newest"]);
    let after = index
        .read_page(Some(&anchor), ReadSide::After, false, 10, 256 * 1024, Some(&filter))
        .unwrap();
    assert_eq!(ids(&after), ["oldest"]);
    assert!(!ids(&before).contains(&"middle"));
    assert!(!ids(&after).contains(&"middle"));

    let removed = index.remove_row(10, &middle.key()).unwrap();
    let departed_before = removed
        .read_page(Some(&anchor), ReadSide::Before, false, 10, 256 * 1024, Some(&filter))
        .unwrap();
    assert_eq!(ids(&departed_before), ["newest"]);
    let departed_after = removed
        .read_page(Some(&anchor), ReadSide::After, false, 10, 256 * 1024, Some(&filter))
        .unwrap();
    assert_eq!(ids(&departed_after), ["oldest"]);

    let mut large = Vec::new();
    for n in 0..32 {
        let mut row = row(&format!("large-{n:02}"), 100 - n);
        row.folder = Some("large".to_owned());
        row.title = "x".repeat(900);
        large.push(row);
    }
    let (_dir, disk) = cold(&large);
    let mut cold_filter = ListFilter::folder(FolderKey::new("local", "large"));
    cold_filter.cold = true;
    let narrow =
        disk.read_page(None, ReadSide::After, false, 32, 4 * 1024, Some(&cold_filter)).unwrap();
    let wide =
        disk.read_page(None, ReadSide::After, false, 32, 256 * 1024, Some(&cold_filter)).unwrap();
    assert!(narrow.rows.len() < wide.rows.len());
    assert!(narrow.rows.iter().map(|row| row.encoded_len() + 1).sum::<usize>() <= 4 * 1024);
    assert!(wide.rows.iter().map(|row| row.encoded_len() + 1).sum::<usize>() <= 256 * 1024);
}

#[test]
fn cold_ancestor_hides_hot_subtree_and_invalidates_its_cursors() {
    let root = row("root", 0);
    let p = parent(row("p", 20), &root);
    let c = parent(row("c", 10), &p);
    let (_dir, mut index) = cold(std::slice::from_ref(&p));
    index = index.apply(2, c.clone());
    let filter = ListFilter::family(root.key());
    let page =
        index.read_page(None, ReadSide::After, false, 10, 256 * 1024, Some(&filter)).unwrap();
    assert!(page.rows.is_empty(), "a cold parent makes its hot descendants unreachable");
    for anchor in [SortKey::of(&p), SortKey::of(&c)] {
        let error = index
            .read_page(Some(&anchor), ReadSide::After, false, 10, 256 * 1024, Some(&filter))
            .err()
            .expect("cold ancestor cursor must be rejected");
        assert!(error.to_string().contains("cursor_gone"));
    }
}

#[test]
fn hot_family_cycles_depth_and_hidden_candidates_are_bounded() {
    let mut root = row("root", 0);
    let a = parent(row("a", 1), &root);
    let b = parent(row("b", 2), &a);
    root.parent = Some(b.key());
    let index = SummaryIndex::new().apply(1, root.clone()).apply(2, a).apply(3, b);
    let (found, _, reads, climb) = scan_after(&index, &ListFilter::family(root.key()), 1, 4096);
    assert_eq!(found, ["a", "b"]);
    assert!(reads + climb < 10);

    let mut last = root.clone();
    let mut deep = SummaryIndex::new();
    for n in 0..65 {
        let child = parent(row(&format!("depth-{n:02}"), n), &last);
        deep = deep.apply(n + 1, child.clone());
        last = child;
    }
    let (found, _, _, climb) = scan_after(&deep, &ListFilter::family(root.key()), 16, 4096);
    assert_eq!(found.len(), 64);
    assert!(climb <= 4 * 64);
    assert!(
        deep.read_page(
            Some(&SortKey::of(&last)),
            ReadSide::After,
            false,
            1,
            4096,
            Some(&ListFilter::family(root.key()))
        )
        .is_err()
    );

    let mut hidden = parent(row("a-hidden", 2), &root);
    hidden.state = "closed".into();
    let mut visible = parent(row("b-visible", 1), &root);
    visible.state = "running".into();
    let index = SummaryIndex::new().apply(1, hidden).apply(2, visible);
    let mut filter = ListFilter::family(root.key());
    filter.state = Some("running".into());
    let first = index.read_page(None, ReadSide::After, false, 1, 4096, Some(&filter)).unwrap();
    assert!(first.rows.is_empty());
    assert!(first.has_after);
    assert_eq!(first.after_key.as_ref().unwrap().row.chat_id.as_ref(), "a-hidden");
    let second = index
        .read_page(first.after_key.as_ref(), ReadSide::After, false, 1, 4096, Some(&filter))
        .unwrap();
    assert_eq!(ids(&second), ["b-visible"]);
}

#[test]
fn cold_family_piece_sizes_agree_and_a_second_ask_reaches_the_next_cold_level() {
    let root = row("root", 0);
    let cold_parent = parent(row("cold-parent", 1000), &root);
    let cold_child = parent(row("cold-child", 500), &cold_parent);
    let hot = parent(row("hot", 1), &root);
    let through_hot = parent(row("through-hot", 100), &hot);
    let mut rows = vec![cold_parent.clone(), cold_child, through_hot];
    for n in 0..200 {
        let mut filler = row(&format!("filler-{n:03}"), n + 200);
        filler.title = "x".repeat(256);
        rows.push(filler);
    }
    let (_dir, index) = cold(&rows);
    let index = index.apply(300, hot);
    let filter = ListFilter { family: Some(root.key()), cold: true, ..ListFilter::default() };
    let narrow = scan_after(&index, &filter, 400, 4096);
    let wide = scan_after(&index, &filter, 400, 256 * 1024);
    assert_eq!(narrow.0, wide.0);
    assert_eq!(narrow.0, ["cold-parent", "through-hot"]);
    assert!(narrow.1 > wide.1, "fixtures must use different physical pieces");
    let deeper =
        ListFilter { family: Some(cold_parent.key()), cold: true, ..ListFilter::default() };
    assert_eq!(scan_after(&index, &deeper, 400, 4096).0, ["cold-child"]);
}

#[test]
fn exclusive_table_boundaries_and_directional_byte_caps_keep_the_nearest_candidate() {
    let source = row("source", 0);
    let mut all = Vec::new();
    for n in 0..3 {
        let mut item = fork(row(&format!("row-{n}"), 3 - n), &source);
        item.folder = Some("one".into());
        item.title = "x".repeat(256);
        all.push(item);
    }
    let index = all
        .iter()
        .enumerate()
        .fold(SummaryIndex::new(), |index, (n, row)| index.apply(n as u64 + 1, row.clone()));
    let first = SortKey::of(all.first().unwrap());
    let last = SortKey::of(all.last().unwrap());
    for filter in
        [ListFilter::folder(FolderKey::new("local", "one")), ListFilter::forks(source.key())]
    {
        let before =
            index.read_page(Some(&first), ReadSide::Before, false, 3, 4096, Some(&filter)).unwrap();
        assert!(before.rows.is_empty() && before.has_after && !before.has_before);
        let after =
            index.read_page(Some(&last), ReadSide::After, false, 3, 4096, Some(&filter)).unwrap();
        assert!(after.rows.is_empty() && after.has_before && !after.has_after);
        let budget = all.get(1).unwrap().encoded_len() + 1;
        let before = index
            .read_page(Some(&last), ReadSide::Before, false, 3, budget, Some(&filter))
            .unwrap();
        assert_eq!(ids(&before), ["row-1"]);
        let anchor = SortKey::of(all.get(1).unwrap());
        let around = index
            .read_page(Some(&anchor), ReadSide::Around, false, 3, budget, Some(&filter))
            .unwrap();
        assert_eq!(ids(&around), ["row-1"]);
        assert!(around.has_before && around.has_after);
        assert!(around.rows_read <= 4);
    }
}
