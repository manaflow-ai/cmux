//! Tests of hung_holder.rs.

use super::*;

const S: fn(u64) -> Duration = Duration::from_secs;

fn bounds() -> Bounds {
    Bounds::DEFAULT
}

// (d) A slow-but-alive holder is never judged hung: any recent beat or answer keeps it.
#[test]
fn stalled_needs_both_no_answer_and_no_beat_for_the_phase_bound() {
    let b = bounds();
    // Serving, beat 3 s old (load 60 delays a 2 s tick by a second): kept however long unanswered.
    assert!(!stalled(S(3600), Some((Phase::Serving, S(3))), b));
    // Serving, beat stale but a probe answered 5 s ago: kept.
    assert!(!stalled(S(5), Some((Phase::Serving, S(3600))), b));
    // Serving, both past 15 s: hung.
    assert!(stalled(S(15), Some((Phase::Serving, S(15))), b));
    assert!(stalled(S(29 * 60), Some((Phase::Serving, S(29 * 60))), b));
    // Starting: one start step may take up to two minutes on a loaded Mac.
    assert!(!stalled(S(100), Some((Phase::Starting, S(100))), b));
    assert!(!stalled(S(8 * 60), Some((Phase::Starting, S(1))), b));
    assert!(stalled(S(8 * 60), Some((Phase::Starting, S(8 * 60))), b));
    // No beat at all (an older build): the starting bound, counted from the waiter's own clock.
    assert!(!stalled(S(60), None, b));
    assert!(stalled(STARTING_STALL, None, b));
}

#[test]
fn bounds_are_the_stated_ones() {
    assert_eq!(SERVING_STALL, S(15));
    assert!(BEAT_EVERY * 5 <= SERVING_STALL, "several beats fit in the serving bound");
    assert!(PROBE_BOUND < SERVING_STALL);
    assert!(STARTING_STALL >= S(60));
}

#[test]
fn beat_of_reads_only_the_named_pid_and_its_phase() {
    let dir = tempfile::tempdir().unwrap();
    let at = now_ms() - 4_000;
    std::fs::write(beat_path(dir.path()), format!(r#"{{"pid":42,"phase":"serving","atMs":{at}}}"#))
        .unwrap();
    let (phase, age) = beat_of(dir.path(), 42).expect("beat");
    assert_eq!(phase, Phase::Serving);
    assert!(age >= S(4) && age < S(30), "{age:?}");
    assert_eq!(beat_of(dir.path(), 43), None, "another pid's beat is none of this one's");
    std::fs::write(beat_path(dir.path()), "not json").unwrap();
    assert_eq!(beat_of(dir.path(), 42), None);
}

struct Child(std::process::Child);

impl Drop for Child {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn alive(child: &mut Child) -> bool {
    child.0.try_wait().unwrap().is_none()
}

// (e) A pid that is not acpmux, or acpmux in another home, is refused and never signalled.
#[test]
fn identity_refuses_a_foreign_process_and_another_homes_acpmux() {
    let home = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    let sleep = which_sleep();

    // A foreign executable whose cwd is this very home.
    let mut foreign = Child(
        std::process::Command::new(&sleep).arg("60").current_dir(home.path()).spawn().unwrap(),
    );
    let pid = foreign.0.id();
    assert!(matches!(check_identity(pid, home.path()), Err(Refusal::NotAcpmux(p, _)) if p == pid));

    // An executable named acpmux, running in another home.
    let fake = other.path().join("acpmux");
    std::fs::copy(&sleep, &fake).unwrap();
    let mut elsewhere = Child(
        std::process::Command::new(&fake).arg("60").current_dir(other.path()).spawn().unwrap(),
    );
    let epid = elsewhere.0.id();
    assert!(
        matches!(check_identity(epid, home.path()), Err(Refusal::OtherHome(p, _)) if p == epid),
        "{:?}",
        check_identity(epid, home.path())
    );
    // The same process is its own home's.
    assert_eq!(check_identity(epid, other.path()), Ok(epid));

    // A pid file naming either: no lock holder and no owner record, so verify and replace refuse.
    std::fs::write(home.path().join("daemon.lock"), format!("{pid}\n/x.sock\n")).unwrap();
    assert_eq!(verify(home.path()), Err(Refusal::NoHolder));
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    assert_eq!(rt.block_on(replace(home.path(), "test")), Err(Refusal::NoHolder));
    std::fs::write(other.path().join("daemon.lock"), format!("{epid}\n/x.sock\n")).unwrap();
    assert!(rt.block_on(replace(other.path(), "test")).is_err());

    std::thread::sleep(Duration::from_millis(200));
    assert!(alive(&mut foreign), "the foreign process was signalled");
    assert!(alive(&mut elsewhere), "the other home's process was signalled");
    assert!(!signal(1, 0) && !signal(0, 0), "init and the process group are never signalled");
}

fn which_sleep() -> PathBuf {
    ["/bin/sleep", "/usr/bin/sleep"]
        .into_iter()
        .map(PathBuf::from)
        .find(|p| p.exists())
        .expect("sleep")
}

// (b) at the unit level: one waiter a home, keyed by the home's path (any binary takes the same
// file), released when it drops.
#[test]
fn one_waiter_stands_a_home() {
    let home = tempfile::tempdir().unwrap();
    let first = stand(home.path()).expect("first stands");
    assert!(first.0.is_some());
    // Another open file description, as a second process (or another binary) would have.
    assert_eq!(stand(home.path()).err(), Some(std::process::id()));
    drop(first);
    assert!(stand(home.path()).is_ok(), "released when the waiter drops");
    assert!(says_waiter_stands(r#"{"ready":false,"lockHeld":true,"waiterStands":true}"#));
    assert!(!says_waiter_stands(r#"{"ready":false,"lockHeld":true}"#));
}

// A pid that answers at the socket its lock records is never replaced, beat or none.
#[test]
fn a_holder_answering_at_its_own_socket_is_not_hung() {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let home = tempfile::tempdir().unwrap();
    // Nothing listens anywhere: no answer.
    std::fs::write(home.path().join("daemon.lock"), "4242\n/nonexistent/acpmux.sock\n").unwrap();
    assert_eq!(rt.block_on(answers_somewhere(home.path(), 4242)), None);
}

// A stopped process is seen as stopped (it cannot handle SIGTERM); a running one is not.
#[cfg(target_os = "linux")]
#[test]
fn a_stopped_process_is_seen_as_stopped() {
    let mut child = Child(std::process::Command::new(which_sleep()).arg("30").spawn().unwrap());
    let pid = child.0.id();
    assert!(!is_stopped(pid));
    assert!(signal(pid, libc::SIGSTOP));
    let until = std::time::Instant::now() + S(5);
    while !is_stopped(pid) && std::time::Instant::now() < until {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(is_stopped(pid));
    assert!(signal(pid, libc::SIGCONT));
    assert!(alive(&mut child));
    assert!(!is_stopped(u32::MAX - 1), "no such process is not stopped");
    assert!(STOPPED_TERM_WAIT < TERM_WAIT);
}

// The candidate probes run together: three silent candidates cost one probe bound, not three.
#[test]
fn candidate_probes_share_one_bound() {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let home = tempfile::tempdir().unwrap();
    std::fs::write(home.path().join("daemon.lock"), "4242\n/nonexistent/a.sock\n").unwrap();
    let t = std::time::Instant::now();
    assert_eq!(rt.block_on(answers_somewhere(home.path(), 4242)), None);
    assert!(t.elapsed() < PROBE_BOUND, "{:?}", t.elapsed());
}
