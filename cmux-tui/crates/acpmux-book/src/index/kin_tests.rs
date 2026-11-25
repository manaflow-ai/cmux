use super::*;

fn row(id: &str, at: u64) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = at;
    row
}

#[test]
fn replacement_only_writes_changed_paths() {
    let mut first = row("chat", 1);
    first.origin = "machine".to_owned();
    first.folder = Some("one".to_owned());
    let mut second = first.clone();
    second.last_activity = 2;
    second.folder = Some("two".to_owned());
    let mut tables = KinTables::new();
    tables.insert(&first);
    let writes = AtomicUsize::new(0);
    let moved = tables.replace_counted(Some(&first), Some(&second), &writes);
    assert_eq!(writes.load(AtomicOrdering::Relaxed), 2);
    assert!(moved.folder_rows(&FolderKey::new("machine", "one")).is_none());
    assert_eq!(moved.folder_rows(&FolderKey::new("machine", "two")).unwrap().len(), 1);

    let mut title = second.clone();
    title.title.push('!');
    let writes = AtomicUsize::new(0);
    let unchanged = moved.replace_counted(Some(&second), Some(&title), &writes);
    assert_eq!(writes.load(AtomicOrdering::Relaxed), 1);
    assert_eq!(
        unchanged
            .folder_rows(&FolderKey::new("machine", "two"))
            .unwrap()
            .get(&SortKey::of(&title))
            .unwrap()
            .title,
        title.title
    );
}

#[test]
fn randomized_lifecycle_rebuild_has_no_empty_sets() {
    let mut seed = 0x5e_u64;
    let mut rows = std::collections::BTreeMap::new();
    let mut tables = KinTables::new();
    for step in 0..10_000 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        let id = format!("chat-{}", (seed >> 32) as usize % 64);
        let old = rows.get(&id).cloned();
        let writes = AtomicUsize::new(0);
        if seed & 7 == 0 {
            if let Some(old) = old.as_ref() {
                tables = tables.replace_counted(Some(old), None, &writes);
                rows.remove(&id);
            }
        } else {
            let mut next = old.clone().unwrap_or_else(|| row(&id, step));
            next.title = format!("title-{step}");
            next.last_activity = seed;
            next.parent =
                (seed & 3 != 0).then(|| RowKey::new("local", format!("parent-{}", seed % 8)));
            next.fork_of = (seed & 7 == 1).then(|| super::super::ForkOf {
                key: RowKey::new("local", format!("fork-{}", seed % 8)),
                seq: seed,
            });
            next.folder = (seed & 3 == 1).then(|| format!("folder-{}", seed % 4));
            tables = tables.replace_counted(old.as_ref(), Some(&next), &writes);
            rows.insert(id, next);
        }
        let row_map = rows.values().fold(OrdMap::new(), |mut map, row| {
            let arc = Arc::new(row.clone());
            map.insert(arc.key(), arc);
            map
        });
        let rebuilt = KinTables::from_rows(row_map.values());
        assert_eq!(tables, rebuilt, "step {step}");
        assert!(tables.children.values().all(|set| !set.is_empty()));
        assert!(tables.forks.values().all(|map| !map.is_empty()));
        assert!(tables.folders.values().all(|map| !map.is_empty()));
    }
}

#[test]
fn parent_handle_copy_stops_at_depth_and_does_not_copy_siblings() {
    let mut rows = OrdMap::new();
    let mut parent = Arc::new(row("root", 0));
    rows.insert(parent.key(), parent.clone());
    for depth in 0..65 {
        let mut child = row(&format!("chain-{depth:02}"), depth + 1);
        child.parent = Some(parent.key());
        parent = Arc::new(child);
        rows.insert(parent.key(), parent.clone());
    }
    let tables = KinTables::from_rows(rows.values());
    let mut leaf = row("new-leaf", 100);
    leaf.parent = Some(parent.key());
    let mut with_leaf = rows.clone();
    let leaf = Arc::new(leaf);
    with_leaf.insert(leaf.key(), leaf.clone());
    let writes = AtomicUsize::new(0);
    let stops_before = super::super::kin_depth_stops();
    let updated = tables.replace_counted_with_rows(None, Some(leaf.as_ref()), &with_leaf, &writes);
    assert_eq!(writes.load(AtomicOrdering::Relaxed), MAX_KIN_DEPTH + 1);
    assert_eq!(super::super::kin_depth_stops(), stops_before + 1);
    assert!(updated.children(&parent.key()).is_some_and(|set| set.get(&leaf.key()).is_some()));

    for sibling_count in [10, 10_000] {
        let parent = Arc::new(row(&format!("siblings-{sibling_count}"), 0));
        let mut rows = OrdMap::new();
        rows.insert(parent.key(), parent.clone());
        for n in 0..sibling_count {
            let mut child = row(&format!("sibling-{sibling_count}-{n}"), n as u64 + 1);
            child.parent = Some(parent.key());
            let child = Arc::new(child);
            rows.insert(child.key(), child);
        }
        let tables = KinTables::from_rows(rows.values());
        let mut next = row(&format!("sibling-new-{sibling_count}"), sibling_count as u64 + 1);
        next.parent = Some(parent.key());
        let writes = AtomicUsize::new(0);
        let _ = tables.replace_counted_with_rows(None, Some(&next), &rows, &writes);
        assert_eq!(writes.load(AtomicOrdering::Relaxed), 1);
    }
}
