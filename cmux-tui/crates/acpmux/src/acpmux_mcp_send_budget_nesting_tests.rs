use super::*;

/// A relay started late in the call gets only what is left, never its full wait.
#[tokio::test(start_paused = true)]
async fn the_relay_deadline_is_cut_to_the_calls_end() {
    let start = tokio::time::Instant::now();
    let call_end = start + CALL_BUDGET;
    assert_eq!(relay_deadline(call_end), start + RELAY_WAIT);
    tokio::time::advance(CALL_BUDGET - Duration::from_secs(3)).await;
    assert_eq!(relay_deadline(call_end), call_end);
}

/// The steps nest: each inner wait is shorter than the call that runs it.
#[test]
fn inner_waits_are_shorter_than_the_call() {
    assert!(RESOLVE_WAIT < CALL_BUDGET && RELAY_WAIT < CALL_BUDGET);
    assert!(CALL_BUDGET < Duration::from_secs(60));
}
