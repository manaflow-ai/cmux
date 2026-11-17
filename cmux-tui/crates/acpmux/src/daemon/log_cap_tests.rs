//! A starting daemon's log cap (`log_cap.rs`). The move itself repoints the process's own stderr,
//! which a test thread shares with every other: these cover when the cap leaves the file alone.

use super::*;

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-logcap-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A log under the cap, a missing one, and one past it that is not this process's stderr (a
/// daemon started from a terminal or by a test) are left as they are.
#[test]
fn a_log_under_the_cap_or_not_this_daemons_output_stays() {
    let dir = scratch("stays");
    let log = dir.join("daemon.log");
    assert!(!rotate_at_start(&log, 16).unwrap(), "no log");
    std::fs::write(&log, b"0123456789").unwrap();
    assert!(!rotate_at_start(&log, 16).unwrap(), "under the cap");
    std::fs::write(&log, vec![b'x'; 64]).unwrap();
    assert!(!rotate_at_start(&log, 16).unwrap(), "stderr is not the log");
    assert_eq!(std::fs::metadata(&log).unwrap().len(), 64);
    assert!(!previous(&log).exists());
    assert_eq!(previous(&log), dir.join("daemon.log.1"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// Output a start sent to /dev/null goes to the log; output that goes to a file stays there.
/// Descriptors of this test's own, never the process's shared stdout and stderr.
#[test]
fn discarded_output_goes_to_the_log_and_other_output_stays() {
    use std::io::Write;
    use std::os::fd::{AsRawFd, FromRawFd};
    let dir = scratch("adopt");
    let log = dir.join("daemon.log");
    let other = dir.join("other.out");
    let null = std::fs::OpenOptions::new().write(true).open("/dev/null").unwrap();
    let file = std::fs::File::create(&other).unwrap();
    // SAFETY: fresh duplicates this test owns; each is closed once, by its File.
    let (a, b) = unsafe { (libc::dup(null.as_raw_fd()), libc::dup(file.as_raw_fd())) };
    assert!(a >= 0 && b >= 0);
    assert!(
        adopt_discarded_output(&log, &[a, b]).unwrap(),
        "the /dev/null descriptor was left blind"
    );
    let (mut a, mut b) = unsafe { (std::fs::File::from_raw_fd(a), std::fs::File::from_raw_fd(b)) };
    a.write_all(b"to the log\n").unwrap();
    b.write_all(b"to its own file\n").unwrap();
    assert_eq!(std::fs::read_to_string(&log).unwrap(), "to the log\n");
    assert_eq!(std::fs::read_to_string(&other).unwrap(), "to its own file\n");
    assert!(!adopt_discarded_output(&log, &[b.as_raw_fd()]).unwrap(), "a file output was moved");
    let _ = std::fs::remove_dir_all(&dir);
}
