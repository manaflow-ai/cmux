//! `_acpmux/debug_panic`: the local unix socket gets a reply and the crash,
//! every WebSocket origin and every bad param get a refusal and no crash, and
//! each kind ends its thread or the process the way it says.

use std::cell::Cell;

use serde_json::json;

use super::*;
use crate::rpc::method;

/// The child process's kind: set only by [`crash_in_child`].
const CHILD_ENV: &str = "ACPMUX_TEST_DEBUG_CRASH_KIND";

/// The answer to `params` from `origin` and the kinds handed to the crash.
fn call(origin: Origin, params: Value) -> (Result<Value, RpcError>, Vec<CrashKind>) {
    let fired = Cell::new(Vec::new());
    let answer = handle(origin, &params, |kind| {
        fired.set([fired.take(), vec![kind]].concat());
        Ok(())
    });
    (answer, fired.take())
}

#[test]
fn debug_crash_inject_fires_each_kind_on_the_local_socket() {
    for kind in CrashKind::ALL {
        let (answer, fired) = call(Origin::Local, json!({"kind": kind.wire_name()}));
        let answer = answer.unwrap();
        assert_eq!(answer, json!({"kind": kind.wire_name(), "pid": std::process::id()}));
        assert_eq!(fired, [kind]);
    }
}

#[test]
fn debug_crash_inject_is_not_found_off_the_local_socket() {
    for origin in [Origin::Web, Origin::LocalApp, Origin::Peer] {
        let (answer, fired) = call(origin, json!({"kind": "abort"}));
        let error = answer.unwrap_err();
        assert_eq!(error.code, RpcError::method_not_found(METHOD).code, "{origin:?}");
        assert!(fired.is_empty(), "{origin:?} crashed the daemon");
    }
}

#[test]
fn debug_crash_inject_refuses_bad_params_without_crashing() {
    for params in [
        Value::Null,
        json!({}),
        json!({"kind": "hang"}),
        json!({"kind": 1}),
        json!({"kind": "panic", "path": "/tmp/x"}),
    ] {
        let (answer, fired) = call(Origin::Local, params.clone());
        let error = answer.unwrap_err();
        assert_eq!(error.code, RpcError::invalid_params("").code, "{params}");
        assert!(fired.is_empty(), "{params}");
    }
}

#[test]
fn debug_crash_inject_reports_a_crash_thread_that_did_not_start() {
    let answer = handle(Origin::Local, &json!({"kind": "panic"}), |_| {
        Err(std::io::Error::other("no threads"))
    });
    assert!(answer.unwrap_err().message.contains("no threads"));
}

/// Release and typed clients never see it: the method is not in the
/// protocol registry or the `rpc::method` table.
#[test]
fn debug_crash_inject_is_not_a_protocol_method() {
    assert!(crate::protocol::registry().iter().all(|decl| decl.name != METHOD));
    assert!(!include_str!("rpc.rs").contains(METHOD));
    assert_ne!(method::MUX_TRACE, METHOD);
}

#[test]
fn debug_crash_inject_panic_ends_only_its_named_thread() {
    let payload = fire(CrashKind::Panic).unwrap().join().expect_err("the thread panics");
    let message = payload.downcast_ref::<&str>().copied().unwrap_or_default();
    assert_eq!(message, "debug_panic: injected acpmux panic");
}

/// Run in a child process by [`debug_crash_inject_abort_and_segv_end_the_process`]:
/// crash as [`CHILD_ENV`] says. Does nothing in an ordinary test run.
#[test]
fn debug_crash_inject_child() {
    let Ok(name) = std::env::var(CHILD_ENV) else { return };
    let kind = CrashKind::parse(&name).expect("a crash kind");
    let ended = fire(kind).unwrap().join();
    panic!("{name} returned: {ended:?}");
}

/// The exit status of this test binary running [`debug_crash_inject_child`]
/// with `kind`.
#[cfg(unix)]
fn crash_in_child(kind: CrashKind) -> std::process::ExitStatus {
    let module = module_path!().split_once("::").map_or(module_path!(), |(_, path)| path);
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([&format!("{module}::debug_crash_inject_child"), "--exact", "--test-threads=1"])
        .env(CHILD_ENV, kind.wire_name())
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("debug_crash_inject_child"), "the child ran no test: {stdout}");
    output.status
}

#[cfg(unix)]
#[test]
fn debug_crash_inject_abort_and_segv_end_the_process() {
    use std::os::unix::process::ExitStatusExt;
    assert_eq!(crash_in_child(CrashKind::Abort).signal(), Some(libc::SIGABRT));
    assert_eq!(crash_in_child(CrashKind::Segv).signal(), Some(libc::SIGSEGV));
}
