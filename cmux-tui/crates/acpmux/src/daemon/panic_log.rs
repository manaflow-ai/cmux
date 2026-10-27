//! The daemon's panic and hang logs (cmux-panic-log), beside each other in
//! `$ACPMUX_HOME`. Its agent hosts (`__agent-host`), which outlive daemon
//! restarts, write to the same two files with `"role": "agent-host"`. The
//! cmux-next app sends their new lines to Sentry (`OwnerPanicForwarder`,
//! `RustPanicSource.acpmux` and `.acpmuxHangs`), scrubbed of paths and only
//! when the person allows reports.

use crate::config::home;
use std::path::{Path, PathBuf};

/// The daemon's panic log, `$ACPMUX_HOME/panics.jsonl`: a panic in a request task ends only
/// that task and used to leave just two lines in `daemon.log` (the 2026-10-14 sort panic).
pub fn panic_log_path() -> PathBuf {
    panic_log_in(&home())
}

fn panic_log_in(home: &Path) -> PathBuf {
    home.join("panics.jsonl")
}

/// The daemon's hang log, `$ACPMUX_HOME/hangs.jsonl`: a scope written with cmux-panic-log
/// `hang::write` lands here, and its `"event": "hang"` lines go to Sentry. Lab builds append
/// their slow polls to the same file (`poll_watch_lab.rs`); those are not sent.
pub fn hang_log_path() -> PathBuf {
    hang_log_in(&home())
}

fn hang_log_in(home: &Path) -> PathBuf {
    home.join("hangs.jsonl")
}

/// Debug builds only: `thread` makes a worker thread panic once the hook is installed, `hang`
/// writes one hang record (tests/panic_log.rs, tests/agent_host_panic_log.rs). Both lines
/// carry `"test": true`. An agent host gets it from its daemon (`agent_host::link`).
#[cfg(debug_assertions)]
pub(crate) const TEST_PANIC_ENV: &str = "ACPMUX_TEST_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "acpmux-panic-test";

/// The fields every line of both logs carries; `os` and `arch` become the Sentry event's
/// platform tags, as the owner's do (cmux-tui `owner_panic.rs`), and `role` tells an agent
/// host from the daemon.
fn log_fields(role: &str) -> cmux_panic_log::Fields {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "acpmux".into());
    fields.insert("role".into(), role.into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.insert("arch".into(), std::env::consts::ARCH.into());
    fields
}

/// Install the daemon's panic hook and hang log; the previous panic hook (stderr, so
/// `daemon.log`) still runs.
pub(super) fn install() {
    install_in(&home(), "daemon");
}

/// Install an agent host's panic hook and hang log in its daemon's home. The host does not
/// read `ACPMUX_HOME` (its environment is cleared): `SpawnSpec::state_home` names it. Call
/// before the host starts its harness.
pub(crate) fn install_agent_host(home: &Path) {
    install_in(home, "agent-host");
}

fn install_in(home: &Path, role: &str) {
    let path = panic_log_in(home);
    cmux_panic_log::install_with_opener(
        move || {
            crate::config::private_state_append(&path)
                .map_err(|error| std::io::Error::other(error.to_string()))
        },
        log_fields(role),
        is_test_panic_thread,
    );
    // One hang log per process; a second install keeps the first.
    let _ = cmux_panic_log::hang::install(cmux_panic_log::hang::file_sink(
        hang_log_in(home),
        log_fields(role),
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
