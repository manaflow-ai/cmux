use super::*;

#[test]
fn a_stop_still_running_is_overdue_at_the_hard_point() {
    let returned = Returned::default();
    let hard = Instant::now() + Duration::from_millis(60);
    assert!(returned.overdue(hard));
    assert!(Instant::now() >= hard, "it returned before the hard point");
}

#[test]
fn a_stop_that_returns_is_never_overdue() {
    let returned = Arc::new(Returned::default());
    drop(Armed(Some(returned.clone())));
    let passed = Instant::now().checked_sub(Duration::from_millis(1)).unwrap();
    assert!(!returned.overdue(passed));
}

/// The return wakes the wait: the watchdog's thread ends at once, not at its hard point.
#[test]
fn the_return_wakes_the_wait() {
    let returned = Returned::default();
    let began = Instant::now();
    let overdue = std::thread::scope(|scope| {
        let waiting = scope.spawn(|| returned.overdue(began + Duration::from_secs(60)));
        std::thread::sleep(Duration::from_millis(50));
        returned.set();
        waiting.join().unwrap()
    });
    assert!(!overdue);
    assert!(began.elapsed() < Duration::from_secs(10), "{:?}", began.elapsed());
}
