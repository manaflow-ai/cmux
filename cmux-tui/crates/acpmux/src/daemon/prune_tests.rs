use super::*;

/// A per-build home a crashed daemon left: nothing holds its lock, its pid is gone, and its
/// socket and pid file are still there.
fn stale() -> Seen {
    Seen {
        home: PathBuf::from("/home/u/.acpmux/builds/x"),
        shared: false,
        this: false,
        lock_held: false,
        holder: Some(4242),
        holder_gone: true,
        socket_exists: true,
        pid_file_exists: true,
        age: Some(Duration::from_secs(3 * 3600 + 600)),
        exe: Some(PathBuf::from("/home/u/.local/bin/acpmux-x")),
        exe_exists: false,
    }
}

#[test]
fn a_dead_daemons_socket_and_pid_file_are_stale() {
    assert_eq!(classify(&stale()), Verdict::Stale { pid: 4242 });
    // Only one of the two left is still worth clearing.
    assert_eq!(classify(&Seen { socket_exists: false, ..stale() }), Verdict::Stale { pid: 4242 });
    assert_eq!(classify(&Seen { pid_file_exists: false, ..stale() }), Verdict::Stale { pid: 4242 });
}

#[test]
fn a_held_lock_is_a_running_daemon_never_pruned() {
    // Whatever the files say, a held lock is a daemon: it stops by its own rules.
    let held = Seen { lock_held: true, ..stale() };
    assert_eq!(
        classify(&held),
        Verdict::Keep(Keep::Runs { pid: Some(4242), exe_gone: true }),
        "its executable is gone: it retires itself, the pass never stops it"
    );
    let installed = Seen { exe_exists: true, ..held.clone() };
    assert_eq!(
        classify(&installed),
        Verdict::Keep(Keep::Runs { pid: Some(4242), exe_gone: false })
    );
    // No owner record: no claim that its executable is gone.
    let unknown = Seen { exe: None, ..held };
    assert_eq!(classify(&unknown), Verdict::Keep(Keep::Runs { pid: Some(4242), exe_gone: false }));
}

#[test]
fn the_shared_homes_daemon_and_this_one_are_never_pruned() {
    let shared = Seen { shared: true, lock_held: true, ..stale() };
    assert_eq!(classify(&shared), Verdict::Keep(Keep::SharedHome { pid: Some(4242) }));
    assert!(Keep::SharedHome { pid: Some(4242) }.phrase().contains("never pruned"));
    assert_eq!(classify(&Seen { this: true, ..stale() }), Verdict::Keep(Keep::ThisDaemon));
    // The shared home's records a dead daemon left are cleared like any other home's.
    assert_eq!(classify(&Seen { shared: true, ..stale() }), Verdict::Stale { pid: 4242 });
}

#[test]
fn only_a_pid_provably_gone_lets_records_go() {
    // The pid runs: maybe a reused pid, maybe an acpmux. Not provably no acpmux.
    assert_eq!(
        classify(&Seen { holder_gone: false, ..stale() }),
        Verdict::Keep(Keep::PidRuns { pid: 4242 })
    );
    // No pid recorded at all.
    assert_eq!(
        classify(&Seen { holder: None, holder_gone: false, ..stale() }),
        Verdict::Keep(Keep::NoPid)
    );
}

#[test]
fn a_lock_written_moments_ago_may_be_a_start_under_way() {
    let young = Seen { age: Some(STALE_AFTER - Duration::from_secs(1)), ..stale() };
    assert_eq!(classify(&young), Verdict::Keep(Keep::Young));
    assert_eq!(classify(&Seen { age: None, ..stale() }), Verdict::Keep(Keep::Young));
}

#[test]
fn a_home_with_nothing_left_is_clean() {
    let clean = Seen { socket_exists: false, pid_file_exists: false, ..stale() };
    assert_eq!(classify(&clean), Verdict::Keep(Keep::Clean));
}

#[test]
fn every_kept_home_names_why() {
    let keeps = [
        Keep::ThisDaemon,
        Keep::SharedHome { pid: None },
        Keep::Runs { pid: Some(1), exe_gone: true },
        Keep::Runs { pid: Some(1), exe_gone: false },
        Keep::Clean,
        Keep::Young,
        Keep::NoPid,
        Keep::PidRuns { pid: 7 },
    ];
    for keep in keeps {
        let judged = Judged { seen: stale(), verdict: Verdict::Keep(keep.clone()), cleared: None };
        let line = judged.line();
        assert!(line.starts_with("kept"), "{line}");
        assert!(line.contains(keep.word()) && line.contains(&keep.phrase()), "{line}");
        assert!(!line.contains('\n'));
        assert_eq!(judged.json()["verdict"], "keep");
        assert_eq!(judged.json()["reason"], keep.word());
    }
}

#[test]
fn a_prune_logs_pid_build_age_and_reason_in_one_line() {
    let judged = Judged {
        seen: stale(),
        verdict: Verdict::Stale { pid: 4242 },
        cleared: Some(Ok(vec!["acpmux.sock", "daemon.pid"])),
    };
    let line = judged.log_line();
    assert!(!line.contains('\n'));
    for part in [
        "pid 4242",
        "build /home/u/.local/bin/acpmux-x",
        "age 3h 10m",
        "reason stale-record",
        "removed acpmux.sock, daemon.pid",
    ] {
        assert!(line.contains(part), "{line}");
    }
    assert_eq!(judged.json()["reason"], "stale-record");
    assert_eq!(judged.json()["verdict"], "prune");
    let dry = Judged { cleared: None, ..judged };
    assert!(dry.line().starts_with("would prune"), "{}", dry.line());
}

#[test]
fn a_retired_daemons_stop_line_names_pid_build_age_and_reason() {
    let line = retired_stop_line(
        "its executable /x/acpmux is gone",
        "unused for 300s: no client, agent, turn or task",
        Duration::from_secs(90_000),
    );
    assert!(!line.contains('\n'));
    for part in [
        format!("pid {}", std::process::id()),
        format!("build {}", crate::build_info::build()),
        "age 1d 1h".into(),
        "reason exe-gone".into(),
    ] {
        assert!(line.contains(&part), "{line}");
    }
}

#[test]
fn pids_and_ages_read() {
    assert_eq!(parse_pid("123\n/home/u/.acpmux/acpmux.sock\n"), Some(123));
    assert_eq!(parse_pid("0\n"), None);
    assert_eq!(parse_pid(""), None);
    assert_eq!(age_words(Duration::from_secs(12)), "12s");
    assert_eq!(age_words(Duration::from_secs(242)), "4m 2s");
}

#[test]
fn an_unreadable_executable_path_is_no_proof_it_went() {
    assert!(exe_present(Path::new("/")));
    assert!(!exe_present(Path::new("/nonexistent-acpmux-prune-test/acpmux")));
}

/// The clear itself, on a home this test made: a dead pid's socket and pid file go, the lock
/// stays; a held lock refuses.
#[test]
fn clear_removes_only_the_socket_and_pid_file_under_the_lock() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    // A pid no process has: past every kernel's pid limit.
    let dead = 0x7fff_fff0u32;
    assert!(pid_gone(dead));
    std::fs::write(
        home.join("daemon.lock"),
        format!("{dead}\n{}\n", home.join("acpmux.sock").display()),
    )
    .unwrap();
    std::fs::write(home.join("daemon.pid"), dead.to_string()).unwrap();
    let _listener = std::os::unix::net::UnixListener::bind(home.join("acpmux.sock")).unwrap();
    std::fs::write(home.join("keep.json"), "{}").unwrap();

    // Held: refused, nothing removed.
    let lock = std::fs::File::open(home.join("daemon.lock")).unwrap();
    let held = cmux_file_lock::FileLock::try_take(lock, cmux_file_lock::Kind::Exclusive).unwrap();
    assert!(clear(home, dead).is_err());
    assert!(home.join("daemon.pid").exists());
    drop(held);

    // This process is alive: never provably gone.
    assert!(clear(home, std::process::id()).is_err());

    assert_eq!(clear(home, dead).unwrap(), vec!["acpmux.sock", "daemon.pid"]);
    assert!(!home.join("acpmux.sock").exists() && !home.join("daemon.pid").exists());
    assert!(home.join("daemon.lock").exists() && home.join("keep.json").exists());
}
