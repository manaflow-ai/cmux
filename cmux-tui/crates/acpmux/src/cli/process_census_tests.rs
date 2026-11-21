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
