//! The daemon's panic log and its supervisor (`crate::supervised`), set up first in
//! `daemon::run`.

use crate::config::home;

/// The daemon's panic log, `$ACPMUX_HOME/panics.jsonl` (cmux-panic-log): a panic in a request task
/// ends only that task and used to leave just two lines in `daemon.log` (the 2026-10-14 sort
/// panic). The cmux-next app sends new lines to Sentry.
pub fn panic_log_path() -> std::path::PathBuf {
    home().join("panics.jsonl")
}

/// Debug builds only: `thread` makes a worker thread panic once the hook
/// is installed (tests/panic_log.rs). Its line carries `"test": true`.
#[cfg(debug_assertions)]
const TEST_PANIC_ENV: &str = "ACPMUX_TEST_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "acpmux-panic-test";

/// Install the panic log hook; the previous hook (stderr, so `daemon.log`) still runs.
/// Returns the daemon's supervisor: a fatal supervised failure adds its line to the same
/// log and ends the daemon (`crate::supervised`).
pub(super) fn install_panic_log() -> crate::supervised::Supervisor {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "acpmux".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    let path = panic_log_path();
    let supervisor = crate::supervised::process_supervisor(Some(path.clone()), fields.clone());
    cmux_panic_log::install_with_opener(
        move || {
            crate::config::private_state_append(&path)
                .map_err(|error| std::io::Error::other(error.to_string()))
        },
        fields,
        is_test_panic_thread,
    );
    #[cfg(debug_assertions)]
    #[allow(
        clippy::panic,
        reason = "debug-build test trigger for the acpmux panic log; release builds have no seam"
    )]
    if std::env::var(TEST_PANIC_ENV).as_deref() == Ok("thread") {
        // supervise-allow: debug-only trigger whose unsupervised panic line is what tests/panic_log.rs checks.
        let _ = cmux_threads::spawn(TEST_PANIC_THREAD, cmux_threads::ThreadQos::Utility, || {
            // crash-allow: debug-only test trigger for the acpmux panic log
            panic!("acpmux test panic")
        });
    }
    supervisor
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
