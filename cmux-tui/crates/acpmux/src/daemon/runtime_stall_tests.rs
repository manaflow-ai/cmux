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

/// 2026-11-28: all 17 "this whole process did not run" lines came right after a capture that took
/// 5 to 87 s. A capture's own time is the watch's work, not the process stopping.
#[test]
fn a_slow_capture_is_not_read_as_the_process_not_running() {
    use std::cell::Cell;
    let clock = Cell::new(Duration::ZERO);
    let mut steps = Vec::new();
    drive(
        Some(90),
        |d| clock.set(clock.get() + d),
        || clock.get(),
        // The runtime beat once at the start, then stalled.
        || Duration::ZERO,
        |step| {
            if let Step::Stalled { capture: true, .. } = step {
                // The capture takes 15 s on a slow disk.
                clock.set(clock.get() + at(15));
            }
            steps.push(step);
        },
    );
    assert!(!steps.iter().any(|s| matches!(s, Step::ProcessLate { .. })), "{steps:?}");
    let captures = steps.iter().filter(|s| matches!(s, Step::Stalled { capture: true, .. })).count();
    assert_eq!(captures, 2, "the first capture and the one at a minute: {steps:?}");
}

/// The process that did stop is still told apart: a sleep that came back 20 s late.
#[test]
fn a_late_sleep_is_still_the_process_not_running() {
    use std::cell::Cell;
    let clock = Cell::new(Duration::ZERO);
    let rounds = Cell::new(0);
    let mut steps = Vec::new();
    drive(
        Some(5),
        |d| {
            rounds.set(rounds.get() + 1);
            let extra = if rounds.get() == 3 { at(20) } else { Duration::ZERO };
            clock.set(clock.get() + d + extra);
        },
        || clock.get(),
        || clock.get(),
        |step| steps.push(step),
    );
    assert_eq!(steps[2], Step::ProcessLate { gap: at(20) }, "{steps:?}");
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
    // The newest 20, the daemon's first capture, and the file that is not a capture.
    assert_eq!(left.len(), 22);
    assert!(left.contains(&"other.txt".to_string()));
    assert!(left.contains(&"stall-20261120T000000Z-1.txt".to_string()));
    assert!(!left.contains(&"stall-20261120T000001Z-1.txt".to_string()));
    assert!(left.contains(&"stall-20261122T000024Z-1.txt".to_string()));
}

/// A daemon restarted again and again (2026-11-28: 28 restarts in four hours, each stalling)
/// keeps the start of each daemon's stall, not only the newest captures.
#[test]
fn prune_keeps_each_daemons_first_capture() {
    let dir = tempfile::tempdir().unwrap();
    // Daemon 7 captured twice at the start, then daemon 9 captured 30 times.
    for name in ["stall-20261128T054534Z-7.txt", "stall-20261128T054629Z-7.txt"] {
        std::fs::write(dir.path().join(name), "x").unwrap();
    }
    for i in 0..30 {
        std::fs::write(dir.path().join(format!("stall-20261128T06{i:02}00Z-9.txt")), "x").unwrap();
    }
    prune(dir.path(), 20);
    let left: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    assert!(left.contains(&"stall-20261128T054534Z-7.txt".to_string()), "{left:?}");
    assert!(!left.contains(&"stall-20261128T054629Z-7.txt".to_string()), "{left:?}");
    assert!(left.contains(&"stall-20261128T060000Z-9.txt".to_string()), "{left:?}");
    assert_eq!(left.len(), 22, "{left:?}");
}

/// The firsts kept are bounded: only the newest daemons' firsts stay.
#[test]
fn prune_bounds_the_firsts_kept() {
    let dir = tempfile::tempdir().unwrap();
    for pid in 0..(KEEP_FIRSTS + 15) {
        std::fs::write(dir.path().join(format!("stall-20261128T{:06}Z-{pid}.txt", pid * 100)), "x")
            .unwrap();
    }
    prune(dir.path(), 5);
    let left = std::fs::read_dir(dir.path()).unwrap().count();
    assert_eq!(left, KEEP_FIRSTS);
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
#[test]
fn a_syscall_names_its_call_and_fd() {
    // fsync(0x14d), as the 2026-11-28 captures read.
    assert_eq!(
        blocked_on("74 0x14d 0x0 0x0 0x0 0x0 0x0 0x7f2d9b3be5f8 0x7f2da06db30c"),
        Some(Blocked { name: "fsync", fd: Some(0x14d) })
    );
    // mkdirat(AT_FDCWD, ...) has no fd to name.
    assert_eq!(
        blocked_on("258 0xffffffffffffff9c 0x7f00 0x1ff"),
        Some(Blocked { name: "mkdirat", fd: None })
    );
    // A futex wait, a thread in user space, and one that runs name nothing.
    assert_eq!(blocked_on("202 0x4f7d64d1400 0x89 0x4"), None);
    assert_eq!(blocked_on("-1 0x7f2d7f5fd678 0x7f2da066252f"), None);
    assert_eq!(blocked_on("running"), None);
}

/// A capture marks the runtime's workers (they park through [`mark_worker`]) and names the file
/// a blocked thread's syscall acts on.
#[cfg(target_os = "linux")]
#[test]
fn the_linux_capture_marks_workers_and_names_a_blocked_fd() {
    use std::io::Read;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .on_thread_park(mark_worker)
        .enable_all()
        .build()
        .unwrap();
    // Let both workers park once.
    runtime.block_on(async { tokio::time::sleep(Duration::from_millis(50)).await });
    let worker_tids: Vec<i64> = workers();
    assert!(!worker_tids.is_empty());
    // A thread blocked in read(2) on one end of a socket pair.
    let (mut a, b) = std::os::unix::net::UnixStream::pair().unwrap();
    let reader = std::thread::spawn(move || {
        let mut buf = [0u8; 1];
        let _ = a.read(&mut buf);
    });
    std::thread::sleep(Duration::from_millis(200));
    let dir = tempfile::tempdir().unwrap();
    let file = capture_stacks(dir.path()).expect("a capture file");
    let text = std::fs::read_to_string(&file).unwrap();
    drop(b);
    reader.join().unwrap();
    assert!(text.starts_with("# workers marked: "), "{text}");
    let marked = text.lines().filter(|l| l.contains(" role=worker")).count();
    assert!(marked >= 2, "{text}");
    let read_line = text.lines().find(|l| l.contains(" call=read")).unwrap_or_default();
    assert!(read_line.contains(" fd=socket:["), "{text}");
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
