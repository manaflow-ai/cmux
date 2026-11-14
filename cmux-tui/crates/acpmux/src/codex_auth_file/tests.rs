use super::*;
use std::os::unix::fs::PermissionsExt;

#[test]
fn missing_file_is_disabled() {
    let dir = std::env::temp_dir().join(format!("cmux-codex-broker-test-{}", uuid::Uuid::now_v7()));
    let file = dir.join("missing.json");
    let marker = dir.join("vm-kind");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(&marker, "shared\n").unwrap();
    assert!(read_at(&file, &marker).unwrap().is_none());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn file_shape_requires_private_owner_marker() {
    let dir = std::env::temp_dir().join(format!("cmux-codex-broker-test-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("access.json");
    let marker = dir.join("vm-kind");
    std::fs::write(&marker, "owner\n").unwrap();
    std::fs::write(&file, r#"{"schema":1,"bridge":"codex-external-access-v1","accessToken":"a","chatgptAccountId":"acct","expiresAt":4102444800}"#).unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(read_at(&file, &marker).is_err());
    std::fs::remove_dir_all(dir).unwrap();
}
