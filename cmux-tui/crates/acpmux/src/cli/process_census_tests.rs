use super::*;
use crate::cli::process_owner::Marks;

fn owned(
    pid: u32,
    verdict: Verdict,
    argv: &[&str],
    nonce: Option<&str>,
    task: Option<&str>,
) -> Owned {
    Owned {
        proc: tree::Started::for_test(pid, 1, "Sat Nov 21 15:40:03 2026"),
        marks: Some(Marks {
            session_id: Some("s1".to_owned()),
            session_name: Some("chief".to_owned()),
            host_nonce: nonce.map(str::to_owned),
            task_mark: task.map(str::to_owned),
            home: None,
        }),
        verdict,
        argv: Some(argv.iter().map(|a| (*a).to_owned()).collect()),
    }
}

/// The 2026-11-21 loss: a process whose command line names a dead owner pid looked leaked, but
/// its host held its live lock. The census reads the lock, not the argv: it is in use, and gc
/// never takes it.
#[test]
fn an_argv_naming_a_dead_owner_is_in_use_while_its_host_lock_is_held() {
    let o = owned(
        4242,
        Verdict::Live,
        &["cmux-tui", "__terminal-host", "--owner", "x@1"],
        Some("ab"),
        None,
    );
    let (state, reason) = state(&o, "helper", &SessionInfo::default());
    assert_eq!(state, "in-use");
    assert!(reason.contains("live lock"), "{reason}");
    assert!(!o.verdict.may_end());
}

#[test]
fn only_left_behind_reads_orphaned() {
    for (verdict, want) in [
        (Verdict::Acpmux, "in-use"),
        (Verdict::Yours, "in-use"),
        (Verdict::Task, "in-use"),
        (Verdict::Live, "in-use"),
        (Verdict::LeftBehind, "orphaned"),
        (Verdict::NotAnAgents, "unknown"),
        (Verdict::Unknown, "unknown"),
    ] {
        let o = owned(10, verdict, &["x"], Some("ab"), None);
        assert_eq!(state(&o, "helper", &SessionInfo::default()).0, want, "{verdict:?}");
    }
}

#[test]
fn a_live_sessions_process_reads_idle_when_its_session_is_idle() {
    let o = owned(10, Verdict::Live, &["claude"], Some("ab"), None);
    let idle = SessionInfo { status: Some("idle".to_owned()), updated_at: Some(1) };
    assert_eq!(state(&o, "agent", &idle).0, "idle");
    // A left-behind process is orphaned whatever its session says.
    let o = owned(10, Verdict::LeftBehind, &["node", "mcp"], Some("ab"), None);
    assert_eq!(state(&o, "mcp-server", &idle).0, "orphaned");
}

#[test]
fn kind_comes_from_marks_and_records_before_names() {
    let host = owned(5, Verdict::Acpmux, &["acpmux", agent_host::HOST_ARG], None, None);
    assert_eq!(kind(&host, Some(2), &[]), "agent-host");
    let runner = owned(6, Verdict::Acpmux, &["acpmux", crate::bg_run::RUN_ARG], None, None);
    assert_eq!(kind(&runner, Some(2), &[]), "task-runner");
    let daemon = owned(2, Verdict::Acpmux, &["acpmux", "daemon", "run"], None, None);
    assert_eq!(kind(&daemon, Some(2), &[]), "daemon");
    // A task's process named like an MCP server is still the task's.
    let task = owned(7, Verdict::Task, &["node", "mcp-server"], None, Some("6-1"));
    assert_eq!(kind(&task, Some(2), &[]), "task");
    let mcp = owned(8, Verdict::Live, &["node", "some-mcp"], Some("ab"), None);
    assert_eq!(kind(&mcp, Some(2), &[]), "mcp-server");
}

#[test]
fn age_reads_ps_lstart_with_padded_days() {
    let now = chrono::Local::now();
    let lstart = now.format("%a %b %e %H:%M:%S %Y").to_string();
    let age = age_secs(&lstart).expect("parses");
    assert!((0..5).contains(&age), "{age}");
    assert_eq!(age_secs("not a date"), None);
}

fn record(session: &str, nonce: &str, host_pid: u32, harness_pid: Option<u32>) -> HostRecord {
    serde_json::from_value(json!({
        "record_version": 1,
        "session_id": session,
        "incarnation": "i",
        "host_pid": host_pid,
        "start_nonce": nonce,
        "harness_pid": harness_pid,
        "owner_token": "t",
        "protocol_min": 1,
        "protocol_max": 1,
        "host_build": "b",
        "socket": "/nonexistent.sock",
    }))
    .unwrap()
}

fn row(r: HostRecord, liveness: Liveness) -> HostRow {
    HostRow { dir: PathBuf::from("/nonexistent"), record: r, pooled: false, liveness }
}

/// A lock file aged `age` ago, the way an ended host leaves it.
fn lock_file(dir: &Path, name: &str, age: std::time::Duration) -> PathBuf {
    let path = dir.join(name);
    let f = std::fs::File::create(&path).unwrap();
    f.set_modified(std::time::SystemTime::now() - age).unwrap();
    path
}

fn hold(path: &Path) -> cmux_file_lock::FileLock {
    let f = std::fs::OpenOptions::new().read(true).write(true).open(path).unwrap();
    cmux_file_lock::FileLock::try_take(f, cmux_file_lock::Kind::Exclusive).unwrap()
}

const OLD: std::time::Duration = std::time::Duration::from_secs(3600);
const MIN: std::time::Duration = STRAY_LOCK_MIN_AGE;

/// Only an old, unheld lock no record names (readable or not) is stray: a young one is a host
/// still starting, whose record comes after its lock.
#[test]
fn a_stray_lock_is_old_unheld_and_named_by_no_record() {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let stray = lock_file(dir.path(), "s1.aa.live", OLD);
    let _young = lock_file(dir.path(), "s2.bb.live", std::time::Duration::from_secs(5));
    let _named = lock_file(dir.path(), "s3.cc.live", OLD);
    let _unreadable = lock_file(dir.path(), "s4.dd.live", OLD);
    let held = lock_file(dir.path(), "s5.ee.live", OLD);
    let _guard = hold(&held);
    let _other = lock_file(dir.path(), "s6.json", OLD);
    let names = LockNames::for_test(&[("s3", "cc")], &["s4"]);
    let found = stray_locks_in(&[dir.path().to_path_buf()], &names, MIN);
    assert_eq!(found, vec![stray]);
}

#[test]
fn removing_a_stray_lock_judges_it_again_under_its_own_flock() {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    // A host took it since the census: left alone.
    let taken = lock_file(dir.path(), "s1.aa.live", OLD);
    let guard = hold(&taken);
    let err = remove_stray_lock(&taken, LockNames::default, MIN).unwrap_err();
    assert!(err.contains("holds it"), "{err}");
    assert!(taken.exists());
    drop(guard);
    // A record that names it appeared since the census: left alone.
    let err =
        remove_stray_lock(&taken, || LockNames::for_test(&[("s1", "aa")], &[]), MIN).unwrap_err();
    assert!(err.contains("record names it"), "{err}");
    assert!(taken.exists());
    // A fresh file took the name since the census: left alone.
    std::fs::remove_file(&taken).unwrap();
    let fresh = lock_file(dir.path(), "s1.aa.live", std::time::Duration::ZERO);
    let err = remove_stray_lock(&fresh, LockNames::default, MIN).unwrap_err();
    assert!(err.contains("younger"), "{err}");
    assert!(fresh.exists());
    // Still old, unheld and unnamed: removed.
    let stray = lock_file(dir.path(), "s2.bb.live", OLD);
    remove_stray_lock(&stray, LockNames::default, MIN).unwrap();
    assert!(!stray.exists());
}

/// gc refuses a left-behind verdict when a host record that is not dead still names the process
/// as its host or harness, or the process sits in that harness's group.
#[test]
fn gc_refuses_what_a_live_or_unknown_host_record_names() {
    let me = std::process::id();
    let o = owned(me, Verdict::LeftBehind, &["x"], Some("aa"), None);
    let own_group = pgid(me).unwrap();
    for (r, live, refused) in [
        (record("s1", "aa", me, None), Liveness::Live, true),
        (record("s1", "aa", 1, Some(me)), Liveness::Unknown, true),
        (record("s1", "aa", 1, Some(own_group)), Liveness::Live, true),
        (record("s1", "aa", me, Some(me)), Liveness::Dead, false),
        (record("s1", "aa", 1, Some(u32::MAX - 1)), Liveness::Live, own_group == u32::MAX - 1),
    ] {
        let got = referenced_by_live_host(&o, &[row(r, live)]);
        assert_eq!(got.is_some(), refused, "{live:?} {got:?}");
    }
}

/// A live process with no agent host incarnation of its own (one acpmux runs for the session)
/// says so, rather than naming a host lock it has none of.
#[test]
fn a_live_process_with_no_host_nonce_names_no_host_lock() {
    let o = owned(10, Verdict::Live, &["x"], None, None);
    let (state, reason) = state(&o, "mcp-server", &SessionInfo::default());
    assert_eq!(state, "in-use");
    assert!(!reason.contains("live lock"), "{reason}");
}

#[test]
fn only_the_daemons_no_session_refusal_reads_gone() {
    // A session the daemon does not hold reads `gone` in `acpmux ps --json`, as in the socket
    // census; a name that merely contains the words, or any other failure, stays unknown.
    assert!(is_no_session(&crate::session_name::not_found("ab12", &[])));
    assert!(is_no_session(&crate::session_name::not_found("ab", &["ab12".to_owned()])));
    assert!(!is_no_session(&crate::rpc::RpcError::internal("no session matches \"x\"")));
    assert!(!is_no_session(&crate::rpc::RpcError::not_found("no prompt pending; no_session")));
    assert!(!is_no_session(&crate::rpc::RpcError::internal("timed out")));
}

#[test]
fn ps_and_gc_read_gone_from_the_same_refusal() {
    // What `Client::request` returns for a daemon refusal: the one shape both `ps`
    // (`session_info`) and `gc` (`process_owner::session_status`) read `gone` from.
    let gone =
        anyhow::Error::new(crate::client::DaemonError(crate::session_name::not_found("x", &[])));
    assert!(refused_as_no_session(&gone));
    let timeout =
        anyhow::Error::new(crate::client::DaemonError(crate::rpc::RpcError::internal("timed out")));
    assert!(!refused_as_no_session(&timeout));
    assert!(!refused_as_no_session(&anyhow::anyhow!("no session matches \"x\"")));
}

fn census_with_argv(rows: usize, arg_bytes: usize) -> Value {
    let row = |pid: usize| {
        json!({"pid": pid, "owner": "left-behind", "state": "orphaned", "reason": "its host ended",
            "argv": ["node", "x".repeat(arg_bytes), "--flag", "€".repeat(arg_bytes / 3)]})
    };
    json!({
        "product": "acpmux",
        "summary": {"processes": rows},
        "processes": (0..rows).map(row).collect::<Vec<_>>(),
        "gc": {"candidates": (0..rows).map(row).collect::<Vec<_>>(), "refused": []},
    })
}

#[test]
fn a_census_that_fits_goes_whole() {
    let mut census = census_with_argv(3, 64);
    let before = census.clone();
    assert!(fit_census(&mut census, 1 << 20));
    assert_eq!(census, before);
}

#[test]
fn a_census_too_large_for_one_reply_cuts_command_lines_and_keeps_every_row() {
    let mut census = census_with_argv(40, 64 << 10);
    let budget = 256 << 10;
    assert!(serde_json::to_string(&census).unwrap().len() > budget);
    assert!(fit_census(&mut census, budget));
    assert!(serde_json::to_string(&census).unwrap().len() <= budget);
    let rows = census["processes"].as_array().unwrap();
    assert_eq!(rows.len(), 40, "no row is dropped");
    assert_eq!(census["gc"]["candidates"].as_array().unwrap().len(), 40);
    for row in rows {
        assert_eq!(row["state"], "orphaned");
        assert_eq!(row["reason"], "its host ended");
    }
    let cut = rows.iter().find(|r| r["argv"].as_array().unwrap().len() == 5).expect("a cut row");
    let argv = cut["argv"].as_array().unwrap();
    assert_eq!(argv[0], "node");
    assert!(argv[1].as_str().unwrap().len() <= 256);
    assert!(argv[3].as_str().unwrap().len() <= 256, "cut on a char boundary");
    assert!(argv[4].as_str().unwrap().starts_with("... ("));
    assert_eq!(census["omitted"]["reason"], "too_large");
    assert!(census["omitted"]["argvTrimmed"].as_u64().unwrap() > 0);
}

#[test]
fn a_census_that_cannot_fit_even_cut_is_refused() {
    let mut census = census_with_argv(4000, 512);
    assert!(!fit_census(&mut census, 64 << 10));
}
