use super::*;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct Number(u64);

impl Record for Number {
    const WIDTH: usize = 8;
    fn encode(self, mut bytes: &mut [u8]) -> io::Result<()> {
        bytes.write_all(&self.0.to_le_bytes())
    }
    fn decode(bytes: &[u8]) -> io::Result<Self> {
        Ok(Self(u64::from_le_bytes(bytes.try_into().map_err(io::Error::other)?)))
    }
}

#[test]
fn tiny_runs_and_multiple_merge_passes_equal_the_in_memory_oracle() {
    let oracle_input: Vec<_> = (0..5003).map(|n| Number((n * 7919) % 101)).collect();
    let mut sorter = Sorter::with_budget(3 * 8).unwrap();
    for record in &oracle_input {
        sorter.push(*record).unwrap();
        assert!(sorter.memory.len() < 3);
        assert_eq!(sorter.memory.capacity(), 3);
    }
    assert!(sorter.runs > FAN_IN * FAN_IN);
    let directory = sorter.space.path.clone();
    let mut expected = oracle_input;
    expected.sort_unstable();
    let mut sorted = sorter.finish().unwrap();
    assert_eq!(sorted.count, expected.len() as u64);
    for record in expected {
        assert_eq!(sorted.next().unwrap(), Some(record));
    }
    assert_eq!(sorted.next().unwrap(), None);
    sorted.rewind().unwrap();
    assert_eq!(sorted.next().unwrap(), Some(Number(0)));
    drop(sorted);
    assert!(!directory.exists());
}

#[test]
fn an_empty_sort_is_an_owned_empty_stream() {
    let sorter = Sorter::<Number>::with_budget(8).unwrap();
    let directory = sorter.space.path.clone();
    let mut sorted = sorter.finish().unwrap();
    assert_eq!(sorted.count, 0);
    assert_eq!(sorted.next().unwrap(), None);
    drop(sorted);
    assert!(!directory.exists());
}

#[test]
fn sort_runs_stay_beside_the_requested_stage_directory() {
    let parent = TempSpace::new(&std::env::temp_dir()).unwrap();
    let mut sorter = Sorter::<Number>::with_budget_in(&parent.path, 8).unwrap();
    let directory = sorter.space.path.clone();
    assert_eq!(directory.parent(), Some(parent.path.as_path()));
    sorter.push(Number(1)).unwrap();
    let mut sorted = sorter.finish().unwrap();
    assert_eq!(sorted.next().unwrap(), Some(Number(1)));
    drop(sorted);
    assert!(!directory.exists());
    let parent_path = parent.path.clone();
    drop(parent);
    assert!(!parent_path.exists());
}

#[cfg(unix)]
#[test]
fn exclusive_run_creation_refuses_symlinks_without_claiming_their_ownership() {
    let space = TempSpace::new(&std::env::temp_dir()).unwrap();
    let (_, mut output) = space.create().unwrap();
    output.write_all(b"unchanged").unwrap();
    output.flush().unwrap();
    drop(output);
    let target = space.path(0);
    let link = space.path(1);
    std::os::unix::fs::symlink(&target, &link).unwrap();
    assert_eq!(space.create().unwrap_err().kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(space.next.load(Ordering::Relaxed), 1);
    assert_eq!(fs::read(&target).unwrap(), b"unchanged");
    // This test created the link; the failed create did not own it.
    fs::remove_file(link).unwrap();
    let directory = space.path.clone();
    drop(space);
    assert!(!directory.exists());
}

#[test]
fn a_partial_record_is_an_error_instead_of_a_clean_end() {
    let mut bytes = [0; Number::WIDTH];
    let mut input = io::Cursor::new([1, 2, 3]);
    assert_eq!(
        read_record::<Number>(&mut input, &mut bytes).unwrap_err().kind(),
        io::ErrorKind::UnexpectedEof
    );
}
