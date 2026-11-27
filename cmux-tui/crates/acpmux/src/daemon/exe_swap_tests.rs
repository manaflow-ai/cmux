use super::*;

#[test]
fn an_incomplete_install_is_not_runnable() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("acpmux");
    assert!(!runnable(&file));
    std::fs::write(&file, "new build").unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert!(!runnable(&file));
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(runnable(&file));
    assert!(!runnable(dir.path()));
}
