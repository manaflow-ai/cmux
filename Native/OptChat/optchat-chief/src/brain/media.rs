//! Files the Chief sends through the explicit `send(attachments:)` tool. The
//! preview thread uploads each one as an attachment record, then removes the
//! generated Markdown image syntax from the posted text. Ordinary reply
//! Markdown never opens a local path.

use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use cmux_conversation::Part;

use crate::daemon::PreviewPort;

/// The largest file the Chief sends (the owner's limit is 100 MB; one upload holds it in memory).
pub const MAX_MEDIA_BYTES: u64 = 50_000_000;

/// One local file an explicit `send` call names.
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

/// The owner's type of any file the Chief attaches with `send` (send.rs):
/// its picture or video type (shown inline), else a file type by extension,
/// else `application/octet-stream`.
pub fn attachment_type(path: &Path) -> &'static str {
    if let Some(t) = media_type(path) {
        return t;
    }
    let extension = path
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    match extension.as_str() {
        "pdf" => "application/pdf",
        "txt" | "log" => "text/plain",
        "md" | "markdown" => "text/markdown",
        "csv" => "text/csv",
        "json" => "application/json",
        "html" | "htm" => "text/html",
        "zip" => "application/zip",
        "gz" | "tgz" => "application/gzip",
        _ => "application/octet-stream",
    }
}

/// The local path an explicit attachment target names:
/// `/abs`, `~/rel`, or `file:///abs`, in `<...>` or not.
pub(super) fn local_path(target: &str, home: Option<&Path>) -> Option<PathBuf> {
    let target = target.trim();
    let target = target
        .strip_prefix('<')
        .and_then(|t| t.strip_suffix('>'))
        .unwrap_or(target);
    let target = target.strip_prefix("file://").unwrap_or(target);
    if let Some(rest) = target.strip_prefix("~/") {
        return Some(home?.join(rest));
    }
    target.starts_with('/').then(|| PathBuf::from(target))
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
/// descriptor-relative `openat` so a path swap cannot redirect the read.
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
        let home = Path::new("/Users/me");
        assert_eq!(
            local_path("/a/b.png", Some(home)),
            Some(PathBuf::from("/a/b.png"))
        );
        assert_eq!(
            local_path("<~/a b.mp4>", Some(home)),
            Some(PathBuf::from("/Users/me/a b.mp4"))
        );
        assert_eq!(
            local_path("file:///x.mov", Some(home)),
            Some(PathBuf::from("/x.mov"))
        );
        assert_eq!(local_path("https://e.com/x.png", Some(home)), None);
        assert_eq!(local_path("x.png", Some(home)), None);
    }

    #[test]
    fn only_picture_and_video_types_are_media() {
        assert_eq!(media_type(Path::new("/a.PNG")), Some("image/png"));
        assert_eq!(media_type(Path::new("/a.mov")), Some("video/quicktime"));
        assert_eq!(media_type(Path::new("/a.svg")), None);
        assert_eq!(media_type(Path::new("/a.html")), None);
    }
}
