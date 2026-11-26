use super::*;

#[test]
fn args_tie_the_hold_to_the_bridge_and_bound_it() {
    assert_eq!(
        caffeinate_args(4242, Duration::from_secs(300)),
        ["-d", "-i", "-u", "-w", "4242", "-t", "300"]
    );
    // A zero window still asks caffeinate for one second, never "forever".
    assert_eq!(caffeinate_args(7, Duration::ZERO).last().map(String::as_str), Some("1"));
}

#[test]
fn a_hold_is_renewed_only_when_missing_dead_or_half_spent() {
    let start = Instant::now();
    let w = Duration::from_secs(300);
    assert!(needs_renewal(None, false, start, w));
    assert!(needs_renewal(Some(start), false, start, w), "an exited caffeinate is renewed");
    assert!(!needs_renewal(Some(start), true, start + Duration::from_secs(149), w));
    assert!(needs_renewal(Some(start), true, start + Duration::from_secs(150), w));
}
