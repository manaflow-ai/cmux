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
fn a_user_managers_scope_moves_hosts_only_under_a_memory_ceiling() {
    let bench = "0::/user.slice/user-1001.slice/user@1001.service/app.slice/run-r09.scope\n";
    let capped = |file: &str| (file == "memory.high").then(|| "805306368\n".to_owned());
    let maxed = |file: &str| (file == "memory.max").then(|| "1073741824\n".to_owned());
    let open = |_: &str| Some("max\n".to_owned());
    let unreadable = |_: &str| None;
    assert!(in_user_scope(bench));
    assert!(moves_hosts_from(bench, capped));
    assert!(moves_hosts_from(bench, maxed));
    // A terminal's scope with no ceiling, or one whose limits cannot be read, keeps its hosts.
    let terminal = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/vte-spawn-1.scope\n";
    assert!(!moves_hosts_from(terminal, open));
    assert!(!moves_hosts_from(terminal, unreadable));
    // Never the manager's own scope, a login session scope, a system unit or cgroup v1, capped
    // or not.
    for other in [
        "0::/user.slice/user-1000.slice/user@1000.service/init.scope\n",
        "0::/user.slice/user-1000.slice/session-4.scope\n",
        "0::/system.slice/run-r1.scope\n",
        "1:name=systemd:/user.slice/user-1000.slice/user@1000.service/app.slice/run-r1.scope\n",
        "",
    ] {
        assert!(!in_user_scope(other), "{other}");
        assert!(!moves_hosts_from(other, capped), "{other}");
    }
    // A service unit moves its hosts with or without a ceiling, as before.
    let service = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/acpmux.service\n";
    assert!(moves_hosts_from(service, open));
    assert!(moves_hosts_from(service, unreadable));
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
    let joined = busctl_args(&unit, 4242, &tasks_only(4096)).join(" ");
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
    let joined = busctl_args(&unit, 4242, &tasks_only(u64::MAX)).join(" ");
    assert!(joined.ends_with("TasksMax t 18446744073709551615 0"), "{joined}");
    // The budget: memory, CPU and IO limits, the property count follows them.
    let budget = crate::session_budget::Budget {
        memory_max: 1 << 30,
        memory_high: 900 << 20,
        tasks_max: Some(4096),
        cpu_weight: 50,
        cpu_quota: 1200,
        io_weight: 50,
        ..Default::default()
    };
    let joined = busctl_args(&unit, 4242, &budget.bus_properties()).join(" ");
    assert!(joined.contains("acpmux-agent-host-4242-0a1b2c3d.scope fail 10 PIDs"), "{joined}");
    assert!(
        joined.ends_with(
            "CollectMode s inactive-or-failed MemoryMax t 1073741824 MemoryHigh t 943718400 \
                 TasksMax t 4096 CPUWeight t 50 CPUQuotaPerSecUSec t 12000000 IOWeight t 50 \
                 OOMPolicy s continue 0"
        ),
        "{joined}"
    );
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

#[test]
fn the_daemons_ssh_runs_in_its_own_low_weight_scope() {
    let argv: Vec<String> =
        helper_argv("/usr/bin/systemd-run").iter().map(|a| a.to_string_lossy().into()).collect();
    assert_eq!(
        argv,
        [
            "/usr/bin/systemd-run",
            "--user",
            "--scope",
            "--quiet",
            "--collect",
            "--slice=acpmuxhelpers.slice",
            "-p",
            "CPUWeight=100",
            "-p",
            "IOWeight=100",
            "--",
        ]
    );
    // Below the daemon's own weight, so its children never outrank it or the agents.
    assert!(HELPER_WEIGHT < crate::daemon_priority::UNIT_WEIGHT);
    // A test (and a Mac, a terminal) runs the program itself.
    let (program, lead) = low_weight(std::ffi::OsStr::new("ssh"));
    assert_eq!((program.to_str(), lead.len()), (Some("ssh"), 0));
}
