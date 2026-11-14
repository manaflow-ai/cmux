//! Deterministic lifecycle coverage for the persistent kin tables.

use super::*;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

#[derive(Clone, Copy)]
struct Rng {
    state: u64,
}

impl Rng {
    fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut value = self.state;
        value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        value ^ (value >> 31)
    }
}

fn row(id: impl Into<String>, activity: u64) -> Summary {
    let mut row = Summary::new(id);
    row.last_activity = activity;
    row.state = "running".to_owned();
    row
}

fn keys(index: &SummaryIndex) -> Vec<RowKey> {
    index.iter().map(|row| row.key()).collect()
}

fn choose_key(index: &SummaryIndex, rng: &mut Rng) -> Option<RowKey> {
    let keys = keys(index);
    keys.get((rng.next() as usize) % keys.len().max(1)).cloned()
}

fn remember_edges(
    row: &Summary,
    parents: &mut BTreeSet<RowKey>,
    forks: &mut BTreeSet<RowKey>,
    folders: &mut BTreeSet<FolderKey>,
) {
    if let Some(parent) = row.parent.as_ref() {
        parents.insert(parent.clone());
    }
    if let Some(fork) = row.fork_of.as_ref() {
        forks.insert(fork.key.clone());
    }
    if let Some(folder) = FolderKey::of(row) {
        folders.insert(folder);
    }
}

fn assert_kin(
    index: &SummaryIndex,
    step: usize,
    parents: &BTreeSet<RowKey>,
    forks: &BTreeSet<RowKey>,
    folders: &BTreeSet<FolderKey>,
) {
    let rebuilt = KinTables::from_rows(index.iter());
    assert_eq!(index.kin(), &rebuilt, "kin mismatch at lifecycle step {step}");
    for row in index.iter() {
        if let Some(parent) = row.parent.as_ref() {
            let parent_handle = index.kin().child_set(parent, &row.key());
            let own_handle = index.kin().children(&row.key());
            assert!(
                match (parent_handle, own_handle) {
                    (None, None) => true,
                    (Some(parent), Some(own)) => parent == own,
                    (Some(parent), None) => parent.is_empty(),
                    (None, Some(_)) => false,
                },
                "child handle mismatch for {} at lifecycle step {step}",
                row.chat_id,
            );
        }
    }
    for parent in parents {
        assert!(index.kin().children(parent).is_none_or(|rows| !rows.is_empty()));
    }
    for fork in forks {
        assert!(index.kin().forks(fork).is_none_or(|rows| !rows.is_empty()));
    }
    for folder in folders {
        assert!(index.kin().folder_rows(folder).is_none_or(|rows| !rows.is_empty()));
    }

    // The folders projection is published from the same hot-row replacement
    // as kin. Rebuild it from the visible index rows so compaction, eviction,
    // hydration, and origin cleanup all exercise the projection seam.
    let mut model = BTreeMap::<FolderKey, (SortKey, RowKey, u32)>::new();
    for hot in index.iter() {
        let Some(folder) = FolderKey::of(hot) else { continue };
        let sort = SortKey::of(hot);
        let entry = model.entry(folder).or_insert_with(|| (sort.clone(), hot.key(), 0));
        if sort < entry.0 {
            entry.0 = sort;
            entry.1 = hot.key();
        }
        entry.2 += 1;
    }
    let rebuilt = model
        .into_iter()
        .try_fold(folders::Folders::new(), |view, (key, (sort, newest, count))| {
            view.apply(folders::FolderEntry::new(
                key.origin,
                key.folder,
                Some(newest),
                sort.last_activity,
                count,
            ))
            .map(|(view, _)| view)
        })
        .unwrap();
    let actual =
        index.folders().iter().map(|row| (row.key(), row.as_ref().clone())).collect::<Vec<_>>();
    let expected = rebuilt.iter().map(|row| (row.key(), row.as_ref().clone())).collect::<Vec<_>>();
    assert_eq!(actual, expected, "folder projection mismatch at lifecycle step {step}");
}

fn plain_family(index: &SummaryIndex, root: &RowKey) -> Vec<RowKey> {
    let mut children = BTreeMap::<RowKey, Vec<RowKey>>::new();
    for row in index.iter() {
        if let Some(parent) = row.parent.as_ref() {
            children.entry(parent.clone()).or_default().push(row.key());
        }
    }
    for rows in children.values_mut() {
        rows.sort();
    }
    fn walk(
        key: &RowKey,
        root: &RowKey,
        depth: usize,
        children: &BTreeMap<RowKey, Vec<RowKey>>,
        visited: &mut BTreeSet<RowKey>,
        output: &mut Vec<RowKey>,
    ) {
        if depth >= MAX_KIN_DEPTH {
            return;
        }
        for child in children.get(key).into_iter().flatten() {
            if child == root || !visited.insert(child.clone()) {
                continue;
            }
            output.push(child.clone());
            walk(child, root, depth + 1, children, visited, output);
        }
    }
    let mut output = Vec::new();
    let mut visited = BTreeSet::new();
    walk(root, root, 0, &children, &mut visited, &mut output);
    output
}

fn assert_independent_kin_oracle(index: &SummaryIndex) {
    let keys = index.iter().map(|row| row.key()).collect::<Vec<_>>();
    for root in &keys {
        let expected = plain_family(index, root);
        let actual = index
            .read_page(
                None,
                ReadSide::After,
                false,
                expected.len() + 1,
                usize::MAX,
                Some(&ListFilter::family(root.clone())),
            )
            .unwrap()
            .rows
            .into_iter()
            .map(|row| row.key())
            .collect::<Vec<_>>();
        assert_eq!(actual, expected, "family oracle mismatch for {root:?}");

        let mut expected_forks = keys
            .iter()
            .filter_map(|key| index.get_row(key))
            .filter(|row| row.fork_of.as_ref().is_some_and(|fork| fork.key == *root))
            .map(|row| row.key())
            .collect::<Vec<_>>();
        expected_forks.sort();
        let actual_forks = index
            .read_page(
                None,
                ReadSide::After,
                false,
                expected_forks.len() + 1,
                usize::MAX,
                Some(&ListFilter::forks(root.clone())),
            )
            .unwrap()
            .rows
            .into_iter()
            .map(|row| row.key())
            .collect::<Vec<_>>();
        assert_eq!(actual_forks, expected_forks, "fork oracle mismatch for {root:?}");
    }
}

fn compact(
    index: &SummaryIndex,
    directory: &tempfile::TempDir,
    generation: u64,
) -> (SummaryIndex, Vec<Arc<Summary>>) {
    let path = directory.path().join(format!("lifecycle-{generation}.snap"));
    SortedSnapshot::write(&path, index).unwrap();
    let snapshot = DiskSnapshot::open(&path).unwrap().unwrap();
    let (index, _retired) = index.with_compacted_snapshot(snapshot, Default::default());
    let rows = index.iter().cloned().collect();
    (index, rows)
}

pub(super) fn randomized_hot_lifecycle() {
    let directory = tempfile::tempdir().unwrap();
    let mut rng = Rng::new(0x5e_a0_14_0f_6d_2b_91);
    let mut index = SummaryIndex::new();
    let mut parents = BTreeSet::new();
    let mut forks = BTreeSet::new();
    let mut folders = BTreeSet::new();
    // Exercise the writer/replay rule: closed peer rows leave every hot table.
    for n in 0..96 {
        let mut row = row(format!("seed-{n:03}"), 10_000 + n);
        row.origin = if n % 5 == 0 { "peer" } else { "local" }.to_owned();
        row.folder = (n % 4 == 0).then(|| format!("seed-folder-{}", n % 3));
        if n > 0 {
            row.parent = Some(RowKey::new("local", format!("seed-{:03}", n - 1)));
        }
        if n % 7 == 0 {
            row.fork_of =
                Some(ForkOf { key: RowKey::new("local", format!("seed-{:03}", n / 2)), seq: n });
        }
        remember_edges(&row, &mut parents, &mut forks, &mut folders);
        index = index.apply_summary(n + 1, row);
    }
    let (mut index, mut snapshot_rows) = compact(&index, &directory, 0);
    assert_kin(&index, 0, &parents, &forks, &folders);

    let mut attempted = [0usize; 9];
    let mut successful = [0usize; 9];
    for step in 0..10_000usize {
        let operation = ((rng.next() >> 60) as usize) % 9;
        attempted[operation] += 1;
        let id_number = ((rng.next() >> 32) % 512) as usize;
        let id = format!("chat-{id_number:03}");
        match operation {
            0 => {
                let mut next = row(id, 20_000 + step as u64);
                next.title = format!("started-{step}");
                next.folder = (rng.next() & 1 == 0).then(|| format!("folder-{}", rng.next() % 8));
                remember_edges(&next, &mut parents, &mut forks, &mut folders);
                index = index.apply_summary(step as u64 + 1, next);
                successful[0] += 1;
            }
            1 => {
                let Some(source) = choose_key(&index, &mut rng) else { continue };
                let mut next = row(id, 20_000 + step as u64);
                next.fork_of = Some(ForkOf { key: source, seq: step as u64 });
                next.folder =
                    (rng.next() & 3 == 0).then(|| format!("fork-folder-{}", rng.next() % 4));
                remember_edges(&next, &mut parents, &mut forks, &mut folders);
                index = index.apply_summary(step as u64 + 1, next);
                successful[1] += 1;
            }
            2 => {
                let Some(key) = choose_key(&index, &mut rng) else { continue };
                let Some(old) = index.get_row(&key) else { continue };
                let mut next = old.as_ref().clone();
                next.last_activity = 20_000 + step as u64;
                next.parent = (rng.next() & 3 != 0).then(|| choose_key(&index, &mut rng)).flatten();
                next.folder =
                    (rng.next() & 1 == 0).then(|| format!("moved-folder-{}", rng.next() % 8));
                remember_edges(&next, &mut parents, &mut forks, &mut folders);
                index = index.apply_summary(step as u64 + 1, next);
                successful[2] += 1;
            }
            3 => {
                let Some(key) = choose_key(&index, &mut rng) else { continue };
                let Some(old) = index.get_row(&key) else { continue };
                let mut next = old.as_ref().clone();
                next.state = "closed".to_owned();
                next.last_activity = 20_000 + step as u64;
                remember_edges(&next, &mut parents, &mut forks, &mut folders);
                index = index.apply_summary(step as u64 + 1, next);
                successful[3] += 1;
            }
            4 => {
                let (next, rows) = compact(&index, &directory, step as u64 + 1);
                index = next;
                snapshot_rows = rows;
                successful[4] += 1;
            }
            5 => {
                let candidates: Vec<_> = snapshot_rows
                    .iter()
                    .filter(|row| {
                        index.get_row(&row.key()).is_some() && !index.is_shadowed(&row.key())
                    })
                    .collect();
                let Some(row) = candidates.get((rng.next() as usize) % candidates.len().max(1))
                else {
                    continue;
                };
                if index.evict_compacted(&row.key()) {
                    successful[5] += 1;
                }
            }
            6 => {
                let candidates: Vec<_> = snapshot_rows
                    .iter()
                    .filter(|row| {
                        index.get_row(&row.key()).is_none() && !index.is_shadowed(&row.key())
                    })
                    .collect();
                let Some(row) = candidates.get((rng.next() as usize) % candidates.len().max(1))
                else {
                    continue;
                };
                let key = row.key();
                index.hydrate_compacted((*row).clone());
                if index.get_row(&key).is_some() {
                    remember_edges(row, &mut parents, &mut forks, &mut folders);
                    successful[6] += 1;
                }
            }
            7 => {
                let Some(key) = choose_key(&index, &mut rng) else { continue };
                if let Some(next) = index.remove_row(step as u64 + 1, &key) {
                    index = next;
                    successful[7] += 1;
                }
            }
            8 => {
                if index.has_origin_rows("peer") {
                    index = index.replay_origin(
                        step as u64 + 1,
                        OriginRecord {
                            seq: step as u64 + 1,
                            id: "peer".to_owned(),
                            state: OriginState::Removed,
                            since: step as u64 + 1,
                            extra: None,
                        },
                    );
                    successful[8] += 1;
                }
            }
            _ => unreachable!(),
        }
        assert_kin(&index, step + 1, &parents, &forks, &folders);
    }

    assert!(attempted.iter().all(|count| *count > 0), "every operation must run: {attempted:?}");
    assert!(successful[0] > 0 && successful[1] > 0 && successful[2] > 0 && successful[3] > 0);
    assert!(successful[4] > 0, "no compaction lifecycle ran");
    assert!(successful[5] > 0, "no cold eviction succeeded");
    assert!(successful[6] > 0, "no warm hydration succeeded");
    assert!(successful[7] > 0, "no delete succeeded");
    assert!(successful[8] > 0, "no origin cleanup succeeded");
    assert_independent_kin_oracle(&index);
}

#[test]
fn deterministic_lifecycle_keeps_kin_tables_equal_to_hot_rows() {
    randomized_hot_lifecycle();
}

#[test]
fn child_before_parent_and_parent_cycle_keep_child_handles_bounded() {
    let empty_parents = BTreeSet::new();
    let empty_forks = BTreeSet::new();
    let empty_folders = BTreeSet::new();
    let root = row("late-root", 1);
    let mut child = row("early-child", 2);
    child.parent = Some(root.key());
    let mut index = SummaryIndex::new().apply(1, child.clone());
    assert_kin(&index, 0, &empty_parents, &empty_forks, &empty_folders);
    index = index.apply(2, root.clone());
    assert_kin(&index, 1, &empty_parents, &empty_forks, &empty_folders);
    assert_eq!(
        index.kin().child_set(&root.key(), &child.key()),
        index.kin().children(&child.key()),
    );

    let mut first = row("cycle-a", 3);
    let mut second = row("cycle-b", 4);
    first.parent = Some(second.key());
    second.parent = Some(first.key());
    index = index.apply(3, first.clone()).apply(4, second.clone());
    assert_kin(&index, 2, &empty_parents, &empty_forks, &empty_folders);
    let page = index
        .read_page(
            None,
            ReadSide::After,
            false,
            16,
            64 * 1024,
            Some(&ListFilter::family(first.key())),
        )
        .unwrap();
    assert!(page.rows.len() <= 2);
}

#[test]
fn deep_handle_refresh_matches_a_fresh_table_at_the_64_level_edge() {
    let root = row("deep-root", 0);
    let mut chain = vec![root.clone()];
    let mut parent = root;
    for depth in 0..66 {
        let mut child = row(format!("deep-{depth:02}"), depth + 1);
        child.parent = Some(parent.key());
        parent = child.clone();
        chain.push(child);
    }
    let mut leaf = row("deep-leaf", 100);
    leaf.parent = Some(parent.key());

    let mut index = SummaryIndex::new();
    for (seq, row) in chain.iter().cloned().enumerate() {
        index = index.apply(seq as u64 + 1, row);
    }
    index = index.apply(chain.len() as u64 + 1, leaf.clone());

    let mut fresh = SummaryIndex::new();
    for (seq, row) in std::iter::once(leaf).chain(chain.iter().rev().cloned()).enumerate() {
        fresh = fresh.apply(seq as u64 + 1, row);
    }

    for depth in [2, 1, 0] {
        let key = RowKey::new("local", format!("deep-{depth:02}"));
        let filter = ListFilter::family(key);
        let actual =
            index.read_page(None, ReadSide::After, false, 128, 256 * 1024, Some(&filter)).unwrap();
        let expected =
            fresh.read_page(None, ReadSide::After, false, 128, 256 * 1024, Some(&filter)).unwrap();
        assert_eq!(
            actual.rows.iter().map(|row| row.key()).collect::<Vec<_>>(),
            expected.rows.iter().map(|row| row.key()).collect::<Vec<_>>(),
            "stale handle at chain depth {depth}",
        );
    }
}

#[test]
fn removing_a_last_child_keeps_hot_ancestors_in_the_family_table() {
    let root = row("remove-root", 0);
    let a = parent_row("remove-a", 1, &root);
    let b = parent_row("remove-b", 2, &a);
    let c = parent_row("remove-c", 3, &b);
    let mut index = SummaryIndex::new();
    for (seq, row) in [root.clone(), a.clone(), b.clone(), c.clone()].into_iter().enumerate() {
        index = index.apply(seq as u64 + 1, row);
    }
    index = index.remove_row(5, &c.key()).unwrap();

    let page = index
        .read_page(
            None,
            ReadSide::After,
            false,
            16,
            64 * 1024,
            Some(&ListFilter::family(root.key())),
        )
        .unwrap();
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["remove-a", "remove-b"],
    );

    let oracle = SummaryIndex::new().apply(1, root).apply(2, a).apply(3, b);
    assert_eq!(index.kin(), oracle.kin());
}

fn parent_row(id: &str, activity: u64, parent: &Summary) -> Summary {
    let mut row = row(id, activity);
    row.parent = Some(parent.key());
    row
}
