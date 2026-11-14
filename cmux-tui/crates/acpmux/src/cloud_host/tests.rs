use super::detect;

#[test]
fn a_cloud_vm_is_known_by_its_records_or_its_vm_id() {
    let dir = std::env::temp_dir().join(format!("acpmux-cloud-host-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    // A Mac or a plain SSH host: none of them.
    assert!(!detect(&dir, None));
    assert!(!detect(&dir, Some("")));
    assert!(!detect(&dir.join("missing"), Some("  ")));
    assert!(detect(&dir, Some("vm-123")));
    for mark in super::MARKS {
        let one = dir.join(mark);
        std::fs::write(&one, "x").unwrap();
        assert!(detect(&dir, None), "{mark}");
        std::fs::remove_file(&one).unwrap();
    }
    let _ = std::fs::remove_dir_all(&dir);
}
