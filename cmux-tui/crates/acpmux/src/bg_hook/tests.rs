use super::*;
use crate::agent_tools::{MCP_TOOLS_ENV, UPSTREAMS_ENV};

fn call(background: bool) -> Value {
    json!({"tool_name": "Bash", "cwd": "/work/app",
            "tool_input": {"command": "npm run dev", "run_in_background": background}})
}

fn reason(route: Route) -> String {
    let deny = decide(&call(true), Some(route)).unwrap();
    assert_eq!(deny["hookSpecificOutput"]["permissionDecision"], "deny");
    deny["hookSpecificOutput"]["permissionDecisionReason"].as_str().unwrap().to_owned()
}

#[test]
fn a_background_shell_is_turned_to_bg_start_with_the_same_command_and_folder() {
    let args = r#"{"command":"npm run dev","cwd":"/work/app"}"#;
    assert!(reason(Route::Direct).contains(&format!("mcp__acpmux__bg_start {args} ")));
    assert!(reason(Route::Listed).contains(&format!("mcp__cmux__acpmux_bg_start {args} ")));
    assert!(reason(Route::CodeMode).contains(&format!("cmux.acpmux_bg_start({args})")));
}

#[test]
fn without_the_acpmux_server_or_in_the_foreground_the_shell_runs() {
    assert_eq!(decide(&call(true), None), None);
    assert_eq!(decide(&foreground("ls -la"), Some(Route::Direct)), None);
    let read = json!({"tool_name": "Read", "tool_input": {"run_in_background": true}});
    assert_eq!(decide(&read, Some(Route::Direct)), None);
}

/// The route is the one the chat's cmux server really offers: code mode, every tool, or a
/// preset's allowlist, which may leave bg_start out (then nothing replaces the shell).
#[test]
fn the_route_comes_from_the_chats_mcp_config() {
    let direct = json!({"mcpServers": {"acpmux": {"command": "acpmux"}}});
    assert_eq!(route(&direct), Some(Route::Direct));
    let ups = json!([{"name": "acpmux"}]).to_string();
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
    let deny = decide(&foreground("cargo test"), None).unwrap();
    let reason = deny["hookSpecificOutput"]["permissionDecisionReason"].as_str().unwrap();
    assert!(reason.contains("a Rust test run"), "{reason}");
    assert!(reason.contains("run_in_background: true"), "{reason}");
    let deny = decide(&foreground("cargo test"), Some(Route::Direct)).unwrap();
    let reason = deny["hookSpecificOutput"]["permissionDecisionReason"].as_str().unwrap();
    assert!(
        reason.contains(r#"mcp__acpmux__bg_start {"command":"cargo test","cwd":"/work/app"}"#),
        "{reason}"
    );
    assert_eq!(decide(&foreground("git status"), None), None);
    assert_eq!(decide(&foreground("git status"), Some(Route::Direct)), None);
}

/// The plugin's Bash hook starts this binary for every call [`main`] may answer (a
/// background shell, a subagent's call, each known-slow command, the forms agents write) and
/// for no quick foreground call of the lead, which then costs a shell and no process start.
#[cfg(unix)]
#[test]
fn the_bash_hook_starts_the_binary_only_for_a_call_it_may_answer() {
    use std::io::Write;
    let words = ["sh", "-c", "cat >/dev/null; echo started"].map(str::to_owned);
    let hook = crate::agent_tools::hook_command(&words, &bash_patterns());
    let starts = |input: &Value| {
        let mut child = std::process::Command::new("sh")
            .args(["-c", &hook])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input.to_string().as_bytes()).unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "{out:?}");
        String::from_utf8_lossy(&out.stdout).trim() == "started"
    };
    let mut slow: Vec<String> = SLOW
        .iter()
        .map(|(tool, next, needs, _)| {
            [Some(*tool), *next, *needs].into_iter().flatten().collect::<Vec<_>>().join(" ")
        })
        .collect();
    slow.extend(
        [
            "cd cmux-tui && cargo test -p acpmux --lib 2>&1 | tail -40",
            "/usr/bin/xcodebuild -scheme cmux -configuration Debug build",
            "gh pr checks 12 --watch --interval 30",
            "tail -n 50 -F /tmp/app.log",
            "npm run dev -- --port 3000",
            "set -e\nswift build -c release",
        ]
        .map(str::to_owned),
    );
    for command in &slow {
        assert!(slow_reason(command).is_some(), "{command}");
        assert!(starts(&foreground(command)), "a slow command did not start the hook: {command}");
    }
    let quick =
        ["git status --short | head -20", "ls -la", "rg -n TODO src", "echo run_in_background"];
    for command in quick {
        assert!(slow_reason(command).is_none());
        assert!(!starts(&foreground(command)), "a quick command started the hook: {command}");
        let mut call = foreground(command);
        call["tool_input"]["run_in_background"] = json!(false);
        assert!(!starts(&call), "{command}");
        call["tool_input"]["run_in_background"] = json!(true);
        assert!(decide(&call, Some(Route::Direct)).is_some());
        assert!(starts(&call), "a background shell did not start the hook: {command}");
        let mut call = foreground(command);
        call["agent_id"] = json!("a0");
        call["agent_type"] = json!("Explore");
        assert!(starts(&call), "a subagent's call did not start the hook: {command}");
    }
}
