//! Cited memory, checked against the code (RFD 0158 §13, harness magic `citedMemory`, off unless
//! `agents.harnessMagic.citedMemory.enabled` is `true`; `ACPMUX_HM_CITEDMEMORY` `0` or `1`
//! overrides it). Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take
//! breaks unless I put in fleet wide pauses, esp when this is stuff that materially improves the
//! app".
//!
//! A fact a chat learned may cite the code it is about, `path/to/file.rs:123`. This first piece
//! checks those citations where the memory inbox offers facts (`hub/memory_inbox.rs`): each
//! cited file is looked up in the chat's folder (the path as written, then the shortest path
//! ending in it, then its file name when only one file has that name) and its line must still be
//! in the file. A fact whose citations all point at no file or past its end is about code that is
//! not there, and is not offered; the offer record carries every citation's verdict. A cited name
//! that more than one file has, or a folder too big to index in time, is `unknown`, never stale.
//!
//! On this VM, the handbook memory (`~/.cache/agent-memory/hq`, 267 docs) cites 2,649 lines;
//! checked against cmux, cmuxterm-hq and leo-workspace, 34 point past the end of their file and
//! up to 316 at a file none of the three has (`scripts/measure/cited-memory-staleness.py`).
//!
//! Next: the same check where a memory is used (the folder's learned section at a session's
//! start), and decay of facts no turn has used.

use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The feature's name in its setting, kill switch and counters.
pub(crate) const FEATURE: &str = "citedMemory";

/// The setting that turns the feature on.
pub(crate) const SETTING_ENABLED: &str = "agents.harnessMagic.citedMemory.enabled";
/// The kill switch: `0` turns it off, `1` on, whatever the setting says.
pub(crate) const KILL_ENV: &str = "ACPMUX_HM_CITEDMEMORY";

/// The most files a folder's index holds; a bigger folder is indexed this far, and a name not
/// found in a cut-short index is `unknown`.
const MAX_FILES: usize = 200_000;
/// The longest an index walk takes.
const WALK_BOUND: Duration = Duration::from_secs(2);
/// The largest file whose lines are counted.
const MAX_COUNTED: u64 = 16 * 1024 * 1024;
/// Folders never walked.
const SKIP_DIRS: &[&str] = &[".git", "target", "node_modules", ".build", "DerivedData", "dist"];
/// The extensions a citation may name.
const EXTS: &[&str] = &["rs", "py", "ts", "tsx", "js", "mjs", "swift", "sh", "toml", "yml", "yaml"];

/// Whether the feature is on for `doc` and the switch's value `env`.
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    match env.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("0" | "false" | "off" | "no") => return false,
        Some("1" | "true" | "on" | "yes") => return true,
        _ => {}
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED)).and_then(|v| v.as_bool())
        == Some(true)
}

/// Whether the feature is on now.
pub(crate) fn enabled() -> bool {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    enabled_with(doc.as_ref(), std::env::var(KILL_ENV).ok().as_deref())
}

/// One `path:line` a fact cites.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Citation {
    pub path: String,
    pub line: u32,
}

/// The `path:line` citations in `text`: a path with at least one `/` and a known extension,
/// then `:` and a line number. A leading `./` is dropped.
pub fn citations(text: &str) -> Vec<Citation> {
    let mut out = Vec::new();
    let bytes = text.as_bytes();
    let path_byte = |b: u8| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-' | b'/');
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b':' {
            i += 1;
            continue;
        }
        let mut start = i;
        while start > 0 && path_byte(bytes[start - 1]) {
            start -= 1;
        }
        let mut end = i + 1;
        while end < bytes.len() && bytes[end].is_ascii_digit() {
            end += 1;
        }
        let path = &text[start..i];
        let digits = &text[i + 1..end];
        i = end.max(i + 1);
        if digits.is_empty() || !path.contains('/') {
            continue;
        }
        let path = path.strip_prefix("./").unwrap_or(path);
        let Some((_, ext)) = path.rsplit_once('.') else { continue };
        if !EXTS.contains(&ext) || path.starts_with('/') || path.split('/').any(|p| p == "..") {
            continue;
        }
        let Ok(line) = digits.parse::<u32>() else { continue };
        if line == 0 {
            continue;
        }
        let c = Citation { path: path.to_owned(), line };
        if !out.contains(&c) {
            out.push(c);
        }
    }
    out
}

/// What a citation's check found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// The file is there and has the line.
    Ok,
    /// The file is there and ends before the line (its line count).
    LineGone(usize),
    /// No file in the folder is the one cited.
    FileGone,
    /// More than one file could be the one cited, or the index was cut short.
    Unknown,
}

impl Verdict {
    /// The verdict's name in an offer record.
    pub fn name(&self) -> &'static str {
        match self {
            Verdict::Ok => "ok",
            Verdict::LineGone(_) => "lineGone",
            Verdict::FileGone => "fileGone",
            Verdict::Unknown => "unknown",
        }
    }

    /// Whether the citation is about code that is not there.
    pub fn stale(&self) -> bool {
        matches!(self, Verdict::LineGone(_) | Verdict::FileGone)
    }
}

/// A folder's files by every path suffix (`a/b/c.rs`, `b/c.rs`, `c.rs`), relative to it.
pub struct Index {
    root: PathBuf,
    by_suffix: HashMap<String, Vec<String>>,
    complete: bool,
}

impl Index {
    /// The index of `root`, walked up to [`MAX_FILES`] files and [`WALK_BOUND`].
    pub fn of(root: &Path) -> Self {
        let deadline = Instant::now() + WALK_BOUND;
        let mut files = Vec::new();
        let mut stack = vec![PathBuf::new()];
        let mut complete = true;
        'walk: while let Some(rel) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(root.join(&rel)) else { continue };
            for entry in entries.flatten() {
                if files.len() >= MAX_FILES || Instant::now() > deadline {
                    complete = false;
                    break 'walk;
                }
                let Ok(kind) = entry.file_type() else { continue };
                let name = entry.file_name();
                let Some(name) = name.to_str() else { continue };
                let child = rel.join(name);
                if kind.is_dir() {
                    if !SKIP_DIRS.contains(&name) {
                        stack.push(child);
                    }
                } else if kind.is_file()
                    && let Some(s) = child.to_str()
                {
                    files.push(s.replace('\\', "/"));
                }
            }
        }
        Self::from_files(root, files, complete)
    }

    /// The index of `files` (relative paths) under `root`.
    pub fn from_files(root: &Path, files: Vec<String>, complete: bool) -> Self {
        let mut by_suffix: HashMap<String, Vec<String>> = HashMap::new();
        for f in files {
            let mut at = 0;
            loop {
                by_suffix.entry(f[at..].to_owned()).or_default().push(f.clone());
                match f[at..].find('/') {
                    Some(i) => at += i + 1,
                    None => break,
                }
            }
        }
        Self { root: root.to_owned(), by_suffix, complete }
    }

    /// The one file `path` names: the path as written, else the only file ending in it, else
    /// the only file with its name. `Err(true)` when more than one could be it or the index was
    /// cut short; `Err(false)` when none is.
    fn resolve(&self, path: &str) -> Result<&str, bool> {
        let name = path.rsplit('/').next().unwrap_or(path);
        for key in [path, name] {
            match self.by_suffix.get(key).map(Vec::as_slice) {
                Some([one]) => return Ok(one),
                Some(many) if many.iter().any(|f| f == path) => return Ok(path_in(many, path)),
                Some([_, _, ..]) => return Err(true),
                _ => {}
            }
        }
        Err(!self.complete)
    }

    /// `c` checked against the folder, with `lines` counting a file's lines.
    pub fn check_with(&self, c: &Citation, lines: &dyn Fn(&Path) -> Option<usize>) -> Verdict {
        match self.resolve(&c.path) {
            Ok(rel) => match lines(&self.root.join(rel)) {
                Some(n) if n >= c.line as usize => Verdict::Ok,
                Some(n) => Verdict::LineGone(n),
                None => Verdict::Unknown,
            },
            Err(true) => Verdict::Unknown,
            Err(false) => Verdict::FileGone,
        }
    }

    /// `c` checked against the folder's files on disk.
    pub fn check(&self, c: &Citation) -> Verdict {
        self.check_with(c, &line_count)
    }
}

/// `path` from `many`, which holds it.
fn path_in<'a>(many: &'a [String], path: &str) -> &'a str {
    many.iter().find(|f| *f == path).map_or("", String::as_str)
}

/// The lines of the file at `path`, None when it cannot be read or is too big.
fn line_count(path: &Path) -> Option<usize> {
    let meta = std::fs::metadata(path).ok()?;
    if meta.len() > MAX_COUNTED {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    if bytes.is_empty() {
        return Some(0);
    }
    let newlines = bytecount(&bytes);
    Some(if bytes.last() == Some(&b'\n') { newlines } else { newlines + 1 })
}

fn bytecount(bytes: &[u8]) -> usize {
    bytes.iter().filter(|b| **b == b'\n').count()
}

/// `facts` checked against `index`: the facts to offer (the ones with no citation, or with one
/// that is not stale), and a record of every checked citation and every dropped fact.
pub fn screen(facts: Vec<String>, index: &Index) -> (Vec<String>, Value) {
    let mut kept = Vec::new();
    let mut checked = Vec::new();
    let mut dropped = Vec::new();
    for fact in facts {
        let cites = citations(&fact);
        if cites.is_empty() {
            kept.push(fact);
            continue;
        }
        let verdicts: Vec<Verdict> = cites.iter().map(|c| index.check(c)).collect();
        for (c, v) in cites.iter().zip(&verdicts) {
            checked.push(json!({"path": c.path, "line": c.line, "verdict": v.name()}));
        }
        if verdicts.iter().all(Verdict::stale) {
            dropped.push(fact);
        } else {
            kept.push(fact);
        }
    }
    (kept, json!({"citations": checked, "dropped": dropped}))
}

#[cfg(test)]
#[path = "cited_memory_tests.rs"]
mod tests;
