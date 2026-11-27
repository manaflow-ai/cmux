use super::*;

/// The timeout names the step and says the message may be queued, not a plain "took over".
#[test]
fn a_timed_out_send_says_it_may_be_queued() {
    let m = send_timeout_message("lane-b");
    assert!(m.contains("lane-b") && m.contains("20s"), "{m}");
    assert!(m.contains("may already be queued"), "{m}");
    assert!(!m.contains("took over"), "{m}");
}
