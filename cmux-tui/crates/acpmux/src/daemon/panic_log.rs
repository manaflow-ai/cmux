//! The daemon's panic and hang logs (cmux-panic-log), beside each other in
//! `$ACPMUX_HOME`. The cmux-next app sends their new lines to Sentry
//! (`OwnerPanicForwarder`, `RustPanicSource.acpmux` and `.acpmuxHangs`),
//! scrubbed of paths and only when the person allows reports.

use crate::config::home;

/// The daemon's panic log, `$ACPMUX_HOME/panics.jsonl`: a panic in a request task ends only
/// that task and used to leave just two lines in `daemon.log` (the 2026-10-14 sort panic).
pub fn panic_log_path() -> std::path::PathBuf {
    home().join("panics.jsonl")
}

/// The daemon's hang log, `$ACPMUX_HOME/hangs.jsonl`: a scope written with cmux-panic-log
/// `hang::write` lands here, and its `"event": "hang"` lines go to Sentry. Lab builds append
/// their slow polls to the same file (`poll_watch_lab.rs`); those are not sent.
pub fn hang_log_path() -> std::path::PathBuf {
    home().join("hangs.jsonl")
}

/// Debug builds only: `thread` makes a worker thread panic once the hook is installed, `hang`
/// writes one hang record (tests/panic_log.rs). Both lines carry `"test": true`.
#[cfg(debug_assertions)]
const TEST_PANIC_ENV: &str = "ACPMUX_TEST_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "acpmux-panic-test";

/// The fields every line of both logs carries; `os` and `arch` become the Sentry event's
/// platform tags, as the owner's do (cmux-tui `owner_panic.rs`).
fn log_fields() -> cmux_panic_log::Fields {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "acpmux".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.insert("arch".into(), std::env::consts::ARCH.into());
    fields
}

/// Install the panic hook and the hang log; the previous panic hook (stderr, so `daemon.log`)
/// still runs.
pub(super) fn install() {
    let path = panic_log_path();
    cmux_panic_log::install_with_opener(
        move || {
            crate::config::private_state_append(&path)
                .map_err(|error| std::io::Error::other(error.to_string()))
        },
        log_fields(),
        is_test_panic_thread,
    );
    // One hang log per process; a second install keeps the first.
    let _ = cmux_panic_log::hang::install(cmux_panic_log::hang::file_sink(
        hang_log_path(),
        log_fields(),
    ));
    #[cfg(debug_assertions)]
    test_trigger();
}

#[cfg(debug_assertions)]
#[allow(
    clippy::panic,
    reason = "debug-build test trigger for the acpmux panic log; release builds have no seam"
)]
fn test_trigger() {
    match std::env::var(TEST_PANIC_ENV).as_deref() {
        Ok("thread") => {
            let _ = std::thread::Builder::new()
                .name(TEST_PANIC_THREAD.into())
                // crash-allow: debug-only test trigger for the acpmux panic log
                .spawn(|| panic!("acpmux test panic"));
        }
        Ok("hang") => cmux_panic_log::hang::write(serde_json::json!({
            "event": "hang",
            "scope": "acpmux-test",
            "method": "test",
            "hang_ms": 2000,
            "busy_ms": 2000,
            "stack": [],
            "test": true,
        })),
        _ => {}
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
