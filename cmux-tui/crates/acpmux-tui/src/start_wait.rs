//! A terminal chat's start (`session/new` from a draft or the new-session form) is bounded and
//! says why it failed, as the GUI chat's is. Leo, 2026-11-24: "in terminals and guis alike perhaps
//! terminal simply needs to also have the fixes and enhancements".
//!
//! - A start that never answers fails at [`START_DEADLINE`] with how to try again, and the
//!   message stays in the composer (cmux#55839, #55783: the GUI's `START_DEADLINE_MS`). Before,
//!   the draft read "starting …" forever and Enter did nothing (`creating` never cleared).
//! - A failed start names the harness and keeps the daemon's cause (cmux#45060, #45302).
//! - A start that failed only because the daemon connection went down starts again by itself on
//!   the next connection, no error (cmux#50654).

use anyhow::Result;
use std::future::Future;
use std::time::Duration;

/// How long a `session/new` may take before the start fails with how to try again.
pub(crate) const START_DEADLINE: Duration = Duration::from_secs(120);

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum StartEnd<T> {
    Started(T),
    /// The daemon answered with an error: the copy to show.
    Failed(String),
    /// The daemon connection went down under it: start again on the next one.
    Lost,
    /// No answer within [`START_DEADLINE`]: the copy to show.
    TimedOut(String),
}

/// `start`, bounded by `deadline`. `lost` tells whether the connection it went over is down.
pub(crate) async fn bounded<T>(
    harness: &str,
    deadline: Duration,
    start: impl Future<Output = Result<T>>,
    lost: impl FnOnce() -> bool,
) -> StartEnd<T> {
    match tokio::time::timeout(deadline, start).await {
        Ok(Ok(v)) => StartEnd::Started(v),
        Ok(Err(_)) if lost() => StartEnd::Lost,
        Ok(Err(e)) => StartEnd::Failed(failure_copy(harness, &format!("{e:#}"))),
        Err(_) => StartEnd::TimedOut(format!(
            "{} did not start within {} s. Enter tries again; your message is still in the composer.",
            name(harness),
            deadline.as_secs()
        )),
    }
}

fn name(harness: &str) -> &str {
    if harness.is_empty() { "The agent" } else { harness }
}

/// "Couldn't start codex: <the daemon's cause>".
pub(crate) fn failure_copy(harness: &str, cause: &str) -> String {
    let cause = cause.trim();
    if cause.is_empty() {
        format!("Couldn't start {}.", name(harness))
    } else {
        format!("Couldn't start {}: {cause}", name(harness))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Before: a `session/new` that never answered left the draft "starting…" for good.
    /// After: it fails at the deadline and says Enter tries again.
    #[tokio::test(start_paused = true)]
    async fn a_start_that_never_answers_fails_at_its_deadline() {
        let started = tokio::time::Instant::now();
        let end =
            bounded("codex", START_DEADLINE, std::future::pending::<Result<()>>(), || false).await;
        assert_eq!(started.elapsed(), START_DEADLINE);
        let StartEnd::TimedOut(copy) = end else { panic!("{end:?}") };
        assert_eq!(
            copy,
            "codex did not start within 120 s. Enter tries again; your message is still in the composer."
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_failed_start_names_the_harness_and_keeps_the_cause() {
        let end = bounded(
            "claude",
            START_DEADLINE,
            async {
                Err::<(), _>(anyhow::anyhow!("spawn claude-code-acp: No such file or directory"))
            },
            || false,
        )
        .await;
        assert_eq!(
            end,
            StartEnd::Failed(
                "Couldn't start claude: spawn claude-code-acp: No such file or directory".into()
            )
        );
    }

    /// A start whose connection went down is not a failure: no copy, it runs again.
    #[tokio::test(start_paused = true)]
    async fn a_start_that_lost_its_connection_is_lost_not_failed() {
        let end = bounded(
            "codex",
            START_DEADLINE,
            async { Err::<(), _>(anyhow::anyhow!("daemon connection closed")) },
            || true,
        )
        .await;
        assert_eq!(end, StartEnd::Lost);
    }

    #[tokio::test(start_paused = true)]
    async fn a_start_that_answers_is_started() {
        let end = bounded("codex", START_DEADLINE, async { Ok(5) }, || true).await;
        assert_eq!(end, StartEnd::Started(5));
    }

    #[test]
    fn copy_without_a_harness_or_cause() {
        assert_eq!(failure_copy("", " "), "Couldn't start The agent.");
    }
}
