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
    pub fn waiting(&self, status: &Status) {
        if status.unbuilt == 0 {
            return self.clear();
        }
        let body = serde_json::json!({
            "built": status.view_lines.saturating_sub(status.unbuilt),
            "total": status.view_lines,
        });
        // Through a temporary file and a rename: the app never reads half a file.
        let tmp = self.path.with_extension("json.tmp");
        let written = self
            .path
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| std::fs::write(&tmp, body.to_string()))
            .and_then(|()| std::fs::rename(&tmp, &self.path));
        if written.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }

    /// Nothing waits (settled, shut down, or a host start after a crash).
    pub fn clear(&self) {
        let _ = std::fs::remove_file(&self.path);
    }

    /// `state/compactor.json` beside `settle.json` (cx-oqnw3): while the
    /// compactor cannot build summaries, `{"error": why}`; the app shows a
    /// system notice in the Chief conversation for it (never a Chief message).
    /// None removes it (a good probe, or a host start).
    pub fn compactor_fault(&self, error: Option<&str>) {
        let path = self.path.with_file_name("compactor.json");
        let Some(error) = error else {
            let _ = std::fs::remove_file(&path);
            return;
        };
        let tmp = path.with_extension("json.tmp");
        let body = serde_json::json!({"error": error}).to_string();
        let written = path
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| std::fs::write(&tmp, body))
            .and_then(|()| std::fs::rename(&tmp, &path));
        if written.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}
