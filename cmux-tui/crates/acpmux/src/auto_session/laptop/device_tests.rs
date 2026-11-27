use super::*;

#[test]
fn the_id_is_made_once_and_kept() {
    let home = tempfile::tempdir().unwrap();
    let first = id_in(home.path()).unwrap();
    assert!(taken(&first));
    assert_eq!(id_in(home.path()).unwrap(), first);
}

#[test]
fn an_id_the_store_refuses_is_replaced() {
    let home = tempfile::tempdir().unwrap();
    std::fs::write(home.path().join(FILE), "not an id\n").unwrap();
    let id = id_in(home.path()).unwrap();
    assert!(taken(&id));
    assert_eq!(std::fs::read_to_string(home.path().join(FILE)).unwrap().trim(), id);
}
