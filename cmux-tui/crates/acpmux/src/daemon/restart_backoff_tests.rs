use super::own_unit;

#[test]
fn own_unit_reads_the_acpmux_service_from_cgroup_v2() {
    let cg = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/acpmux.service\n";
    assert_eq!(own_unit(cg).as_deref(), Some("acpmux.service"));
}

#[test]
fn own_unit_is_none_outside_an_acpmux_service() {
    // A daemon a client started from a login shell, another unit, cgroup v1 only.
    assert_eq!(own_unit("0::/user.slice/user-1000.slice/session-3.scope\n"), None);
    assert_eq!(
        own_unit("0::/user.slice/user-1000.slice/user@1000.service/app.slice/other.service\n"),
        None
    );
    assert_eq!(own_unit("12:pids:/user.slice\n1:name=systemd:/user.slice\n"), None);
}
