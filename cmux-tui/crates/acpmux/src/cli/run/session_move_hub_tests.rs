use super::*;

fn args(interrupt: bool, after_turn: bool, dry_run: bool) -> MoveArgs {
    MoveArgs {
        sessions: vec![],
        host: "vm-b".into(),
        all_idle: false,
        interrupt,
        after_turn,
        turn_timeout: std::time::Duration::from_secs(60),
        leave_dirty: false,
        carry_changes: false,
        cwd: None,
        dry_run,
        resume_there: false,
        from: None,
        slow_ok: false,
        from_snapshot: false,
        as_harness: None,
    }
}

/// Leo: "any chat moves Mac↔Cloud and back in one action, keeping its live state". A hub move
/// of a chat mid-turn takes the turn along, as an ssh move does, instead of refusing it.
#[test]
fn a_hub_move_takes_a_running_turn_along() {
    let running = json!({"status": "running", "turn": {"id": "t1"}});
    assert_eq!(plan::refusal(&running, hub_running_ok(&args(false, false, false))), None);
    assert_eq!(plan::refusal(&running, hub_running_ok(&args(true, false, false))), None);
    assert_eq!(plan::refusal(&running, hub_running_ok(&args(false, true, false))), None);
    // A dry run only reports the running turn, as over ssh.
    assert!(plan::refusal(&running, hub_running_ok(&args(false, false, true))).is_some());
}

#[test]
fn a_hub_move_says_whether_it_carried_the_running_turn() {
    let timing = |carried| Timing {
        started: std::time::Instant::now(),
        begin_ms: 10,
        begun_ms: 20,
        sent_ms: 30,
        answer_ms: 50,
        carried,
        target: json!({"via": "circuit"}),
    };
    let carried = timing(true).value(80);
    assert_eq!(carried["carriedRunningTurn"], true);
    assert_eq!(carried["freezeMs"], 70);
    assert_eq!(carried["via"], "circuit");
    assert_eq!(timing(false).value(80)["carriedRunningTurn"], false);
}

#[test]
fn a_hub_move_names_its_folder_as_the_target_can_make_it() {
    let home = Path::new("/home/me");
    let plain = Folder::Plain { cwd: "/home/me/notes/a".into() };
    assert_eq!(folder_value(&plain, home, false).unwrap(), json!({"home": "notes/a"}));
    assert_eq!(folder_value(&plain, home, true).unwrap(), json!({"cwd": "/home/me/notes/a"}));
    let outside = Folder::Plain { cwd: "/srv/x".into() };
    assert!(folder_value(&outside, home, false).is_err());
    let tree = Folder::Worktree {
        repo: "o/n".into(),
        url: "https://github.com/o/n.git".into(),
        branch: "lane/x".into(),
        subdir: "sub".into(),
        dirty: false,
        snapshot: false,
    };
    assert_eq!(
        folder_value(&tree, home, false).unwrap(),
        json!({"repo": "o/n", "url": "https://github.com/o/n.git", "branch": "lane/x", "subdir": "sub"})
    );
}
