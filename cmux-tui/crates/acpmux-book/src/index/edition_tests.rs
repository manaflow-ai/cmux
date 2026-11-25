use super::*;

#[test]
fn same_boot_never_rewrites_and_new_boot_is_durable_before_return() {
    let dir = tempfile::tempdir().unwrap();
    let first = IndexEdition::open(dir.path(), 123, false, || 7).unwrap();
    assert_eq!(first.edition, 1);
    for _ in 0..50 {
        let same = IndexEdition::open(dir.path(), 123, true, || panic!("no randomness")).unwrap();
        assert_eq!((same.edition, same.writes), (1, 0));
    }
    let next = IndexEdition::open(dir.path(), 124, true, || 7).unwrap();
    assert_eq!((next.edition, next.writes), (2, 1));
    let restart = IndexEdition::open(dir.path(), 124, true, || 7).unwrap();
    assert_eq!((restart.edition, restart.writes), (2, 0));
}

#[test]
fn damaged_record_uses_injected_nonzero_random_edition() {
    let dir = tempfile::tempdir().unwrap();
    for cut in 0..RECORD_BYTES {
        fs::write(dir.path().join("index.edition"), vec![0; cut]).unwrap();
        assert_eq!(IndexEdition::open(dir.path(), 1, true, || 73).unwrap().edition, 73);
    }
    fs::write(dir.path().join("index.edition"), []).unwrap();
    assert_eq!(IndexEdition::open(dir.path(), 1, true, || 0).unwrap().edition, 1);
}
