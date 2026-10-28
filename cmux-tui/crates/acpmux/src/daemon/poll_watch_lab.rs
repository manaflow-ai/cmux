//! Lab builds only (`cmux-tui/lab/stability.env`): the daemon's slow task
//! polls (cmux-blocking `poll_watch`, installed on the runtime in
//! `cli/entry.rs`, which writes the totals before the daemon exits) and
//! blocking stalls go to `$ACPMUX_HOME/hangs.jsonl`, next to `panics.jsonl`.

use crate::config::home;

fn hang_log_path() -> std::path::PathBuf {
    home().join("hangs.jsonl")
}

/// Debug lab builds only: `1` spawns one task whose poll sleeps
/// (tests/poll_watch_lab.rs).
#[cfg(debug_assertions)]
const TEST_SLOW_POLL_ENV: &str = "ACPMUX_TEST_SLOW_POLL";

pub(super) fn install() {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "acpmux".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    let sink = cmux_blocking::JsonlSink::new(hang_log_path(), fields);
    if let Err(error) = cmux_blocking::install_sink(Box::new(sink)) {
        tracing::warn!("{error}; slow polls go to the first sink");
    }
    #[cfg(debug_assertions)]
    if std::env::var(TEST_SLOW_POLL_ENV).as_deref() == Ok("1") {
        // The slow poll under test: this sleep holds a worker for 20 ms.
        // blocking-allow: the blocked worker is what tests/poll_watch_lab.rs measures; debug builds with TEST_SLOW_POLL_ENV=1 only
        // wakeup-allow: debug the slow poll a test asks for, debug builds only and only with TEST_SLOW_POLL_ENV=1; it runs once
        drop(tokio::spawn(async { std::thread::sleep(std::time::Duration::from_millis(20)) }));
    }
}
