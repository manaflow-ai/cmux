use super::*;

fn launch(words: &[&str]) -> Launch {
    #[derive(clap::Parser)]
    struct New {
        #[command(flatten)]
        args: NewArgs,
    }
    // A brief of its own per call: tests run in parallel, and a shared
    // file one test rewrites (truncate, then write) reads empty in another.
    let dir = tempfile::tempdir().unwrap();
    let brief = dir.path().join("brief.md");
    std::fs::write(&brief, "do it\n").unwrap();
    let mut argv = vec!["new".to_owned()];
    argv.extend(words.iter().map(|w| w.replace("BRIEF", &brief.to_string_lossy())));
    let new = <New as clap::Parser>::try_parse_from(argv).unwrap();
    Launch::prepare(&new.args).unwrap()
}

#[test]
fn stale_bundled_cli_falls_back_to_path_name() {
    let stale = std::env::temp_dir().join(format!("acpmux-stale-cli-{}", std::process::id()));
    assert_eq!(select_cli(Some(&stale), None), Path::new("cmux"));
}

#[cfg(unix)]
#[test]
fn a_failing_bundled_cli_retries_the_path_cli() {
    let root = std::env::temp_dir().join(format!("acpmux-cli-fallback-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let bundled = root.join("bundled");
    let path_cli = root.join("path-cmux");
    std::fs::write(&bundled, "#!/bin/sh\nexit 7\n").unwrap();
    std::fs::write(&path_cli, "#!/bin/sh\nexit 0\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for path in [&bundled, &path_cli] {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
    }
    let args = ["agent", "open", "session-id"];
    let (chosen, output) = run_with_fallback(&bundled, &args, &path_cli, None);
    assert_eq!(chosen, path_cli);
    assert!(output.unwrap().status.success());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn a_launched_session_never_gets_ask_user_question() {
    // Nobody sits at its chat: a multiple-choice question would lock it.
    let ask = Some(json!(["AskUserQuestion"]));
    assert_eq!(launch(&["-n", "x", "--prompt-file", "BRIEF"]).disallowed_tools(), ask);
    assert_eq!(launch(&["--report-to", "coord", "go"]).disallowed_tools(), ask);
    assert_eq!(launch(&["-n", "x", "go"]).disallowed_tools(), None);
    assert_eq!(launch(&["-n", "x", "--reuse"]).disallowed_tools(), None);
}

#[test]
fn a_name_with_slashes_becomes_a_session_name() {
    assert_eq!(session_name("gui/composer").unwrap(), "gui-composer");
    assert_eq!(session_name("lane-launcher").unwrap(), "lane-launcher");
    assert_eq!(session_name(" a // b c ").unwrap(), "a-b-c");
    assert_eq!(session_name("/.x/").unwrap(), "x");
    // One worktree, one session: the name is the worktree's.
    assert_eq!(session_name("Lane_A").unwrap(), session_name("lane-a").unwrap());
    assert!(session_name("//").is_err());
}

#[test]
fn a_group_is_a_human_label_and_never_an_object_id() {
    for group in [
        "",
        "   ",
        "grp_012345",
        "ws_012345",
        "workspace_group:42",
        "550e8400-e29b-41d4-a716-446655440000",
    ] {
        let refused = validate_group(group).unwrap_err();
        let error = refused.to_string();
        assert!(error.contains("human label"), "{group:?}: {error}");
        assert!(error.contains("omit --group"), "{group:?}: {error}");
        // A usage error (exit 2) the --json envelope names, before any session is made.
        let app = crate::cli::errors::classify(&refused);
        assert_eq!(app.exit_status(), 2, "{group:?}");
        let envelope = app.envelope();
        assert_eq!(envelope["error"]["detail"], "group_name", "{envelope}");
        assert_eq!(envelope["error"]["data"]["reason"], "usage.group_name", "{envelope}");
    }
    assert!(validate_group("GUI push").is_ok());
}

#[test]
fn a_remote_session_can_join_a_group_without_an_explicit_name() {
    let prepared = launch(&[
        "--host",
        "gcp-codex-lane-2",
        "-m",
        "codex",
        "--group",
        "Remote demo",
        "-d",
        "say hi",
    ]);
    assert!(prepared.name.is_none());
    assert!(!prepared.reuse);
}

#[test]
fn a_named_remote_group_launch_keeps_reuse_and_its_title() {
    let prepared = launch(&[
        "--host",
        "peer",
        "--group",
        "Remote demo",
        "--name",
        "Remote task",
        "--reuse",
        "-d",
    ]);
    assert_eq!(prepared.name.as_deref(), Some("remote-task"));
    assert_eq!(prepared.title.as_deref(), Some("Remote task"));
    assert!(prepared.reuse);
}

#[test]
fn the_last_at_splits_off_the_base() {
    assert_eq!(split_worktree("~/r@origin/feat"), ("~/r", Some("origin/feat")));
    assert_eq!(split_worktree("/a@b/r@main"), ("/a@b/r", Some("main")));
    assert_eq!(split_worktree("/r"), ("/r", None));
    assert_eq!(split_worktree("/r@"), ("/r@", None));
}

#[test]
fn only_a_session_with_no_turn_and_nothing_queued_was_never_prompted() {
    let fresh =
        json!({"turn": null, "lastPrompt": null, "lastTurn": null, "turnCount": 0, "queued": 0});
    assert!(never_prompted(&fresh));
    for (k, v) in [
        ("turn", json!({"prompt": "go"})),
        ("lastPrompt", json!("go")),
        ("turnCount", json!(1)),
        ("queued", json!(1)),
    ] {
        let mut info = fresh.clone();
        info[k] = v;
        assert!(!never_prompted(&info), "{k}");
    }
}

#[test]
fn reuse_finds_a_name_in_another_case_but_never_a_prefix_or_a_peers() {
    let here = json!({"name": "td2-A"});
    assert!(names(&here, "td2-A"));
    assert!(names(&here, "td2-a"));
    assert!(!names(&here, "td2"));
    assert!(!names(&here, "td2_a"));
    let peer = json!({"name": "td2-A", "peer": "Lane-1"});
    assert!(names(&peer, "lane-1/TD2-a"));
    assert!(!names(&peer, "td2-a"));
    assert!(!names(&peer, "lane-2/td2-a"));
    assert!(!names(&here, "lane-1/td2-a"));
}

#[test]
fn a_session_outside_its_worktree_or_ended_is_not_reused() {
    let top = std::env::temp_dir().join(format!("acpmux-reuse-{}", uuid::Uuid::now_v7()));
    let (repo, wt, other) = (top.join("repo"), top.join("wts/lane"), top.join("wts/lane-2"));
    std::fs::create_dir_all(&repo).unwrap();
    let git = |dir: &Path, args: &[&str]| {
        let ok = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
            .args(args)
            .status()
            .unwrap()
            .success();
        assert!(ok, "git {args:?}");
    };
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);
    git(&repo, &["worktree", "add", "-q", "-B", "a", &wt.to_string_lossy()]);
    std::fs::create_dir_all(wt.join("sub")).unwrap();
    git(&repo, &["worktree", "add", "-q", "-B", "b", &other.to_string_lossy()]);
    let at = |cwd: &Path, status: &str| json!({"cwd": cwd, "status": status});
    let r = Some(repo.as_path());
    assert!(check_reusable(&at(&wt, "ready"), "lane", r).is_ok());
    assert!(check_reusable(&at(&wt.join("sub"), "running"), "lane", r).is_ok());
    assert!(check_reusable(&at(&repo, "ready"), "lane", r).is_err());
    assert!(check_reusable(&at(&repo, "ready"), "lane", None).is_ok());
    assert!(check_reusable(&at(&wt, "closed"), "lane", r).is_err());
    assert!(check_reusable(&at(&other, "ready"), "lane", r).is_err());
    let _ = std::fs::remove_dir_all(&top);
}

#[test]
fn the_sidebar_key_is_a_stable_uuid() {
    let k = workspace_key("lane");
    assert_eq!(k, workspace_key("lane"));
    assert_ne!(k, workspace_key("lane2"));
    assert!(uuid::Uuid::parse_str(&k).is_ok());
}

/// An unnamed launch's workspace is named for its session, never the app's `workspace-N`
/// (Leo, 2026-11-02: "hundreds of random sessions"), and a peer's session reads with its peer.
#[test]
fn an_unnamed_launch_names_its_workspace_for_the_session() {
    assert_eq!(
        default_workspace_name("ergo-help", "s-1", Some("gcp-lane-11")).as_deref(),
        Some("gcp-lane-11/ergo-help")
    );
    assert_eq!(
        default_workspace_name("gcp-lane-11/ergo-help", "s-1", Some("gcp-lane-11")).as_deref(),
        Some("gcp-lane-11/ergo-help")
    );
    assert_eq!(default_workspace_name("codex-1", "s-1", None).as_deref(), Some("codex-1"));
    assert_eq!(default_workspace_name("codex-1", "s-1", Some(" ")).as_deref(), Some("codex-1"));
    // No reported name (it fell back to the raw id), or a blank one: nothing better than workspace-N.
    assert_eq!(default_workspace_name("s-1", "s-1", Some("gcp-lane-11")), None);
    assert_eq!(default_workspace_name("  ", "s-1", None), None);
}

/// The session's name goes as `--default-name`, which never reuses a predecessor row; only an
/// explicit launch name goes as `--name`.
#[test]
fn only_an_explicit_name_opts_into_predecessor_reuse() {
    let unnamed = group_open_args("p/s-1", "k", None, Some("p/codex-1"), "g");
    assert_eq!(
        unnamed,
        ["agent", "open", "p/s-1", "--default-name", "p/codex-1", "--key", "k", "--group", "g"]
    );
    assert!(!unnamed.iter().any(|word| word == "--name"), "{unnamed:?}");
    let named = group_open_args("s-1", "k", Some("lane"), Some("lane"), "g");
    assert_eq!(named, ["agent", "open", "s-1", "--name", "lane", "--key", "k", "--group", "g"]);
    assert_eq!(
        group_open_args("s-1", "k", None, None, "g"),
        ["agent", "open", "s-1", "--key", "k", "--group", "g"]
    );
}

#[test]
fn a_group_open_failure_keeps_the_session_name_and_retry_command() {
    let error = show_in_group(
        "session-id",
        "lane-name",
        None,
        None,
        "remote-audit",
        Some(Path::new("/definitely/missing/cmux")),
        None,
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("session lane-name was created"), "{error}");
    assert!(error.contains("cmux agent open session-id"), "{error}");
    assert!(error.contains("--group remote-audit"), "{error}");
}

/// A `cmux agent open` that stalls ends at the caller's deadline, exits as a timeout and is
/// not tried again on the PATH fallback.
#[cfg(unix)]
#[test]
fn a_stalled_group_open_ends_at_the_caller_deadline_as_a_timeout() {
    let dir = std::env::temp_dir().join(format!("acpmux-group-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let cli = dir.join("cmux");
    crate::test_exec::write_executable(&cli, "#!/bin/sh\nsleep 30\n");
    let started = std::time::Instant::now();
    let deadline = Instant::now() + std::time::Duration::from_millis(300);
    let error =
        show_in_group("session-id", "lane-name", None, None, "g", Some(&cli), Some(deadline))
            .unwrap_err();
    assert!(started.elapsed() < std::time::Duration::from_secs(2), "{:?}", started.elapsed());
    let app = error.downcast_ref::<crate::cli::errors::AppError>();
    assert_eq!(app.map(|a| a.code), Some(crate::cli::errors::Code::Timeout), "{error:#}");
    assert!(error.to_string().contains("session lane-name was created"), "{error:#}");
    std::fs::remove_dir_all(dir).unwrap();
}

/// An app older than `defaultName` refuses the argument: the open runs again without it, so
/// the launch still shows its session (named `workspace-N` there), as before the default name.
#[cfg(unix)]
#[test]
fn an_app_without_default_name_still_shows_the_session() {
    let dir = std::env::temp_dir().join(format!("acpmux-group-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let cli = dir.join("cmux");
    let log = dir.join("calls");
    crate::test_exec::write_executable(
        &cli,
        format!(
            "#!/bin/sh\necho \"$*\" >> '{}'\ncase \"$*\" in *--default-name*) echo \"agent.openSessionWorkspace has no argument 'defaultName'\" >&2; exit 1;; esac\n",
            log.display()
        ),
    );
    show_in_group("session-id", "lane-name", None, Some("peer/lane"), "g", Some(&cli), None)
        .unwrap();
    let calls = std::fs::read_to_string(&log).unwrap();
    let calls: Vec<&str> = calls.lines().collect();
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(calls[0].contains("--default-name peer/lane"), "{calls:?}");
    assert!(!calls[1].contains("--default-name"), "{calls:?}");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn an_empty_or_missing_prompt_file_fails() {
    let dir = std::env::temp_dir().join(format!("acpmux-launch-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let empty = dir.join("empty.md");
    std::fs::write(&empty, " \n").unwrap();
    assert!(read_prompt_file(&empty).unwrap_err().to_string().contains("is empty"));
    assert!(read_prompt_file(&dir.join("missing.md")).is_err());
    let brief = dir.join("brief.md");
    std::fs::write(&brief, "do it\n").unwrap();
    assert_eq!(read_prompt_file(&brief).unwrap(), "do it\n");
    let oversized = dir.join("oversized.md");
    std::fs::write(&oversized, vec![b'x'; (MAX_PROMPT_FILE + 1) as usize]).unwrap();
    assert!(read_prompt_file(&oversized).unwrap_err().to_string().contains("more than 1 MiB"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn stdin_prompt_paths_read_from_the_already_open_stdin() {
    for path in ["-", "/dev/stdin", "/proc/self/fd/0", "/dev/fd/0"] {
        assert_eq!(
            read_prompt_file_with(Path::new(path), std::io::Cursor::new("do it\n")).unwrap(),
            "do it\n",
            "{path}"
        );
    }
}
