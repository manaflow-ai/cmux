//! The daemon's panic log hook and the debug-build test panic triggers (tests/panic_log.rs).

use super::*;

/// Debug builds only: `thread` makes a worker thread panic once the hook
/// is installed (tests/panic_log.rs). Its line carries `"test": true`.
#[cfg(debug_assertions)]
const TEST_PANIC_ENV: &str = "ACPMUX_TEST_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "acpmux-panic-test";

/// Install the panic log hook; the previous hook (stderr, so `daemon.log`) still runs.
pub(super) fn install_panic_log() {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "acpmux".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    let path = panic_log_path();
    cmux_panic_log::install_with_opener(
        move || {
            crate::config::private_state_append(&path)
                .map_err(|error| std::io::Error::other(error.to_string()))
        },
        fields,
        is_test_panic_thread,
    );
    #[cfg(debug_assertions)]
    if std::env::var(TEST_PANIC_ENV).as_deref() == Ok("thread") {
        let _ = std::thread::Builder::new()
            .name(TEST_PANIC_THREAD.into())
            .spawn(|| test_panic("acpmux test panic"));
    }
}

/// Debug builds and unit tests: the one panic the test triggers raise (below, and the agent host's
/// translator seam, `agent_host/host.rs` `test_translator_panic`).
#[cfg(any(test, debug_assertions))]
#[allow(
    clippy::panic,
    reason = "debug-build and test-build trigger for the acpmux panic log; release builds have no seam"
)]
pub(crate) fn test_panic(message: &str) -> ! {
    // crash-allow: debug-only test trigger for the acpmux panic log
    panic!("{message}");
}

/// Debug builds only: `ACPMUX_TEST_PANIC=<task>` makes that task of the daemon panic
/// (tests/panic_log.rs).
#[cfg(debug_assertions)]
pub(super) fn test_panic_in(task: &str) {
    if std::env::var(TEST_PANIC_ENV).as_deref() == Ok(task) {
        test_panic(&format!("acpmux test panic in {task}"));
    }
}

/// The debug test trigger's thread; its line carries `"test": true`.
fn is_test_panic_thread(thread: &str) -> bool {
    #[cfg(debug_assertions)]
    {
        thread == TEST_PANIC_THREAD
    }
    #[cfg(not(debug_assertions))]
    {
        let _ = thread;
        false
    }
}
