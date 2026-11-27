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
//!
//! The git repositories in a projected folder (its own, or clones in folders below it) are named
//! with their branch and last commit ([`checkouts`]): each is the person's own checkout as it is
//! on the Mac now, so an old commit is their old checkout, never a stale copy (issue 57201: an
//! agent on a folder of clones read one on a two-month-old branch as "a stale mirror" and cloned
//! the repository again).

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
    let found = match (&projection, &git) {
        (Some(_), Some(root)) => checkouts(root),
        (Some(_), None) => checkouts(path),
        (None, _) => Vec::new(),
    };
    describe_found(path, projection, git, &found)
}

/// [`describe_with`] once the projection and the checkouts in it are read.
fn describe_found(
    path: &Path,
    projection: Option<(PathBuf, Option<String>)>,
    git: Option<PathBuf>,
    found: &[Checkout],
) -> Value {
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
    let mut summary = summary;
    if projection.is_some() && !found.is_empty() {
        answer["repositories"] = json!(found.iter().map(Checkout::to_json).collect::<Vec<_>>());
        let listed: Vec<String> = found.iter().map(Checkout::line).collect();
        summary.push_str(&format!(
            " Its git {}: {}. Each is the person's own checkout exactly as it is on their Mac now, \
             not a cached or out-of-date copy: an old branch or commit date means they have not \
             updated that checkout, not that this folder is stale. To work on newer code, fetch \
             or check out a branch in that repository (or ask the person), instead of cloning it \
             again.",
            if found.len() == 1 { "repository" } else { "repositories" },
            listed.join("; "),
        ));
    }
    answer["summary"] = json!(summary);
    answer
}

/// The most repositories [`checkouts`] names.
const MAX_CHECKOUTS: usize = 16;
/// How deep below the folder [`checkouts`] looks (as the machine's swap does).
const MAX_DEPTH: usize = 3;
/// Folders [`checkouts`] never looks in: build output and package caches.
const NOT_CLONES: [&str; 6] = ["node_modules", "target", ".build", "DerivedData", "Pods", "vendor"];

/// One git repository of a projected folder: where, its branch, its last commit.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Checkout {
    path: PathBuf,
    /// None when detached.
    branch: Option<String>,
    /// The commit's committer date, `YYYY-MM-DD`; None on a branch with no commit.
    date: Option<String>,
    /// The commit's short id.
    commit: Option<String>,
}

impl Checkout {
    fn line(&self) -> String {
        let branch =
            self.branch.as_deref().map_or("detached HEAD".to_owned(), |b| format!("branch {b}"));
        match (&self.commit, &self.date) {
            (Some(commit), Some(date)) => {
                format!("{} on {branch}, last commit {commit} of {date}", self.path.display())
            }
            _ => format!("{} on {branch}, no commit yet", self.path.display()),
        }
    }

    fn to_json(&self) -> Value {
        json!({"path": self.path, "branch": self.branch, "commit": self.commit,
               "commit_date": self.date, "mac_checkout": true})
    }
}

/// The git repositories at or below `root`: `root` itself when it is one, else every folder
/// holding a `.git` at most [`MAX_DEPTH`] down, never inside one, a hidden folder or one of
/// [`NOT_CLONES`]; at most [`MAX_CHECKOUTS`], shallowest first.
fn checkouts(root: &Path) -> Vec<Checkout> {
    repository_paths(root).into_iter().map(|path| read_checkout(&path)).collect()
}

fn repository_paths(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut level = vec![root.to_path_buf()];
    for depth in 0..=MAX_DEPTH {
        let mut next = Vec::new();
        for dir in level {
            if dir.join(".git").exists() {
                found.push(dir);
                if found.len() == MAX_CHECKOUTS {
                    return found;
                }
                continue;
            }
            if depth == MAX_DEPTH {
                continue;
            }
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            let mut names: Vec<String> = entries
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
                .filter_map(|entry| entry.file_name().into_string().ok())
                .filter(|name| !name.starts_with('.') && !NOT_CLONES.contains(&name.as_str()))
                .collect();
            names.sort();
            next.extend(names.into_iter().map(|name| dir.join(name)));
        }
        level = next;
    }
    found
}

fn read_checkout(path: &Path) -> Checkout {
    let git = |args: &[&str]| {
        std::process::Command::new("git")
            .arg("-C")
            .arg(path)
            .args(args)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()
            .filter(|out| out.status.success())
            .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
            .filter(|text| !text.is_empty())
    };
    let branch = git(&["symbolic-ref", "--quiet", "--short", "HEAD"]);
    let (commit, date) = git(&["log", "-1", "--format=%h %cs"])
        .and_then(|line| line.split_once(' ').map(|(c, d)| (c.to_owned(), d.to_owned())))
        .map_or((None, None), |(c, d)| (Some(c), Some(d)));
    Checkout { path: path.to_path_buf(), branch, date, commit }
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
