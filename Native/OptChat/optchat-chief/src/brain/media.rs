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
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
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

/// The private folder a turn may attach files from. Its name is a log id, so a
/// later turn cannot reuse a path a previous prompt named.
pub fn turn_outbox(session_dir: &Path, first: u64) -> PathBuf {
    session_dir
        .join(".cmux-media")
        .join(format!("turn-{first}"))
}

/// Makes this turn's outbox owner-only, refusing an unexpected non-directory
/// or symlink. None keeps media attachment disabled for the turn.
pub fn prepare_turn_outbox(session_dir: &Path, first: u64) -> Option<PathBuf> {
    let base = session_dir.join(".cmux-media");
    let turn = turn_outbox(session_dir, first);
    for path in [&base, &turn] {
        if let Ok(meta) = std::fs::symlink_metadata(path)
            && (!meta.file_type().is_dir() || meta.file_type().is_symlink())
        {
            return None;
        }
        if std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
            .is_err()
        {
            return None;
        }
        if std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).is_err() {
            return None;
        }
    }
    Some(turn)
}

/// The local path an explicit attachment or Markdown target names:
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
        let Some(path) = local_path(&reply[target_start..target_end], None) else {
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
            let mut file = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&media.path)?;
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
