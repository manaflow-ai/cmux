//! Swift live code on an iPhone (cmuxterm-hq `docs/design/ios-dev-channels.md`, step 4): the
//! Mac's patches for a cmux Dev app on a phone travel over the link, not through a folder the
//! phone can read. In the Simulator the app watches a folder on the Mac's disk
//! (`scripts/live-code/ios-sim.sh`); a phone cannot, so hostd watches it for the phone.
//!
//! `scripts/live-code/ios-device.sh patch` (through `patch.py`, which signs the patch with the
//! Mac's Apple Development identity) moves each patch into the live folder,
//! `CMUX_MOBILE_LIVE_CODE_DIR` or `~/Library/Caches/cmux-live-code/ios-device`. The `live-code`
//! service streams each new entry to the phone, in name order:
//!
//! - one data frame of JSON `{"name","bytes","sha256"}` (a `*.dylib` patch; `*.rollback` and
//!   `*.rollback-all` undo requests have `bytes` 0 and no body);
//! - then exactly `bytes` raw bytes in frames of at most [`CHUNK`].
//!
//! What was in the folder when the channel opened belongs to an earlier run, maybe of an older
//! build, and is never sent (the app's engine does the same with its own folder). Each data frame
//! the phone sends back is one line of its live code log (what it applied or refused, and its
//! redraws); hostd appends it to `live-code.log` in the folder, so the script reads the phone's
//! answer exactly as `ios-sim.sh` reads the simulator app's.
//!
//! hostd checks nothing about the code itself: the phone loads a patch only in a DEBUG cmux Dev
//! build, only when it is signed by the app's own team, and iOS maps only code signed that way.
//! Machines are never offered the service (`peer.rs`); phones need to be paired, as for every
//! service.

use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use sha2::{Digest, Sha256};

use crate::services::Refusal;

/// One body frame (the link's writers split at 16 KiB anyway).
pub const CHUNK: usize = 64 * 1024;
/// The largest patch sent; a patch of a few edited files is well under 1 MiB.
pub const MAX_PATCH_BYTES: u64 = 64 << 20;
/// How often the folder is listed while a phone listens: one `readdir` of a small folder.
pub const POLL: Duration = Duration::from_millis(100);
/// The longest log line kept from the phone.
pub const MAX_LINE: usize = 4096;

/// The live folder: `CMUX_MOBILE_LIVE_CODE_DIR`, else `~/Library/Caches/cmux-live-code/ios-device`.
/// Every build of the Mac app on this computer serves the same one, so the script need not know
/// which build the phone is linked to.
pub fn folder() -> PathBuf {
    if let Some(dir) = std::env::var_os("CMUX_MOBILE_LIVE_CODE_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join("Library/Caches/cmux-live-code/ios-device")
}

/// Whether `name` is an entry the phone takes: a patch or an undo request, not hidden (a hidden
/// name is a file still being written) and a plain file name.
pub fn is_entry(name: &str) -> bool {
    !name.starts_with('.')
        && !name.contains('/')
        && (name.ends_with(".dylib") || name.ends_with(".rollback") || name.ends_with(".rollback-all"))
}

/// The folder's entries, in name order (patch.py names patches by time, so name order is the
/// order they were made). An unreadable or missing folder has none.
pub fn entries(dir: &Path) -> Vec<String> {
    let Ok(read) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut names: Vec<String> = read
        .filter_map(Result::ok)
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| is_entry(n))
        .collect();
    names.sort();
    names
}

/// The entries not seen yet, in name order; each is marked seen.
pub fn fresh(seen: &mut HashSet<String>, names: Vec<String>) -> Vec<String> {
    names.into_iter().filter(|n| seen.insert(n.clone())).collect()
}

/// One entry, ready to send: its header frame and its body (empty for an undo request).
#[derive(Debug, PartialEq, Eq)]
pub struct Entry {
    pub header: String,
    pub body: Vec<u8>,
}

/// Reads `name` from `dir`. A patch is read once, without following a link, and must be a regular
/// file of at most [`MAX_PATCH_BYTES`]; its SHA-256 lets the phone tell a short read.
pub fn read_entry(dir: &Path, name: &str) -> Result<Entry, String> {
    let body = if name.ends_with(".dylib") {
        let path = dir.join(name);
        let meta = std::fs::symlink_metadata(&path).map_err(|e| format!("{name}: {e}"))?;
        if !meta.file_type().is_file() {
            return Err(format!("{name} is not a regular file"));
        }
        if meta.len() > MAX_PATCH_BYTES {
            return Err(format!("{name} is {} bytes, over {MAX_PATCH_BYTES}", meta.len()));
        }
        std::fs::read(&path).map_err(|e| format!("{name}: {e}"))?
    } else {
        Vec::new()
    };
    let digest: String = Sha256::digest(&body).iter().map(|b| format!("{b:02x}")).collect();
    let header = serde_json::json!({ "name": name, "bytes": body.len(), "sha256": digest }).to_string();
    Ok(Entry { header, body })
}

/// One line of the phone's log, as hostd appends it: one line, at most [`MAX_LINE`] bytes, no
/// control characters. None when nothing is left.
pub fn log_line(data: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(data);
    let line: String = text
        .trim_end_matches(['\n', '\r'])
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let mut line = line.trim().to_owned();
    if line.is_empty() {
        return None;
    }
    if line.len() > MAX_LINE {
        let mut end = MAX_LINE;
        while !line.is_char_boundary(end) {
            end -= 1;
        }
        line.truncate(end);
    }
    Some(line)
}

/// Appends `line` to the folder's `live-code.log`.
pub fn append_log(dir: &Path, line: &str) {
    let _ = std::fs::create_dir_all(dir);
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("live-code.log")) {
        let _ = writeln!(file, "{line}");
    }
}

/// The `live-code` service: new entries of the live folder to the phone, the phone's log lines
/// into the folder's log, until the channel or the link closes.
pub async fn serve(sender: &ChannelSender, receiver: ChannelReceiver) -> Result<(), Refusal> {
    serve_folder(&folder(), sender, receiver).await
}

pub(crate) async fn serve_folder(dir: &Path, sender: &ChannelSender, mut receiver: ChannelReceiver) -> Result<(), Refusal> {
    std::fs::create_dir_all(dir).map_err(|e| Refusal::new("io", format!("cannot make the live folder: {e}")))?;
    // What is there now belongs to an earlier run: never sent.
    let mut seen: HashSet<String> = entries(dir).into_iter().collect();
    append_log(dir, &format!("live code: hostd: a phone listens on {}", dir.display()));
    let mut tick = tokio::time::interval(POLL);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            _ = tick.tick() => {
                for name in fresh(&mut seen, entries(dir)) {
                    let entry = match read_entry(dir, &name) {
                        Ok(entry) => entry,
                        Err(why) => {
                            append_log(dir, &format!("live code: hostd: {name} refused: {why}"));
                            continue;
                        }
                    };
                    if sender.send(Bytes::from(entry.header)).await.is_err() {
                        return Ok(());
                    }
                    for chunk in entry.body.chunks(CHUNK) {
                        if sender.send(Bytes::copy_from_slice(chunk)).await.is_err() {
                            return Ok(());
                        }
                    }
                }
            }
            event = receiver.recv() => match event {
                Some(ChannelEvent::Data(data)) => {
                    if let Some(line) = log_line(&data) {
                        append_log(dir, &line);
                    }
                }
                Some(ChannelEvent::Closed(_)) | None => return Ok(()),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_patches_and_undo_requests_are_entries() {
        assert!(is_entry("patch-1-2.dylib"));
        assert!(is_entry("undo-1.rollback"));
        assert!(is_entry("undo-1.rollback-all"));
        assert!(!is_entry(".patch-1-2.dylib"), "a hidden name is still being written");
        assert!(!is_entry("patch-1-2.json"), "a sidecar stays on the Mac");
        assert!(!is_entry("live-code.log"));
        assert!(!is_entry("a/b.dylib"));
    }

    #[test]
    fn entries_are_in_name_order_and_seen_once() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["patch-2.dylib", "patch-1.dylib", ".patch-3.dylib", "patch-1.json", "undo-9.rollback"] {
            std::fs::write(dir.path().join(name), b"x").unwrap();
        }
        std::fs::create_dir(dir.path().join("folder.dylib")).unwrap();
        let mut seen = HashSet::from(["patch-1.dylib".to_owned()]);
        assert_eq!(fresh(&mut seen, entries(dir.path())), vec!["patch-2.dylib", "undo-9.rollback"]);
        assert!(fresh(&mut seen, entries(dir.path())).is_empty());
        std::fs::rename(dir.path().join(".patch-3.dylib"), dir.path().join("patch-3.dylib")).unwrap();
        assert_eq!(fresh(&mut seen, entries(dir.path())), vec!["patch-3.dylib"]);
    }

    #[test]
    fn a_patch_carries_its_size_and_digest() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("p.dylib"), b"abc").unwrap();
        let entry = read_entry(dir.path(), "p.dylib").unwrap();
        assert_eq!(entry.body, b"abc");
        let header: serde_json::Value = serde_json::from_str(&entry.header).unwrap();
        assert_eq!(header["name"], "p.dylib");
        assert_eq!(header["bytes"], 3);
        assert_eq!(header["sha256"], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        std::fs::write(dir.path().join("u.rollback"), b"ignored").unwrap();
        let undo = read_entry(dir.path(), "u.rollback").unwrap();
        assert!(undo.body.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn a_linked_patch_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("real"), b"abc").unwrap();
        std::os::unix::fs::symlink(dir.path().join("real"), dir.path().join("p.dylib")).unwrap();
        assert!(read_entry(dir.path(), "p.dylib").is_err());
    }

    #[test]
    fn a_log_line_is_one_line() {
        assert_eq!(log_line(b"live code: applied p.dylib\n").as_deref(), Some("live code: applied p.dylib"));
        assert_eq!(log_line(b"a\nb\x1b[31m").as_deref(), Some("a b [31m"));
        assert_eq!(log_line(b"  \n"), None);
        assert_eq!(log_line(&vec![b'x'; MAX_LINE + 10]).map(|l| l.len()), Some(MAX_LINE));
    }

    #[test]
    fn the_log_appends() {
        let dir = tempfile::tempdir().unwrap();
        append_log(dir.path(), "one");
        append_log(dir.path(), "two");
        assert_eq!(std::fs::read_to_string(dir.path().join("live-code.log")).unwrap(), "one\ntwo\n");
    }
}
