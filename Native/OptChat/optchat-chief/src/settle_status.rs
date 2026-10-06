//! `<mux home>/state/settle.json`: how far the compactor is while a turn
//! waits for the view to settle (section 6: no turn starts before every view
//! line is a summary). The app shows it in the Chief conversation
//! ("Organizing Chief history: N of M") instead of silence; after a large
//! import the first settle can take minutes. The file exists only while a
//! turn waits; the host removes it when the view settles and at start.

use optchat_host::Status;
use std::path::{Path, PathBuf};

pub struct SettleStatus {
    path: PathBuf,
}

impl SettleStatus {
    pub fn new(path: &Path) -> SettleStatus {
        SettleStatus {
            path: path.to_path_buf(),
        }
    }

    /// A turn still waits: write the built and total view lines, or remove
    /// the file once nothing is unbuilt.
    pub fn waiting(&self, _status: &Status) {}

    /// Nothing waits (settled, shut down, or a host start after a crash).
    pub fn clear(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(view_lines: usize, unbuilt: usize) -> Status {
        Status {
            messages: 177,
            view_lines,
            view_size: 0,
            budget: 0,
            unbuilt,
            built: 0,
            busy: Vec::new(),
            failures: Vec::new(),
            fatal: None,
            closed: false,
        }
    }

    fn read(path: &Path) -> serde_json::Value {
        serde_json::from_slice(&std::fs::read(path).expect("settle.json exists")).unwrap()
    }

    #[test]
    fn a_waiting_turn_shows_built_of_total_view_lines_and_the_file_goes_when_settled() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state").join("settle.json");
        let settle = SettleStatus::new(&path);
        settle.waiting(&status(308, 300));
        assert_eq!(read(&path), serde_json::json!({"built": 8, "total": 308}));
        settle.waiting(&status(308, 120));
        assert_eq!(read(&path), serde_json::json!({"built": 188, "total": 308}));
        settle.waiting(&status(308, 0));
        assert!(!path.exists(), "a settled view leaves no status");
        settle.waiting(&status(10, 4));
        settle.clear();
        assert!(!path.exists(), "clear removes the status");
    }
}
