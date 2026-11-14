use super::*;

#[test]
fn failed_writes_stop_the_log_until_reopen() {
    for map_failure in [false, true] {
        let home = tempfile::tempdir().unwrap();
        let (mut log, _) = Log::open(home.path(), Options::default()).unwrap();
        log.append_settled(1, 1, RawRange::NONE, b"old").unwrap();
        log.write_checkpoint(&[], &[]).unwrap();
        // Read-only descriptors produce a real failed write without production fault hooks.
        let error = if map_failure {
            log.raw_map = File::open(home.path().join("raw.map")).unwrap();
            log.append_raw_file(b"raw").unwrap_err()
        } else {
            log.tail.file = File::open(segment_path(&log.rows_dir, log.tail.seg)).unwrap();
            log.append_settled(2, 1, RawRange::NONE, b"new").unwrap_err()
        };
        assert!(matches!(error, Error::Io(_)));
        assert!(matches!(log.append_settled(2, 1, RawRange::NONE, b"new"), Err(Error::Stopped)));
        assert!(matches!(log.patch(1, 2, RawRange::NONE, b"patch"), Err(Error::Stopped)));
        assert!(matches!(log.write_checkpoint(&[], &[]), Err(Error::Stopped)));
        assert!(matches!(log.append_raw_file(b"raw"), Err(Error::Stopped)));
        drop(log);
        let (mut log, _) = Log::open(home.path(), Options::default()).unwrap();
        assert_eq!(log.append_settled(2, 1, RawRange::NONE, b"new").unwrap(), 2);
    }
}

#[test]
fn a_short_write_in_a_new_segment_does_not_shift_the_next_record() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = Log::open(home.path(), Options::default()).unwrap();
    log.append_settled(1, 1, RawRange::NONE, b"first").unwrap();
    log.roll().unwrap();
    log.fail_after = Some(3);
    assert!(matches!(log.append_settled(2, 1, RawRange::NONE, b"second"), Err(Error::Io(_))));
    log.append_settled(2, 1, RawRange::NONE, b"second").unwrap();
    log.append_settled(3, 1, RawRange::NONE, b"third").unwrap();
    drop(log);
    let (log, _) = Log::open(home.path(), Options::default()).unwrap();
    assert_eq!(log.row(2).unwrap().len, 6);
    assert_eq!(log.row(3).unwrap().len, 5);
}

#[test]
fn a_failed_sync_stops_the_log() {
    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = Log::open(home.path(), Options::default()).unwrap();
    let file = log.append_raw_file(b"raw").unwrap();
    log.append_settled(1, 1, RawRange { file, off: 0, len: 1 }, b"row").unwrap();
    log.tail.file = File::open("/dev/full").unwrap();
    assert!(matches!(log.sync(), Err(Error::Io(_))));
    assert!(matches!(log.append_settled(2, 1, RawRange::NONE, b"row"), Err(Error::Stopped)));
}
