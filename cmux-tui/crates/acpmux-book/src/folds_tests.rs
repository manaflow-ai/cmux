use super::*;

#[test]
fn write_failure_stops_the_owner_until_reopen() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("folds.idx");
    let mut folds = Folds::open(&path, 0)?;
    folds.append(2, 8)?;
    folds.sync()?;
    drop(folds);
    // A read-only descriptor makes the write fail without a filesystem-wide fault.
    let mut stopped = Folds {
        file: File::open(&path)?,
        len: ENTRY_BYTES,
        last_group: 2,
        last_row: 8,
        stopped: false,
        counters: Counters::default(),
    };
    assert!(matches!(stopped.append(10, 20), Err(Error::Io(_))));
    assert_eq!(stopped.len(), ENTRY_BYTES);
    assert!(matches!(stopped.append(10, 20), Err(Error::Stopped)));
    assert!(matches!(stopped.sync(), Err(Error::Stopped)));
    drop(stopped);
    let mut reopened = Folds::open(&path, ENTRY_BYTES)?;
    reopened.append(10, 20)?;
    reopened.sync()?;
    assert_eq!(reopened.len(), 2 * ENTRY_BYTES);
    Ok(())
}

#[test]
fn checkpoint_suffix_is_replayed_once() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("folds.idx");
    let mut folds = Folds::open(&path, 0)?;
    folds.append(2, 8)?;
    folds.sync()?;
    let checkpoint = folds.len();
    folds.append(10, 20)?;
    drop(folds);
    // Include a torn final entry, as a killed writer can leave.
    OpenOptions::new().append(true).open(&path)?.write_all(&[1, 2, 3])?;
    let mut folds = Folds::open(&path, checkpoint)?;
    assert_eq!(folds.len(), ENTRY_BYTES);
    folds.append(10, 20)?;
    folds.sync()?;
    assert_eq!(folds.len(), 2 * ENTRY_BYTES);
    let mut reader = File::open(&path)?;
    assert_eq!(read_entry(&mut reader)?, (2, 8));
    assert_eq!(read_entry(&mut reader)?, (10, 20));
    assert_eq!(reader.metadata()?.len(), 2 * ENTRY_BYTES);
    Ok(())
}

#[test]
fn missing_checkpoint_bytes_are_damage() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("folds.idx");
    assert!(matches!(Folds::open(&path, ENTRY_BYTES), Err(Error::Corrupt(_))));
    assert!(matches!(Folds::open(&path, 1), Err(Error::Corrupt(_))));
    let mut folds = Folds::open(&path, 0)?;
    assert!(matches!(folds.append(0, 1), Err(Error::InvalidInput(_))));
    folds.append(2, 8)?;
    assert!(matches!(folds.append(2, 8), Err(Error::InvalidInput(_))));
    assert!(matches!(folds.append(10, 9), Err(Error::InvalidInput(_))));
    Ok(())
}

#[test]
fn overlapping_and_nested_ranges_are_refused_before_and_after_reopen()
-> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("folds.idx");
    let mut folds = Folds::open(&path, 0)?;
    folds.append(2, 8)?;
    for (group, last) in [(3, 4), (7, 10), (8, 9)] {
        assert!(matches!(folds.append(group, last), Err(Error::InvalidInput(_))));
        assert_eq!(folds.len(), ENTRY_BYTES);
    }
    folds.sync()?;
    drop(folds);
    let mut folds = Folds::open(&path, ENTRY_BYTES)?;
    assert!(matches!(folds.append(8, 20), Err(Error::InvalidInput(_))));
    folds.append(9, 9)?;
    folds.append(10, 20)?;
    assert_eq!(folds.containing(8)?, Some(Entry { group: 2, last: 8 }));
    assert_eq!(folds.containing(9)?, Some(Entry { group: 9, last: 9 }));
    assert_eq!(folds.containing(10)?, Some(Entry { group: 10, last: 20 }));
    assert_eq!(folds.len(), 3 * ENTRY_BYTES);
    Ok(())
}

#[test]
fn search_finds_the_entry_at_or_before_a_row() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let mut folds = Folds::open(&dir.path().join("folds.idx"), 0)?;
    assert_eq!(folds.search(5)?, None);
    assert_eq!(folds.entry_at(0)?, None);
    // Folds (10k+1 ..= 10k+5) for k in 1..=1000; rows 10k+6 ..= 10k+10 are gaps.
    for k in 1..=1000u64 {
        folds.append(10 * k + 1, 10 * k + 5)?;
    }
    let rows = [0, 1, 10, 11, 13, 15, 16, 20, 21, 5_000, 5_001, 9_999, 10_001, 10_006, 99_999];
    for row in rows {
        let expected = (1..=1000u64)
            .rev()
            .map(|k| (k - 1, Entry { group: 10 * k + 1, last: 10 * k + 5 }))
            .find(|(_, entry)| entry.group <= row);
        assert_eq!(folds.search(row)?, expected, "row {row}");
        let within = expected.map(|(_, entry)| entry).filter(|entry| row <= entry.last);
        assert_eq!(folds.containing(row)?, within, "row {row}");
        if let Some((position, entry)) = expected {
            assert_eq!(folds.entry_at(position)?, Some(entry));
        }
    }
    assert_eq!(folds.entry_at(1000)?, None);
    // A row in the last fold reads nothing; one near the end a few entries.
    let before = folds.stats();
    assert_eq!(folds.search(10_003)?.map(|(position, _)| position), Some(999));
    let after = folds.stats();
    assert_eq!((after.searches - before.searches, after.search_reads), (1, before.search_reads));
    folds.search(9_993)?;
    assert!(folds.stats().search_reads - after.search_reads <= 3);
    let before = folds.stats();
    folds.search(13)?;
    let after = folds.stats();
    assert_eq!(after.searches - before.searches, 1);
    assert!(after.search_reads - before.search_reads <= 2 * 11, "logarithmic in the distance");
    assert_eq!(folds.entry_at(3)?, Some(Entry { group: 41, last: 45 }));
    assert_eq!(folds.stats().entry_reads - after.entry_reads, 1);
    Ok(())
}
