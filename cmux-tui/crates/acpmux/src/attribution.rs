//! Which chat wrote a line (`_acpmux/attribution`): when a turn ends, the lines its successful edit
//! tool calls left in each file are recorded with the chat, the turn, its model and the first line
//! of its prompt, keyed by the file's worktree, its path there and the `gitHead` the turn ended on
//! (`hub/turn_git.rs`). A diff asks for the lines it shows ([`Index::candidates`], then [`verify`]
//! against the file as it is now) and gets who wrote them, newest first, older writers after.
//! A line no recorded turn wrote gets nothing, and so does one asked about at another head or whose
//! text has changed since: never a guess.
//!
//! Where a line is: an edit's diff block names its file and its new text, not where that text went.
//! At the turn's end the file is read once and the new text found in it ([`locate`]); text found
//! nowhere, or in more than one place, is an unknown location and is left out. Only the lines the
//! edit changed count: the lines its old and new text share at their start and end (the context an
//! edit tool carries) are dropped. A failed call, a call still running and a call that is not an
//! edit write nothing.
//!
//! The index is built once per turn and bounded ([`MAX_PER_CHAT`] ranges a chat, [`MAX_TOTAL`] in
//! all, oldest first out); a hover reads one file's entries and that one file, never a log. Earlier
//! entries of a file a turn edits again are moved to where their text now is when it is in one
//! place, and dropped when it is not ([`Index::record`]).
//! Leo, 2026-11-08: "go think of things/look at things, esp valuable things that people would
//! think \"wow this is awesome\"".

use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};

/// The most ranges one chat keeps; its oldest go first.
pub const MAX_PER_CHAT: usize = 2000;
/// The most ranges the index keeps for every chat together.
pub const MAX_TOTAL: usize = 50_000;
/// A file larger than this is neither indexed nor checked.
pub const MAX_FILE_BYTES: u64 = 4 << 20;
/// The most tool calls one turn notes; later ones in the same turn are not attributed.
pub const MAX_CALLS_PER_TURN: usize = 256;
/// The most ranges one query asks about.
pub const MAX_QUERY_RANGES: usize = 64;
/// The most bytes of shown text one query carries (`texts`).
const MAX_QUERY_TEXT_BYTES: usize = 1 << 20;
/// An edit's new text past this is not noted (a generated file written whole).
const MAX_TEXT_BYTES: usize = 512 << 10;
/// How long the prompt's first line may be in an answer.
const MAX_PROMPT_CHARS: usize = 200;
/// The most lines one read of a file compares to find where its ranges are ([`Places`]); a range
/// left unchecked past it is dropped, never kept on a guess.
const MAX_PLACE_WORK: usize = 4_000_000;

/// One file an edit tool call wrote, from its diff block.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditBlock {
    /// Absolute and canonical (`path_canon.rs`).
    pub path: String,
    /// The text it replaced; none for a new file, or for a file written over whose old text the
    /// call did not carry.
    pub old_text: Option<String>,
    pub new_text: String,
    /// The block is part of its file, not the whole of it (`_meta.acpmux.fragment`).
    pub fragment: bool,
}

/// A tool call of the running turn, as its updates said.
#[derive(Clone, Debug, Default)]
struct EditCall {
    /// Its kind: an edit (or delete or move), something else, or not said yet.
    edits: Option<bool>,
    status: Option<String>,
    blocks: Vec<EditBlock>,
}

/// The running turn's tool calls that carry a diff, by call id (`Session::turn_edits`).
#[derive(Debug, Default)]
pub struct TurnEdits {
    calls: HashMap<String, EditCall>,
    order: Vec<String>,
}

impl TurnEdits {
    /// Notes a `tool_call` or `tool_call_update`; `canon` makes a path absolute and canonical. A
    /// later update's diff blocks replace the call's earlier ones; its kind and status update them.
    pub fn absorb(&mut self, update: &Value, canon: impl Fn(&str) -> Option<String>) {
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
        if !self.calls.contains_key(id) {
            if self.order.len() >= MAX_CALLS_PER_TURN {
                return;
            }
            self.order.push(id.to_owned());
        }
        let call = self.calls.entry(id.to_owned()).or_default();
        match update.get("kind").and_then(Value::as_str) {
            Some("edit" | "delete" | "move") => call.edits = Some(true),
            Some(_) => call.edits = Some(false),
            None => {}
        }
        if let Some(status) = update.get("status").and_then(Value::as_str) {
            call.status = Some(status.to_owned());
        }
        let blocks: Vec<EditBlock> = update
            .get("content")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("diff"))
            .filter_map(|b| {
                let path = b.get("path").and_then(Value::as_str)?;
                let new_text = b.get("newText").and_then(Value::as_str)?;
                if new_text.len() > MAX_TEXT_BYTES {
                    return None;
                }
                Some(EditBlock {
                    path: canon(path)?,
                    old_text: b.get("oldText").and_then(Value::as_str).map(str::to_owned),
                    new_text: new_text.to_owned(),
                    fragment: b.pointer("/_meta/acpmux/fragment") == Some(&Value::Bool(true)),
                })
            })
            .collect();
        if !blocks.is_empty() {
            call.blocks = blocks;
        }
    }

    /// The diff blocks of the calls that completed as edits (a call that never said its kind but
    /// carried a diff counts), in the order the calls began, and forgets every call.
    pub fn take_written(&mut self) -> Vec<EditBlock> {
        let mut calls = std::mem::take(&mut self.calls);
        std::mem::take(&mut self.order)
            .into_iter()
            .filter_map(|id| calls.remove(&id))
            .filter(|c| c.status.as_deref() == Some("completed") && c.edits != Some(false))
            .flat_map(|c| c.blocks)
            .collect()
    }
}

/// FNV-1a over the lines `start..=end` (1-based) of `lines`, each followed by a newline; none when
/// the range is not in the file.
fn range_hash(lines: &[&str], start: u32, end: u32) -> Option<u64> {
    let (from, to) = (start.checked_sub(1)? as usize, end as usize);
    if from >= to {
        return None;
    }
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for line in lines.get(from..to)? {
        for byte in line.bytes().chain(std::iter::once(b'\n')) {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
    }
    Some(hash)
}

/// A file's lines as git counts them: `\n`-separated, a trailing `\r` kept off.
pub fn file_lines(text: &str) -> Vec<&str> {
    text.lines().collect()
}

/// The lines `block` added to `text` (the file at the turn's end): runs of consecutive lines,
/// `(start, end)`, 1-based and inclusive, from a line diff of its old text against its new. Empty
/// when its new text is in the file nowhere or in more than one place, when it added no line (a
/// pure deletion), or when it is a fragment of a file written over without its old text (its
/// lines there are not known to be new).
pub fn locate(text: &str, block: &EditBlock) -> Vec<(u32, u32)> {
    let new = block.new_text.as_str();
    if new.trim().is_empty() || (block.fragment && block.old_text.is_none()) {
        return vec![];
    }
    let mut found = text.match_indices(new).map(|(at, _)| at);
    let Some(at) = found.next() else { return vec![] };
    if found.next().is_some() {
        return vec![];
    }
    let first = text.bytes().take(at).filter(|b| *b == b'\n').count();
    let new_lines: Vec<&str> = new.lines().collect();
    let old_lines: Vec<&str> =
        block.old_text.as_deref().map(|o| o.lines().collect()).unwrap_or_default();
    let mut ranges: Vec<(u32, u32)> = vec![];
    for index in added_lines(&old_lines, &new_lines) {
        let Ok(line) = u32::try_from(first + index + 1) else { break };
        match ranges.last_mut() {
            Some(last) if last.1 + 1 == line => last.1 = line,
            _ => ranges.push((line, line)),
        }
    }
    ranges
}

/// The most cells a line diff ([`added_lines`]) fills; past it, the lines between the first and
/// last changed one all count as added.
const MAX_DIFF_CELLS: usize = 1 << 20;

/// The indexes of `new`'s lines that are not in a longest common subsequence with `old`: the lines
/// an edit added or changed. The lines the two share at their start and end are trimmed first.
fn added_lines(old: &[&str], new: &[&str]) -> Vec<usize> {
    let prefix = old.iter().zip(new).take_while(|(a, b)| a == b).count();
    let (old, new) = (old.get(prefix..).unwrap_or_default(), new.get(prefix..).unwrap_or_default());
    let suffix = old.iter().rev().zip(new.iter().rev()).take_while(|(a, b)| a == b).count();
    let o = old.get(..old.len() - suffix).unwrap_or_default();
    let n = new.get(..new.len() - suffix).unwrap_or_default();
    if o.is_empty() || n.is_empty() || o.len().saturating_mul(n.len()) > MAX_DIFF_CELLS {
        return (prefix..prefix + n.len()).collect();
    }
    // lcs[i][j]: the longest common subsequence of o[i..] and n[j..]; out of range reads 0.
    let w = n.len() + 1;
    let mut lcs = vec![0u32; (o.len() + 1) * w];
    let at = |lcs: &[u32], i: usize, j: usize| lcs.get(i * w + j).copied().unwrap_or(0);
    for (i, a) in o.iter().enumerate().rev() {
        for (j, b) in n.iter().enumerate().rev() {
            let cell = if a == b {
                at(&lcs, i + 1, j + 1) + 1
            } else {
                at(&lcs, i + 1, j).max(at(&lcs, i, j + 1))
            };
            if let Some(slot) = lcs.get_mut(i * w + j) {
                *slot = cell;
            }
        }
    }
    let (mut i, mut j, mut out) = (0, 0, vec![]);
    while let Some(b) = n.get(j) {
        match o.get(i) {
            Some(a) if a == b => {
                i += 1;
                j += 1;
            }
            Some(_) if at(&lcs, i + 1, j) >= at(&lcs, i, j + 1) => i += 1,
            _ => {
                out.push(prefix + j);
                j += 1;
            }
        }
    }
    out
}

/// Who wrote a range: the chat and its turn.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Author {
    pub session_id: String,
    pub turn_id: String,
    /// The `gitHead` the turn ended on.
    pub head: String,
    pub model: Option<String>,
    pub title: Option<String>,
    /// The turn's prompt, its first line only.
    pub prompt: Option<String>,
    /// When the turn ended, Unix ms.
    pub at: u64,
}

impl Author {
    /// `prompt`'s first non-empty line, cut at [`MAX_PROMPT_CHARS`].
    pub fn first_line(prompt: &str) -> Option<String> {
        let line = prompt.lines().map(str::trim).find(|l| !l.is_empty())?;
        Some(match line.char_indices().nth(MAX_PROMPT_CHARS) {
            Some((cut, _)) => format!("{}…", line.get(..cut).unwrap_or(line)),
            None => line.to_owned(),
        })
    }
}

/// One range a turn wrote, as an answer gives it.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Written {
    pub start: u32,
    pub end: u32,
    pub session_id: String,
    pub turn_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    pub at: u64,
    #[serde(skip)]
    head: String,
    #[serde(skip)]
    hash: u64,
    /// The hash of its first line alone ([`line_hash`]), where [`Places`] starts looking.
    #[serde(skip)]
    first: u64,
    /// Its order of recording: a later turn's range has a larger one.
    #[serde(skip)]
    seq: u64,
}

type FileKey = (String, String);

/// Every chat's recorded ranges, by worktree and path in it.
#[derive(Debug, Default)]
pub struct Index {
    files: HashMap<FileKey, Vec<Written>>,
    /// Each chat's ranges, oldest first, for its bound.
    per_chat: HashMap<String, VecDeque<(FileKey, u64)>>,
    /// Every range, oldest first, for the total bound.
    all: VecDeque<(FileKey, u64)>,
    next: u64,
}

impl Index {
    /// Records the ranges `author` wrote in `path` of the worktree `root`, with `text` the file
    /// now. The file's earlier ranges whose text is no longer where it was move to where it is now
    /// when that is one place, and go when it is not.
    pub fn record(
        &mut self,
        root: &str,
        path: &str,
        text: &str,
        ranges: &[(u32, u32)],
        author: &Author,
    ) {
        let places = Places::new(text);
        let lines = &places.lines;
        let key: FileKey = (root.to_owned(), path.to_owned());
        if let Some(entries) = self.files.get_mut(&key) {
            let mut budget = MAX_PLACE_WORK;
            let mut gone = HashSet::new();
            for entry in entries.iter_mut() {
                match places.only(entry, &mut budget) {
                    Some(start) => {
                        entry.end = start + (entry.end - entry.start);
                        entry.start = start;
                    }
                    None => {
                        gone.insert(entry.seq);
                    }
                }
            }
            entries.retain(|e| !gone.contains(&e.seq));
            if entries.is_empty() {
                self.files.remove(&key);
            }
            self.forget(&gone);
        }
        for &(start, end) in ranges {
            let Some(hash) = range_hash(lines, start, end) else { continue };
            let Some(first) = lines.get(start.saturating_sub(1) as usize).map(|l| line_hash(l))
            else {
                continue;
            };
            let seq = self.next;
            self.next += 1;
            self.files.entry(key.clone()).or_default().push(Written {
                start,
                end,
                session_id: author.session_id.clone(),
                turn_id: author.turn_id.clone(),
                model: author.model.clone(),
                title: author.title.clone(),
                prompt: author.prompt.clone(),
                at: author.at,
                head: author.head.clone(),
                hash,
                first,
                seq,
            });
            self.per_chat
                .entry(author.session_id.clone())
                .or_default()
                .push_back((key.clone(), seq));
            self.all.push_back((key.clone(), seq));
        }
        self.bound(&author.session_id);
    }

    /// Drops `seqs` from the bookkeeping lists (their entries are gone already).
    fn forget(&mut self, seqs: &HashSet<u64>) {
        if seqs.is_empty() {
            return;
        }
        self.all.retain(|(_, s)| !seqs.contains(s));
        for list in self.per_chat.values_mut() {
            list.retain(|(_, s)| !seqs.contains(s));
        }
        self.per_chat.retain(|_, list| !list.is_empty());
    }

    /// Keeps `session`'s ranges and everyone's under their bounds, oldest out.
    fn bound(&mut self, session: &str) {
        let mut out = vec![];
        if let Some(list) = self.per_chat.get_mut(session) {
            let over = list.len().saturating_sub(MAX_PER_CHAT);
            out.extend(list.drain(..over));
        }
        let over = self.all.len().saturating_sub(MAX_TOTAL + out.len());
        let oldest: Vec<(FileKey, u64)> = self
            .all
            .iter()
            .filter(|(_, s)| !out.iter().any(|(_, o)| o == s))
            .take(over)
            .cloned()
            .collect();
        out.extend(oldest);
        for (key, seq) in &out {
            if let Some(entries) = self.files.get_mut(key) {
                entries.retain(|e| e.seq != *seq);
                if entries.is_empty() {
                    self.files.remove(key);
                }
            }
        }
        let seqs: HashSet<u64> = out.into_iter().map(|(_, s)| s).collect();
        self.forget(&seqs);
    }

    /// Whether the index holds any range of `path` in `root`: only such a file is read for a query.
    pub fn knows(&self, root: &str, path: &str) -> bool {
        self.files.contains_key(&(root.to_owned(), path.to_owned()))
    }

    /// The recorded ranges of `path` in `root` at `head` that overlap one of `ranges`, newest first.
    /// Not yet checked against the file: [`verify`] does that.
    pub fn candidates(
        &self,
        root: &str,
        head: &str,
        path: &str,
        ranges: &[(u32, u32)],
    ) -> Vec<Written> {
        let Some(entries) = self.files.get(&(root.to_owned(), path.to_owned())) else {
            return vec![];
        };
        let mut out: Vec<Written> = entries
            .iter()
            .filter(|e| e.head == head)
            .filter(|e| ranges.iter().any(|&(s, t)| e.start <= t && s <= e.end))
            .cloned()
            .collect();
        out.sort_by_key(|w| std::cmp::Reverse(w.seq));
        out
    }
}

/// FNV-1a of one line.
fn line_hash(line: &str) -> u64 {
    range_hash(&[line], 1, 1).unwrap_or_default()
}

/// A file's lines, and where each line's text is, to find where a range's text is now.
pub struct Places<'a> {
    lines: Vec<&'a str>,
    /// The 0-based indexes of the lines with each [`line_hash`].
    starts: HashMap<u64, Vec<usize>>,
}

impl<'a> Places<'a> {
    pub fn new(text: &'a str) -> Self {
        let lines = file_lines(text);
        let mut starts: HashMap<u64, Vec<usize>> = HashMap::new();
        for (index, line) in lines.iter().enumerate() {
            starts.entry(line_hash(line)).or_default().push(index);
        }
        Places { lines, starts }
    }

    /// Where `entry`'s text is now when that is exactly one place: none when it is nowhere, in more
    /// than one place (a copy of it could be either), or past `budget` line comparisons.
    fn only(&self, entry: &Written, budget: &mut usize) -> Option<u32> {
        let len = entry.end - entry.start + 1;
        let mut found = None;
        for &from in self.starts.get(&entry.first)? {
            *budget = budget.checked_sub(len as usize)?;
            let start = u32::try_from(from + 1).ok()?;
            if range_hash(&self.lines, start, start + len - 1) == Some(entry.hash) {
                if found.is_some() {
                    return None;
                }
                found = Some(start);
            }
        }
        found
    }
}

/// `candidates` whose lines in `text` (the file now) are still the lines their turn wrote, there
/// and nowhere else.
pub fn verify(text: &str, candidates: Vec<Written>) -> Vec<Written> {
    let places = Places::new(text);
    let mut budget = MAX_PLACE_WORK;
    candidates.into_iter().filter(|c| places.only(c, &mut budget) == Some(c.start)).collect()
}

/// A query's `ranges` (`[[start, end], ...]`, 1-based, inclusive), at most [`MAX_QUERY_RANGES`].
pub fn query_ranges(value: Option<&Value>) -> Result<Vec<(u32, u32)>, String> {
    let list = value.and_then(Value::as_array).ok_or("ranges is required")?;
    if list.len() > MAX_QUERY_RANGES {
        return Err(format!("at most {MAX_QUERY_RANGES} ranges"));
    }
    list.iter()
        .map(|r| {
            let pair = r.as_array().filter(|p| p.len() == 2).ok_or("a range is [start, end]")?;
            let n = |v: &Value| v.as_u64().and_then(|n| u32::try_from(n).ok()).filter(|n| *n >= 1);
            match (pair.first().and_then(n), pair.get(1).and_then(n)) {
                (Some(s), Some(e)) if s <= e => Ok((s, e)),
                _ => Err("a range is [start, end], 1-based, start <= end".into()),
            }
        })
        .collect()
}

/// A query's `texts`, beside its `ranges`: the lines the diff shows in each, one string a line.
/// None when the query sends none.
pub fn query_texts(
    value: Option<&Value>,
    ranges: &[(u32, u32)],
) -> Result<Option<Vec<Vec<String>>>, String> {
    let Some(value) = value.filter(|v| !v.is_null()) else { return Ok(None) };
    let list =
        value.as_array().filter(|l| l.len() == ranges.len()).ok_or("texts has one list a range")?;
    let mut bytes = 0;
    let mut out = Vec::with_capacity(list.len());
    for (lines, &(start, end)) in list.iter().zip(ranges) {
        let lines = lines
            .as_array()
            .filter(|l| l.len() as u64 == u64::from(end - start) + 1)
            .ok_or("texts has one string a line of its range")?;
        let mut range = Vec::with_capacity(lines.len());
        for line in lines {
            let line = line.as_str().ok_or("a shown line is a string")?;
            bytes += line.len();
            if bytes > MAX_QUERY_TEXT_BYTES {
                return Err("texts is too long".into());
            }
            range.push(line.to_owned());
        }
        out.push(range);
    }
    Ok(Some(out))
}

/// The `ranges` whose lines in `text` (the file now) are the ones the diff shows (`texts`): a diff
/// of an older turn whose lines were rewritten since asks about lines the file no longer holds,
/// and gets no answer for them rather than the rewriter's.
pub fn shown_ranges(
    text: &str,
    ranges: &[(u32, u32)],
    texts: Option<&[Vec<String>]>,
) -> Vec<(u32, u32)> {
    let Some(texts) = texts else { return ranges.to_vec() };
    let lines = file_lines(text);
    ranges
        .iter()
        .zip(texts)
        .filter(|((start, end), shown)| {
            let (from, to) = (start.saturating_sub(1) as usize, *end as usize);
            lines
                .get(from..to)
                .is_some_and(|got| got.iter().zip(shown.iter()).all(|(a, b)| *a == b.as_str()))
        })
        .map(|(range, _)| *range)
        .collect()
}

/// A query's `path`: relative to its worktree, `/`-separated, with no `.` or `..` part.
pub fn query_path(value: Option<&Value>) -> Result<String, String> {
    let path = value.and_then(Value::as_str).ok_or("path is required")?;
    let ok = !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\\')
        && path.split('/').all(|part| !part.is_empty() && part != "." && part != "..");
    if ok {
        Ok(path.to_owned())
    } else {
        Err("path is relative to root, with no . or .. part".into())
    }
}

#[cfg(test)]
#[path = "attribution_tests.rs"]
mod tests;
