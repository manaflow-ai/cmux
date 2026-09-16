use cmux_cli::dispatch;

fn run(args: &[&str]) -> i32 {
    let mut owned = args.iter().map(|value| (*value).to_owned()).collect();
    dispatch(&mut owned).expect("no-socket command should succeed")
}

#[test]
fn help_aliases_are_socket_free() {
    for args in [
        vec!["--help"],
        vec!["-h"],
        vec!["help"],
        vec!["--socket", "/definitely-missing.sock", "help"],
    ] {
        assert_eq!(run(&args), 0, "failed invocation: {args:?}");
    }
}

#[test]
fn version_aliases_are_socket_free() {
    for args in [vec!["--version"], vec!["-v"], vec!["version"]] {
        assert_eq!(run(&args), 0, "failed invocation: {args:?}");
    }
}

#[test]
fn capabilities_is_local_agent_discovery() {
    // Agents use this probe before a cmux app is running. A capability catalog
    // must therefore not depend on transport::rpc or an implicit socket.
    assert_eq!(run(&["capabilities", "--local"]), 0);
}

#[test]
fn global_parser_accepts_agent_options_before_no_socket_commands() {
    for args in [
        vec!["--json", "help"],
        vec!["--output", "json", "help"],
        vec!["--non-interactive", "help"],
        vec!["--dry-run", "help"],
        vec!["--explain", "help"],
        vec!["--id-format", "both", "help"],
    ] {
        assert_eq!(run(&args), 0, "failed invocation: {args:?}");
    }
}
