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
