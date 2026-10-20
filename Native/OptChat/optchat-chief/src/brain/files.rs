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

/// Largest file read for a turn: the owner's per-file cap (any type).
pub const MAX_FILE_BYTES: u64 = cmux_conversation::MAX_ATTACHMENT_BYTES;

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

/// Non-owner files are named in the turn without downloading their bytes to
/// the owner's Mac. The owner can re-send one to authorize materialization.
pub fn unread_files(message: &Message) -> Vec<TurnFile> {
    message
        .parts
        .iter()
        .filter_map(|part| {
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
            (!mime_type.starts_with("image/")).then(|| TurnFile {
                hash: hash.clone(),
                name: name.clone(),
                mime_type: mime_type.clone(),
                byte_count: *byte_count,
                path: None,
                note: Some("not downloaded: the owner did not send it".into()),
            })
        })
        .collect()
}

/// One file part read whole from the owner and written to
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
    if *byte_count > MAX_FILE_BYTES {
        file.note = Some(format!("over {MAX_FILE_BYTES} bytes"));
        return Some(file);
    }
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
    use base64::Engine as _;
    if !cmux_conversation::is_sha256(hash) {
        return Err("bad hash".into());
    }
    let folder = root.join(hash);
    let path = folder.join(file_name(name));
    if std::fs::metadata(&path).is_ok_and(|m| m.is_file() && m.len() == byte_count) {
        return Ok(path);
    }
    let data = port
        .attachment(conversation, hash, "original", byte_count)
        .map_err(|e| format!("reading it failed: {e}"))?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data.as_bytes())
        .map_err(|e| format!("bad base64: {e}"))?;
    drop(data);
    create_private_dir(&folder).map_err(|e| format!("making its folder failed: {e}"))?;
    write_private(&path, &bytes).map_err(|e| format!("writing it failed: {e}"))?;
    Ok(path)
}

fn create_private_dir(folder: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(folder)
}

/// Writes through a temp file and renames, so a reader never sees half a file.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    let temp = path.with_file_name(format!(".incoming-{}", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut out = options.open(&temp)?;
    out.write_all(bytes)?;
    out.sync_all()?;
    std::fs::rename(&temp, path)
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
    use base64::Engine as _;
    use cmux_conversation::{Change, Op, Summary};
    use std::collections::BTreeMap;

    use crate::daemon::OpError;

    #[derive(Default)]
    struct Owner {
        files: BTreeMap<String, Vec<u8>>,
        reads: usize,
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
        fn attachment(
            &mut self,
            _: &str,
            hash: &str,
            variant: &str,
            _: u64,
        ) -> Result<String, OpError> {
            assert_eq!(variant, "original");
            self.reads += 1;
            self.files
                .get(hash)
                .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                .ok_or_else(|| OpError::Rejected("unknown_attachment".into()))
        }
    }

    fn part(hash: char, name: &str, mime: &str, bytes: u64) -> Part {
        Part::Attachment {
            hash: hash.to_string().repeat(64),
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
        owner.files.insert("a".repeat(64), page.clone());
        let file = read_file(
            &mut owner,
            "c1",
            &part('a', "index.html", "text/plain", page.len() as u64),
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
            &part('a', "index.html", "text/plain", page.len() as u64),
            &root,
        )
        .unwrap();
        assert_eq!(owner.reads, 1);
    }

    #[test]
    fn a_binary_and_a_dotfile_keep_their_names() {
        let root = temp_root();
        let mut owner = Owner::default();
        owner.files.insert("b".repeat(64), vec![0, 1, 2, 0xff]);
        owner.files.insert("c".repeat(64), b"export A=1\n".to_vec());
        let binary = read_file(
            &mut owner,
            "c1",
            &part('b', "state.sqlite", "application/octet-stream", 4),
            &root,
        )
        .unwrap();
        assert_eq!(binary.path.unwrap().file_name().unwrap(), "state.sqlite");
        let dotfile = read_file(
            &mut owner,
            "c1",
            &part('c', ".zshrc", "text/plain", 11),
            &root,
        )
        .unwrap();
        assert_eq!(dotfile.path.unwrap().file_name().unwrap(), ".zshrc");
    }

    #[test]
    fn images_are_not_files_and_a_missing_file_says_why() {
        let root = temp_root();
        let mut owner = Owner::default();
        assert!(!is_file_part(&part('d', "a.png", "image/png", 10)));
        assert!(
            read_file(
                &mut owner,
                "c1",
                &part('d', "a.png", "image/png", 10),
                &root
            )
            .is_none()
        );
        let missing = read_file(
            &mut owner,
            "c1",
            &part('e', "notes.pdf", "application/pdf", 10),
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
            logged_text("look", &[file.clone()]),
            "look\n[file sha256:ffffffffffff \"Makefile\" 3 bytes text/plain at /tmp/x/Makefile]"
        );
        assert_eq!(
            logged_text("  ", &[file]),
            "[file sha256:ffffffffffff \"Makefile\" 3 bytes text/plain at /tmp/x/Makefile]"
        );
    }
}
