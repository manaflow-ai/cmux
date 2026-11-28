use super::*;

fn at(secs: u64) -> Duration {
    Duration::from_secs(secs)
}

#[test]
fn a_beating_runtime_is_fine() {
    let mut watch = Watch::default();
    for t in 1..100 {
        assert_eq!(
            watch.check(at(t), at(t) - Duration::from_millis(500), Duration::ZERO),
            Step::Fine
        );
    }
}

#[test]
fn a_stale_beat_is_a_stall_captured_once_then_again_at_a_minute_then_recovered() {
    let mut watch = Watch::default();
    // Beats until 10 s, then nothing.
    assert_eq!(watch.check(at(10), at(10), Duration::ZERO), Step::Fine);
    assert_eq!(watch.check(at(14), at(10), Duration::ZERO), Step::Fine);
    assert_eq!(
        watch.check(at(15), at(10), Duration::ZERO),
        Step::Stalled { silent: at(5), capture: true, first: true }
    );
    // Quiet while it goes on.
    for t in 16..70 {
        assert_eq!(watch.check(at(t), at(10), Duration::ZERO), Step::Fine, "t={t}");
    }
    assert_eq!(
        watch.check(at(70), at(10), Duration::ZERO),
        Step::Stalled { silent: at(60), capture: true, first: false }
    );
    // A 20-minute stall takes no third capture.
    for t in 71..1210 {
        assert_eq!(watch.check(at(t), at(10), Duration::ZERO), Step::Fine, "t={t}");
    }
    assert_eq!(
        watch.check(at(1211), at(1210), Duration::ZERO),
        Step::Recovered { stopped: at(1200) }
    );
    assert_eq!(watch.check(at(1212), at(1212), Duration::ZERO), Step::Fine);
}

#[test]
fn the_whole_process_not_running_is_no_stall() {
    let mut watch = Watch::default();
    // Thread and runtime both stopped for 20 minutes (SIGSTOP, a sleeping Mac): the thread's own
    // sleep came back that late, so nothing is captured.
    assert_eq!(watch.check(at(1210), at(10), at(1200)), Step::ProcessLate { gap: at(1200) });
    // The runtime beats right after: fine, no recovery line for a stall never named.
    assert_eq!(watch.check(at(1211), at(1211), Duration::ZERO), Step::Fine);
}

#[test]
fn captures_are_bounded_per_hour() {
    let mut watch = Watch::default();
    let mut captured = 0;
    let mut t = 0;
    // A one-shot 6 s stall every 20 s for an hour: 180 stalls.
    for _ in 0..180 {
        let beat = at(t);
        t += 6;
        if let Step::Stalled { capture: true, .. } = watch.check(at(t), beat, Duration::ZERO) {
            captured += 1;
        }
        t += 14;
        watch.check(at(t), at(t), Duration::ZERO);
    }
    assert_eq!(captured, MAX_CAPTURES_PER_HOUR);
}

#[cfg(unix)]
#[test]
fn stall_threshold_sits_under_the_waiters_replace() {
    // The stacks must be taken before a waiter replaces the silent daemon (`hung_holder.rs`).
    assert!(STALL * 2 < crate::daemon::hung_holder::SERVING_STALL);
    assert!(CHECK_EVERY < STALL && BEAT_EVERY < STALL);
}

#[test]
fn civil_dates() {
    assert_eq!(civil_from_days(0), (1970, 1, 1));
    // 2026-11-27 is day 20784.
    assert_eq!(civil_from_days(20_784), (2026, 11, 27));
    assert_eq!(civil_from_days(11_016), (2000, 2, 29));
}

#[test]
fn prune_keeps_the_newest() {
    let dir = tempfile::tempdir().unwrap();
    for i in 0..25 {
        std::fs::write(dir.path().join(format!("stall-2026112{}T0000{i:02}Z-1.txt", i / 10)), "x")
            .unwrap();
    }
    std::fs::write(dir.path().join("other.txt"), "x").unwrap();
    prune(dir.path(), 20);
    let mut left: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    left.sort();
    assert_eq!(left.len(), 21);
    assert!(left.contains(&"other.txt".to_string()));
    assert!(!left.contains(&"stall-20261120T000000Z-1.txt".to_string()));
    assert!(left.contains(&"stall-20261122T000024Z-1.txt".to_string()));
}

/// A runtime whose only worker is blocked is seen by the real thread and named in one capture.
#[test]
fn a_blocked_single_worker_runtime_is_seen() {
    let rt = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
    rt.block_on(async {
        let mut watch = Watch::default();
        stamp();
        let beat = Duration::from_millis(BEAT_MS.load(Ordering::Relaxed));
        // Nothing beats while this blocks the only worker.
        std::thread::sleep(STALL + Duration::from_millis(200));
        let step = watch.check(origin().elapsed(), beat, Duration::ZERO);
        assert!(matches!(step, Step::Stalled { capture: true, first: true, .. }), "{step:?}");
    });
}

/// Linux: the capture names every thread with its state and wait channel, readable without root.
#[cfg(target_os = "linux")]
#[test]
fn the_linux_capture_names_each_thread() {
    let dir = tempfile::tempdir().unwrap();
    let file = capture_stacks(dir.path()).expect("a capture file");
    let text = std::fs::read_to_string(&file).unwrap();
    assert!(text.lines().filter(|l| l.starts_with("tid=")).count() >= 1, "{text}");
    assert!(text.contains("state="), "{text}");
}
