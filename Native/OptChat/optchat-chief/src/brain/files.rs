//! Files of a turn (Lawrence 2026-10-20: any file attaches, "index.html"
//! included). A human message's `attachment` parts that are not images
//! (text of any name as `text/plain`, PDFs, archives, any binary as
//! `application/octet-stream`) are read from the conversation owner and
//! written under the Chief home's `attachments/<hash>/<name>`, so the turn's
//! agent opens them with its own tools. The user line names each file: its
//! SHA-256, name, size, type and where it is on this Mac, never the bytes.

use std::path::{Path, PathBuf};

use cmux_conversation::{Message, Part};

use crate::daemon::ConversationPort;

/// One non-image file of a turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnFile {
    pub hash: String,
    pub name: String,
    pub mime_type: String,
    pub byte_count: u64,
    /// Where the bytes are on this Mac; None when they could not be read
    /// or written (`note` says why).
    pub path: Option<PathBuf>,
    pub note: Option<String>,
}

impl TurnFile {
    /// The log's (and the turn's) reference:
    /// `[file sha256:<12 hex> "name" 1234 bytes type at /path]`.
    pub fn reference(&self) -> String {
        let place = match (&self.path, &self.note) {
            (Some(path), _) => format!(" at {}", path.display()),
            (None, Some(note)) => format!(", not saved: {note}"),
            (None, None) => ", not saved".to_owned(),
        };
        format!(
            "[file sha256:{} \"{}\" {} bytes {}{place}]",
            super::images::short(&self.hash),
            self.name,
            self.byte_count,
            self.mime_type
        )
    }
}

/// True when the part is an attachment the turn reads as a file (not an image).
pub fn is_file_part(part: &Part) -> bool {
    matches!(part, Part::Attachment { mime_type, .. } if !mime_type.starts_with("image/"))
}

/// The non-image attachment parts of `message`, each saved under `root`
/// (see [`read_file`]).
pub fn read_files(
    port: &mut dyn ConversationPort,
    message: &Message,
    root: &Path,
) -> Vec<TurnFile> {
    message
        .parts
        .iter()
        .filter(|part| is_file_part(part))
        .filter_map(|part| read_file(port, &message.conversation, part, root))
        .collect()
}

/// One file part streamed from the owner and written to
/// `<root>/<hash>/<name>` (owner-only folder and file). An existing copy of
/// the same bytes is reused. Never silently dropped: a failure keeps the
/// reference with a note.
pub fn read_file(
    port: &mut dyn ConversationPort,
    conversation: &str,
    part: &Part,
    root: &Path,
) -> Option<TurnFile> {
    let Part::Attachment {
        hash,
        name,
        mime_type,
        byte_count,
        ..
    } = part
    else {
        return None;
    };
    if mime_type.starts_with("image/") {
        return None;
    }
    let mut file = TurnFile {
        hash: hash.clone(),
        name: name.clone(),
        mime_type: mime_type.clone(),
        byte_count: *byte_count,
        path: None,
        note: None,
    };
    match save(port, conversation, hash, name, *byte_count, root) {
        Ok(path) => file.path = Some(path),
        Err(e) => file.note = Some(e),
    }
    Some(file)
}

/// A name that is one file in a folder: the owner's name rules already
/// forbid separators and control characters; `.` and `..` cannot reach
/// here, but a leading dot stays (a dotfile keeps its name).
fn file_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c == '/' || c == '\\' || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        "attachment".into()
    } else {
        cleaned
    }
}

fn save(
    port: &mut dyn ConversationPort,
    conversation: &str,
    hash: &str,
    name: &str,
    byte_count: u64,
    root: &Path,
) -> Result<PathBuf, String> {
    use sha2::{Digest, Sha256};
    if !cmux_conversation::is_sha256(hash) {
        return Err("bad hash".into());
    }
    let folder = root.join(hash);
    let path = folder.join(file_name(name));
    if std::fs::metadata(&path).is_ok_and(|m| m.is_file() && m.len() == byte_count) {
        return Ok(path);
    }
    create_private_dir(&folder).map_err(|e| format!("making its folder failed: {e}"))?;
    let mut incoming = IncomingFile::new(&path).map_err(|e| format!("writing it failed: {e}"))?;
    let mut sink = VerifiedWriter {
        out: &mut incoming.file,
        hash: Sha256::new(),
        remaining: byte_count,
    };
    port.attachment_into(conversation, hash, "original", byte_count, &mut sink)
        .map_err(|e| format!("reading it failed: {e}"))?;
    if sink.remaining != 0 || format!("{:x}", sink.hash.finalize()) != hash {
        return Err("attachment size or hash mismatch".into());
    }
    incoming
        .file
        .sync_all()
        .map_err(|e| format!("writing it failed: {e}"))?;
    std::fs::rename(&incoming.path, &path).map_err(|e| format!("saving it failed: {e}"))?;
    Ok(path)
}

struct VerifiedWriter<'a> {
    out: &'a mut std::fs::File,
    hash: sha2::Sha256,
    remaining: u64,
}

impl std::io::Write for VerifiedWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        use sha2::Digest as _;
        if bytes.len() as u64 > self.remaining {
            return Err(std::io::Error::other("attachment exceeds declared length"));
        }
        let count = self.out.write(bytes)?;
        self.hash.update(&bytes[..count]);
        self.remaining -= count as u64;
        Ok(count)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.out.flush()
    }
}

/// Exclusive creation avoids clobbering another transfer; all error paths
/// remove their own temporary file. Rename exposes only verified bytes.
struct IncomingFile {
    path: PathBuf,
    file: std::fs::File,
}

impl IncomingFile {
    fn new(path: &Path) -> std::io::Result<Self> {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = path.with_file_name(format!(
            ".incoming-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let file = options.open(&path)?;
        Ok(Self { path, file })
    }
}

impl Drop for IncomingFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn create_private_dir(folder: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(folder)
}

/// The user line with one reference per file appended, each on its own line.
pub fn logged_text(text: &str, files: &[TurnFile]) -> String {
    let references: Vec<String> = files.iter().map(TurnFile::reference).collect();
    match (text.trim().is_empty(), references.is_empty()) {
        (_, true) => text.to_owned(),
        (true, false) => references.join("\n"),
        (false, false) => format!("{text}\n{}", references.join("\n")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_conversation::{Change, Op, Summary};
    use sha2::{Digest, Sha256};
    use std::collections::BTreeMap;

    use crate::daemon::OpError;

    #[derive(Default)]
    struct Owner {
        files: BTreeMap<String, Vec<u8>>,
        reads: usize,
        generated_bytes: Option<u64>,
        interrupt: bool,
    }

    impl ConversationPort for Owner {
        fn snapshot(&mut self, _: &str, _: u32) -> Result<(Summary, Vec<Message>), OpError> {
            unreachable!()
        }
        fn history(&mut self, _: &str, _: u64, _: u32) -> Result<Vec<Message>, OpError> {
            unreachable!()
        }
        fn op(&mut self, _: &str, _: &str, _: &Op) -> Result<Option<Change>, OpError> {
            unreachable!()
        }
        fn typing(&mut self, _: &str, _: bool) -> Result<(), OpError> {
            unreachable!()
        }
        fn draft(&mut self, _: &str, _: &crate::draft::Draft) -> Result<(), OpError> {
            unreachable!()
        }
        fn attachment_into(
            &mut self,
            _: &str,
            hash: &str,
            variant: &str,
            _: u64,
            out: &mut dyn std::io::Write,
        ) -> Result<(), OpError> {
            assert_eq!(variant, "original");
            self.reads += 1;
            if let Some(mut remaining) = self.generated_bytes {
                let chunk = [42; 64 * 1024];
                while remaining > 0 {
                    let count = remaining.min(chunk.len() as u64) as usize;
                    out.write_all(&chunk[..count])
                        .map_err(|e| OpError::Transport(e.to_string()))?;
                    remaining -= count as u64;
                    if self.interrupt {
                        return Err(OpError::Transport("disconnected".into()));
                    }
                }
                return Ok(());
            }
            let bytes = self
                .files
                .get(hash)
                .ok_or_else(|| OpError::Rejected("unknown_attachment".into()))?;
            for chunk in bytes.chunks(7) {
                out.write_all(chunk)
                    .map_err(|e| OpError::Transport(e.to_string()))?;
            }
            Ok(())
        }
    }

    fn part(hash: &str, name: &str, mime: &str, bytes: u64) -> Part {
        Part::Attachment {
            hash: hash.into(),
            name: name.into(),
            mime_type: mime.into(),
            byte_count: bytes,
            width: None,
            height: None,
            duration_ms: None,
            poster: None,
            preview: None,
        }
    }

    fn temp_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "optchat-files-{}-{}",
            std::process::id(),
            rand_suffix()
        ));
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    fn rand_suffix() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    }

    #[test]
    fn an_html_page_reaches_the_turn_as_a_saved_file() {
        let root = temp_root();
        let page = b"<!doctype html><p>hi</p>\n".to_vec();
        let mut owner = Owner::default();
        let hash = format!("{:x}", Sha256::digest(&page));
        owner.files.insert(hash.clone(), page.clone());
        let file = read_file(
            &mut owner,
            "c1",
            &part(&hash, "index.html", "text/plain", page.len() as u64),
            &root,
        )
        .unwrap();
        let path = file.path.clone().expect("saved");
        assert_eq!(path.file_name().unwrap(), "index.html");
        assert_eq!(std::fs::read(&path).unwrap(), page);
        let reference = file.reference();
        assert!(
            reference.contains("\"index.html\" 25 bytes text/plain at /"),
            "{reference}"
        );
        // The same bytes again: the copy is reused, nothing is read.
        read_file(
            &mut owner,
            "c1",
            &part(&hash, "index.html", "text/plain", page.len() as u64),
            &root,
        )
        .unwrap();
        assert_eq!(owner.reads, 1);
    }

    #[test]
    fn a_binary_and_a_dotfile_keep_their_names() {
        let root = temp_root();
        let mut owner = Owner::default();
        let binary_hash = format!("{:x}", Sha256::digest([0, 1, 2, 0xff]));
        let dotfile_hash = format!("{:x}", Sha256::digest(b"export A=1\n"));
        owner.files.insert(binary_hash.clone(), vec![0, 1, 2, 0xff]);
        owner
            .files
            .insert(dotfile_hash.clone(), b"export A=1\n".to_vec());
        let binary = read_file(
            &mut owner,
            "c1",
            &part(&binary_hash, "state.sqlite", "application/octet-stream", 4),
            &root,
        )
        .unwrap();
        assert_eq!(binary.path.unwrap().file_name().unwrap(), "state.sqlite");
        let dotfile = read_file(
            &mut owner,
            "c1",
            &part(&dotfile_hash, ".zshrc", "text/plain", 11),
            &root,
        )
        .unwrap();
        assert_eq!(dotfile.path.unwrap().file_name().unwrap(), ".zshrc");
    }

    #[test]
    fn images_are_not_files_and_a_missing_file_says_why() {
        let root = temp_root();
        let mut owner = Owner::default();
        assert!(!is_file_part(&part(
            &"d".repeat(64),
            "a.png",
            "image/png",
            10
        )));
        assert!(
            read_file(
                &mut owner,
                "c1",
                &part(&"d".repeat(64), "a.png", "image/png", 10),
                &root
            )
            .is_none()
        );
        let missing = read_file(
            &mut owner,
            "c1",
            &part(&"e".repeat(64), "notes.pdf", "application/pdf", 10),
            &root,
        )
        .unwrap();
        assert!(missing.path.is_none());
        assert!(
            missing.reference().contains("not saved: reading it failed"),
            "{}",
            missing.reference()
        );
    }

    #[test]
    fn a_multichunk_original_streams_without_the_aggregate_api() {
        let root = tempfile::tempdir().unwrap();
        let byte_count = 9 * 1024 * 1024 + 17;
        let chunk = [42; 64 * 1024];
        let mut digest = Sha256::new();
        let mut remaining = byte_count;
        while remaining > 0 {
            let count = remaining.min(chunk.len() as u64) as usize;
            digest.update(&chunk[..count]);
            remaining -= count as u64;
        }
        let hash = format!("{:x}", digest.finalize());
        let mut owner = Owner {
            generated_bytes: Some(byte_count),
            ..Owner::default()
        };
        let saved = read_file(
            &mut owner,
            "c1",
            &part(&hash, "archive.bin", "application/octet-stream", byte_count),
            root.path(),
        )
        .unwrap();
        let path = saved.path.expect("streamed file");
        assert_eq!(std::fs::metadata(&path).unwrap().len(), byte_count);
        let mut input = std::fs::File::open(&path).unwrap();
        let mut actual_hash = Sha256::new();
        std::io::copy(&mut input, &mut actual_hash).unwrap();
        assert_eq!(format!("{:x}", actual_hash.finalize()), hash);
        assert_eq!(
            std::fs::read_dir(path.parent().unwrap()).unwrap().count(),
            1
        );
    }

    #[test]
    fn an_original_above_the_former_cap_reaches_the_stream_and_cleans_up_on_failure() {
        let root = tempfile::tempdir().unwrap();
        let mut owner = Owner {
            generated_bytes: Some(100_000_001),
            interrupt: true,
            ..Owner::default()
        };
        let hash = "a".repeat(64);
        let saved = read_file(
            &mut owner,
            "c1",
            &part(&hash, "large.bin", "application/octet-stream", 100_000_001),
            root.path(),
        )
        .unwrap();
        assert_eq!(owner.reads, 1);
        assert!(saved.path.is_none());
        assert!(saved.note.unwrap().contains("disconnected"));
        assert_eq!(
            std::fs::read_dir(root.path().join(hash)).unwrap().count(),
            0
        );
    }

    #[test]
    fn interrupted_or_invalid_originals_leave_no_file_or_temporary_bytes() {
        for (declared, interrupt) in [
            (100_000, false),
            (200_000, false),
            (150_000, false),
            (150_000, true),
        ] {
            let root = tempfile::tempdir().unwrap();
            let mut owner = Owner {
                generated_bytes: Some(150_000),
                interrupt,
                ..Owner::default()
            };
            // Incorrect hash also exercises validation after a complete transfer.
            let hash = "a".repeat(64);
            let saved = read_file(
                &mut owner,
                "c1",
                &part(&hash, "archive.bin", "application/octet-stream", declared),
                root.path(),
            )
            .unwrap();
            assert!(saved.path.is_none());
            assert!(saved.note.is_some());
            assert_eq!(
                std::fs::read_dir(root.path().join(hash)).unwrap().count(),
                0
            );
        }
    }

    #[test]
    fn the_user_line_lists_each_file() {
        let file = TurnFile {
            hash: "f".repeat(64),
            name: "Makefile".into(),
            mime_type: "text/plain".into(),
            byte_count: 3,
            path: Some(PathBuf::from("/tmp/x/Makefile")),
            note: None,
        };
        assert_eq!(
            logged_text("look", std::slice::from_ref(&file)),
            "look\n[file sha256:ffffffffffff \"Makefile\" 3 bytes text/plain at /tmp/x/Makefile]"
        );
        assert_eq!(
            logged_text("  ", &[file]),
            "[file sha256:ffffffffffff \"Makefile\" 3 bytes text/plain at /tmp/x/Makefile]"
        );
    }
}
