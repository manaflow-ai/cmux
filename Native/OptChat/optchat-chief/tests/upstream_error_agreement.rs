//! The Chief turn and the compactor read an upstream error the same way
//! (cmux_upstream_error; ask-616b73f6bc, "fix 529s properly with better designs"). Before, the
//! turn knew only "api error: 529" and "retry after N", so an "HTTP 529 ...; retry-after: 30"
//! the compactor waited out failed the turn.

use std::time::Duration;

use optchat_chief::turn::{CAPACITY_DEFAULT_WAIT, capacity_retry_after};
use optchat_host::{CAPACITY_WAIT, capacity_wait};

#[test]
fn a_named_wait_is_waited_by_the_turn_and_the_compactor_alike() {
    for (error, secs) in [
        ("HTTP 529 overloaded_error; retry-after: 30", 30),
        ("API Error: 529 overloaded; retry after 45s", 45),
        (
            "API error: 503 no non-exhausted accounts; retry after 3596s",
            3596,
        ),
        (
            "{\"error\":{\"type\":\"overloaded_error\"},\"retry_after\":12}",
            12,
        ),
        ("502 the gateway is at its call limit; retry-after: 5", 5),
    ] {
        let wait = Some(Duration::from_secs(secs));
        assert_eq!(capacity_retry_after(error), wait, "turn: {error}");
        assert_eq!(capacity_wait(error), wait, "compactor: {error}");
    }
}

#[test]
fn an_unnamed_overload_parks_the_route_but_stays_the_turns_error() {
    // The corpus (cmux-chief-corpus/1) pins "(turn failed: ...)" for a bare overload; the
    // compactor parks the route for its default wait.
    for error in [
        "API Error: 529 {\"type\":\"overloaded_error\"}",
        "HTTP 529 Overloaded",
    ] {
        assert_eq!(capacity_retry_after(error), None, "turn: {error}");
        assert_eq!(
            capacity_wait(error),
            Some(CAPACITY_WAIT),
            "compactor: {error}"
        );
    }
    assert_eq!(
        capacity_retry_after("no non-exhausted accounts"),
        Some(CAPACITY_DEFAULT_WAIT)
    );
}

#[test]
fn a_request_error_or_a_number_inside_a_word_is_no_capacity() {
    for error in [
        "API Error: 400 invalid_request_error",
        "waited 2503s; retry after 9",
    ] {
        assert_eq!(capacity_retry_after(error), None, "turn: {error}");
        assert_eq!(capacity_wait(error), None, "compactor: {error}");
    }
}
