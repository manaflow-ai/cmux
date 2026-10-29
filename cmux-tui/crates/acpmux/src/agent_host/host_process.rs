//! The `__agent-host` process's own setup: signal dispositions, its panic
//! log, and detaching from the bootstrap pipes.
//!
//! The host runs detached with stdout and stdin on /dev/null and stderr
//! closed, so a panic used to leave nothing: a panic on its runtime thread
//! ended the host and the harness lost its keeper without a trace. The
//! controller names the daemon's `agent-host-panics.jsonl` in
//! [`PANIC_LOG_ENV`] (the host gets no `ACPMUX_HOME`), and the hook appends
//! one JSON line per panic (cmux-panic-log). The cmux-next app sends new
//! lines to Sentry (`RustPanicSource.agentHost`).

use cmux_blocking::{BlockingKind, scoped_blocking_call};
use std::os::fd::AsRawFd;

/// The panic log's path, set by the controller ([`super::link`]). A path,
/// no authority; the harness never sees it (its environment is the spec's).
pub const PANIC_LOG_ENV: &str = "ACPMUX_AGENT_HOST_PANIC_LOG";

/// Debug builds only: `thread` makes a worker thread panic once the hook is
/// installed (tests/agent_host_panic_log.rs). The controller passes it on.
#[cfg(debug_assertions)]
pub(super) const TEST_PANIC_ENV: &str = "ACPMUX_TEST_AGENT_HOST_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "agent-host-panic-test";

/// The first thing the host does: ignore SIGPIPE and SIGHUP, then install
/// its panic log.
pub(super) fn start() {
    // The host must not die when a controller or the bootstrap parent goes
    // away mid-write.
    // SAFETY: setting a signal disposition has no memory-safety preconditions.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
    }
    if let Some(path) = std::env::var_os(PANIC_LOG_ENV).filter(|path| !path.is_empty()) {
        install_panic_log(std::path::PathBuf::from(path));
    }
}

fn install_panic_log(path: std::path::PathBuf) {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "acpmux-agent-host".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
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
        reason = "debug-build test trigger for the agent host panic log; release builds have no seam"
    )]
    if std::env::var(TEST_PANIC_ENV).as_deref() == Ok("thread") {
        // supervise-allow: debug-only trigger whose unsupervised panic line is what tests/agent_host_panic_log.rs checks.
        let _ = cmux_threads::spawn(TEST_PANIC_THREAD, cmux_threads::ThreadQos::Utility, || {
            // crash-allow: debug-only test trigger for the agent host panic log
            panic!("acpmux agent host test panic")
        });
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

/// Point stdin and stdout at /dev/null so the bootstrap pipes close.
pub(super) fn detach_stdio() {
    #[allow(clippy::disallowed_methods, reason = "inside scoped_blocking_call")]
    let opened = scoped_blocking_call("fs::open_with", BlockingKind::Fs, || {
        std::fs::OpenOptions::new().read(true).write(true).open("/dev/null")
    });
    if let Ok(null) = opened {
        // SAFETY: dup2 onto the standard descriptors of this process.
        unsafe {
            libc::dup2(null.as_raw_fd(), 0);
            libc::dup2(null.as_raw_fd(), 1);
        }
    }
}
