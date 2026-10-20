//! Pictures and videos the Chief sends (the user, 2026-10-20: "are you able to send me
//! screenshots and videos?"). In a reply, a Markdown image of a local file,
//! `![shot](/Users/me/shot.png)` or `![clip](<~/demo clip.mp4>)`, and a link to one,
//! `[run.mov](/tmp/run.mov)`, name a file to send. The preview thread (previews.rs) uploads
//! each one as an attachment record of the conversation and the reply goes out with an
//! `attachment` part per file after its text; the image syntax leaves the text (the picture
//! shows instead), a link stays. Only an existing regular file of a type the owner takes as a
//! picture or video (png, jpeg, gif, webp, heic, mp4, mov), at most [`MAX_MEDIA_BYTES`], is
//! read; anything else stays text.

use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use cmux_conversation::Part;

use crate::daemon::PreviewPort;

/// The largest file the Chief sends (the owner's limit is 100 MB; one upload holds it in memory).
pub const MAX_MEDIA_BYTES: u64 = 50_000_000;

/// One local file a reply names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaRef {
    pub path: PathBuf,
    pub mime_type: &'static str,
    /// The byte range of `![alt](path)` in the reply (it leaves the text); None for a link.
    pub image_syntax: Option<std::ops::Range<usize>>,
}

/// The owner's type of a picture or video file, by its extension.
pub fn media_type(path: &Path) -> Option<&'static str> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(match extension.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        _ => return None,
    })
}

/// Makes a fresh, unguessable owner-only outbox for one turn. Existing names
/// are never reused after a history rollback.
pub fn prepare_turn_outbox(session_dir: &Path) -> Option<PathBuf> {
    prepare_turn_outbox_result(session_dir).ok()
}

fn prepare_turn_outbox_result(session_dir: &Path) -> std::io::Result<PathBuf> {
    use ring::rand::SecureRandom as _;
    // Resolve trusted system aliases such as macOS `/var -> /private/var`
    // once. Every attacker-controlled component below the session stays
    // descriptor-relative and O_NOFOLLOW.
    let session_dir = std::fs::canonicalize(session_dir)?;
    let session = open_directory_chain(&session_dir)?;
    let base_name = c".cmux-media";
    // SAFETY: `session` and `base_name` are valid descriptors/strings. A
    // pre-existing entry is opened below with O_NOFOLLOW before it is used.
    let made = unsafe { libc::mkdirat(session.as_raw_fd(), base_name.as_ptr(), 0o700) };
    if made < 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::AlreadyExists {
            return Err(error);
        }
    }
    let base = open_child_directory(session.as_raw_fd(), base_name)?;
    // SAFETY: `base` is the directory descriptor just opened without
    // following a symlink. A failure leaves media disabled for this turn.
    if unsafe { libc::fchmod(base.as_raw_fd(), 0o700) } < 0 {
        return Err(std::io::Error::last_os_error());
    }

    let random = ring::rand::SystemRandom::new();
    for _ in 0..4 {
        let mut nonce = [0u8; 16];
        random
            .fill(&mut nonce)
            .map_err(|_| std::io::Error::other("secure random generation failed"))?;
        let name = nonce.iter().map(|b| format!("{b:02x}")).collect::<String>();
        let c_name = std::ffi::CString::new(name.as_bytes())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        // SAFETY: `base` and `c_name` are valid; mkdirat creates only a
        // direct child of the verified outbox directory.
        if unsafe { libc::mkdirat(base.as_raw_fd(), c_name.as_ptr(), 0o700) } == 0 {
            return Ok(session_dir.join(".cmux-media").join(name));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::AlreadyExists {
            return Err(error);
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not allocate a unique turn outbox",
    ))
}

/// Removes one generated outbox without following any component. Best effort:
/// attachment delivery must not fail on cleanup.
pub fn cleanup_turn_outbox(path: Option<PathBuf>) {
    let Some(path) = path else { return };
    let Some(parent) = path.parent() else { return };
    let Some(name) = path.file_name() else { return };
    let Ok(parent) = open_directory_chain(parent) else {
        return;
    };
    let Ok(name) = std::ffi::CString::new(name.as_bytes()) else {
        return;
    };
    remove_child(parent.as_raw_fd(), &name, 0);
}

/// A stopped/crashed host owns no live turn outbox. Called only after taking
/// the per-Chief host lock.
pub fn cleanup_stale_outboxes(session_dir: &Path) {
    if let Ok(session_dir) = std::fs::canonicalize(session_dir) {
        cleanup_turn_outbox(Some(session_dir.join(".cmux-media")));
    }
}

/// The absolute local path a Markdown link target names, in `<…>` or not.
fn local_path(target: &str) -> Option<PathBuf> {
    let target = target.trim();
    let target = target
        .strip_prefix('<')
        .and_then(|t| t.strip_suffix('>'))
        .unwrap_or(target);
    let target = target.strip_prefix("file://").unwrap_or(target);
    target.starts_with('/').then(|| PathBuf::from(target))
}

/// The files a reply names that can be sent: direct regular-file children of
/// this turn's outbox, each once, in reply order.
pub fn media_refs(reply: &str, outbox: Option<&Path>) -> Vec<MediaRef> {
    let mut refs: Vec<MediaRef> = Vec::new();
    let bytes = reply.as_bytes();
    let mut at = 0;
    while let Some(found) = reply[at..].find("](") {
        let close_label = at + found;
        let target_start = close_label + 2;
        at = target_start;
        let Some(open_label) = reply[..close_label].rfind('[') else {
            continue;
        };
        if reply[open_label..close_label].contains('\n') {
            continue;
        }
        let target_end = if reply[target_start..].starts_with('<') {
            reply[target_start..]
                .find(">)")
                .map(|e| target_start + e + 1)
        } else {
            reply[target_start..]
                .find([')', '\n'])
                .map(|e| target_start + e)
                .filter(|&e| bytes[e] == b')')
        };
        let Some(target_end) = target_end else {
            continue;
        };
        at = target_end + 1;
        let Some(path) = local_path(&reply[target_start..target_end]) else {
            continue;
        };
        let Some(outbox) = outbox else { continue };
        if path.parent() != Some(outbox) {
            continue;
        }
        let Some(mime_type) = media_type(&path) else {
            continue;
        };
        let sendable = std::fs::symlink_metadata(&path).is_ok_and(|meta| {
            meta.file_type().is_file() && meta.len() > 0 && meta.len() <= MAX_MEDIA_BYTES
        });
        if !sendable || refs.iter().any(|r| r.path == path) {
            continue;
        }
        let image = open_label > 0 && bytes[open_label - 1] == b'!';
        refs.push(MediaRef {
            path,
            mime_type,
            image_syntax: image.then(|| (open_label - 1)..(target_end + 1)),
        });
    }
    refs
}

/// The reply without the image syntax of `sent` files: a line left empty by it goes, the
/// others lose their trailing spaces.
pub fn without_images(reply: &str, sent: &[&MediaRef]) -> String {
    let mut ranges: Vec<std::ops::Range<usize>> =
        sent.iter().filter_map(|r| r.image_syntax.clone()).collect();
    ranges.sort_by_key(|r| r.start);
    let mut lines = Vec::new();
    let mut start = 0;
    for line in reply.split('\n') {
        let end = start + line.len();
        let mut kept = String::new();
        let mut cut = false;
        let mut from = start;
        for range in ranges.iter().filter(|r| r.start >= start && r.end <= end) {
            kept.push_str(&reply[from..range.start]);
            from = range.end;
            cut = true;
        }
        kept.push_str(&reply[from..end]);
        if !(cut && kept.trim().is_empty()) {
            lines.push(if cut {
                kept.trim_end().to_owned()
            } else {
                kept
            });
        }
        start = end + 1;
    }
    lines.join("\n")
}

/// Uploads each file of `refs` to `conversation`: the attachment parts of the ones that went
/// (a failure is logged and leaves that file's text as it was), with the refs they came from.
pub fn upload(
    port: &mut dyn PreviewPort,
    conversation: &str,
    refs: &[MediaRef],
    log: &super::Log,
) -> Vec<(MediaRef, Part)> {
    let mut sent = Vec::new();
    for media in refs {
        let bytes = match (|| {
            let mut file = open_media_file(&media.path)?;
            let meta = file.metadata()?;
            if !meta.file_type().is_file() || meta.len() == 0 || meta.len() > MAX_MEDIA_BYTES {
                return Ok::<_, std::io::Error>(Vec::new());
            }
            let mut bytes = Vec::with_capacity(meta.len() as usize);
            file.read_to_end(&mut bytes)?;
            Ok(bytes)
        })() {
            Ok(bytes) if !bytes.is_empty() && bytes.len() as u64 <= MAX_MEDIA_BYTES => bytes,
            Ok(_) => continue,
            Err(e) => {
                log(&format!(
                    "sending {}: reading it failed: {e}",
                    media.path.display()
                ));
                continue;
            }
        };
        let size = media
            .mime_type
            .starts_with("image/")
            .then(|| {
                image::ImageReader::new(std::io::Cursor::new(&bytes))
                    .with_guessed_format()
                    .ok()?
                    .into_dimensions()
                    .ok()
            })
            .flatten();
        let name = media
            .path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("file")
            .chars()
            .take(255)
            .collect::<String>();
        match port.upload_attachment(
            conversation,
            &bytes,
            media.mime_type,
            &name,
            size.map(|s| s.0),
            size.map(|s| s.1),
        ) {
            Ok(stored) => sent.push((
                media.clone(),
                Part::Attachment {
                    hash: stored.hash,
                    name,
                    mime_type: stored.mime_type,
                    byte_count: stored.byte_count,
                    width: size.map(|s| s.0),
                    height: size.map(|s| s.1),
                    duration_ms: None,
                    poster: None,
                    preview: None,
                },
            )),
            Err(e) => log(&format!(
                "sending {}: the upload failed: {e}",
                media.path.display()
            )),
        }
    }
    sent
}

/// Opens every directory component and then the file with `O_NOFOLLOW`, using
/// descriptor-relative `openat` so swapping an outbox parent to a symlink
/// cannot redirect the read between validation and open.
fn open_media_file(path: &Path) -> std::io::Result<std::fs::File> {
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let directory = open_directory_chain(parent)?;
    let leaf = path
        .file_name()
        .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let leaf = std::ffi::CString::new(leaf.as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    // SAFETY: `directory` is open, `leaf` is NUL-terminated, and flags request
    // a read-only descriptor without following the final component.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            leaf.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: `openat` returned a new owned descriptor.
    Ok(std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) }))
}

/// Deletes a direct child through an already-open parent. Directories are
/// traversed through their descriptors, so a concurrent rename or symlink
/// replacement can at worst leave an entry behind, never redirect deletion.
fn remove_child(parent: RawFd, name: &std::ffi::CStr, depth: usize) {
    match open_child_directory(parent, name) {
        Ok(directory) => {
            if depth < 32 {
                remove_directory_contents(directory.as_raw_fd(), depth + 1);
            }
            drop(directory);
            // SAFETY: this removes only `name` relative to the open parent.
            let _ = unsafe { libc::unlinkat(parent, name.as_ptr(), libc::AT_REMOVEDIR) };
        }
        Err(_) => {
            // SAFETY: unlinkat without AT_REMOVEDIR removes a file/symlink
            // itself and never follows it.
            let _ = unsafe { libc::unlinkat(parent, name.as_ptr(), 0) };
        }
    }
}

fn remove_directory_contents(directory: RawFd, depth: usize) {
    // `fdopendir` takes ownership of its descriptor, so duplicate ours.
    // SAFETY: `directory` is open for the duration of this function.
    let duplicate = unsafe { libc::dup(directory) };
    if duplicate < 0 {
        return;
    }
    // SAFETY: `duplicate` is a newly owned directory descriptor.
    let stream = unsafe { libc::fdopendir(duplicate) };
    if stream.is_null() {
        // SAFETY: fdopendir did not take ownership on failure.
        let _ = unsafe { libc::close(duplicate) };
        return;
    }
    // Cleanup is best effort and must not let an adversarial producer keep the
    // host in an unbounded loop. Anything beyond this cap stays for startup.
    for _ in 0..4096 {
        // SAFETY: `stream` remains live until closed below. readdir's entry
        // is valid until the next readdir call, and d_name is NUL-terminated.
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            break;
        }
        // SAFETY: POSIX guarantees d_name is a NUL-terminated byte array.
        let name = unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()) };
        if matches!(name.to_bytes(), b"." | b"..") {
            continue;
        }
        remove_child(directory, name, depth);
    }
    // SAFETY: `stream` is live and owns `duplicate`.
    let _ = unsafe { libc::closedir(stream) };
}

fn open_child_directory(parent: RawFd, name: &std::ffi::CStr) -> std::io::Result<OwnedFd> {
    // SAFETY: `parent` is open and `name` is NUL-terminated. O_NOFOLLOW
    // rejects a symlink in the child position.
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: openat returned a new owned descriptor.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn open_directory_chain(path: &Path) -> std::io::Result<OwnedFd> {
    if !path.is_absolute() {
        return Err(std::io::Error::from(std::io::ErrorKind::InvalidInput));
    }
    let root = c"/";
    // SAFETY: `root` is a valid C string and the flags have no pointer output.
    let root_fd = unsafe {
        libc::open(
            root.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
    };
    if root_fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: `open` returned a new owned descriptor.
    let mut current = unsafe { OwnedFd::from_raw_fd(root_fd) };
    for component in path.components() {
        use std::path::Component;
        let name = match component {
            Component::RootDir | Component::CurDir => continue,
            Component::Normal(name) => name,
            Component::ParentDir | Component::Prefix(_) => {
                return Err(std::io::Error::from(std::io::ErrorKind::InvalidInput));
            }
        };
        let name = std::ffi::CString::new(name.as_bytes())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        current = open_child_directory(current.as_raw_fd(), &name)?;
    }
    Ok(current)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn targets_resolve_to_local_paths() {
        assert_eq!(local_path("/a/b.png"), Some(PathBuf::from("/a/b.png")));
        assert_eq!(local_path("<~/a b.mp4>"), None);
        assert_eq!(local_path("file:///x.mov"), Some(PathBuf::from("/x.mov")));
        assert_eq!(local_path("https://e.com/x.png"), None);
        assert_eq!(local_path("x.png"), None);
    }

    #[test]
    fn only_picture_and_video_types_are_media() {
        assert_eq!(media_type(Path::new("/a.PNG")), Some("image/png"));
        assert_eq!(media_type(Path::new("/a.mov")), Some("video/quicktime"));
        assert_eq!(media_type(Path::new("/a.svg")), None);
        assert_eq!(media_type(Path::new("/a.html")), None);
    }

    #[test]
    fn security_a_turn_outbox_is_created_under_an_existing_session() {
        let dir = tempfile::tempdir().unwrap();
        let session = dir.path().join("session");
        std::fs::create_dir(&session).unwrap();
        let outbox = prepare_turn_outbox_result(&session).unwrap();
        let session = std::fs::canonicalize(session).unwrap();
        assert_eq!(outbox.parent(), Some(session.join(".cmux-media").as_path()));
        assert!(outbox.is_dir());
        cleanup_turn_outbox(Some(outbox));
    }
}
