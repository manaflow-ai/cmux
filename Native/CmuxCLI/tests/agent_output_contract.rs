use std::{process::{Command, Output, Stdio}, thread, time::{Duration, Instant}};

use serde_json::Value;

fn invoke(args: &[&str]) -> Output {
    let mut process = Command::new(env!("CARGO_BIN_EXE_cmux"));
    for (name, _) in std::env::vars() {
        if name.starts_with("CMUX_") || name.starts_with("CMUXD_") {
            process.env_remove(name);
        }
    }
    process.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = process.spawn().expect("launch Rust CLI");
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if child.try_wait().expect("poll CLI").is_some() {
            return child.wait_with_output().expect("collect CLI output");
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let output = child.wait_with_output().expect("collect timed out CLI");
            panic!("no-socket invocation hung: {args:?}; stderr={}", String::from_utf8_lossy(&output.stderr));
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn unknown_command_returns_structured_machine_error() {
    let output = invoke(&["--output", "json", "this-command-does-not-exist"]);
    assert!(!output.status.success());
    let value: Value = serde_json::from_slice(&output.stdout).expect("JSON errors must be on stdout");
    assert_eq!(value["ok"], false);
    assert!(value["error"]["code"].as_str().is_some_and(|s| !s.is_empty()));
    assert!(value["error"]["message"].as_str().is_some_and(|s| !s.is_empty()));
    assert!(value["error"]["retryable"].is_boolean());
    assert!(value["error"]["next"].is_array());
    assert!(!String::from_utf8_lossy(&output.stdout).contains('\u{1b}'));
}

#[test]
fn invalid_global_option_values_fail_before_socket_access() {
    for args in [
        vec!["--socket"],
        vec!["--password"],
        vec!["--window"],
        vec!["--output", "not-a-format", "ping"],
        vec!["--id-format", "not-an-id-format", "ping"],
    ] {
        let output = invoke(&args);
        assert_eq!(output.status.code(), Some(2), "invocation={args:?}, stderr={}", String::from_utf8_lossy(&output.stderr));
        let stderr = String::from_utf8_lossy(&output.stderr).to_lowercase();
        assert!(!stderr.contains("failed to connect"), "parser attempted socket access: {args:?}");
    }
}

#[test]
fn version_aliases_emit_identical_clean_stdout() {
    let expected = invoke(&["--version"]);
    assert!(expected.status.success());
    assert!(!expected.stdout.is_empty());
    assert!(expected.stderr.is_empty());
    for args in [["-v"], ["version"]] {
        let actual = invoke(&args);
        assert!(actual.status.success());
        assert_eq!(actual.stdout, expected.stdout);
        assert!(actual.stderr.is_empty());
    }
}
