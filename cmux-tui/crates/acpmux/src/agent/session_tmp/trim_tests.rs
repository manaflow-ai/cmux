//! [`super::trim`]: an open session's temporary folder kept under its cap.

use super::trim::held;
use super::*;
use std::time::{Duration, SystemTime};

const MIB: u64 = 1024 * 1024;
const IDLE: Duration = Duration::from_secs(60 * 60);

struct Scratch(PathBuf);
impl Scratch {
    /// A daemon root with one session folder in it.
    fn new(tag: &str) -> (Self, PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "acpmux-session-trim-{tag}-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7().simple()
        ));
        let dir = root.join("01a15d7d-b692-76b3-b8de-a9a71809de2a");
        std::fs::create_dir_all(&dir).unwrap();
        (Scratch(root), dir)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// `dir/name/blob`, `mib` MiB of real blocks.
fn filled(dir: &Path, name: &str, mib: u64) -> PathBuf {
    let entry = dir.join(name);
    std::fs::create_dir_all(&entry).unwrap();
    std::fs::write(entry.join("blob"), vec![7u8; (mib * MIB) as usize]).unwrap();
    entry
}

/// A moment after everything made so far changed: with it as `now - IDLE`, what was made before
/// is untouched for the idle time and what is made after is not.
fn mark() -> SystemTime {
    std::thread::sleep(Duration::from_millis(20));
    let at = SystemTime::now();
    std::thread::sleep(Duration::from_millis(20));
    at
}

fn names(dir: &Path) -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().into_string().unwrap())
        .collect();
    out.sort();
    out
}

#[test]
fn under_the_cap_nothing_goes() {
    let (s, dir) = Scratch::new("under");
    filled(&dir, "lint", 1);
    let out = trim(&dir, &s.0, 8 * MIB, IDLE, SystemTime::now() + 2 * IDLE);
    assert_eq!((out.evicted, out.kept), (0, 0));
    assert!(out.before >= MIB && out.before == out.after, "{out:?}");
    assert_eq!(names(&dir), ["lint"]);
}

#[test]
fn over_the_cap_the_oldest_untouched_go_first_until_under() {
    let (s, dir) = Scratch::new("oldest");
    filled(&dir, "cmux-web-lint-a", 1);
    filled(&dir, "fast-gate-webviews-base-b", 1);
    filled(&dir, "tmp-c", 1);
    let idle_from = mark();
    // Touched within the idle time: stays though it is over the cap.
    filled(&dir, "fresh", 1);
    // acpmux's own, for the agent's life: stays.
    filled(&dir, "copilot-route.1", 1);
    let out = trim(&dir, &s.0, (5 * MIB) / 2, IDLE, idle_from + IDLE);
    // a, b, c are 3 MiB untouched; with fresh and copilot 5 MiB: a and b go, then still over
    // (3 MiB), c goes too; fresh and copilot stay, counted as kept only while still over.
    assert_eq!(names(&dir), ["copilot-route.1", "fresh"]);
    assert_eq!(out.evicted, 3, "{out:?}");
    assert!(out.after < out.before && out.after <= 2 * MIB + 64 * 1024, "{out:?}");
    // Nothing moved aside is left in the root.
    assert_eq!(names(&s.0), ["01a15d7d-b692-76b3-b8de-a9a71809de2a"]);

    // Oldest first: with room for one more, only the oldest goes.
    let (s, dir) = Scratch::new("order");
    filled(&dir, "first", 1);
    std::thread::sleep(Duration::from_millis(20));
    filled(&dir, "second", 1);
    let at = mark();
    let out = trim(&dir, &s.0, (3 * MIB) / 2, IDLE, at + IDLE);
    assert_eq!((out.evicted, names(&dir)), (1, vec!["second".to_owned()]));
}

#[test]
fn an_entry_a_live_process_holds_open_is_never_evicted() {
    let (s, dir) = Scratch::new("held");
    let deep = filled(&dir, "held-deep", 1);
    std::fs::create_dir(deep.join("sub")).unwrap();
    std::fs::write(deep.join("sub/open.log"), "x").unwrap();
    let flat = dir.join("held-flat");
    std::fs::write(&flat, vec![1u8; MIB as usize]).unwrap();
    let child_held = filled(&dir, "held-child", 1);
    filled(&dir, "free", 1);
    let at = mark();
    // Held: a file read deep inside a folder, a top-level file written, a file a child reads.
    let reader = std::fs::File::open(deep.join("sub/open.log")).unwrap();
    let writer = std::fs::OpenOptions::new().append(true).open(&flat).unwrap();
    let mut child = std::process::Command::new("sh")
        .arg("-c")
        .arg("exec 3<\"$1\"; exec sleep 30")
        .arg("sh")
        .arg(child_held.join("blob"))
        .spawn()
        .unwrap();
    // The child has the file open once its shell ran the redirect.
    let until = std::time::Instant::now() + Duration::from_secs(10);
    while !held(&child_held) && std::time::Instant::now() < until {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(held(&deep) && held(&flat) && held(&child_held));
    assert!(!held(&dir.join("free")));
    // A socket is held while something answers on it (a short path: 108 bytes at most).
    let sock = std::env::temp_dir().join(format!("ats-{}.sock", std::process::id()));
    let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
    assert!(held(&sock));
    drop(listener);
    assert!(!held(&sock));
    std::fs::remove_file(&sock).unwrap();

    let out = trim(&dir, &s.0, 0, IDLE, at + IDLE);
    assert_eq!(names(&dir), ["held-child", "held-deep", "held-flat"], "{out:?}");
    assert_eq!((out.evicted, out.kept), (1, 3));

    // Let go, they go at the next pass.
    drop((reader, writer));
    let _ = child.kill();
    let _ = child.wait();
    let out = trim(&dir, &s.0, 0, IDLE, SystemTime::now() + IDLE);
    assert_eq!((out.evicted, names(&dir)), (3, Vec::<String>::new()), "{out:?}");
}

#[test]
fn the_cap_and_idle_time_default_and_turn_off() {
    let mut cfg = crate::config::SessionResourceConfig::default();
    assert_eq!(super::trim::cap_bytes(&cfg), Some(2048 * MIB));
    assert_eq!(super::trim::idle(&cfg), Duration::from_secs(30 * 60));
    cfg.tmp_max_mb = Some(0);
    cfg.tmp_idle_minutes = Some(5);
    assert_eq!(super::trim::cap_bytes(&cfg), None);
    assert_eq!(super::trim::idle(&cfg), Duration::from_secs(5 * 60));
    let parsed: crate::config::SessionResourceConfig =
        serde_json::from_str(r#"{"tmpMaxMb": 512, "tmpIdleMinutes": 10}"#).unwrap();
    assert_eq!((parsed.tmp_max_mb, parsed.tmp_idle_minutes), (Some(512), Some(10)));
}
