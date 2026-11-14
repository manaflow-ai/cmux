use super::*;

#[test]
fn the_boot_id_is_read_once_and_is_never_zero() {
    let first = system_boot_id();
    assert_ne!(first, 0);
    assert_eq!(system_boot_id(), first);
    #[cfg(target_os = "linux")]
    {
        let uuid = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").unwrap();
        assert_eq!(first, fold(uuid.trim()).max(1));
    }
}

#[test]
fn a_uuid_folds_its_two_halves() {
    assert_eq!(fold("00000000-0000-0001-0000-000000000002"), 3);
    assert_eq!(fold("ffffffff-ffff-ffff-ffff-ffffffffffff"), 0);
}
