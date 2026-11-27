use super::*;

#[test]
fn spare_is_on_by_default_and_the_env_turns_it_off() {
    assert!(PoolConfig::default().spare);
    assert!(spare_env_allows(None));
    assert!(spare_env_allows(Some("1")));
    for off in ["0", "false", "OFF", " no "] {
        assert!(!spare_env_allows(Some(off)), "{off}");
    }
}

#[test]
fn a_spare_never_waits_less_than_the_pool() {
    let cfg = PoolConfig { idle_minutes: 30, spare_idle_minutes: 5, ..Default::default() };
    assert_eq!(cfg.spare_idle(), cfg.idle());
    assert_eq!(PoolConfig::default().spare_idle().as_secs(), 3600);
}

#[test]
fn personal_spares_are_on_unless_the_kill_switch_is_set() {
    // The same reading as the spare's own switch: unset or anything but an off word keeps it on.
    assert!(spare_env_allows(None));
    for off in ["0", "false", " OFF ", "no"] {
        assert!(!spare_env_allows(Some(off)), "{off}");
    }
    assert_eq!(SPARE_PERSONAL_ENV, "ACPMUX_SPARE_PERSONAL");
}
