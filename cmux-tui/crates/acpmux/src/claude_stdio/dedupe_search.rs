//! What a `Grep` or `Glob` answer depends on, for the dedupe callback (`dedupe.rs`, RFD 0147).
//!
//! Both tools run ripgrep over a directory tree, so a repeat is answered only when nothing in the
//! tree the tool could see has moved. The fingerprint walks a superset of the files the tool
//! reads and stamps every directory (an entry added, removed or renamed changes its directory) and
//! every file whose content or modification time the answer can show. A tree too big for
//! [`MAX_ENTRIES`] or for the caller's deadline gives no fingerprint, and the call runs.
//!
//! The tool's own ripgrep arguments, read from Claude Code 2.1.332 and checked against a fixture
//! (a gitignored file, a hidden file) the same day:
//! - `Grep`: `rg --hidden --no-follow --glob !.git --glob !.svn --glob !.hg --glob !.bzr
//!   --glob !.jj --glob !.sl ...`, ignore files honored. The walk here honors only `.gitignore`
//!   files inside the tree (no parent, global, `.ignore` or `.rgignore` rules), so it sees every
//!   file ripgrep searches and maybe more.
//! - `Glob`: `rg --files --null --glob PATTERN --no-ignore --hidden ... --sort=modified`, so it
//!   lists ignored files and `.git` too and orders by modification time. The walk here ignores
//!   nothing and stamps every directory and every file but the loose objects and packs under a
//!   `.git/objects`, which it stamps only when the pattern can match them (a catch-all `**/*`). Its
//!   other globs are the permission rules' negations, which only narrow.

use std::path::{Path, PathBuf};
use std::time::Instant;

use super::dedupe_shell::stamp;

/// The most entries (directories and files) one fingerprint walks.
const MAX_ENTRIES: usize = 50_000;

/// The directories Claude Code's `Grep` never searches.
const GREP_SKIPS: [&str; 6] = [".git", ".svn", ".hg", ".bzr", ".jj", ".sl"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Tool {
    Grep,
    Glob,
}

impl Tool {
    pub(super) fn name(self) -> &'static str {
        match self {
            Tool::Grep => "Grep",
            Tool::Glob => "Glob",
        }
    }
}

/// One `Grep` or `Glob` call: the tree it reads and, for `Glob`, its pattern.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Search {
    pub tool: Tool,
    pub root: PathBuf,
    pub pattern: Option<String>,
}

/// The search in a hook `tool_input` (`args`) run from `cwd`, when it is one dedupe may answer.
pub(super) fn search(
    tool: &str,
    args: &serde_json::Map<String, serde_json::Value>,
    cwd: &Path,
) -> Option<Search> {
    let tool = match tool {
        "Grep" => Tool::Grep,
        "Glob" => Tool::Glob,
        _ => return None,
    };
    let known: &[&str] = match tool {
        Tool::Grep => &[
            "pattern",
            "path",
            "glob",
            "type",
            "output_mode",
            "-B",
            "-A",
            "-C",
            "context",
            "-n",
            "-i",
            "-o",
            "head_limit",
            "offset",
            "multiline",
        ],
        Tool::Glob => &["pattern", "path"],
    };
    if args.keys().any(|k| !known.contains(&k.as_str())) {
        return None;
    }
    let pattern = args.get("pattern")?.as_str()?;
    if pattern.is_empty() {
        return None;
    }
    let root = match args.get("path") {
        None | Some(serde_json::Value::Null) => cwd.to_path_buf(),
        Some(v) => {
            let p = Path::new(v.as_str()?);
            if p.as_os_str().is_empty() { cwd.to_path_buf() } else { cwd.join(p) }
        }
    };
    if !root.is_absolute() {
        return None;
    }
    let pattern = match tool {
        // An absolute or parent-relative pattern names files outside the walk's view.
        Tool::Glob if pattern.starts_with('/') || pattern.split('/').any(|c| c == "..") => {
            return None;
        }
        Tool::Glob => Some(pattern.to_owned()),
        Tool::Grep => None,
    };
    Some(Search { tool, root, pattern })
}

/// The search's fingerprint: equal fingerprints mean the tool's answer is the same. `None` when
/// it cannot be taken by `deadline` within [`MAX_ENTRIES`].
pub(super) fn fingerprint(s: &Search, deadline: Instant) -> Option<String> {
    let meta = std::fs::symlink_metadata(&s.root).ok()?;
    if meta.is_file() {
        // `Grep` of one file; a `Glob` root must be a directory.
        return (s.tool == Tool::Grep).then(|| stamp(&s.root));
    }
    if !meta.is_dir() {
        return None;
    }
    let objects_match = match &s.pattern {
        Some(p) => matches_objects(&s.root, p)?,
        None => false,
    };
    let mut walk = ignore::WalkBuilder::new(&s.root);
    walk.standard_filters(false).hidden(false).follow_links(false).parents(false);
    if s.tool == Tool::Grep {
        walk.git_ignore(true).require_git(true);
        walk.filter_entry(|e| {
            !(e.depth() > 0
                && e.file_type().is_some_and(|t| t.is_dir())
                && e.file_name().to_str().is_some_and(|n| GREP_SKIPS.contains(&n)))
        });
    }
    let mut parts = Vec::new();
    for (n, entry) in walk.build().enumerate() {
        if n >= MAX_ENTRIES || (n % 256 == 0 && Instant::now() >= deadline) {
            return None;
        }
        // An unreadable directory or a walk error: what the tool sees is unknown.
        let entry = entry.ok()?;
        let path = entry.path();
        let kind = entry.file_type()?;
        if kind.is_dir() {
            parts.push(stamp(path));
            continue;
        }
        if !objects_match && s.tool == Tool::Glob && under_git_objects(&s.root, path) {
            continue;
        }
        if kind.is_symlink() {
            // `stamp` follows it; a link to a directory the tool does not walk (no follow) still
            // gets its own stamp, which is what a listing shows.
            parts.push(format!("{}\n{}", link_stamp(path), stamp(path)));
            continue;
        }
        parts.push(stamp(path));
    }
    Some(parts.join("\n"))
}

/// A symlink's own identity and target.
fn link_stamp(path: &Path) -> String {
    let target = std::fs::read_link(path).map(|t| t.display().to_string()).unwrap_or_default();
    format!("{}@{target}", path.display())
}

/// Whether `path` is under a `.git/objects` directory below `root`.
fn under_git_objects(root: &Path, path: &Path) -> bool {
    let Ok(rel) = path.strip_prefix(root) else { return false };
    let names: Vec<_> = rel.components().map(|c| c.as_os_str()).collect();
    names.windows(2).any(|w| matches!(w, [a, b] if *a == ".git" && *b == "objects"))
}

/// Whether the `Glob` pattern can match a loose object or a pack (ripgrep's own `--glob`
/// semantics); `None` when it does not parse, so the call runs.
fn matches_objects(root: &Path, pattern: &str) -> Option<bool> {
    let mut b = ignore::overrides::OverrideBuilder::new(root);
    b.add(pattern).ok()?;
    let o = b.build().ok()?;
    let probes = [
        ".git/objects/ab/cdef0123456789abcdef0123456789abcdef01",
        ".git/objects/pack/pack-0123456789abcdef0123456789abcdef01234567.pack",
        ".git/objects/pack/pack-0123456789abcdef0123456789abcdef01234567.idx",
        ".git/objects/info/packs",
    ];
    Some(probes.iter().any(|p| !o.matched(root.join(p), false).is_ignore()))
}
