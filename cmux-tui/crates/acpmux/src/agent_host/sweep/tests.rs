use super::*;
use crate::clock::ManualClock;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};

const GRACE: Duration = Duration::from_secs(3);

/// A process that holds `lock` as a host holds its liveness lock;
/// `ignore_term` makes it a host that does not end on SIGTERM.
fn fake_host(lock: &Path, ignore_term: bool) -> Child {
    let script = format!(
        "import fcntl, signal, sys, time\n{}f = open(sys.argv[1], 'a+')\nfcntl.flock(f, fcntl.LOCK_EX)\nprint('locked', flush=True)\ntime.sleep(600)\n",
        if ignore_term { "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n" } else { "" }
    );
    let mut child = Command::new("python3")
        .args(["-c", &script])
        .arg(lock)
        .stdout(Stdio::piped())
        .spawn()
        .expect("python3");
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
    assert_eq!(line.trim(), "locked");
    child
}

fn owned(dir: &Path, session: &str, child: &Child) -> OwnedHost {
    OwnedHost {
        dir: dir.to_owned(),
        session_id: session.into(),
        start_nonce: "00ff".into(),
        host_pid: child.id(),
        harness_pid: None,
        pooled: false,
    }
}

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-sweep-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[tokio::test]
async fn a_host_that_ends_on_sigterm_is_not_waited_for() {
    let dir = temp_dir("term");
    let mut child = fake_host(&live_path(&dir, "s1", "00ff"), false);
    let host = owned(&dir, "s1", &child);
    // The clock never moves: only the host's exit can end the wait.
    let left = tokio::time::timeout(
        Duration::from_secs(20),
        end_hosts(&*ManualClock::new(), vec![host], GRACE),
    )
    .await
    .expect("the wait outlived the host");
    assert!(left.is_empty(), "{left:?}");
    child.wait().unwrap();
}

#[tokio::test]
async fn a_host_that_ignores_sigterm_is_killed_after_the_grace_on_the_clock() {
    let dir = temp_dir("kill");
    let mut child = fake_host(&live_path(&dir, "s1", "00ff"), true);
    let host = owned(&dir, "s1", &child);
    let clock = ManualClock::new();
    let mut ending = std::pin::pin!(end_hosts(&*clock, vec![host], GRACE));
    // Polled once: SIGTERM is sent and the deadline is set.
    assert!(futures::poll!(&mut ending).is_pending());
    assert!(child.try_wait().unwrap().is_none(), "the host ended on SIGTERM");
    clock.advance(GRACE);
    let left = tokio::time::timeout(Duration::from_secs(20), ending)
        .await
        .expect("SIGKILL did not follow the grace on the injected clock");
    assert!(left.is_empty(), "{left:?}");
    assert!(child.wait().unwrap().code().is_none(), "the host was not killed");
}

#[cfg(unix)]
#[tokio::test]
async fn a_harness_child_that_left_the_group_ends_with_its_host() {
    let dir = temp_dir("setsid");
    // A host whose child moves itself into a new session, out of reach
    // of the harness group signal, then a host that ends on SIGTERM.
    let script = "import fcntl, subprocess, sys, time\nf = open(sys.argv[1], 'a+')\nfcntl.flock(f, fcntl.LOCK_EX)\nc = subprocess.Popen([sys.executable, '-c', 'import os, sys, time; os.setsid(); print(os.getpid(), flush=True); time.sleep(600)'], stdout=subprocess.PIPE)\nprint('locked', c.stdout.readline().decode().strip(), flush=True)\ntime.sleep(600)\n";
    let mut child = Command::new("python3")
        .args(["-c", script])
        .arg(live_path(&dir, "s1", "00ff"))
        .stdout(Stdio::piped())
        .spawn()
        .expect("python3");
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let escaped: i32 = line.trim().strip_prefix("locked ").unwrap().parse().unwrap();
    let host = owned(&dir, "s1", &child);
    let left = tokio::time::timeout(
        Duration::from_secs(20),
        end_hosts(&*ManualClock::new(), vec![host], GRACE),
    )
    .await
    .expect("the wait outlived the host");
    assert!(left.is_empty(), "{left:?}");
    child.wait().unwrap();
    // The escaped child is reparented and reaped once killed.
    let gone = (0..100).any(|_| {
        // SAFETY: signal 0 only probes whether the pid exists.
        let alive = unsafe { libc::kill(escaped, 0) } == 0;
        if alive {
            std::thread::sleep(Duration::from_millis(50));
        }
        !alive
    });
    if !gone {
        // SAFETY: the test started this pid; end it before failing.
        unsafe { libc::kill(escaped, libc::SIGKILL) };
    }
    assert!(gone, "the child that left the harness group outlived its host");
}

#[tokio::test]
async fn a_pid_without_its_held_lock_is_never_signalled() {
    let dir = temp_dir("own");
    // A live process the record names, but its lock is not held: the
    // pid may now be any process, so it is not this home's host.
    let mut other = Command::new("sleep").arg("600").spawn().unwrap();
    std::fs::write(live_path(&dir, "s1", "00ff"), "").unwrap();
    let host = owned(&dir, "s1", &other);
    assert!(running_hosts(&dir).is_empty());
    let left = end_hosts(&*ManualClock::new(), vec![host], GRACE).await;
    assert!(left.is_empty(), "{left:?}");
    assert!(other.try_wait().unwrap().is_none(), "an unowned process was signalled");
    other.kill().unwrap();
    other.wait().unwrap();
}
