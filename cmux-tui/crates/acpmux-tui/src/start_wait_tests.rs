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
