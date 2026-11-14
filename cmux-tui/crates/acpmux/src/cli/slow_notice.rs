//! One line on stderr when a one-shot read waits long for the daemon (`acpmux ls`, `status`,
//! `info`, `last`): what it waits for and where the daemon's log is. The read keeps waiting;
//! stdout, `--json` output and the exit status do not change. aws-m4pro-5, 2026-11-10: an
//! `acpmux ls` waited 2 h 41 min on a daemon that had stopped answering, and said nothing.

use std::future::Future;
use std::time::Duration;

/// How long a one-shot read waits before it says so.
const AFTER: Duration = Duration::from_secs(10);

/// `read`'s result. When it takes more than [`AFTER`], one line on stderr says that the daemon
/// has not answered `what` yet, and where its log is.
pub(crate) async fn noted<T>(what: &str, read: impl Future<Output = T>) -> T {
    noted_to(what, after(), read, |line| eprintln!("{line}")).await
}

/// [`AFTER`]; in a debug build `ACPMUX_TEST_SLOW_NOTICE_MS` when set (`tests/slow_notice.rs`).
fn after() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) =
        std::env::var("ACPMUX_TEST_SLOW_NOTICE_MS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        return Duration::from_millis(ms);
    }
    AFTER
}

async fn noted_to<T>(
    what: &str,
    after: Duration,
    read: impl Future<Output = T>,
    say: impl FnOnce(String),
) -> T {
    let mut read = std::pin::pin!(read);
    tokio::select! {
        out = &mut read => out,
        () = tokio::time::sleep(after) => {
            say(line(what, after));
            read.await
        }
    }
}

fn line(what: &str, after: Duration) -> String {
    format!(
        "acpmux: the daemon has not answered {what} in {:.0?}; still waiting. Its log is {}",
        after,
        crate::config::home().join("daemon.log").display()
    )
}

#[cfg(test)]
mod tests;
