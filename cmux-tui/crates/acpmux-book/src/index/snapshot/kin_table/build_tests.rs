use super::*;

fn check_truncated_record<R: Record>(record: R) {
    let mut bytes = vec![0; R::WIDTH];
    record.encode(&mut bytes).unwrap();
    assert!(R::decode(&bytes).is_ok_and(|decoded| decoded == record));
    for length in 0..R::WIDTH {
        assert!(record.encode(&mut bytes[..length]).is_err());
        assert!(R::decode(&bytes[..length]).is_err());
    }
}

#[test]
fn fixed_records_reject_every_truncation_without_panicking() {
    check_truncated_record(Edge { child: (1, 2), parent: (3, 4) });
    let entry =
        Entry { hash: 5, activity: 6, offset: 7, check: 8, len: 9, depth: 10, kind: FAMILY_KIND };
    check_truncated_record(EntryRecord(entry));
    check_truncated_record(Level { entry, own: (11, 12), eligible: true });
}
