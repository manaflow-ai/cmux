//! Security and transport parity checks for the native Rust CLI.
//!
//! These tests deliberately exercise the wire boundary rather than command
//! implementations.  The Swift CLI's socket policy is fail-closed: a command
//! must not become a second command through a newline, a path must identify a
//! socket owned by this user, and socket failures must stay machine-readable
//! without echoing credentials.

use cmux_cli::Context;
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::tempdir;

fn context(socket: impl AsRef<Path>) -> Context {
    Context {
        socket: Some(socket.as_ref().to_string_lossy().into_owned()),
        timeout: Duration::from_millis(250),
        ..Context::default()
    }
}

/// Start a tiny legacy socket server.  The production socket may send an
/// authentication line before the requested command, so acknowledge that line
/// and record both lines before sending the test response.
fn server_with_response(
    socket: &Path,
    response: &'static str,
    lines: Arc<Mutex<Vec<String>>>,
) -> thread::JoinHandle<()> {
    let listener = UnixListener::bind(socket).expect("bind test socket");
    thread::spawn(move || {
        let (stream, _) = listener.accept().expect("accept test socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone test socket"));
        let mut writer = stream;
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).expect("read test socket") == 0 {
                return;
            }
            let line = line.trim_end_matches(['\r', '\n']).to_owned();
            lines.lock().expect("lock test lines").push(line.clone());
            if line.starts_with("auth ") {
                writer.write_all(b"OK\n").expect("write auth response");
                writer.flush().expect("flush auth response");
                continue;
            }
            writer
                .write_all(response.as_bytes())
                .expect("write test response");
            writer.flush().expect("flush test response");
            return;
        }
    })
}

#[test]
fn raw_rejects_newline_in_command_before_opening_socket() {
    let ctx = context("/definitely/missing/cmux.sock");
    let error = ctx
        .raw("workspace.list\nclose-all")
        .expect_err("newline must be rejected");
    assert_eq!(error.code, "invalid_command");
}

#[test]
fn raw_rejects_newline_in_socket_password_before_opening_socket() {
    let mut ctx = context("/definitely/missing/cmux.sock");
    ctx.password = Some("correct\nforged-command".into());
    let error = ctx
        .raw("ping")
        .expect_err("newline password must be rejected");
    assert_eq!(error.code, "invalid_password");
}

#[test]
fn raw_rejects_regular_file_as_socket() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("not-a-socket");
    fs::write(&path, b"this is intentionally not a unix socket").expect("write fixture");
    let error = context(&path)
        .raw("ping")
        .expect_err("regular files are not sockets");
    assert_eq!(error.code, "socket_type_conflict");
}

#[test]
fn raw_timeout_is_bounded_when_peer_never_responds() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("silent.sock");
    let listener = UnixListener::bind(&path).expect("bind test socket");
    let peer = thread::spawn(move || {
        let (_stream, _) = listener.accept().expect("accept test socket");
        thread::sleep(Duration::from_millis(180));
    });
    let mut ctx = context(&path);
    ctx.timeout = Duration::from_millis(40);
    let started = Instant::now();
    let error = ctx.raw("ping").expect_err("silent peer must time out");
    assert_eq!(error.code, "timeout");
    assert!(
        started.elapsed() < Duration::from_millis(150),
        "timeout escaped its deadline"
    );
    peer.join().expect("join silent peer");
}

#[test]
fn rpc_invalid_response_fails_closed_as_protocol_error() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("invalid-response.sock");
    let lines = Arc::new(Mutex::new(Vec::new()));
    let server = server_with_response(&path, "this is not JSON\n", lines);
    let error = context(&path)
        .rpc("workspace.list", Value::Object(Default::default()))
        .expect_err("invalid response must not be accepted");
    assert_eq!(error.code, "protocol");
    server.join().expect("join response server");
}

#[test]
fn rpc_error_envelope_is_structured_and_does_not_echo_socket_password() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("error-response.sock");
    let lines = Arc::new(Mutex::new(Vec::new()));
    let server = server_with_response(
        &path,
        r#"{"ok":false,"error":{"code":"auth_required","message":"Sign in required","data":{"retryable":true}}}
"#,
        lines.clone(),
    );
    let mut ctx = context(&path);
    ctx.password = Some("super-secret-do-not-print".into());
    let error = ctx
        .rpc("workspace.list", Value::Object(Default::default()))
        .expect_err("server error must propagate");
    assert_eq!(error.code, "auth_required");
    assert!(error.retryable);
    let envelope = error.envelope().to_string();
    assert!(envelope.contains("auth_required"));
    assert!(!envelope.contains("super-secret-do-not-print"));
    let request_lines = lines.lock().expect("lock test lines");
    assert!(
        request_lines
            .iter()
            .any(|line| line == "workspace.list" || line.contains("workspace.list"))
    );
    // The password must cross the authenticated socket once, but it must not
    // be copied into the requested command or the user-visible error envelope.
    assert!(
        request_lines.iter().any(|line| {
            line.starts_with("auth ") && line.contains("super-secret-do-not-print")
        })
    );
    assert!(
        request_lines
            .iter()
            .filter(|line| !line.starts_with("auth "))
            .all(|line| !line.contains("super-secret-do-not-print"))
    );
    drop(request_lines);
    server.join().expect("join response server");
}

#[test]
fn relay_without_local_credentials_fails_closed() {
    // CI and local development should not inherit relay credentials.  If an
    // operator intentionally exports them, this assertion is not meaningful,
    // so leave the existing relay session untouched.
    if std::env::var_os("CMUX_RELAY_ID").is_some() || std::env::var_os("CMUX_RELAY_TOKEN").is_some()
    {
        return;
    }
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind relay fixture");
    let port = listener.local_addr().expect("relay address").port();
    let peer = thread::spawn(move || {
        let (_stream, _) = listener.accept().expect("accept relay fixture");
    });
    let error = context(format!("127.0.0.1:{port}"))
        .raw("ping")
        .expect_err("relay without credentials must be rejected");
    assert_eq!(error.code, "relay_auth");
    peer.join().expect("join relay fixture");
}
