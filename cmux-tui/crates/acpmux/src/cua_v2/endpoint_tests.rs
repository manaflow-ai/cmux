//! `endpoint.json` parsing and the pipe-name rule on every platform; on
//! Windows, the owner-only refusal, liveness and the bridge over a real named
//! pipe (a stand-in worker in this test process).

use super::*;

#[test]
fn a_cmux_remote_host_endpoint_parses_with_its_owner() {
    let text = r#"{"socket":"\\\\.\\pipe\\cmux-remote-rh-0123456789ab-cu","secret":"ab12","pid":4242,"start":133500000000000000}"#;
    let endpoint = parse_endpoint(text).unwrap();
    assert_eq!(endpoint.socket, PathBuf::from(r"\\.\pipe\cmux-remote-rh-0123456789ab-cu"));
    assert_eq!(endpoint.secret, "ab12");
    assert_eq!(endpoint.owner, Some(Owner { pid: 4242, start: Some((133_500_000_000_000_000, 0)) }));
}

/// The secret goes only to the process endpoint.json names (pid, then start
/// time when recorded), never just any server of this user.
#[test]
fn the_server_must_be_the_recorded_owner() {
    let owner = Owner { pid: 4242, start: Some((77, 0)) };
    assert_eq!(server_is_owner(Some(4242), Some((77, 0)), Some(owner)), Ok(()));
    assert!(server_is_owner(Some(4243), Some((77, 0)), Some(owner)).unwrap_err().contains("not the recorded owner"));
    assert!(server_is_owner(Some(4242), Some((78, 0)), Some(owner)).unwrap_err().contains("later process"));
    assert!(server_is_owner(Some(4242), None, Some(owner)).is_err(), "an unreadable start fails closed");
    assert!(server_is_owner(None, None, Some(owner)).is_err(), "an unknown server pid fails closed");
    let no_start = Owner { pid: 4242, start: None };
    assert_eq!(server_is_owner(Some(4242), None, Some(no_start)), Ok(()));
    assert_eq!(server_is_owner(None, None, None), Ok(()), "an older endpoint without an owner");
}

#[cfg(unix)]
#[test]
fn this_process_start_time_is_readable_where_the_host_records_one() {
    let me = i32::try_from(std::process::id()).unwrap();
    if cfg!(any(target_os = "macos", target_os = "linux")) {
        assert!(liveness::start_time(me).is_some());
        assert_eq!(liveness::start_time(me), liveness::start_time(me));
    }
}

#[test]
fn the_app_owner_fields_win_over_a_host_start() {
    let value = json!({"pid": 77, "start_sec": 5, "start_usec": 6, "start": 9});
    assert_eq!(Owner::from_json(&value), Some(Owner { pid: 77, start: Some((5, 6)) }));
    let unknown = json!({"pid": 77, "start": 0});
    assert_eq!(Owner::from_json(&unknown), Some(Owner { pid: 77, start: None }));
    assert_eq!(Owner::from_json(&json!({"pid": 1})), None);
    assert_eq!(Owner::from_json(&json!({})), None);
}

#[test]
fn an_endpoint_without_a_socket_or_secret_is_refused() {
    for text in [
        r#"{"secret":"s"}"#,
        r#"{"socket":"/s"}"#,
        r#"{"socket":"","secret":"s"}"#,
        r#"{"socket":"/s","secret":""}"#,
        r#"{"socket":7,"secret":"s"}"#,
        "not json",
    ] {
        assert!(parse_endpoint(text).is_err(), "{text}");
    }
}

#[test]
fn the_secret_never_prints() {
    let endpoint = parse_endpoint(r#"{"socket":"/s","secret":"topsecret"}"#).unwrap();
    assert!(!format!("{endpoint:?}").contains("topsecret"));
}

#[test]
fn only_a_local_pipe_name_is_accepted() {
    assert!(is_local_pipe_name(r"\\.\pipe\cmux-remote-rh-1-cu"));
    assert!(is_local_pipe_name(r"\\.\PIPE\cmux-remote-rh-1-cu"));
    for name in [
        r"\\.\pipe\",
        r"\\server\pipe\cmux-remote-rh-1-cu",
        r"\\?\pipe\x",
        r"C:\Users\me\w-cu.sock",
        "/tmp/w-cu.sock",
        "",
        "\\\\.\\pipe\\a\0b",
    ] {
        assert!(!is_local_pipe_name(name), "{name:?}");
    }
}

#[cfg(windows)]
mod windows {
    use super::*;
    use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};

    struct Dir(PathBuf);

    impl Dir {
        fn new(tag: &str) -> Dir {
            let path = std::env::temp_dir().join(format!(
                "acpmux-cua-{tag}-{}-{}",
                std::process::id(),
                uuid::Uuid::now_v7()
            ));
            crate::owner_only::create_dir_all(&path).unwrap();
            Dir(path)
        }

        /// `endpoint.json` created owner-only, as the host's folder makes it.
        fn write(&self, text: &str) -> PathBuf {
            use std::io::Write;
            let path = self.0.join(ENDPOINT_FILE);
            let mut file = crate::owner_only::create_new(&path).unwrap();
            file.write_all(text.as_bytes()).unwrap();
            path
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn icacls(path: &Path, grant: &str) {
        let output = std::process::Command::new("icacls")
            .arg(path)
            .args(["/grant", grant])
            .output()
            .unwrap();
        assert!(output.status.success(), "icacls: {}", String::from_utf8_lossy(&output.stderr));
    }

    fn pipe_name(tag: &str) -> PathBuf {
        PathBuf::from(format!(
            r"\\.\pipe\acpmux-test-{tag}-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ))
    }

    fn endpoint_text(pipe: &Path, secret: &str) -> String {
        json!({"socket": pipe.to_string_lossy(), "secret": secret}).to_string()
    }

    #[test]
    fn a_private_endpoint_is_read() {
        let dir = Dir::new("private");
        dir.write(&endpoint_text(Path::new(r"\\.\pipe\x-cu"), "ab"));
        let endpoint = read_endpoint(&dir.0).unwrap();
        assert_eq!(endpoint.socket, PathBuf::from(r"\\.\pipe\x-cu"));
        assert_eq!(endpoint.secret, "ab");
    }

    #[test]
    fn an_endpoint_another_identity_can_read_is_refused() {
        let dir = Dir::new("wide");
        let path = dir.write(&endpoint_text(Path::new(r"\\.\pipe\x-cu"), "ab"));
        icacls(&path, "*S-1-1-0:(R)");
        let error = read_endpoint(&dir.0).unwrap_err().to_string();
        assert!(error.contains("not private"), "{error}");
        // Refused, never narrowed: the person sees why.
        assert!(!crate::owner_only::only_owner_reads(&path).unwrap());
    }

    #[test]
    fn an_endpoint_naming_a_file_or_remote_pipe_is_refused() {
        for socket in [r"C:\Users\me\w-cu.sock", r"\\host\pipe\x-cu"] {
            let dir = Dir::new("notpipe");
            dir.write(&endpoint_text(Path::new(socket), "ab"));
            let error = read_endpoint(&dir.0).unwrap_err().to_string();
            assert!(error.contains("not a local named pipe"), "{error}");
        }
    }

    #[test]
    fn a_missing_endpoint_says_the_helper_is_not_running() {
        let dir = Dir::new("missing");
        let error = read_endpoint(&dir.0).unwrap_err().to_string();
        assert!(error.contains("not running"), "{error}");
    }

    #[tokio::test]
    async fn liveness_follows_the_owner_and_the_pipe() {
        let name = pipe_name("live");
        let _server = ServerOptions::new().first_pipe_instance(true).create(&name).unwrap();
        let me = i32::try_from(std::process::id()).unwrap();
        let liveness::Process::Alive(Some(start)) = liveness::process_start(me) else {
            panic!("this process has no start time")
        };
        assert_eq!(liveness::check(Some(Owner { pid: me, start: Some(start) }), &name), Ok(()));
        assert_eq!(liveness::check(None, &name), Ok(()));
        assert_eq!(
            liveness::check(Some(Owner { pid: me, start: Some((start.0 + 1, 0)) }), &name),
            Err(liveness::Stale::OwnerReplaced(me))
        );
        let gone = pipe_name("gone");
        let dead = liveness::check(Some(Owner { pid: me, start: Some(start) }), &gone).unwrap_err();
        assert!(matches!(dead, liveness::Stale::SocketDead { owner_alive: true, .. }), "{dead:?}");
        assert!(!dead.removable());
        let exited = exited_pid();
        assert_eq!(
            liveness::check(Some(Owner { pid: exited, start: None }), &name),
            Err(liveness::Stale::OwnerGone(exited))
        );
    }

    /// A pid whose process has exited (and whose handle is closed).
    fn exited_pid() -> i32 {
        let mut child = std::process::Command::new("cmd").args(["/C", "exit 0"]).spawn().unwrap();
        let pid = i32::try_from(child.id()).unwrap();
        child.wait().unwrap();
        drop(child);
        pid
    }

    /// A stand-in worker on one pipe instance: reads the secret line, admits
    /// it, then answers `session/hello` and `tools/list` with one tool.
    async fn worker(mut server: NamedPipeServer, secret: &'static str) -> String {
        server.connect().await.unwrap();
        let mut stream = BufReader::new(server);
        let mut first = String::new();
        stream.read_line(&mut first).await.unwrap();
        let presented: Value = serde_json::from_str(&first).unwrap();
        let ok = presented["secret"] == secret;
        stream
            .get_mut()
            .write_all(format!("{}\n", json!({"ok": ok, "protocol": 1})).as_bytes())
            .await
            .unwrap();
        loop {
            let mut line = String::new();
            if stream.read_line(&mut line).await.unwrap_or(0) == 0 {
                break;
            }
            let request: Value = serde_json::from_str(&line).unwrap();
            let reply = match request["method"].as_str() {
                Some("tools/list") => json!({"id": request["id"], "ok": true,
                    "result": [{"name": "screenshot", "inputSchema": {"type": "object"}}]}),
                _ => json!({"id": request["id"], "ok": true, "result": {}}),
            };
            stream.get_mut().write_all(format!("{reply}\n").as_bytes()).await.unwrap();
        }
        first
    }

    async fn run_tools_list(endpoint: Endpoint) -> Value {
        let input = concat!(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            "\n",
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            "\n"
        );
        let mut output = Vec::new();
        serve(BufReader::new(input.as_bytes()), &mut output, || {
            let endpoint = endpoint.clone();
            async move {
                let mut helper = Helper::connect(&endpoint).await?;
                helper.hello(&Labels::new("claude", "w", "cmux")).await?;
                Ok(helper)
            }
        })
        .await
        .unwrap();
        let text = String::from_utf8(output).unwrap();
        let last = text.lines().last().unwrap();
        serde_json::from_str(last).unwrap()
    }

    #[tokio::test]
    async fn the_bridge_lists_tools_through_the_worker_pipe() {
        let name = pipe_name("bridge");
        let server = ServerOptions::new().first_pipe_instance(true).create(&name).unwrap();
        let worker = tokio::spawn(worker(server, "s3cret"));
        let endpoint = Endpoint { socket: name, secret: "s3cret".into(), owner: None };
        let reply = run_tools_list(endpoint).await;
        assert_eq!(reply["id"], 2);
        assert_eq!(reply["result"]["tools"][0]["name"], "screenshot", "{reply}");
        let first = worker.await.unwrap();
        assert!(first.contains("s3cret"));
    }

    #[tokio::test]
    async fn a_refused_secret_is_a_tool_error_not_a_crash() {
        let name = pipe_name("refused");
        let server = ServerOptions::new().first_pipe_instance(true).create(&name).unwrap();
        let worker = tokio::spawn(worker(server, "right"));
        let endpoint = Endpoint { socket: name, secret: "wrong".into(), owner: None };
        let reply = run_tools_list(endpoint).await;
        let message = reply["error"]["message"].as_str().unwrap_or_default();
        assert!(message.contains("refused"), "{reply}");
        worker.await.unwrap();
    }

    #[tokio::test]
    async fn a_busy_pipe_is_waited_for_until_its_next_instance() {
        let name = pipe_name("busy");
        let first = ServerOptions::new().first_pipe_instance(true).create(&name).unwrap();
        let holder = pipe::connect(&name).await.unwrap();
        first.connect().await.unwrap();
        // Every instance is taken: the next connect waits for a new one.
        let waiting = tokio::spawn({
            let name = name.clone();
            async move { pipe::connect(&name).await }
        });
        let second = ServerOptions::new().create(&name).unwrap();
        second.connect().await.unwrap();
        let client = waiting.await.unwrap().unwrap();
        pipe::require_same_user_server(&client, &name, None).unwrap();
        // This test process serves the pipe: pinned to itself it passes, to another pid it fails.
        let me = i32::try_from(std::process::id()).unwrap();
        let start = match liveness::process_start(me) {
            liveness::Process::Alive(start) => start,
            liveness::Process::Gone => None,
        };
        pipe::require_same_user_server(&client, &name, Some(Owner { pid: me, start })).unwrap();
        let other = Owner { pid: me.wrapping_add(1), start: None };
        let error = pipe::require_same_user_server(&client, &name, Some(other)).unwrap_err();
        assert!(error.to_string().contains("not the recorded owner"), "{error:#}");
        drop((holder, client, first, second));
    }

    #[tokio::test]
    async fn no_server_is_an_error_at_once() {
        let error = pipe::connect(&pipe_name("none")).await.unwrap_err();
        assert!(error.to_string().contains("cannot connect"), "{error:#}");
    }
}

/// The pointer a Windows or Linux cmux-tui daemon writes names the endpoint
/// folder for an acpmux it did not start, privately.
#[test]
fn the_daemons_pointer_names_the_endpoint_folder() {
    let home = tempfile::tempdir().unwrap();
    let endpoint = tempfile::tempdir().unwrap();
    write_pointer(home.path(), endpoint.path()).unwrap();
    let pointer = home.path().join(ENDPOINT_POINTER_FILE);
    assert_eq!(pointer_dir(&pointer).as_deref(), Some(endpoint.path()));
    // Written again (a daemon restart), it is replaced, not appended.
    let other = tempfile::tempdir().unwrap();
    write_pointer(home.path(), other.path()).unwrap();
    assert_eq!(pointer_dir(&pointer).as_deref(), Some(other.path()));
}

#[test]
fn a_missing_relative_or_vanished_pointer_names_nothing() {
    let home = tempfile::tempdir().unwrap();
    let pointer = home.path().join(ENDPOINT_POINTER_FILE);
    assert_eq!(pointer_dir(&pointer), None, "no file");
    write_pointer(home.path(), Path::new("relative/cu")).unwrap();
    assert_eq!(pointer_dir(&pointer), None, "a relative path");
    let gone = home.path().join("gone");
    write_pointer(home.path(), &gone).unwrap();
    assert_eq!(pointer_dir(&pointer), None, "a folder that does not exist");
}

/// Another user (or anything) able to read or change the pointer could
/// steer the bridge, and its secret, elsewhere: such a file is ignored.
#[cfg(unix)]
#[test]
fn a_pointer_others_can_read_is_ignored() {
    use std::os::unix::fs::PermissionsExt;
    let home = tempfile::tempdir().unwrap();
    let endpoint = tempfile::tempdir().unwrap();
    write_pointer(home.path(), endpoint.path()).unwrap();
    let pointer = home.path().join(ENDPOINT_POINTER_FILE);
    assert_eq!(std::fs::metadata(&pointer).unwrap().permissions().mode() & 0o077, 0, "written owner-only");
    std::fs::set_permissions(&pointer, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(pointer_dir(&pointer), None);
}
