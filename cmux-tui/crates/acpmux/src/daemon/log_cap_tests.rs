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
