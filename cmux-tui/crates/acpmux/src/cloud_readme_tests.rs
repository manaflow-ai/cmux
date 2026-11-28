use super::*;

#[test]
fn writes_once_keeps_a_persons_own_and_refreshes_its_own() {
    let dir = tempfile::tempdir().unwrap();
    assert!(ensure(dir.path()).unwrap());
    assert!(!ensure(dir.path()).unwrap());
    let path = dir.path().join("README.md");
    assert!(std::fs::read_to_string(&path).unwrap().contains("cmux machine request"));
    std::fs::write(&path, format!("{MARK}\nold\n")).unwrap();
    assert!(ensure(dir.path()).unwrap());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), text());
    std::fs::write(&path, "mine\n").unwrap();
    assert!(!ensure(dir.path()).unwrap());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "mine\n");
}
