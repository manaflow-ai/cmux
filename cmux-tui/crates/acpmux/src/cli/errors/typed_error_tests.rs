use super::*;
use crate::rpc::RpcError;
use serde_json::json;

fn daemon(e: RpcError) -> anyhow::Error {
    anyhow::Error::from(crate::client::DaemonError(e))
}

/// A typed error prints its sentence and, on the next line, what to do; the JSON envelope
/// carries the kind and the recovery beside the daemon's data.
#[test]
fn a_typed_error_prints_the_sentence_and_the_action() {
    let e = daemon(RpcError::internal("No space left on device (os error 28)").with_data(json!({
            "errorKind": "disk.full",
            "recovery": "The disk is full. Free space on the disk that holds /h: 0.1 GB free of 252 GB.",
            "details": {"path": "/h", "freeBytes": 100_000_000u64, "totalBytes": 252_000_000_000u64},
        })));
    let app = classify(&e);
    assert_eq!(app.detail, "disk.full");
    assert_eq!(
        app.text(),
        "acpmux: runtime: No space left on device (os error 28)\n  The disk is full. Free space on the disk that holds /h: 0.1 GB free of 252 GB."
    );
    let env = app.envelope();
    assert_eq!(env["error"]["errorKind"], "disk.full");
    assert!(env["error"]["recovery"].as_str().unwrap().starts_with("The disk is full."));
    assert_eq!(env["error"]["data"]["details"]["path"], "/h");
}

/// A refusal with a reason keeps that reason as its detail and still prints the action.
#[test]
fn a_peer_refusal_keeps_its_reason_and_prints_the_action() {
    let mut e = RpcError::internal(
        "peer_unreachable: b (reconnecting, last seen 40s ago: connect timed out)",
    )
    .with_data(
        json!({"reason": "peer_unreachable", "retryable": true, "peer": "b", "lastSeen": 1_000u64}),
    );
    crate::recovery::annotate(&mut e, None);
    let app = classify(&daemon(e));
    assert_eq!(app.detail, "peer_unreachable");
    assert!(app.retryable);
    let text = app.text();
    assert!(text.contains("\n  Check that b is on and online in `tailscale status`; `acpmux machine doctor b` checks the link"), "{text}");
    assert_eq!(app.envelope()["error"]["errorKind"], "peer.unreachable");
    assert_eq!(
        app.envelope()["error"]["data"]["details"]["lastSeenAt"],
        "1970-01-01T00:00:01.000Z"
    );
}

/// A refused `session stop --if-idle` exits 6 with the daemon's reason as its detail, and
/// the envelope keeps the revision the caller reads again.
#[test]
fn a_refused_conditional_stop_exits_6_with_its_reason() {
    use crate::hub::stop_if_idle::{BUSY, NOT_IDLE_CODE, REVISION_MOVED};
    for (reason, busy_with) in [(BUSY, json!("turn")), (REVISION_MOVED, json!(null))] {
        let e = RpcError::new(NOT_IDLE_CODE, "session is not idle: not stopped").with_data(
                json!({"reason": reason, "busyWith": busy_with, "revision": 41u64, "sessionId": "s", "retryable": true}),
            );
        let app = classify(&daemon(e));
        assert_eq!(app.code, Code::NotIdle);
        assert_eq!(app.exit_status(), 6);
        assert_eq!(app.detail, reason);
        assert!(app.retryable);
        let env = app.envelope();
        assert_eq!(env["error"]["code"], "not_idle");
        assert_eq!(env["error"]["data"]["revision"], 41);
    }
}

/// The daemon refusing work while it shuts down says it is restarting.
#[test]
fn a_shutting_down_daemon_says_it_is_restarting() {
    let mut e = RpcError::internal(crate::hub::SHUTTING_DOWN);
    crate::recovery::annotate(&mut e, None);
    let app = classify(&daemon(e));
    assert_eq!(app.detail, "daemon.restarting");
    assert!(app.text().contains("\n  The daemon is restarting."), "{}", app.text());
}

/// A kind adds detail and never changes the exit code: a timeout still exits 3 and an
/// unknown session 4 when the daemon typed the error.
#[test]
fn a_typed_error_keeps_its_exit_code() {
    let typed = |message: &str| {
        daemon(RpcError::internal(message).with_data(json!({
            "errorKind": "agent.exited",
            "recovery": "The agent stopped in the middle of the turn.",
            "details": {},
        })))
    };
    let app = classify(&typed("request timed out"));
    assert_eq!(app.code as i32, 3, "{:?}", app.envelope());
    assert_eq!(app.detail, "agent.exited");
    assert_eq!(app.recovery(), Some("The agent stopped in the middle of the turn."));
    let app = classify(&typed("unknown session s-1"));
    assert_eq!(app.code as i32, 4, "{:?}", app.envelope());
    assert_eq!(app.envelope()["error"]["errorKind"], "agent.exited");
}

/// The names the daemon said a key nearly matched reach the message and the envelope;
/// the refusal stays no_session (exit 4), so the send relay still takes it.
#[test]
fn a_no_session_refusal_names_the_close_matches() {
    let refused = daemon(crate::session_name::not_found("mac-ci", &["a/mac-ci-3".into()]));
    let app = AppError::no_session_from("mac-ci", &refused);
    assert_eq!((app.code, app.detail.as_str()), (Code::NoSession, "no_session"));
    assert!(app.message.contains("close matches: a/mac-ci-3"), "{}", app.message);
    assert_eq!(app.envelope()["error"]["data"]["candidates"], json!(["a/mac-ci-3"]));
    let classified = classify(&refused);
    assert_eq!(classified.code, Code::NoSession);
    assert_eq!(classified.envelope()["error"]["data"]["candidates"], json!(["a/mac-ci-3"]));
    let plain =
        AppError::no_session_from("x", &daemon(RpcError::not_found("no session matches \"x\"")));
    assert_eq!(plain.message, AppError::no_session("x").message);
    assert!(crate::cli::send_relay::no_such_session(&app.into()));
}

/// A send's refusal names the machine and the closest names there (`hub/no_session.rs`).
#[test]
fn a_send_refusal_names_the_host_and_the_closest_names() {
    let refused = daemon(RpcError::invalid_params("no session: h/proc-title").with_data(json!({
            "reason": "no_session", "host": "h", "name": "proc-title",
            "candidates": ["feed-lane", "lane"]})));
    let app = AppError::no_session_from("h/proc-title", &refused);
    assert_eq!((app.code, app.detail.as_str()), (Code::NoSession, "no_session"));
    assert_eq!(app.message, "no session proc-title on h; did you mean: feed-lane, lane");
    // `--json` keeps the refusal's whole shape.
    assert_eq!(
        app.envelope()["error"]["data"],
        json!({"reason": "no_session", "session": "h/proc-title", "host": "h",
                   "name": "proc-title", "candidates": ["feed-lane", "lane"]})
    );
    let none = daemon(RpcError::invalid_params("no session: h/x").with_data(json!({
            "reason": "no_session", "host": "h", "name": "x", "candidates": []})));
    assert_eq!(
        AppError::no_session_from("h/x", &none).message,
        "no session x on h; run `acpmux ls` for its sessions"
    );
}

/// An error with nothing to add prints as before.
#[test]
fn an_untyped_error_prints_as_before() {
    let mut e = RpcError::internal("something odd");
    crate::recovery::annotate(&mut e, None);
    assert!(e.data.is_none());
    assert_eq!(classify(&daemon(e)).text(), "acpmux: runtime: something odd");
}
