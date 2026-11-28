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

#[test]
fn a_hello_waits_until_just_before_systemds_limit_from_the_last_ping() {
    let plan = Plan::for_limit(LIMIT);
    let pinged = Instant::now();
    // The check a minute after the last ping waits out the rest of systemd's 180 s, less 10 s.
    assert_eq!(plan.hello_wait(pinged, pinged + Duration::from_secs(60)), Duration::from_secs(110));
    // Past the window it still gets the floor: one hello is never handed zero.
    assert_eq!(plan.hello_wait(pinged, pinged + Duration::from_secs(175)), HELLO_BOUND);
    assert_eq!(plan.hello_wait(pinged, pinged + Duration::from_secs(400)), HELLO_BOUND);
}

/// The stand-in daemon's socket and answer delay, for [`stand_in_daemon`] in a child process.
const STAND_IN_SOCKET: &str = "ACPMUX_WATCHDOG_STAND_IN";
const STAND_IN_DELAY_MS: &str = "ACPMUX_WATCHDOG_STAND_IN_DELAY_MS";

/// Not a check: run in a child of this test binary (`stand_in`), it is a daemon of its own that
/// answers each hello after the delay, so a test can SIGSTOP it (cmux-fault) as a starved Mac is.
#[test]
fn stand_in_daemon() {
    let Ok(path) = std::env::var(STAND_IN_SOCKET) else { return };
    let delay = Duration::from_millis(
        std::env::var(STAND_IN_DELAY_MS).ok().and_then(|v| v.parse().ok()).unwrap_or(0),
    );
    let listener = UnixListener::bind(&path).unwrap();
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { return };
        std::thread::spawn(move || {
            let mut line = String::new();
            let _ = BufReader::new(stream.try_clone().unwrap()).read_line(&mut line);
            std::thread::sleep(delay);
            let _ = stream.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n");
            let _ = stream.read(&mut [0u8; 1]);
        });
    }
}

/// A stand-in daemon process this test spawned, killed and reaped on drop.
struct StandIn {
    child: std::process::Child,
    socket: PathBuf,
    process: cmux_fault::process::Recorded,
}

impl Drop for StandIn {
    fn drop(&mut self) {
        self.process.kill();
        let _ = self.child.wait();
    }
}

fn stand_in(dir: &Path, delay: Duration) -> StandIn {
    let socket = dir.join("stand-in.sock");
    let child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "daemon::watchdog::tests::stand_in_daemon",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(STAND_IN_SOCKET, &socket)
        .env(STAND_IN_DELAY_MS, delay.as_millis().to_string())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let process = cmux_fault::process::Recorded::child(
        &child,
        "stand-in acpmux daemon",
        &cmux_fault::trace::Trace::new(),
    );
    let up = Instant::now();
    while UnixStream::connect(&socket).is_err() {
        assert!(
            up.elapsed() < Duration::from_secs(20),
            "the stand-in daemon never bound its socket"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    StandIn { child, socket, process }
}

/// systemd's side: the times pings arrive, read until the returned flag is set.
fn systemd(dir: &Path) -> (String, std::sync::Arc<std::sync::Mutex<Vec<Instant>>>) {
    let path = dir.join("notify");
    let socket = UnixDatagram::bind(&path).unwrap();
    socket.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let pings = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let seen = pings.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 64];
        loop {
            match socket.recv(&mut buf) {
                Ok(n) if &buf[..n] == b"WATCHDOG=1" => seen.lock().unwrap().push(Instant::now()),
                Ok(_) => {}
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => return,
            }
        }
    });
    (path.to_str().unwrap().to_owned(), pings)
}

/// The longest stretch with no ping from `from` to `to`: past systemd's limit, systemd ends the daemon.
fn longest_quiet(pings: &[Instant], from: Instant, to: Instant) -> Duration {
    let mut last = from;
    let mut longest = Duration::ZERO;
    for &at in pings.iter().filter(|&&at| at >= from && at <= to).chain(std::iter::once(&to)) {
        longest = longest.max(at.saturating_duration_since(last));
        last = at;
    }
    longest
}

/// The daemon's plan scaled down 60 times: a 3 s limit, a check a second, no startup grace, and
/// the old fixed hello bound scaled the same (20 s of 180 s).
fn scaled() -> Plan {
    Plan {
        limit: Duration::from_secs(3),
        every: Duration::from_secs(1),
        grace: Duration::ZERO,
        reserve: Duration::from_millis(300),
        floor: Duration::from_millis(333),
    }
}

fn watching(
    socket: PathBuf,
    notify: String,
    plan: Plan,
) -> (std::sync::Arc<AtomicBool>, std::thread::JoinHandle<()>) {
    let stop = std::sync::Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    let thread = std::thread::spawn(move || watch(&socket, &notify, plan, None, &flag));
    (stop, thread)
}

/// incident 6, a starved Mac never comes back: a daemon that answers every hello, only slower than
/// the old fixed hello bound, was read as hung and ended by systemd within its limit, over and
/// over. The hello now waits on systemd's own deadline, so slow is never dead.
#[test]
fn a_daemon_answering_slower_than_the_old_hello_bound_keeps_its_pings() {
    let dir = tempfile::tempdir().unwrap();
    let plan = scaled();
    let daemon = stand_in(dir.path(), Duration::from_millis(1_200));
    // Before: each check waited the fixed bound only, so none of these answers counted.
    let old_start = Instant::now();
    let mut old_pings = 0;
    while old_start.elapsed() < Duration::from_secs(4) {
        if hello(&daemon.socket, plan.floor).is_ok() {
            old_pings += 1;
        }
    }
    let old_quiet = old_start.elapsed();
    // After: the same daemon, watched as the daemon watches itself.
    let (notify, pings) = systemd(dir.path());
    let start = Instant::now();
    let (stop, thread) = watching(daemon.socket.clone(), notify, plan);
    std::thread::sleep(Duration::from_secs(6));
    stop.store(true, Ordering::Relaxed);
    let end = Instant::now();
    let pings = pings.lock().unwrap().clone();
    let quiet = longest_quiet(&pings, start, end);
    eprintln!(
        "slow hello (1.2 s against a {:?} old bound, {:?} limit): before {old_pings} pings, {:?} quiet (systemd ends it); after {} pings, longest quiet {:?}",
        plan.floor,
        plan.limit,
        old_quiet,
        pings.len(),
        quiet
    );
    assert_eq!(old_pings, 0, "the old fixed bound counted a slow answer");
    assert!(pings.len() >= 3, "the slow daemon's answers should ping: {pings:?}");
    assert!(
        quiet < plan.limit,
        "systemd would end a daemon that answers every hello: {quiet:?} quiet"
    );
    let _ = thread.join();
}

/// The detector (handbook `starved-app-never-comes-back`): SIGSTOP the daemon through cmux-fault.
/// Frozen for less than systemd's limit, it comes back with no restart; frozen for good, the
/// watchdog stops pinging so systemd's restart (agents kept) lands within the limit: never a
/// wait with no end, and never a restart of a daemon that was only starved.
#[test]
fn a_sigstopped_daemon_is_kept_while_starved_and_restarted_within_the_limit_when_hung() {
    let dir = tempfile::tempdir().unwrap();
    let plan = scaled();
    let daemon = stand_in(dir.path(), Duration::ZERO);
    let (notify, pings) = systemd(dir.path());
    let start = Instant::now();
    let (stop, thread) = watching(daemon.socket.clone(), notify, plan);
    std::thread::sleep(Duration::from_millis(1_100));
    // Starved: frozen for two thirds of the limit, then thawed.
    assert!(daemon.process.freeze());
    std::thread::sleep(Duration::from_millis(2_000));
    assert!(daemon.process.resume());
    std::thread::sleep(Duration::from_millis(2_000));
    let starved_end = Instant::now();
    // Hung: frozen for good.
    assert!(daemon.process.freeze());
    let frozen = Instant::now();
    std::thread::sleep(plan.limit + plan.every);
    stop.store(true, Ordering::Relaxed);
    let end = Instant::now();
    let pings = pings.lock().unwrap().clone();
    let starved_quiet = longest_quiet(&pings, start, starved_end);
    let after_freeze: Vec<_> = pings.iter().filter(|&&at| at > frozen).collect();
    eprintln!(
        "starved 2 s of a {:?} limit: longest quiet {starved_quiet:?}; frozen for good: {} pings after, quiet {:?}",
        plan.limit,
        after_freeze.len(),
        end - frozen
    );
    assert!(
        starved_quiet < plan.limit,
        "a daemon starved for less than the limit was ended: {starved_quiet:?} quiet"
    );
    assert!(
        after_freeze.is_empty(),
        "a frozen daemon kept its pings, so nothing ever restarts it: {after_freeze:?}"
    );
    daemon.process.resume();
    let _ = thread.join();
}
