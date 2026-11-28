use super::*;

fn os(args: &[&str]) -> Vec<OsString> {
    args.iter().map(OsString::from).collect()
}

#[test]
fn the_agent_router_recognizes_every_engine_command_and_alias() {
    // Build the full grammar on the CLI stack. Run the router on the normal test thread.
    let words = std::thread::Builder::new()
        .stack_size(WORKER_STACK_BYTES)
        .spawn(|| {
            Cli::command()
                .get_subcommands()
                .flat_map(|cmd| {
                    std::iter::once(cmd.get_name()).chain(cmd.get_all_aliases()).map(str::to_owned)
                })
                .collect::<Vec<_>>()
        })
        .unwrap()
        .join()
        .unwrap();
    for word in &words {
        assert!(is_command(word), "{word}");
    }
    for &alias in aliases::GROUPS.iter().flat_map(|group| group.iter()) {
        assert!(words.iter().any(|word| word == alias), "unregistered alias {alias}");
    }
    for word in ["stop", "--skill", "--guide"] {
        assert!(is_command(word), "{word}");
    }
    for word in ["", "unknown-command", "open-terminal-as-chat"] {
        assert!(!is_command(word), "{word}");
    }
}

#[test]
fn an_agent_s_guess_at_a_session_s_events_runs_session_tail() {
    use clap::Parser as _;
    // The words an agent tried for interim-coord's events (Leo's screenshot, 2026-11-21):
    // `events NAME --tail 25` and `log NAME`, both "unrecognized subcommand" before.
    let parse = |args: &[&str]| {
        let argv: Vec<OsString> =
            std::iter::once("acpmux").chain(args.iter().copied()).map(Into::into).collect();
        std::thread::Builder::new()
            .stack_size(WORKER_STACK_BYTES)
            .spawn(move || {
                let cli = Cli::try_parse_from(argv).unwrap_or_else(|e| panic!("{e}"));
                match cli.command.map(flatten) {
                    Some(Command::Tail { session, last, follow, .. }) => (session, last, follow),
                    _ => panic!("not tail"),
                }
            })
            .unwrap()
            .join()
            .unwrap()
    };
    assert_eq!(
        parse(&["events", "interim-coord", "--tail", "25"]),
        ("interim-coord".into(), 25, false)
    );
    assert_eq!(parse(&["log", "coord"]), ("coord".into(), 50, false));
    assert_eq!(parse(&["logs", "coord", "-n", "5", "-f"]), ("coord".into(), 5, true));
    assert_eq!(parse(&["session", "tail", "coord", "--tail", "7"]), ("coord".into(), 7, false));
    for word in ["events", "log", "logs"] {
        assert!(is_command(word), "{word}");
    }
}

#[test]
fn a_stdio_mcp_server_runs_on_a_small_runtime() {
    for name in [
        "acpmux-mcp",
        "subsession-mcp",
        "forum-mcp",
        "offer-mcp",
        "secret-mcp",
        "computer-use-mcp",
        "repo-mcp",
        "hosted-mcp",
        "github-mcp",
    ] {
        assert_eq!(runtime_workers(&os(&[name])), Some(MCP_WORKERS), "{name}");
        assert_eq!(runtime_workers(&os(&["--json", name])), Some(MCP_WORKERS), "{name}");
    }
    let bridge = os(&["bridge", "mcp", "--as", "codex-desktop"]);
    assert_eq!(runtime_workers(&bridge), Some(MCP_WORKERS));
    // acpmux's own servers in one process per chat: one worker.
    assert_eq!(runtime_workers(&os(&["tools-mcp"])), Some(TOOLS_MCP_WORKERS));
    assert_eq!(runtime(&os(&["tools-mcp"])).unwrap().metrics().num_workers(), 1);
}

#[test]
fn every_other_command_keeps_the_default_runtime() {
    for args in [
        &["ls"][..],
        &["daemon", "run"],
        &["send", "forum-mcp"],
        &[],
        &["--json"],
        &["bridge", "inbox"],
    ] {
        assert_eq!(runtime_workers(&os(args)), None, "{args:?}");
    }
}

/// The worker count each command line runs with, read as `main` reads it: the word rule, then
/// the parsed command (on the CLI's stack, as the grammar needs).
fn workers_of(args: &[&str]) -> Option<usize> {
    let args = os(args);
    std::thread::Builder::new()
        .stack_size(WORKER_STACK_BYTES)
        .spawn(move || {
            use clap::Parser as _;
            let mut argv = vec![OsString::from("acpmux")];
            argv.extend(args.iter().cloned());
            let cli = Cli::try_parse_from(argv).unwrap();
            workers_for(runtime_workers(&args), cli.command.map(flatten).as_ref())
        })
        .unwrap()
        .join()
        .unwrap()
}

#[test]
fn a_one_shot_call_runs_on_one_worker_not_one_per_core() {
    for args in [
        &["ls"][..],
        &["--json", "ls"],
        &["send", "--no-wait", "worker", "hello"],
        &["send", "worker", "hello"],
        &["register", "duress-reg-1"],
        &["status"],
        &["info", "worker"],
        &["last", "worker"],
        &["pending"],
    ] {
        assert_eq!(workers_of(args), Some(ONE_SHOT_WORKERS), "{args:?}");
    }
    assert_eq!(runtime_with(false, Some(ONE_SHOT_WORKERS)).unwrap().metrics().num_workers(), 1);
    // The daemon, the terminal UI and every other command keep tokio's default.
    for args in [&["daemon", "run"][..], &[], &["--json"], &["attach", "worker"]] {
        assert_eq!(workers_of(args), None, "{args:?}");
    }
    // The word rule still wins: a stdio MCP server keeps its two.
    assert_eq!(workers_of(&["forum-mcp"]), Some(MCP_WORKERS));
}

#[test]
fn the_small_runtime_has_its_workers_and_not_one_per_core() {
    let small = runtime(&os(&["forum-mcp"])).unwrap();
    assert_eq!(small.metrics().num_workers(), MCP_WORKERS);
    // Every other command keeps tokio's default: one worker per core.
    let default = runtime(&os(&["ls"])).unwrap();
    if std::thread::available_parallelism().unwrap().get() > MCP_WORKERS {
        assert!(default.metrics().num_workers() > MCP_WORKERS);
    }
}
