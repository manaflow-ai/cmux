//! `this_folder` of the Cloud repository tools ([`crate::cloud_repo_mcp`]): what a folder on this
//! Cloud machine is, read from the machine itself, so the agent says it truthfully (Leo,
//! 2026-11-25, on a Cloud chat started on an empty folder whose agent said nothing comes back to
//! the Mac: "and then like on an empty folder cloud whatever im not sure").
//!
//! A folder a chat was started on from the person's Mac is a projection (RFD 0007): a FUSE mount
//! whose mount-table source is `cmux-projection`, then `:` and the Mac folder percent-encoded
//! (`cmux_tui_core::projection::fsname_for`). Its edits stay on the machine, over the Mac's
//! files, until the person brings them back; empty or not, git or not. Anything else is the
//! machine's own folder.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The mount-table source every projection starts with (`cmux_tui_core::projection::FSNAME`).
const FSNAME: &str = "cmux-projection";

/// What `this_folder` answers for `path`, read from this machine's mount table.
pub fn describe(path: &str) -> Value {
    let given = PathBuf::from(path);
    let resolved = std::fs::canonicalize(&given).unwrap_or(given);
    let mountinfo = std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    describe_with(&resolved, &mountinfo, git_root(&resolved))
}

/// [`describe`] over a mount table and the folder's git root, as read.
fn describe_with(path: &Path, mountinfo: &str, git: Option<PathBuf>) -> Value {
    let projection = projection_of(path, mountinfo);
    let git_root = git.map(|root| root.to_string_lossy().into_owned());
    let mut answer = json!({
        "path": path,
        "projected": projection.is_some(),
        "git": git_root.is_some(),
        "git_root": git_root,
    });
    let summary = match &projection {
        Some((mount, mac)) => {
            let source = match mac {
                Some(mac) => format!("the folder {mac} on the person's Mac"),
                None => "a folder on the person's Mac".to_owned(),
            };
            answer["mount_point"] = json!(mount);
            answer["mac_folder"] = json!(mac);
            answer["edits_reach_mac"] = json!("on_bring_back");
            format!(
                "{} is a live projection of {source}{}: every file there reads here, fetched from the Mac \
                 on first use. What you write stays on this machine, over the Mac's files, until the person \
                 brings it back (Bring Back), which applies it to that Mac folder; until then their files \
                 are unchanged. It is {}.",
                path.display(),
                if mount.as_path() == path {
                    String::new()
                } else {
                    format!(" (mounted at {})", mount.display())
                },
                if answer["git"] == json!(true) {
                    "a git repository"
                } else {
                    "not a git repository"
                },
            )
        }
        None => {
            answer["edits_reach_mac"] = json!("never");
            format!(
                "{} is this machine's own folder, not a projection of the person's Mac: its files stay on the \
                 machine until it is deleted, and nothing here is copied to the Mac. It is {}.",
                path.display(),
                if answer["git"] == json!(true) {
                    "a git repository: push to keep work anywhere else"
                } else {
                    "not a git repository"
                },
            )
        }
    };
    answer["summary"] = json!(summary);
    answer
}

/// The projection mount holding `path` (the deepest mount at or above it), and the Mac folder
/// its source names. None when that mount is no projection.
fn projection_of(path: &Path, mountinfo: &str) -> Option<(PathBuf, Option<String>)> {
    let mut best: Option<(PathBuf, String, String)> = None;
    for line in mountinfo.lines() {
        // `ID PARENT MAJ:MIN ROOT MOUNT_POINT OPTIONS [OPTIONAL...] - FSTYPE SOURCE SUPER`
        let Some((before, after)) = line.split_once(" - ") else { continue };
        let Some(mount) = before.split(' ').nth(4).map(unescape) else { continue };
        let mut fields = after.split(' ');
        let (Some(kind), Some(source)) = (fields.next(), fields.next()) else { continue };
        let mount = PathBuf::from(mount);
        if path.starts_with(&mount)
            && best.as_ref().is_none_or(|(deepest, ..)| {
                mount.components().count() >= deepest.components().count()
            })
        {
            best = Some((mount, kind.to_owned(), unescape(source)));
        }
    }
    let (mount, kind, source) = best?;
    if !kind.starts_with("fuse") {
        return None;
    }
    let mac = match source.strip_prefix(FSNAME)? {
        "" => None,
        rest => Some(percent_decode(rest.strip_prefix(':')?)?),
    };
    Some((mount, mac))
}

/// mountinfo's octal escapes (`\040` a space, `\011` a tab, `\012` a newline, `\134` a backslash).
fn unescape(field: &str) -> String {
    let bytes = field.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let octal = bytes
            .get(i + 1..i + 4)
            .filter(|d| bytes[i] == b'\\' && d.iter().all(|b| (b'0'..=b'7').contains(b)));
        if let Some(digits) = octal {
            out.push(digits.iter().fold(0u8, |n, d| n.wrapping_mul(8).wrapping_add(d - b'0')));
            i += 4;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `fsname_for`'s percent-encoding undone; None for a malformed one.
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The git work tree `path` is in: the nearest folder at or above it holding `.git`.
fn git_root(path: &Path) -> Option<PathBuf> {
    path.ancestors().find(|dir| dir.join(".git").exists()).map(Path::to_path_buf)
}

#[cfg(test)]
#[path = "cloud_folder_tests.rs"]
mod tests;
