use super::*;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};

#[test]
fn every_reconnect_wait_recovers() {
    let states = [
        Phase::Backoff { attempt: 1, delay: BACKOFF_FIRST, left: BUDGET },
        Phase::Dialing { attempt: 1, delay: BACKOFF_FIRST, left: BUDGET },
        Phase::Dialing { attempt: 9, delay: BACKOFF_MAX, left: Duration::from_secs(1) },
        Phase::Backoff { attempt: 6, delay: BACKOFF_MAX, left: Duration::from_millis(500) },
        Phase::Back,
        Phase::GaveUp,
    ];
    // Unanswered, every state reaches `GaveUp` within the budget plus one attempt (a dial
    // sent with a moment of budget left still gets its whole attempt).
    let walks = cmux_bounded::testing::assert_every_wait_recovers::<Reconnect>(
        |s: &Phase| Reconnect(s.clone()),
        &states,
        BUDGET + ATTEMPT,
    );
    assert_eq!(walks.len(), 4, "the four waiting states");
}

/// Before: a daemon that accepts and never answers `initialize` held the reconnect forever
/// (its 60 s deadline was read only after a dial failed). After: each attempt ends at
/// `ATTEMPT` and the reconnect fails at `BUDGET` with why.
#[tokio::test(start_paused = true)]
async fn a_daemon_that_accepts_and_never_answers_ends_the_reconnect_at_its_budget() {
    let tries = Arc::new(AtomicU32::new(0));
    let counted = tries.clone();
    let before = cmux_bounded::overrun_count(Reconnect::NAME);
    let started = Instant::now();
    let ended = tokio::time::timeout(
        Duration::from_secs(600),
        redial(move || {
            counted.fetch_add(1, Ordering::SeqCst);
            std::future::pending::<Result<()>>()
        }),
    )
    .await
    .expect("a reconnect to a daemon that never answers held the pane forever");
    let err = ended.expect_err("a daemon that never answered reconnected").to_string();
    assert!(err.contains("did not answer within 10 s"), "{err}");
    assert!(started.elapsed() <= BUDGET + ATTEMPT + BACKOFF_MAX, "{:?}", started.elapsed());
    assert!(tries.load(Ordering::SeqCst) >= 4, "{tries:?}");
    assert!(cmux_bounded::overrun_count(Reconnect::NAME) > before);
}

/// One attempt the daemon never answers, then one it does: reconnected on the second.
#[tokio::test(start_paused = true)]
async fn a_dial_that_hangs_once_is_dialed_again_and_reconnects() {
    let tries = Arc::new(AtomicU32::new(0));
    let counted = tries.clone();
    let back = redial(move || {
        let n = counted.fetch_add(1, Ordering::SeqCst);
        async move {
            if n == 0 {
                std::future::pending::<()>().await;
            }
            Ok(n)
        }
    })
    .await
    .expect("reconnected");
    assert_eq!(back, 1);
}

/// A dial that fails at once still backs off and gives up at the budget, as before.
#[tokio::test(start_paused = true)]
async fn a_dial_that_fails_gives_up_at_the_budget_with_its_reason() {
    let err = redial(|| async { Err::<(), _>(anyhow::anyhow!("no socket")) })
        .await
        .expect_err("no daemon")
        .to_string();
    assert!(err.contains("within 60s: no socket"), "{err}");
}
