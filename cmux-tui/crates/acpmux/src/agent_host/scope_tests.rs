use super::*;
use std::time::Instant;

#[test]
fn only_a_user_managers_service_unit_moves_hosts() {
    let hand_written = "0::/user.slice/user-1001.slice/user@1001.service/acpmux.slice/\
                            acpmux-agent.slice/acpmux-agent-huge.slice/\
                            acpmux-agent-huge-blue.slice/acpmux-agent-huge-blue.service\n";
    assert!(in_user_service(hand_written));
    assert!(in_user_service(
        "0::/user.slice/user-1000.slice/user@1000.service/app.slice/acpmux.service\n"
    ));
    // A terminal, an ssh login, the manager itself, a system service, cgroup v1.
    for other in [
        "0::/user.slice/user-1000.slice/user@1000.service/app.slice/vte-spawn-1.scope\n",
        "0::/user.slice/user-1000.slice/session-4.scope\n",
        "0::/user.slice/user-1000.slice/user@1000.service\n",
        "0::/user.slice/user-1000.slice/user@1000.service/init.scope\n",
        "0::/system.slice/acpmux.service\n",
        "1:name=systemd:/user.slice/user-1000.slice/user@1000.service/acpmux.service\n",
        "",
    ] {
        assert!(!in_user_service(other), "{other}");
    }
}

#[test]
fn a_host_counts_as_placed_only_when_its_cgroup_names_its_own_scope() {
    let unit = scope_unit(4242, "0a1b2c3d");
    assert_eq!(unit, "acpmux-agent-host-4242-0a1b2c3d.scope");
    let placed = format!("0::/user.slice/user-1000.slice/user@1000.service/{HOST_SLICE}/{unit}\n");
    assert!(names_scope(&placed, &unit));
    // A stale scope of an earlier process with the same pid is not this move's.
    assert!(!names_scope(&placed, &scope_unit(4242, "ffffffff")));
    assert!(!names_scope(
        "0::/user.slice/user-1000.slice/user@1000.service/app.slice/acpmux.service\n",
        &unit
    ));
    assert!(!HOST_SLICE.trim_end_matches(".slice").contains('-'), "a dash nests slices");
}

#[test]
fn the_scope_request_names_the_host_pid_and_the_host_slice_on_the_user_bus() {
    let unit = scope_unit(4242, "0a1b2c3d");
    let joined = busctl_args(&unit, 4242, 4096).join(" ");
    assert!(joined.starts_with("--user --quiet call org.freedesktop.systemd1 "), "{joined}");
    assert!(
        joined.contains(
            "StartTransientUnit ssa(sv)a(sa(sv)) acpmux-agent-host-4242-0a1b2c3d.scope fail 4"
        ),
        "{joined}"
    );
    assert!(joined.contains("PIDs au 1 4242 Slice"), "{joined}");
    assert!(joined.contains("Slice s acpmuxhosts.slice"), "{joined}");
    assert!(joined.ends_with("CollectMode s inactive-or-failed TasksMax t 4096 0"), "{joined}");
    // No cap: `infinity` (uint64 max), never systemd's DefaultTasksMax.
    let joined = busctl_args(&unit, 4242, u64::MAX).join(" ");
    assert!(joined.ends_with("TasksMax t 18446744073709551615 0"), "{joined}");
}

#[test]
fn busctl_comes_from_system_directories_with_only_the_bus_address() {
    assert!(BUSCTL.iter().all(|p| p.starts_with("/usr/bin/") || p.starts_with("/bin/")));
    let env = busctl_env(None, None, 1001);
    assert_eq!(
        env,
        vec![("XDG_RUNTIME_DIR", "/run/user/1001".into()), ("PATH", "/usr/bin:/bin".into())]
    );
    let env = busctl_env(Some("/run/user/7".into()), Some("unix:path=/b".into()), 7);
    let keys: Vec<_> = env.iter().map(|(k, _)| *k).collect();
    assert_eq!(keys, ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "PATH"]);
}

#[test]
fn a_failure_pauses_moves_for_a_while_not_for_good() {
    let now = Instant::now();
    assert!(!backing_off(None, now));
    assert!(backing_off(Some(now), now + Duration::from_secs(1)));
    assert!(!backing_off(Some(now), now + RETRY_AFTER));
}
