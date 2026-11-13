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
    let mut rebuilt = KinTables::new();
    for row in index.iter() {
        rebuilt.insert(row.as_ref());
    }
    assert_eq!(index.kin(), &rebuilt, "kin mismatch at lifecycle step {step}");
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
        index = index.apply(n + 1, row);
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
                index = index.apply(step as u64 + 1, next);
                successful[0] += 1;
            }
            1 => {
                let Some(source) = choose_key(&index, &mut rng) else { continue };
                let mut next = row(id, 20_000 + step as u64);
                next.fork_of = Some(ForkOf { key: source, seq: step as u64 });
                next.folder =
                    (rng.next() & 3 == 0).then(|| format!("fork-folder-{}", rng.next() % 4));
                remember_edges(&next, &mut parents, &mut forks, &mut folders);
                index = index.apply(step as u64 + 1, next);
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
                index = index.apply(step as u64 + 1, next);
                successful[2] += 1;
            }
            3 => {
                let Some(key) = choose_key(&index, &mut rng) else { continue };
                let Some(old) = index.get_row(&key) else { continue };
                let mut next = old.as_ref().clone();
                next.state = "closed".to_owned();
                next.last_activity = 20_000 + step as u64;
                remember_edges(&next, &mut parents, &mut forks, &mut folders);
                index = index.apply(step as u64 + 1, next);
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
}

#[test]
fn deterministic_lifecycle_keeps_kin_tables_equal_to_hot_rows() {
    randomized_hot_lifecycle();
}
