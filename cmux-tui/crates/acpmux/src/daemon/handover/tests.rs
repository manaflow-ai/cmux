use super::*;
use std::cell::Cell;

// Production reclaim waits on `RECLAIM_WAIT` and on the holder's liveness; these two only
// drive the paused-clock assertions below.
// timeout: test-only bound for the paused-clock reclaim assertions.
const BUDGET: Duration = Duration::from_secs(15);
// timeout: test-only retry cadence for the same paused-clock assertions.
const RETRY: Duration = Duration::from_millis(50);

#[tokio::test(start_paused = true)]
async fn a_holder_still_starting_is_asked_again_once_it_answers() {
    let asks = Cell::new(0);
    let ask = || {
        asks.set(asks.get() + 1);
        let answer = if asks.get() < 3 { Ask::NotYet } else { Ask::Accepted };
        async move { answer }
    };
    assert!(drive_reclaim(ask, std::future::ready(()), BUDGET, RETRY).await);
    assert_eq!(asks.get(), 3);
}

#[tokio::test(start_paused = true)]
async fn a_refusal_or_a_foreign_daemon_ends_the_wait_at_once() {
    let started = tokio::time::Instant::now();
    let ask = || async { Ask::Stop };
    assert!(!drive_reclaim(ask, std::future::pending::<()>(), BUDGET, RETRY).await);
    assert_eq!(started.elapsed(), Duration::ZERO);
}

#[tokio::test(start_paused = true)]
async fn a_holder_that_never_answers_or_never_lets_go_costs_only_the_budget() {
    let started = tokio::time::Instant::now();
    let silent = || std::future::pending::<Ask>();
    assert!(!drive_reclaim(silent, std::future::ready(()), BUDGET, RETRY).await);
    assert_eq!(started.elapsed(), BUDGET);

    let started = tokio::time::Instant::now();
    let accepted = || async { Ask::Accepted };
    assert!(!drive_reclaim(accepted, std::future::pending::<()>(), BUDGET, RETRY).await);
    assert_eq!(started.elapsed(), BUDGET);
}
