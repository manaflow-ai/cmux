use super::*;

fn marks(session: &str, nonce: Option<&str>, task: Option<&str>) -> Marks {
    Marks {
        session_id: Some(session.to_owned()),
        session_name: Some("n".to_owned()),
        host_nonce: nonce.map(str::to_owned),
        task_mark: task.map(str::to_owned),
        home: None,
    }
}

#[test]
fn the_callers_own_process_is_yours_whatever_its_host() {
    let m = marks("s1", Some("abc"), None);
    assert_eq!(judge(Some(&m), Some("s1"), None, Some(Liveness::Dead)), Verdict::Yours);
    assert_eq!(judge(Some(&m), Some("s1"), None, Some(Liveness::Live)), Verdict::Yours);
}

#[test]
fn another_sessions_process_under_a_live_host_is_never_ended() {
    let m = marks("s2", Some("abc"), None);
    let v = judge(Some(&m), Some("s1"), None, Some(Liveness::Live));
    assert_eq!(v, Verdict::Live);
    assert!(!v.may_end());
}

#[test]
fn a_process_whose_host_ended_is_left_behind_and_may_end() {
    let m = marks("s2", Some("abc"), None);
    let v = judge(Some(&m), Some("s1"), None, Some(Liveness::Dead));
    assert_eq!(v, Verdict::LeftBehind);
    assert!(v.may_end());
    // No caller session (a person's terminal): the same.
    assert_eq!(judge(Some(&m), None, None, Some(Liveness::Dead)), Verdict::LeftBehind);
}

#[test]
fn a_running_task_outlives_its_hibernated_host() {
    let m = marks("s2", Some("abc"), Some("123-456"));
    assert_eq!(
        judge(Some(&m), Some("s1"), Some(Liveness::Live), Some(Liveness::Dead)),
        Verdict::Task
    );
    assert!(!Verdict::Task.may_end());
    // Its runner gone too: left behind.
    assert_eq!(
        judge(Some(&m), Some("s1"), Some(Liveness::Dead), Some(Liveness::Dead)),
        Verdict::LeftBehind
    );
    assert_eq!(
        judge(Some(&m), Some("s1"), Some(Liveness::Unknown), Some(Liveness::Dead)),
        Verdict::Unknown
    );
}

#[test]
fn nothing_unreadable_or_unproven_may_end() {
    assert_eq!(judge(None, Some("s1"), None, None), Verdict::Unknown);
    let m = marks("s2", Some("abc"), None);
    assert_eq!(judge(Some(&m), Some("s1"), None, Some(Liveness::Unknown)), Verdict::Unknown);
    assert_eq!(judge(Some(&Marks::default()), Some("s1"), None, None), Verdict::NotAnAgents);
    for v in [Verdict::Task, Verdict::Live, Verdict::NotAnAgents, Verdict::Unknown] {
        assert!(!v.may_end(), "{v:?}");
    }
}

#[test]
fn acpmuxs_own_processes_are_known_by_argv() {
    let v = |a: &[&str]| a.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert!(is_acpmux_own(&v(&["/x/acpmux", "daemon", "run", "--ready-fd", "3"])));
    assert!(is_acpmux_own(&v(&["/x/acpmux", "__agent-host"])));
    assert!(is_acpmux_own(&v(&["/x/acpmux", "__bg-run"])));
    assert!(!is_acpmux_own(&v(&["/usr/bin/python3", "server.py", "--daemon"])));
    assert!(!is_acpmux_own(&v(&["__bg-run"])));
    assert!(!Verdict::Acpmux.may_end());
}

#[test]
fn a_task_whose_runner_ended_with_no_host_is_left_behind() {
    let m = marks("s2", None, Some("123-456"));
    assert_eq!(judge(Some(&m), Some("s1"), Some(Liveness::Dead), None), Verdict::LeftBehind);
    assert_eq!(judge(Some(&m), Some("s1"), Some(Liveness::Live), None), Verdict::Task);
}

#[test]
fn the_callers_own_running_task_is_stopped_through_its_runner() {
    let m = marks("s1", None, Some("123-456"));
    assert_eq!(judge(Some(&m), Some("s1"), Some(Liveness::Live), None), Verdict::Task);
    assert_eq!(judge(Some(&m), Some("s1"), Some(Liveness::Dead), None), Verdict::Yours);
}

#[test]
fn a_daemon_drops_every_mark_this_module_reads() {
    let dropped = crate::daemon::STARTER_SESSION_MARKS;
    for k in [SESSION_ID, SESSION_NAME, agent_host::HOST_MARK, crate::bg_run::TASK_MARK] {
        assert!(dropped.contains(&k), "{k}");
    }
}

#[test]
fn marks_read_the_last_value_and_skip_empty_ones() {
    let env = vec![
        (SESSION_ID.to_owned(), "old".to_owned()),
        (SESSION_ID.to_owned(), "s1".to_owned()),
        (agent_host::HOST_MARK.to_owned(), String::new()),
    ];
    let m = Marks::from_env(&env);
    assert_eq!(m.session_id.as_deref(), Some("s1"));
    assert_eq!(m.host_nonce, None);
}

#[test]
fn only_a_process_of_this_home_can_be_left_behind() {
    let here = crate::config::home();
    assert!(same_home(here.to_str()));
    assert!(!same_home(None));
    assert!(!same_home(Some("/nonexistent/other-acpmux-home")));
}

#[test]
fn a_host_whose_lock_is_gone_from_every_place_of_this_home_is_dead() {
    // A session id no host ever had: no record, no lock anywhere.
    assert_eq!(host_liveness(Some("no-such-session-0000"), "00ff"), Liveness::Dead);
    assert_eq!(host_liveness(None, "00ff"), Liveness::Unknown);
}

#[test]
fn a_live_process_of_this_test_is_read_with_its_marks() {
    // This test process: never ended, and `owners` reads it.
    let me = std::process::id();
    let found = owners(&[me]);
    assert_eq!(found.len(), 1);
    assert!(found[0].1.is_some());
}
