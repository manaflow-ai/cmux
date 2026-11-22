use super::*;
use std::io::Read;
use std::os::unix::net::UnixListener;

const GB: u64 = 1 << 30;

#[test]
fn an_answered_hello_pings_and_an_unanswered_one_after_startup_does_not() {
    let mut check = Check::default();
    let up = STARTUP_GRACE + Duration::from_secs(1);
    assert_eq!(check.judge(true, up, Some(GB), Some(6 * GB)), Verdict::Ping);
    assert_eq!(check.judge(false, up, Some(GB), Some(6 * GB)), Verdict::Hung);
    assert_eq!(check.judge(false, up, None, Some(6 * GB)), Verdict::Hung);
    assert_eq!(check.unanswered, 2);
    assert_eq!(check.judge(true, up, Some(GB), Some(6 * GB)), Verdict::Ping);
    assert_eq!(check.unanswered, 0);
}

#[test]
fn a_start_that_has_not_answered_yet_still_pings_within_the_grace() {
    let mut check = Check::default();
    assert_eq!(check.judge(false, Duration::from_secs(93), None, Some(6 * GB)), Verdict::Ping);
}

#[test]
fn memory_over_the_bound_restarts_only_after_strikes_in_a_row() {
    let mut check = Check::default();
    let up = Duration::from_secs(3600);
    let over = Some(16 * GB);
    for _ in 1..RSS_STRIKES {
        assert_eq!(check.judge(true, up, over, Some(6 * GB)), Verdict::Ping);
    }
    // A check under the bound starts the count again.
    assert_eq!(check.judge(true, up, Some(GB), Some(6 * GB)), Verdict::Ping);
    for _ in 1..RSS_STRIKES {
        assert_eq!(check.judge(true, up, over, Some(6 * GB)), Verdict::Ping);
    }
    assert_eq!(check.judge(true, up, over, Some(6 * GB)), Verdict::Restart);
    // Off (no bound): never a restart.
    let mut off = Check::default();
    for _ in 0..10 {
        assert_eq!(off.judge(true, up, over, None), Verdict::Ping);
    }
}

#[test]
fn the_bound_is_the_default_or_the_environment_and_zero_turns_it_off() {
    assert_eq!(rss_bound(None), Some(RSS_BOUND));
    assert_eq!(rss_bound(Some("")), Some(RSS_BOUND));
    assert_eq!(rss_bound(Some("8589934592")), Some(8 * GB));
    assert_eq!(rss_bound(Some("0")), None);
    assert_eq!(rss_bound(Some("lots")), Some(RSS_BOUND));
}

#[test]
fn the_check_runs_three_times_per_limit_at_least_every_five_seconds() {
    assert_eq!(interval(LIMIT), Duration::from_secs(60));
    assert_eq!(interval(Duration::from_secs(6)), Duration::from_secs(5));
}

/// A daemon stand-in on a socket: `answer` says whether it replies to the hello.
fn daemon(dir: &Path, answer: bool) -> PathBuf {
    let path = dir.join("acpmux.sock");
    let listener = UnixListener::bind(&path).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let mut line = String::new();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let _ = reader.read_line(&mut line);
            let asked: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert_eq!(asked["method"], crate::rpc::method::INITIALIZE);
            if answer {
                let _ = stream
                    .write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"x/notice\",\"params\":{}}\n");
                let _ = stream.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n");
            }
            // Holds the connection open with no answer, as a hung daemon does.
            let _ = stream.read(&mut [0u8; 1]);
        }
    });
    path
}

#[test]
fn hello_is_answered_by_a_daemon_that_answers() {
    let dir = tempfile::tempdir().unwrap();
    let socket = daemon(dir.path(), true);
    assert_eq!(hello(&socket, Duration::from_secs(5)), Ok(()));
}

#[test]
fn hello_fails_within_its_bound_on_a_daemon_that_holds_the_connection() {
    let dir = tempfile::tempdir().unwrap();
    let socket = daemon(dir.path(), false);
    let asked = Instant::now();
    assert!(hello(&socket, Duration::from_millis(300)).is_err());
    assert!(asked.elapsed() < Duration::from_secs(3));
}

#[test]
fn hello_fails_when_nothing_serves_the_socket() {
    let dir = tempfile::tempdir().unwrap();
    assert!(hello(&dir.path().join("gone.sock"), Duration::from_secs(1)).is_err());
}

#[test]
fn pings_and_the_armed_limit_reach_the_notify_socket() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("notify");
    let systemd = UnixDatagram::bind(&path).unwrap();
    let notify = path.to_str().unwrap();
    notify_line(notify, &format!("WATCHDOG_USEC={}", LIMIT.as_micros()));
    ping(notify);
    let mut buf = [0u8; 64];
    let n = systemd.recv(&mut buf).unwrap();
    assert_eq!(&buf[..n], b"WATCHDOG_USEC=180000000");
    let n = systemd.recv(&mut buf).unwrap();
    assert_eq!(&buf[..n], b"WATCHDOG=1");
}

#[test]
fn pings_reach_an_abstract_notify_socket() {
    use std::os::linux::net::SocketAddrExt;
    let name = format!("acpmux-watchdog-test-{}", std::process::id());
    let addr = std::os::unix::net::SocketAddr::from_abstract_name(name.as_bytes()).unwrap();
    let systemd = UnixDatagram::bind_addr(&addr).unwrap();
    ping(&format!("@{name}"));
    let mut buf = [0u8; 16];
    let n = systemd.recv(&mut buf).unwrap();
    assert_eq!(&buf[..n], b"WATCHDOG=1");
}
