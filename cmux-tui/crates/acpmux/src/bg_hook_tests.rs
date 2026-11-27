use super::*;
use crate::agent_tools::{MCP_TOOLS_ENV, UPSTREAMS_ENV};

fn call(background: bool) -> Value {
    json!({"tool_name": "Bash", "cwd": "/work/app",
        "tool_input": {"command": "npm run dev", "run_in_background": background}})
}

/// A stand-in for this binary: a shell that prints each argument it gets on a line.
fn cli() -> TaskCli {
    let words = ["sh", "-c", "printf '%s\\n' \"$@\"", "acpmux"].map(str::to_owned).to_vec();
    TaskCli {
        words,
        denied: "/h/chat's mcp.json.bg-denied".into(),
        key: "k1".to_owned(),
        run_vm: None,
        slow: true,
    }
}

/// The rewritten call's input, or a panic when the hook did not rewrite it.
fn rewritten(input: &Value, route: Route) -> Value {
    let answer = decide(input, Some(route), &cli()).expect("rewritten");
    let out = &answer["hookSpecificOutput"];
    assert_eq!(out["hookEventName"], "PreToolUse");
    assert!(out.get("permissionDecision").is_none(), "asked or allowed as before: {out}");
    out["updatedInput"].clone()
}

/// The words the rewritten command hands this binary, as the shell splits them.
#[cfg(unix)]
fn argv(updated: &Value) -> Vec<String> {
    let out = std::process::Command::new("sh")
        .args(["-c", updated["command"].as_str().unwrap()])
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    let text = String::from_utf8(out.stdout).unwrap();
    text.strip_suffix('\n').unwrap().split('\n').map(str::to_owned).collect()
}

#[test]
fn a_tail_bounded_by_a_process_is_not_a_follow_that_never_ends() {
    assert_eq!(slow_reason("tail -f --pid=1234 /dev/null"), None);
    assert_eq!(slow_reason("timeout 200 tail -f --pid 99 log"), None);
    assert!(slow_reason("tail -f log").is_some());
}

/// The top refusal of every guard on one agent host (245 in 24 h): a background shell
/// was turned away with the `bg_start` call to make instead. Now the same call runs, in the
/// foreground, as this binary's `process start` with the same command, which starts the
/// daemon-owned task and answers at once; the rest of the call stays.
#[cfg(unix)]
#[test]
fn a_background_shell_is_rewritten_into_a_daemon_task_start() {
    let command = "cd 'my app' && npm run dev -- --port \"$PORT\" 2>&1 | tee log";
    let input = json!({"tool_name": "Bash", "cwd": "/work/app", "tool_input": {
        "command": command, "run_in_background": true, "description": "dev server",
        "timeout": 5000}});
    for (route, word) in
        [(Route::Direct, "direct"), (Route::Listed, "listed"), (Route::CodeMode, "code-mode")]
    {
        let updated = rewritten(&input, route);
        assert_eq!(updated["run_in_background"], false, "{updated}");
        assert_eq!(updated["description"], "dev server");
        assert_eq!(updated["timeout"], 5000);
        let expected = [
            "process",
            "start",
            "--route",
            word,
            "--hook-denied",
            "/h/chat's mcp.json.bg-denied",
            "--hook-key",
            "k1",
            "--description",
            "dev server",
            "--",
            command,
        ];
        assert_eq!(argv(&updated), expected, "{updated}");
    }
}

/// The rewritten start names the Bash call it came from, so the process registry lists the
/// daemon's task under that call and the transcript's row and the task are one.
#[cfg(unix)]
#[test]
fn a_rewritten_start_names_its_tool_call() {
    let input = json!({"tool_name": "Bash", "tool_use_id": "toolu_01ABC", "tool_input": {
        "command": "npm run dev", "run_in_background": true}});
    let words = argv(&rewritten(&input, Route::Direct));
    let at = words.iter().position(|w| w == "--tool-call").expect("--tool-call");
    assert_eq!(words[at + 1], "toolu_01ABC");
    assert!(at < words.iter().position(|w| w == "--").unwrap(), "{words:?}");
}

/// The second refusal (221 in 24 h): a follow that never ends, in the foreground. It is
/// rewritten too, with why, so `process start` can say it.
#[cfg(unix)]
#[test]
fn a_slow_foreground_command_is_rewritten_into_a_daemon_task_start() {
    let updated = rewritten(&foreground("tail -f /var/log/app.log"), Route::CodeMode);
    assert_eq!(updated["run_in_background"], false);
    let words = argv(&updated);
    let slow = words.iter().position(|w| w == "--slow").expect("--slow");
    assert_eq!(words[slow + 1], "a follow that never ends on its own");
    assert_eq!(words.last().unwrap(), "tail -f /var/log/app.log");
}

/// The two chats that would not hibernate (2026-11-22): a background subagent blocked in a
/// foreground `glaeda-gh wait` for 40 and 90 minutes, a bash under an idle harness. The wait
/// now starts as a daemon task, still marked as that subagent's, so its end reaches it or its
/// lead and the harness can hibernate meanwhile.
#[cfg(unix)]
#[test]
fn a_subagents_foreground_ci_wait_is_rewritten_into_a_daemon_task_start() {
    for command in [
        "timeout 5500 glaeda-gh wait pr o/r#45270 --until done --sha 641e4a7 --timeout 5400 \
--max 5400 2>&1 | grep -v 'WARNING: the daemon' | tail -25",
        "timeout 2500 glaeda-gh wait pr o/r#17815 --until merged --timeout 2400 2>&1 | tail -15",
        "glaeda-gh wait run o/r/7",
        "lane-gh call ci_wait o/r '{\"id\":3}'",
    ] {
        let mut input = foreground(command);
        input["tool_input"]["timeout"] = json!(5_600_000);
        input["agent_id"] = json!("aaa3e4dce28a52538");
        input["agent_type"] = json!("claude");
        let updated = rewritten(&input, Route::Direct);
        let words = argv(&updated);
        let slow = words.iter().position(|w| w == "--slow").expect("--slow");
        assert_eq!(words[slow + 1], "a CI wait", "{command}");
        assert_eq!(words.last().unwrap(), command);
        // `main` marks the rewritten call as the subagent's, so `process start` names it.
        let mut call = input.clone();
        call["tool_input"] = updated;
        let marked = subagent_mark(&call).expect("marked");
        let text = marked["hookSpecificOutput"]["updatedInput"]["command"].as_str().unwrap();
        assert!(
            text.starts_with("export ACPMUX_CALLER_SUBAGENT=claude:aaa3e4dce28a52538\n"),
            "{text}"
        );
    }
}

/// A wait with a short bound of its own reads the state now: it runs as asked.
#[test]
fn a_wait_with_a_short_bound_is_a_read() {
    for command in [
        "timeout 300 glaeda-gh wait pr o/r#1 --until done --sha abc --timeout 60 --json",
        "glaeda-gh wait pr o/r#1 --max=30",
        "glaeda-gh wait run o/r/7 --timeout 2m",
        "glaeda-gh wait --help",
    ] {
        assert_eq!(slow_reason(command), None, "{command}");
    }
    for command in [
        "glaeda-gh wait pr o/r#1",
        "glaeda-gh wait pr o/r#1 --timeout 600",
        "glaeda-gh wait run o/r/7 --timeout 30m",
        "glaeda-gh status",
    ] {
        assert_eq!(slow_reason(command).is_some(), command.contains(" wait "), "{command}");
    }
}

/// Off (cmux's default), a known-slow foreground command runs as asked, routed or not;
/// a background shell is still moved to a daemon task.
#[test]
fn with_the_slow_switch_off_a_slow_foreground_command_runs_as_asked() {
    let off = TaskCli { slow: false, ..cli() };
    for command in ["cargo test -p acpmux", "glaeda-gh wait pr o/r#1", "tail -f log"] {
        assert_eq!(decide(&foreground(command), None, &off), None, "{command}");
        assert_eq!(decide(&foreground(command), Some(Route::Direct), &off), None, "{command}");
    }
    assert!(decide(&call(true), Some(Route::Direct), &off).is_some());
}

#[test]
fn the_slow_switch_is_off_unless_the_setting_or_env_turns_it_on() {
    assert!(!slow_foreground_in(&json!({})));
    assert!(!slow_foreground_in(&json!({"agents": {"slowForeground": {"enabled": false}}})));
    assert!(slow_foreground_in(&json!({"agents": {"slowForeground": {"enabled": true}}})));
    assert!(slow_foreground_in(&json!({"agents.slowForeground.enabled": true})));
    assert_eq!(switch_word(" On "), Some(true));
    assert_eq!(switch_word("0"), Some(false));
    assert_eq!(switch_word("maybe"), None);
}

#[test]
fn without_the_acpmux_server_or_in_the_foreground_the_shell_runs() {
    assert_eq!(decide(&call(true), None, &cli()), None);
    assert_eq!(decide(&foreground("ls -la"), Some(Route::Direct), &cli()), None);
    let read = json!({"tool_name": "Read", "tool_input": {"run_in_background": true}});
    assert_eq!(decide(&read, Some(Route::Direct), &cli()), None);
}

/// A rewritten call is recorded like a refusal was: the same call again runs as asked (the
/// task may not have started), unless `process start` started it and forgot the key, when
/// the same call later is rewritten again.
#[cfg(unix)]
#[test]
fn a_started_task_forgets_its_key_and_a_failed_one_lets_the_repeat_run() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("mcp.json.bg-denied");
    assert!(first_time(&file, "a").unwrap(), "rewritten");
    assert!(!first_time(&file, "a").unwrap(), "a repeat after a failed start runs");
    assert!(first_time(&file, "a").unwrap(), "and the next is rewritten again");
    assert!(forget(&file, "a").unwrap(), "a started task forgets it");
    assert!(!forget(&file, "a").unwrap());
    assert!(first_time(&file, "a").unwrap(), "so the same call later is rewritten again");
    assert!(first_time(&file, "b").unwrap());
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "a\nb\n");
}

#[test]
fn the_read_call_follows_the_chats_route() {
    assert_eq!(read_call(Some(&Route::Direct), "t1"), r#"mcp__cmux-agent__bg_output {"id":"t1"}"#);
    assert_eq!(
        read_call(Some(&Route::DirectLegacy), "t1"),
        r#"mcp__acpmux__bg_output {"id":"t1"}"#
    );
    assert_eq!(read_call(Some(&Route::Listed), "t1"), r#"mcp__cmux__acpmux_bg_output {"id":"t1"}"#);
    assert!(read_call(Some(&Route::CodeMode), "t1").contains("cmux.acpmux_bg_output("));
    for route in [Route::Direct, Route::DirectLegacy, Route::Listed, Route::CodeMode] {
        assert_eq!(route_of_word(route_word(&route)), Some(route));
    }
}

/// The route is the one the chat's cmux server really offers: code mode, every tool, or a
/// preset's allowlist, which may leave bg_start out (then nothing replaces the shell).
#[test]
fn the_route_comes_from_the_chats_mcp_config() {
    let direct = json!({"mcpServers": {"cmux-agent": {"command": "acpmux"}}});
    assert_eq!(route(&direct), Some(Route::Direct));
    // Under its name before the rename, which a person's own entry kept.
    let legacy = json!({"mcpServers": {"acpmux": {"command": "acpmux"}}});
    assert_eq!(route(&legacy), Some(Route::DirectLegacy));
    let ups = json!([{"name": "cmux-agent"}]).to_string();
    let old_ups = json!([{"name": "acpmux"}]).to_string();
    let serve_old = json!({"mcpServers": {"cmux": {"args": ["mcp", "serve"],
        "env": {UPSTREAMS_ENV: old_ups}}}});
    assert_eq!(route(&serve_old), Some(Route::CodeMode));
    let cmux =
        |args: Value, env: Value| json!({"mcpServers": {"cmux": {"args": args, "env": env}}});
    let serve = json!(["mcp", "serve"]);
    assert_eq!(route(&cmux(serve.clone(), json!({UPSTREAMS_ENV: ups}))), Some(Route::CodeMode));
    let all = json!(["mcp", "serve", "--all-tools"]);
    assert_eq!(route(&cmux(all, json!({UPSTREAMS_ENV: ups}))), Some(Route::Listed));
    let allowed =
        |tools: &str| cmux(serve.clone(), json!({UPSTREAMS_ENV: ups, MCP_TOOLS_ENV: tools}));
    assert_eq!(route(&allowed("render, acpmux_bg_start")), Some(Route::Listed));
    assert_eq!(route(&allowed("render,agents_snapshot")), None);
    assert_eq!(route(&cmux(serve.clone(), json!({UPSTREAMS_ENV: "[]"}))), None);
    assert_eq!(route(&json!({})), None);
}

fn foreground(command: &str) -> Value {
    json!({"tool_name": "Bash", "cwd": "/work/app", "tool_input": {"command": command}})
}

#[test]
fn known_slow_commands_are_named() {
    for slow in [
        "cargo test -p acpmux",
        "cd cmux-tui && RUST_LOG=debug cargo build --release",
        "timeout 900 cargo clippy --workspace",
        "/usr/bin/xcodebuild -scheme App build",
        "swift test --filter Foo",
        "gh run watch 123",
        "gh pr checks 12 --watch",
        "nohup npm run dev > dev.log",
        "npm run dev",
        "pnpm dev",
        "bash -lc 'yarn start'",
        "tail -f /var/log/app.log",
    ] {
        assert!(slow_reason(slow).is_some(), "{slow}");
    }
    for quick in [
        "cargo --version",
        "cargo test --help",
        "xcodebuild -version",
        "xcodebuild -list",
        "npm run build",
        "gh pr checks 12",
        "gh run view 123",
        "ls && git status",
        "cargo test -p acpmux # fg-ok",
        "npm run dev &",
        "tail -n 50 log.txt",
    ] {
        assert_eq!(slow_reason(quick), None, "{quick}");
    }
}

/// Only a command the shell runs is slow, never the text of an argument, a quote or a
/// heredoc body. The lane live-apply-nightly was turned away five times on 2026-11-04 for a
/// grep pattern and a heredoc that named `swift build`, `tail -f` and `watch`.
#[test]
fn words_in_arguments_quotes_and_heredocs_are_not_run() {
    for quick in [
        "grep -e 'swift build' -r .",
        r#"rg "tail -f" src"#,
        r#"grep -rIl -iE "foreground|swift build.*watch|tail -f" ~/.claude"#,
        "cat <<'EOF' > notes.md\nrun tail -f log, then watch -n1 ls\nswift build\nEOF",
        "cat <<EOF\ntail -F x\nwatch ls\nEOF\ngit status",
        "cat > f.txt <<-EOF\n\ttail -f x\n\tEOF",
        r#"git commit -m "fix: swift build | tail -f; watch""#,
        "echo 'watch this'",
        "echo watch this # tail -f x",
        "ls 2>&1 | tee log",
        "cat <<'EOF'\n$(swift build)\nEOF",
        "bash; cat <<EOF\nswift build\nEOF",
        "cat <<DATA; bash <<CODE\nswift build\nDATA\nls\nCODE",
        // ssh's remote command is not read (the policy before this change).
        "ssh host swift build",
    ] {
        assert_eq!(slow_reason(quick), None, "{quick}");
    }
    for slow in [
        "swift build",
        r#"bash -c "swift build""#,
        "sh -ec 'cd x && tail -F y'",
        "foo | tail -f x",
        "watch -n1 ls",
        "env A=1 swift build",
        r#"echo "$(swift build)""#,
        "x=`tail -f log`",
        "bash <<EOF\nswift build\nEOF",
        "cat <<EOF | sh\nswift build\nEOF",
        "cat <<EOF\nnotes\nEOF\nswift build",
        "( cd app && swift build )",
        "cat <<EOF\n$(\nswift build\n)\nEOF",
        r#"echo "${X:-$(swift build)}""#,
        "if true; then watch ls; fi",
        "tail --follow app.log",
        // Unreadable input falls back to the loose read, which names more.
        "echo 'open && swift build",
    ] {
        assert!(slow_reason(slow).is_some(), "{slow}");
    }
}

mod agent_messaging {
    use super::*;

    /// Claude Code names a subagent only in the hook's input (`agent_id`, `agent_type`; read on
    /// 2.1.319): its acpmux command gets the mark, with no permission decision, and the lead's
    /// own calls and any other command run unchanged.
    #[test]
    fn a_subagents_acpmux_command_is_marked_and_nothing_else_is() {
        let call = |command: &str, agent: Option<(&str, &str)>| {
            let mut input = json!({"tool_name": "Bash", "cwd": "/w",
                "tool_input": {"command": command, "description": "ask beta", "timeout": 5000}});
            if let Some((kind, id)) = agent {
                input.set("agent_type", json!(kind));
                input.set("agent_id", json!(id));
            }
            input
        };
        let sub = Some(("general-purpose", "a0a68e7af3df5967e"));
        let mark = subagent_mark(&call("acpmux send beta --wait 'hi'", sub)).unwrap();
        let out = &mark["hookSpecificOutput"];
        assert_eq!(out["hookEventName"], "PreToolUse");
        assert!(out.get("permissionDecision").is_none(), "asks or allows as before: {out}");
        assert_eq!(
            out["updatedInput"]["command"],
            "export ACPMUX_CALLER_SUBAGENT=general-purpose:a0a68e7af3df5967e\nacpmux send beta --wait 'hi'"
        );
        assert_eq!(out["updatedInput"]["description"], "ask beta", "the rest of the call stays");
        assert_eq!(out["updatedInput"]["timeout"], 5000);
        // The lead's own call, another command, a marked one, an odd id: unchanged.
        assert_eq!(subagent_mark(&call("acpmux send beta hi", None)), None);
        assert_eq!(subagent_mark(&call("git status", sub)), None);
        let again = "export ACPMUX_CALLER_SUBAGENT=x:y\nacpmux ls";
        assert_eq!(subagent_mark(&call(again, sub)), None);
        assert_eq!(subagent_mark(&call("acpmux ls", Some(("x", "a1;rm -rf /")))), None);
        // A type that is no plain word is named `subagent`.
        let odd = subagent_mark(&call("acpmux ls", Some(("my agent", "a1")))).unwrap();
        let command = odd["hookSpecificOutput"]["updatedInput"]["command"].as_str().unwrap();
        assert!(command.starts_with("export ACPMUX_CALLER_SUBAGENT=subagent:a1\n"), "{command}");
    }
}

mod caller_identity {
    use super::*;

    fn sub_call(command: &str) -> Value {
        json!({"tool_name": "Bash", "cwd": "/w", "agent_type": "general-purpose",
            "agent_id": "a0a68e7af3df5967e", "tool_input": {"command": command}})
    }

    fn marked(command: &str) -> Option<String> {
        let mark = subagent_mark(&sub_call(command))?;
        let out = mark["hookSpecificOutput"]["updatedInput"]["command"].as_str()?.to_owned();
        Some(out)
    }

    /// The mark does not hang on the word "acpmux" in the command: a wrapper script, an
    /// alias, a variable or an absolute path under another name runs the same CLI, and a
    /// subagent's send through one went out as its lead's.
    #[test]
    fn a_subagents_command_through_a_wrapper_alias_or_other_path_is_marked() {
        let prefix = "export ACPMUX_CALLER_SUBAGENT=general-purpose:a0a68e7af3df5967e\n";
        for command in [
            "./scripts/tell beta 'hi'",
            "amx send beta hi",
            "/opt/tools/bin/agent-send beta hi",
            "$A send beta hi",
            "cd /w && python3 tools/notify.py beta",
            "ls && ./tell beta hi",
            "echo $(./tell beta hi)",
            "sh -c 'tell beta hi'",
            "git -c core.pager=./tell log",
            "git submodule foreach ./tell",
            "git rebase --exec ./tell main",
            "rg --pre ./tell foo",
            "sort --compress-program=./tell a.txt",
            "sed 's/x/./e' a.txt",
        ] {
            let got = marked(command).unwrap_or_else(|| panic!("not marked: {command}"));
            assert_eq!(got, format!("{prefix}{command}"), "{command}");
        }
    }

    /// A command made only of tools that never start another program stays as it was, so
    /// the harness judges it as before (Claude Code runs a read-only command unasked).
    #[test]
    fn a_subagents_plain_read_only_command_is_not_changed() {
        for command in [
            "ls -la",
            "git status",
            "git -C /w log --oneline -5",
            "rg -n foo src | head -20",
            "cat a.txt && wc -l b.txt",
            "sed -n '1,40p' src/main.rs",
        ] {
            assert_eq!(marked(command), None, "{command}");
        }
    }
}

#[test]
fn a_slow_foreground_shell_goes_to_the_background() {
    // With no bg_start in the chat, still a refusal towards the harness's own background.
    let deny = decide(&foreground("cargo test"), None, &cli()).unwrap();
    assert_eq!(deny["hookSpecificOutput"]["permissionDecision"], "deny");
    let reason = deny["hookSpecificOutput"]["permissionDecisionReason"].as_str().unwrap();
    assert!(reason.contains("a Rust test run"), "{reason}");
    assert!(reason.contains("run_in_background: true"), "{reason}");
    let updated = rewritten(&foreground("cargo test"), Route::Direct);
    let command = updated["command"].as_str().unwrap();
    assert!(command.contains("'start' '--route' 'direct'"), "{command}");
    assert!(command.ends_with("'--slow' 'a Rust test run' '--' 'cargo test'"), "{command}");
    assert_eq!(decide(&foreground("git status"), None, &cli()), None);
    assert_eq!(decide(&foreground("git status"), Some(Route::Direct), &cli()), None);
}
