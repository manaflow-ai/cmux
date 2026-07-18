use std::io::{BufRead, BufReader, Write};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use futures_util::{SinkExt, StreamExt};

#[test]
fn rpc_uses_stdio_without_server_state() {
    let output = run_stdio_rpc(br#"{"id":"probe","version":1,"method":"protocolHandshake"}"#);
    assert!(output.status.success());
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode response");
    assert_eq!(response["id"], "probe");
    assert_eq!(response["result"]["type"], "handshake");
}

#[test]
fn rpc_keeps_one_process_alive_for_multiple_requests() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-persistent-rpc-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&root).expect("create root");
    #[cfg(unix)]
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
        .expect("secure root permissions");

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"))
        .arg("rpc")
        .arg("--root")
        .arg(&root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start persistent sidecar");
    let mut input = child.stdin.take().expect("sidecar stdin");
    let output = child.stdout.take().expect("sidecar stdout");
    let (response_sender, response_receiver) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(output).lines().take(2) {
            response_sender
                .send(line.expect("read response line"))
                .expect("send response line");
        }
    });

    for id in ["first", "second"] {
        writeln!(
            input,
            "{}",
            serde_json::json!({
                "id": id,
                "version": 1,
                "method": "protocolHandshake"
            })
        )
        .expect("write request frame");
        input.flush().expect("flush request frame");

        let response = response_receiver.recv_timeout(std::time::Duration::from_secs(2));
        let Ok(response) = response else {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            let _ = std::fs::remove_dir_all(&root);
            panic!("sidecar did not reply before stdin closed: {response:?}");
        };
        let response: serde_json::Value = serde_json::from_str(&response).expect("decode response");
        assert_eq!(response["id"], id);
        assert_eq!(response["result"]["type"], "handshake");
        assert!(child.try_wait().expect("inspect sidecar").is_none());
    }

    drop(input);
    assert!(child.wait().expect("wait for sidecar").success());
    reader.join().expect("join response reader");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn rpc_process_exits_when_its_response_pipe_closes() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-closed-output-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&root).expect("create root");
    #[cfg(unix)]
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
        .expect("secure root permissions");
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"))
        .arg("rpc")
        .arg("--root")
        .arg(&root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("start sidecar");
    drop(child.stdout.take());
    let mut stdin = child.stdin.take().expect("sidecar stdin");
    stdin
        .write_all(b"{\"id\":\"probe\",\"version\":1,\"method\":\"protocolHandshake\"}\n")
        .expect("write request");

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    let status = loop {
        if let Some(status) = child.try_wait().expect("poll sidecar") {
            break Some(status);
        }
        if std::time::Instant::now() >= deadline {
            break None;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    };
    if status.is_none() {
        let _ = child.kill();
        let _ = child.wait();
    }
    assert!(
        status.is_some(),
        "closed response pipe must terminate the RPC process"
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn rpc_returns_typed_failure_for_malformed_request() {
    let output = run_stdio_rpc(br#"{"id": "unclosed"#);
    assert!(output.status.success());
    assert_rpc_failure(&output, "invalidRequest");
}

#[test]
fn rpc_returns_typed_failure_for_oversized_request() {
    let output = run_stdio_rpc(&vec![b' '; 1024 * 1024 + 1]);
    assert!(output.status.success());
    assert_rpc_failure(&output, "requestTooLarge");
}

#[test]
fn rpc_accepts_request_at_one_mib_limit() {
    let mut request = br#"{"id":"limit","version":1,"method":"protocolHandshake"}"#.to_vec();
    request.resize(1024 * 1024, b' ');
    let output = run_stdio_rpc(&request);
    assert!(output.status.success());
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode limit response");
    assert_eq!(response["id"], "limit");
    assert_eq!(response["result"]["type"], "handshake");
}

#[cfg(unix)]
#[test]
fn cancelling_rpc_terminates_its_process_group_and_removes_partial_patch() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-cancel-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let repo = create_large_changed_repo(&root);
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
        .expect("secure root permissions");

    let token = "0123456789abcdef";
    write_cancellation_test_authorization(&root, &repo, token);

    let request = serde_json::to_vec(&serde_json::json!({
        "id": "cancel-session",
        "version": 1,
        "method": "sessionOpen",
        "params": {
            "source": {"kind": "unstaged", "repoRoot": repo},
            "capabilityToken": token
        }
    }))
    .expect("encode request");
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"))
        .arg("rpc")
        .arg("--root")
        .arg(&root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .arg("--process-group-ready")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start cancellable sidecar");
    let mut ready = String::new();
    BufReader::new(child.stderr.take().expect("sidecar stderr"))
        .read_line(&mut ready)
        .expect("read process-group readiness");
    assert_eq!(ready, "cmux-diff-sidecar-process-group-ready\n");
    child
        .stdin
        .take()
        .expect("sidecar stdin")
        .write_all(&[request.as_slice(), b"\n"].concat())
        .expect("write request");

    let sidecar_pid =
        rustix::process::Pid::from_raw(child.id().cast_signed()).expect("sidecar pid");
    let git_pid = wait_for_direct_child(child.id());
    assert_eq!(
        rustix::process::getpgid(Some(git_pid)).expect("git process group"),
        sidecar_pid
    );

    rustix::process::kill_process_group(sidecar_pid, rustix::process::Signal::TERM)
        .expect("terminate process group");
    let _ = child.wait().expect("reap sidecar");
    let _ = rustix::process::kill_process_group(sidecar_pid, rustix::process::Signal::KILL);
    assert_process_stopped(git_pid);
    assert!(
        std::fs::read_dir(&root)
            .expect("read sidecar root")
            .flatten()
            .all(|entry| {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                !(name.contains("diff-session-") && name.ends_with(".patch"))
            })
    );
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn rpc_cancel_frame_stops_only_the_matching_request() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-request-cancel-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let repo = create_large_changed_repo(&root);
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
        .expect("secure root permissions");
    let token = "0123456789abcdef";
    write_cancellation_test_authorization(&root, &repo, token);

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"))
        .arg("rpc")
        .arg("--root")
        .arg(&root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .arg("--process-group-ready")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start cancellable sidecar");
    let mut ready = String::new();
    BufReader::new(child.stderr.take().expect("sidecar stderr"))
        .read_line(&mut ready)
        .expect("read process-group readiness");
    assert_eq!(ready, "cmux-diff-sidecar-process-group-ready\n");

    let mut input = child.stdin.take().expect("sidecar stdin");
    writeln!(
        input,
        "{}",
        serde_json::json!({
            "id": "cancel-session",
            "version": 1,
            "method": "sessionOpen",
            "params": {
                "source": {"kind": "unstaged", "repoRoot": repo},
                "capabilityToken": token
            }
        })
    )
    .expect("write cancellable request");
    input.flush().expect("flush cancellable request");
    let git_pid = wait_for_direct_child(child.id());

    writeln!(
        input,
        "{}",
        serde_json::json!({"control": "cancel", "requestId": "cancel-session"})
    )
    .expect("write cancel frame");
    writeln!(
        input,
        "{}",
        serde_json::json!({
            "id": "still-alive",
            "version": 1,
            "method": "protocolHandshake"
        })
    )
    .expect("write follow-up request");
    input.flush().expect("flush control frames");

    let mut response = String::new();
    BufReader::new(child.stdout.take().expect("sidecar stdout"))
        .read_line(&mut response)
        .expect("read follow-up response");
    let response: serde_json::Value = serde_json::from_str(&response).expect("decode response");
    assert_eq!(response["id"], "still-alive");
    assert_eq!(response["result"]["type"], "handshake");
    assert_process_stopped(git_pid);
    assert!(child.try_wait().expect("inspect sidecar").is_none());

    drop(input);
    assert!(child.wait().expect("wait for sidecar").success());
    assert!(
        std::fs::read_dir(&root)
            .expect("read sidecar root")
            .flatten()
            .all(|entry| {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                !(name.contains("diff-session-") && name.ends_with(".patch"))
            })
    );
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
fn assert_process_stopped(pid: rustix::process::Pid) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        if rustix::process::test_kill_process(pid).is_err() {
            return;
        }
        let status = Command::new("/bin/ps")
            .args(["-o", "stat=", "-p", &pid.as_raw_nonzero().to_string()])
            .output()
            .expect("inspect terminated git");
        if String::from_utf8_lossy(&status.stdout)
            .trim()
            .starts_with('Z')
        {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "git descendant remained live"
        );
        std::thread::yield_now();
    }
}

#[cfg(unix)]
fn create_large_changed_repo(root: &Path) -> std::path::PathBuf {
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).expect("create repo");
    run_git(&repo, &["init"]);
    run_git(&repo, &["config", "user.name", "cmux tests"]);
    run_git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    let mut contents = vec![b'a'; 32 * 1024 * 1024];
    std::fs::write(repo.join("large.txt"), &contents).expect("write initial file");
    run_git(&repo, &["add", "large.txt"]);
    run_git(&repo, &["commit", "-m", "initial"]);
    let last_index = contents.len() - 1;
    contents[last_index] = b'b';
    std::fs::write(repo.join("large.txt"), contents).expect("write changed file");
    repo
}

#[cfg(unix)]
fn write_cancellation_test_authorization(root: &Path, repo: &Path, token: &str) {
    std::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&serde_json::json!({"token": token, "files": []}))
            .expect("encode manifest"),
    )
    .expect("write manifest");
    std::fs::write(
        root.join(".branch-session-cancel-test.json"),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "groupID": "cancel-test",
            "allowedRepoRoots": [repo]
        }))
        .expect("encode session"),
    )
    .expect("write session");
}

#[cfg(unix)]
fn wait_for_direct_child(parent_pid: u32) -> rustix::process::Pid {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let output = Command::new("/usr/bin/pgrep")
            .arg("-P")
            .arg(parent_pid.to_string())
            .output()
            .expect("inspect sidecar children");
        if let Some(pid) = String::from_utf8_lossy(&output.stdout)
            .lines()
            .find_map(|line| line.trim().parse::<i32>().ok())
            .and_then(rustix::process::Pid::from_raw)
        {
            return pid;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "git child did not start"
        );
        std::thread::yield_now();
    }
}

fn run_stdio_rpc(input: &[u8]) -> Output {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-rpc-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&root).expect("create root");
    #[cfg(unix)]
    {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
            .expect("secure root permissions");
    }

    let output = run_stdio_rpc_in_root(input, &root);
    assert!(!root.join(".server.json").exists());
    let _ = std::fs::remove_dir_all(root);
    output
}

fn run_stdio_rpc_in_root(input: &[u8], root: &Path) -> Output {
    run_stdio_rpc_in_root_with_home(input, root, None)
}

fn run_stdio_rpc_in_root_with_home(input: &[u8], root: &Path, home: Option<&Path>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"));
    command
        .arg("rpc")
        .arg("--root")
        .arg(root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    if let Some(home) = home {
        command.env("HOME", home);
    }
    let mut child = command.spawn().expect("start stdio sidecar");
    child
        .stdin
        .take()
        .expect("sidecar stdin")
        .write_all(input)
        .expect("write request");
    child.wait_with_output().expect("wait for sidecar")
}

#[test]
fn rpc_resolves_agent_turn_from_provider_and_session_id() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-agent-session-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let home = prepare_agent_rpc_fixture(&root);
    let expected_repo = std::fs::canonicalize(root.join("repo")).expect("canonical repo");
    let token = "0123456789abcdef";
    let request = serde_json::to_vec(&serde_json::json!({
        "id": "agent-session",
        "version": 1,
        "method": "sessionOpen",
        "params": {
            "source": {
                "kind": "agentTurn",
                "provider": "claude",
                "sessionId": "claude-session"
            },
            "capabilityToken": token
        }
    }))
    .expect("encode request");
    let output = run_stdio_rpc_in_root_with_home(&request, &root, Some(&home));
    assert!(output.status.success());
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode response");
    assert_eq!(response["result"]["type"], "sessionOpened", "{response}");
    assert_eq!(
        response["result"]["value"]["source"],
        serde_json::json!({
            "kind": "agentTurn",
            "provider": "claude",
            "sessionId": "claude-session"
        })
    );
    assert_eq!(
        response["result"]["value"]["repoRoot"],
        expected_repo.to_string_lossy().as_ref()
    );
    let patch_id = response["result"]["value"]["patch"]["id"]
        .as_str()
        .expect("patch id");
    let request_path = patch_id.split_once(token).expect("token in patch id").1;
    let patch = std::fs::read_to_string(root.join(request_path.trim_start_matches('/')))
        .expect("read trajectory patch");
    assert!(patch.contains("diff --git a/story.txt b/story.txt"));
    assert!(patch.contains("+after"));

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn rpc_rejects_agent_turn_when_repo_scope_lacks_exact_agent_identity() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-agent-scope-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let home = prepare_agent_rpc_fixture(&root);
    let token = "0123456789abcdef";
    let authorized_repo = root.join("repo");
    std::fs::write(
        root.join(".branch-session-agent-test.json"),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "groupID": "agent-test",
            "allowedRepoRoots": [authorized_repo]
        }))
        .expect("encode restricted authorization"),
    )
    .expect("write repo-only authorization");
    let request = serde_json::to_vec(&serde_json::json!({
        "id": "agent-session-outside-scope",
        "version": 1,
        "method": "sessionOpen",
        "params": {
            "source": {
                "kind": "agentTurn",
                "provider": "claude",
                "sessionId": "claude-session"
            },
            "capabilityToken": token
        }
    }))
    .expect("encode request");

    let output = run_stdio_rpc_in_root_with_home(&request, &root, Some(&home));
    assert!(output.status.success());
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode response");
    assert_eq!(response["error"]["code"], "notAllowed", "{response}");
    assert!(response["result"].is_null(), "{response}");

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn rpc_rejects_unauthorized_unknown_agent_without_resolving_it() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-agent-unknown-auth-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let home = prepare_agent_rpc_fixture(&root);
    let token = "0123456789abcdef";
    std::fs::write(
        root.join(".branch-session-agent-test.json"),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "groupID": "agent-test",
            "allowedRepoRoots": [root.join("repo")]
        }))
        .expect("encode repo-only authorization"),
    )
    .expect("write repo-only authorization");
    let request = serde_json::to_vec(&serde_json::json!({
        "id": "unauthorized-unknown-agent",
        "version": 1,
        "method": "sessionOpen",
        "params": {
            "source": {
                "kind": "agentTurn",
                "provider": "claude",
                "sessionId": "does-not-exist"
            },
            "capabilityToken": token
        }
    }))
    .expect("encode request");

    let output = run_stdio_rpc_in_root_with_home(&request, &root, Some(&home));
    assert!(output.status.success());
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode response");
    assert_eq!(response["error"]["code"], "notAllowed", "{response}");

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn rpc_authorizes_agent_repository_before_parsing_its_transcript() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-agent-preauthorization-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let home = prepare_agent_rpc_fixture(&root);
    let token = "0123456789abcdef";
    let unauthorized_repo = root.join("unauthorized-repo");
    std::fs::create_dir_all(&unauthorized_repo).expect("create unauthorized repo");
    std::fs::write(home.join("claude-session.jsonl"), b"malformed transcript\n")
        .expect("corrupt out-of-scope transcript");
    std::fs::write(
        root.join(".branch-session-agent-test.json"),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "groupID": "agent-test",
            "allowedRepoRoots": [unauthorized_repo]
        }))
        .expect("encode restricted authorization"),
    )
    .expect("restrict authorization");
    let request = serde_json::to_vec(&serde_json::json!({
        "id": "agent-session-preauthorization",
        "version": 1,
        "method": "sessionOpen",
        "params": {
            "source": {
                "kind": "agentTurn",
                "provider": "claude",
                "sessionId": "claude-session"
            },
            "capabilityToken": token
        }
    }))
    .expect("encode request");

    let output = run_stdio_rpc_in_root_with_home(&request, &root, Some(&home));
    assert!(output.status.success());
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode response");
    assert_eq!(response["error"]["code"], "notAllowed", "{response}");

    let _ = std::fs::remove_dir_all(root);
}

fn prepare_agent_rpc_fixture(root: &Path) -> std::path::PathBuf {
    let home = root.join("home");
    let repo = root.join("repo");
    std::fs::create_dir_all(home.join(".cmuxterm")).expect("create hook directory");
    std::fs::create_dir_all(&repo).expect("create repo");
    #[cfg(unix)]
    std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))
        .expect("secure root permissions");
    let transcript = home.join("claude-session.jsonl");
    let lines = [
        serde_json::json!({
            "type": "user",
            "promptId": "prompt-current",
            "message": {"content": "change the story"}
        }),
        serde_json::json!({
            "type": "user",
            "promptId": "prompt-current",
            "toolUseResult": {
                "filePath": repo.join("story.txt"),
                "structuredPatch": [{
                    "oldStart": 1, "oldLines": 1,
                    "newStart": 1, "newLines": 1,
                    "lines": ["-before", "+after"]
                }]
            }
        }),
    ];
    std::fs::write(
        &transcript,
        lines
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n",
    )
    .expect("write transcript");
    std::fs::write(
        home.join(".cmuxterm/claude-hook-sessions.json"),
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "sessions": {"claude-session": {"cwd": repo, "transcriptPath": transcript}}
        }))
        .expect("encode hook store"),
    )
    .expect("write hook store");
    let token = "0123456789abcdef";
    std::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&serde_json::json!({"token": token, "files": []}))
            .expect("encode manifest"),
    )
    .expect("write manifest");
    std::fs::write(
        root.join(".branch-session-agent-test.json"),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "groupID": "agent-test",
            "allowedRepoRoots": [],
            "allowedAgentTurns": [{
                "provider": "claude",
                "sessionId": "claude-session"
            }]
        }))
        .expect("encode authorization"),
    )
    .expect("write authorization");
    home
}

fn assert_rpc_failure(output: &Output, code: &str) {
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode typed failure");
    assert_eq!(response["id"], "__cmux_untrusted_request__");
    assert_eq!(response["version"], 1);
    assert!(response["result"].is_null());
    assert_eq!(response["error"]["code"], code);
}

#[test]
fn rpc_git_sessions_match_git_without_starting_a_server() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-session-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).expect("create repo");
    #[cfg(unix)]
    {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
            .expect("secure root permissions");
    }
    run_git(&repo, &["init"]);
    run_git(&repo, &["config", "user.name", "cmux tests"]);
    run_git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    std::fs::write(repo.join("story.txt"), b"one\n").expect("write initial file");
    run_git(&repo, &["add", "story.txt"]);
    run_git(&repo, &["commit", "-m", "initial"]);
    std::fs::write(repo.join("story.txt"), b"one\ntwo\n").expect("write changed file");

    let token = "0123456789abcdef";
    let shell = root.join("viewer.html");
    std::fs::write(&shell, b"<!doctype html>").expect("write shell");
    std::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "files": [{
                "request_path": "/viewer.html",
                "file_path": shell,
                "mime_type": "text/html"
            }]
        }))
        .expect("encode manifest"),
    )
    .expect("write manifest");
    std::fs::write(
        root.join(".branch-session-session-test.json"),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "groupID": "session-test",
            "allowedRepoRoots": [&repo]
        }))
        .expect("encode session"),
    )
    .expect("write session");

    assert_overlapping_sessions_remain_independently_closable(&root, &repo, token);

    assert_session_matches_git(
        &root,
        &repo,
        token,
        &serde_json::json!({"kind": "unstaged", "repoRoot": repo}),
        &["diff", "--no-ext-diff", "--no-color", "--binary", "--"],
    );
    run_git(&repo, &["add", "story.txt"]);
    assert_session_matches_git(
        &root,
        &repo,
        token,
        &serde_json::json!({"kind": "staged", "repoRoot": repo}),
        &[
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--binary",
            "--cached",
            "--",
        ],
    );
    assert_session_matches_git(
        &root,
        &repo,
        token,
        &serde_json::json!({"kind": "branch", "repoRoot": repo, "baseRef": "HEAD"}),
        &[
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--binary",
            "HEAD",
            "--",
        ],
    );
    assert_session_matches_git(
        &root,
        &repo,
        token,
        &serde_json::json!({"kind": "branch", "repoRoot": repo}),
        &[
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--binary",
            "HEAD",
            "--",
        ],
    );
    assert!(!root.join(".server.json").exists());
    let _ = std::fs::remove_dir_all(root);
}

fn assert_overlapping_sessions_remain_independently_closable(
    root: &Path,
    repo: &Path,
    token: &str,
) {
    let source = serde_json::json!({"kind": "unstaged", "repoRoot": repo});
    let git_arguments = ["diff", "--no-ext-diff", "--no-color", "--binary", "--"];
    let (abandoned_session, abandoned_path) =
        open_session_matches_git(root, repo, token, &source, &git_arguments);
    let (replacement_session, replacement_path) =
        open_session_matches_git(root, repo, token, &source, &git_arguments);
    assert!(root.join(abandoned_path.trim_start_matches('/')).exists());
    let manifest: serde_json::Value = serde_json::from_slice(
        &std::fs::read(root.join(format!(".manifest-{token}.json"))).expect("read manifest"),
    )
    .expect("decode manifest");
    let session_paths: Vec<&str> = manifest["files"]
        .as_array()
        .expect("manifest files")
        .iter()
        .filter_map(|entry| entry["request_path"].as_str())
        .filter(|path| path.starts_with("/diff-session-"))
        .collect();
    assert_eq!(
        session_paths,
        [abandoned_path.as_str(), replacement_path.as_str()]
    );
    let attacker_token = "fedcba9876543210";
    std::fs::write(
        root.join(format!(".manifest-{attacker_token}.json")),
        serde_json::to_vec(&serde_json::json!({
            "token": attacker_token,
            "files": [{
                "request_path": "/viewer.html",
                "file_path": root.join("viewer.html"),
                "mime_type": "text/html"
            }]
        }))
        .expect("encode attacker manifest"),
    )
    .expect("write attacker manifest");
    let attacker_close = serde_json::to_vec(&serde_json::json!({
        "id": "attacker-close",
        "version": 1,
        "method": "sessionClose",
        "params": {"sessionId": abandoned_session, "capabilityToken": attacker_token}
    }))
    .expect("encode attacker close");
    assert!(
        run_stdio_rpc_in_root(&attacker_close, root)
            .status
            .success()
    );
    assert!(root.join(abandoned_path.trim_start_matches('/')).exists());
    close_session(root, token, &replacement_session, &replacement_path);
    assert!(root.join(abandoned_path.trim_start_matches('/')).exists());
    close_session(root, token, &abandoned_session, &abandoned_path);
}

fn assert_session_matches_git(
    root: &Path,
    repo: &Path,
    token: &str,
    source: &serde_json::Value,
    git_arguments: &[&str],
) {
    let (session_id, request_path) =
        open_session_matches_git(root, repo, token, source, git_arguments);
    close_session(root, token, &session_id, &request_path);
}

fn open_session_matches_git(
    root: &Path,
    repo: &Path,
    token: &str,
    source: &serde_json::Value,
    git_arguments: &[&str],
) -> (String, String) {
    let requested_session_id = uuid::Uuid::new_v4().to_string();
    let request = serde_json::to_vec(&serde_json::json!({
        "id": "open-session",
        "version": 1,
        "method": "sessionOpen",
        "params": {
            "source": source,
            "capabilityToken": token,
            "sessionId": requested_session_id,
        }
    }))
    .expect("encode request");
    let output = run_stdio_rpc_in_root(&request, root);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode response");
    assert_eq!(response["result"]["type"], "sessionOpened", "{response}");
    if source["kind"] == "branch" && source.get("baseRef").is_none() {
        assert_eq!(response["result"]["value"]["source"]["baseRef"], "HEAD");
    }
    let session_id = response["result"]["value"]["sessionId"]
        .as_str()
        .expect("session id")
        .to_owned();
    assert_eq!(session_id, requested_session_id);
    let id = response["result"]["value"]["patch"]["id"]
        .as_str()
        .expect("patch id");
    assert!(id.starts_with(&format!("cmux-diff-viewer://{token}/diff-session-")));
    let request_path = id.split_once(token).expect("token in id").1.to_owned();
    let generated = std::fs::read(root.join(request_path.trim_start_matches('/')))
        .expect("read generated patch");
    let expected = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(repo)
        .args(git_arguments)
        .output()
        .expect("run expected git");
    assert!(expected.status.success());
    assert_eq!(generated, expected.stdout);

    (session_id, request_path)
}

fn close_session(root: &Path, token: &str, session_id: &str, request_path: &str) {
    let close = serde_json::to_vec(&serde_json::json!({
        "id": "close-session",
        "version": 1,
        "method": "sessionClose",
        "params": {"sessionId": session_id, "capabilityToken": token}
    }))
    .expect("encode close request");
    let close_output = run_stdio_rpc_in_root(&close, root);
    assert!(close_output.status.success());
    let close_response: serde_json::Value =
        serde_json::from_slice(&close_output.stdout).expect("decode close response");
    assert_eq!(close_response["result"]["type"], "sessionClosed");
    assert!(!root.join(request_path.trim_start_matches('/')).exists());
}

fn run_git(repo: &Path, arguments: &[&str]) {
    let output = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn serves_only_manifest_allowlisted_files() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&root).expect("create root");
    #[cfg(unix)]
    {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
            .expect("secure root permissions");
    }
    let token = "0123456789abcdef";
    let group = "short-group";
    let patch_path = root.join("sample.patch");
    let generated_path = root.join("generated.html");
    std::fs::write(&patch_path, b"diff --git a/a b/a\n").expect("write patch");
    std::fs::write(&generated_path, b"<!doctype html>").expect("write generated page");
    let manifest = serde_json::json!({
        "token": token,
        "files": [
            {
                "request_path": "/sample.patch",
                "file_path": patch_path,
                "mime_type": "text/x-diff"
            },
            {
                "request_path": "/generated.html",
                "file_path": generated_path,
                "mime_type": "text/html"
            }
        ]
    });
    std::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&manifest).expect("encode manifest"),
    )
    .expect("write manifest");
    let branch_session = serde_json::json!({
        "token": token,
        "groupID": group,
        "allowedRepoRoots": [&root]
    });
    std::fs::write(
        root.join(format!(".branch-session-{group}.json")),
        serde_json::to_vec(&branch_session).expect("encode branch session"),
    )
    .expect("write branch session");

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"))
        .arg("serve")
        .arg("--root")
        .arg(&root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start sidecar");
    let stdout = child.stdout.take().expect("sidecar stdout");
    let mut reader = BufReader::new(stdout);
    let mut port = String::new();
    reader.read_line(&mut port).expect("read port");
    let port = port.trim().parse::<u16>().expect("valid port");
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let client = reqwest::Client::new();
        verify_resources(&client, port, token, &root).await;
        verify_rpc(&client, port, token, group, &root).await;
        verify_websocket(port).await;
    });
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(root);
}

async fn verify_resources(client: &reqwest::Client, port: u16, token: &str, root: &Path) {
    let health = client
        .get(format!(
            "http://127.0.0.1:{port}/__cmux_diff_viewer_healthz"
        ))
        .send()
        .await
        .expect("health request");
    assert_eq!(health.status(), reqwest::StatusCode::OK);
    assert_eq!(
        health.text().await.expect("health body"),
        cmux_diff_sidecar::health_response()
    );
    let patch = client
        .get(format!("http://127.0.0.1:{port}/{token}/sample.patch"))
        .send()
        .await
        .expect("patch request");
    assert_eq!(patch.status(), reqwest::StatusCode::OK);
    assert_eq!(
        patch.bytes().await.expect("patch body").as_ref(),
        b"diff --git a/a b/a\n"
    );
    let denied = client
        .get(format!("http://127.0.0.1:{port}/{token}/not-allowed.patch"))
        .send()
        .await
        .expect("denied request");
    assert_eq!(denied.status(), reqwest::StatusCode::NOT_FOUND);

    let second_path = root.join("second.patch");
    tokio::fs::write(&second_path, b"diff --git a/b b/b\n")
        .await
        .expect("write second patch");
    let refreshed_manifest = serde_json::json!({
        "token": token,
        "files": [
            {
                "request_path": "/sample.patch",
                "file_path": root.join("sample.patch"),
                "mime_type": "text/x-diff"
            },
            {
                "request_path": "/second.patch",
                "file_path": second_path,
                "mime_type": "text/x-diff"
            },
            {
                "request_path": "/generated.html",
                "file_path": root.join("generated.html"),
                "mime_type": "text/html"
            }
        ]
    });
    tokio::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&refreshed_manifest).expect("encode refreshed manifest"),
    )
    .await
    .expect("refresh manifest");
    let refreshed = client
        .get(format!("http://127.0.0.1:{port}/{token}/second.patch"))
        .send()
        .await
        .expect("refreshed manifest request");
    assert_eq!(refreshed.status(), reqwest::StatusCode::OK);
}

async fn verify_rpc(client: &reqwest::Client, port: u16, token: &str, group: &str, root: &Path) {
    let endpoint = format!("http://127.0.0.1:{port}/__cmux_diff_rpc");
    let origin = format!("http://127.0.0.1:{port}");
    let branch_request = serde_json::json!({
        "id": "branches",
        "version": 1,
        "method": "branchList",
        "params": {
            "repoRoot": root,
            "capabilityToken": token,
            "selectedBase": "main"
        }
    });
    let branches = client
        .post(&endpoint)
        .header(reqwest::header::ORIGIN, &origin)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(branch_request.to_string())
        .send()
        .await
        .expect("branch list request");
    let branch_bytes = branches.bytes().await.expect("branch list response");
    let branches: serde_json::Value =
        serde_json::from_slice(&branch_bytes).expect("branch list JSON");
    assert_eq!(branches["result"]["type"], "branches");
    assert_eq!(
        branches["result"]["value"]["groups"][0]["rows"][0]["ref"],
        "HEAD"
    );

    let unauthorized_request = serde_json::json!({
        "id": "unauthorized",
        "version": 1,
        "method": "branchList",
        "params": {
            "repoRoot": root,
            "capabilityToken": "fedcba9876543210",
            "selectedBase": "main"
        }
    });
    let unauthorized: serde_json::Value = client
        .post(&endpoint)
        .header(reqwest::header::ORIGIN, &origin)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(unauthorized_request.to_string())
        .send()
        .await
        .expect("unauthorized request")
        .bytes()
        .await
        .map(|bytes| serde_json::from_slice(&bytes).expect("unauthorized response JSON"))
        .expect("unauthorized response bytes");
    assert_eq!(unauthorized["error"]["code"], "branchListFailed");

    let untrusted = client
        .post(&endpoint)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(branch_request.to_string())
        .send()
        .await
        .expect("untrusted request");
    assert_eq!(untrusted.status(), reqwest::StatusCode::NOT_FOUND);

    verify_branch_change(client, &endpoint, &origin, token, group, root).await;
}

async fn verify_branch_change(
    client: &reqwest::Client,
    endpoint: &str,
    origin: &str,
    token: &str,
    group: &str,
    root: &Path,
) {
    let branch_change = serde_json::json!({
        "id": "branch-change",
        "version": 1,
        "method": "branchChange",
        "params": {
            "groupId": group,
            "repoRoot": root,
            "baseRef": "main",
            "capabilityToken": token
        }
    });
    let changed: serde_json::Value = client
        .post(endpoint)
        .header(reqwest::header::ORIGIN, origin)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(branch_change.to_string())
        .send()
        .await
        .expect("branch change request")
        .bytes()
        .await
        .map(|bytes| serde_json::from_slice(&bytes).expect("branch change response JSON"))
        .expect("branch change response bytes");
    assert_eq!(changed["result"]["type"], "navigation");

    let malformed_change = serde_json::json!({
        "id": "malformed-branch-change",
        "version": 1,
        "method": "branchChange",
        "params": {
            "groupId": group,
            "repoRoot": root,
            "baseRef": "malformed",
            "capabilityToken": token
        }
    });
    let malformed: serde_json::Value = client
        .post(endpoint)
        .header(reqwest::header::ORIGIN, origin)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(malformed_change.to_string())
        .send()
        .await
        .expect("malformed branch change request")
        .bytes()
        .await
        .map(|bytes| serde_json::from_slice(&bytes).expect("malformed response JSON"))
        .expect("malformed response bytes");
    assert_eq!(malformed["error"]["code"], "branchChangeFailed");
}

async fn verify_websocket(port: u16) {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    let mut request = format!("ws://127.0.0.1:{port}/__cmux_diff_ws")
        .into_client_request()
        .expect("WebSocket request");
    request.headers_mut().insert(
        "origin",
        format!("http://127.0.0.1:{port}")
            .parse()
            .expect("origin header"),
    );
    let (mut socket, _) = tokio_tungstenite::connect_async(request)
        .await
        .expect("WebSocket connect");
    socket
        .send(tokio_tungstenite::tungstenite::Message::Text(
            r#"{"id":"hello","version":1,"method":"protocolHandshake"}"#.into(),
        ))
        .await
        .expect("WebSocket handshake request");
    let response = socket
        .next()
        .await
        .expect("WebSocket response")
        .expect("valid WebSocket response")
        .into_text()
        .expect("text response");
    let response: serde_json::Value = serde_json::from_str(&response).expect("JSON response");
    assert_eq!(response["id"], "hello");
    assert_eq!(response["result"]["value"]["protocolVersion"], 1);

    socket
        .send(tokio_tungstenite::tungstenite::Message::Text(
            "not-json".into(),
        ))
        .await
        .expect("invalid WebSocket request");
    let close = socket
        .next()
        .await
        .expect("WebSocket close")
        .expect("valid WebSocket close");
    assert!(close.is_close());
}
