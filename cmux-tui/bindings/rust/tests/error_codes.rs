//! `Error::error_code`: a raw command's machine-readable `error_code` (and
//! `error_details`) survive on `Error::Command` for typed calls and
//! `request_raw`, and a protocol/2 error's `code` reads the same way, so a
//! client never parses a message prefix.

mod common;

use cmux::Error;
use cmux::raw::{DeleteBookmarkRequest, Optional};
use common::{command, mock, reply, request, respond};
use serde_json::json;

#[test]
fn typed_raw_call_keeps_error_code_and_details() {
    let mock = mock(|stream, reader| {
        let delete = command(reader, "delete-bookmark");
        reply(
            stream,
            &delete,
            json!({"ok": false, "error": "unknown bookmark bm_1", "error_code": "not_found",
                   "error_details": {"bookmark": "bm_1"}}),
        );
        let again = command(reader, "delete-bookmark");
        reply(stream, &again, json!({"ok": false, "error": "bad request: oops"}));
    });
    let mut raw = mock.raw();
    let request = DeleteBookmarkRequest {
        bookmark: "bm_1".into(),
        origin: Optional::Missing,
        mutation_id: Optional::Missing,
    };
    let error = raw.delete_bookmark(request.clone()).unwrap_err();
    assert_eq!(error.error_code(), Some("not_found"));
    match &error {
        Error::Command { command, message, error_code, error_details, .. } => {
            assert_eq!(
                (command.as_str(), message.as_str(), error_code.as_deref()),
                ("delete-bookmark", "unknown bookmark bm_1", Some("not_found"))
            );
            assert_eq!(error_details.as_deref(), Some(&json!({"bookmark": "bm_1"})));
        }
        other => panic!("expected Error::Command, got {other:?}"),
    }
    // A failure without a code has none; the message is unchanged.
    let error = raw.delete_bookmark(request).unwrap_err();
    assert_eq!(error.error_code(), None);
    assert_eq!(error.to_string(), "delete-bookmark: bad request: oops");
    raw.close();
    mock.finish();
}

#[test]
fn request_raw_reads_raw_and_protocol_two_codes_alike() {
    let mock = mock(|stream, reader| {
        let create = command(reader, "new-frontend-browser-tab");
        reply(
            stream,
            &create,
            json!({"ok": false, "error_code": "frontend_browser_key_closed",
                   "error": "frontend_browser_key_closed: the keyed tab was closed"}),
        );
        let close = request(reader, "workspace.close");
        respond(
            stream,
            &close,
            json!({"ok": false, "error": {"code": "home.not_closable", "message": "home",
                   "details": {}, "retryable": false}}),
        );
    });
    let mut raw = mock.raw();
    let legacy = json!({"cmd": "new-frontend-browser-tab", "idempotency_key": "k"});
    let error = raw.request_raw(legacy.as_object().unwrap().clone()).unwrap_err();
    assert!(matches!(error, Error::Command { .. }), "{error:?}");
    assert_eq!(error.error_code(), Some("frontend_browser_key_closed"));
    let envelope = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "r1",
                          "operation": "workspace.close", "idempotency_key": "k",
                          "params": {"machine": "current", "session": "current"}});
    let error = raw.request_raw(envelope.as_object().unwrap().clone()).unwrap_err();
    assert!(matches!(error, Error::Protocol { .. }), "{error:?}");
    assert_eq!(error.error_code(), Some("home.not_closable"));
    raw.close();
    mock.finish();
}

#[test]
fn local_failures_have_no_error_code() {
    assert_eq!(Error::InvalidArgument("x".into()).error_code(), None);
    assert_eq!(Error::Timeout("x".into()).error_code(), None);
}
