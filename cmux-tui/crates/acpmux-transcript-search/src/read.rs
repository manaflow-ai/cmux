//! Reading the text around a search hit (`acpmux search --show`, the agents' `transcript_read`):
//! the message at one transcript line and the messages next to it, or one turn whole, unescaped,
//! from the index ([`crate::Index`]) and never from the transcript file. Leo, 2026-11-18:
//! "shouldn't you be able to like have better tools for finding stuff?": a hit names a session and
//! a line; this reads what is there.
//!
//! Cost: a read finds its place with a binary search over the file's docs (each probe one rowid
//! seek: a doc's rowid is its file's id in the high 32 bits and its order in the file in the low
//! 32, and the line and turn only grow with that order), then reads the rows it answers with. So a
//! read of a 542 MB transcript costs what a read of a small one does.
//!
//! A read names a session and, for a subagent's transcript, that file's name; never a path. What
//! it returns is bounded: at most [`MAX_AROUND`] messages each side, [`MAX_BYTES`] of text, and a
//! message's text is what the index keeps of it (64 KiB of a prompt or reply, 8 KiB of a tool call
//! or its output, `capped` when that cut it).

use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

use crate::index::{Error, Result};
use crate::parse::{Harness, MAX_MESSAGE_BYTES, MAX_TOOL_BYTES, Role};

/// The text a read returns unless asked for less or more.
pub const DEFAULT_MAX_BYTES: usize = 32 * 1024;
/// The most text one read returns.
pub const MAX_BYTES: usize = 256 * 1024;
/// The most messages (or turns) a read takes on each side.
pub const MAX_AROUND: usize = 50;
/// The most rows one side of a read looks at, tool rows it leaves out included.
const MAX_SCAN: i64 = 4096;

/// Where a read is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum At {
    /// The message (or messages: a line can hold a reply and its tool calls) at this line, from 1.
    Line(u64),
    /// Every message of this turn (1: the first prompt and what answered it).
    Turn(u32),
}

/// One read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadQuery {
    /// The harness session (a Claude Code session, a Codex thread).
    pub session: String,
    /// A subagent's transcript of that session, by its file name (`agent-a1b2`, with or without
    /// `.jsonl`); none: the session's own transcript.
    pub subagent: Option<String>,
    pub at: At,
    /// With [`At::Line`], how many messages before and after it; with [`At::Turn`], how many
    /// turns.
    pub before: usize,
    pub after: usize,
    /// Whether tool calls and their output are in it; the message at a line always is.
    pub tools: bool,
    /// The most text it returns, in bytes.
    pub max_bytes: usize,
}

impl ReadQuery {
    pub fn new(session: impl Into<String>, at: At) -> Self {
        Self {
            session: session.into(),
            subagent: None,
            at,
            before: 0,
            after: 0,
            tools: true,
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }
}

/// One transcript of a session, as the index holds it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileRef {
    pub path: PathBuf,
    /// Its file name without `.jsonl`: what [`ReadQuery::subagent`] names.
    pub name: String,
    pub harness: Harness,
    pub subagent: bool,
    /// The lines and turns read into the index so far.
    pub lines: u64,
    pub turns: u32,
    id: i64,
    docs: i64,
}

/// One message a read returns.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub line: u64,
    pub turn: u32,
    pub at_ms: Option<i64>,
    pub role: Role,
    pub text: String,
    /// The index kept only the start of it ([`MAX_MESSAGE_BYTES`], [`MAX_TOOL_BYTES`]).
    pub capped: bool,
    /// The read's own budget cut it.
    pub cut: bool,
    /// It is at the line (or in the turn) asked for, not around it.
    pub anchor: bool,
}

/// What a read found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Read {
    pub file: FileRef,
    /// Every transcript of the session the index holds (its own and its subagents').
    pub files: Vec<FileRef>,
    /// In transcript order.
    pub messages: Vec<Message>,
    /// Whether the transcript has messages before the first and after the last returned.
    pub more_before: bool,
    pub more_after: bool,
    /// Whether [`ReadQuery::max_bytes`] or the scan bound left messages out.
    pub truncated: bool,
}

/// Why a read found nothing.
#[derive(Debug)]
pub enum ReadError {
    /// No such session, file, line or turn in the index.
    NotFound(String),
    Index(Error),
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound(m) => f.write_str(m),
            Self::Index(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for ReadError {}

impl From<Error> for ReadError {
    fn from(e: Error) -> Self {
        Self::Index(e)
    }
}

impl From<rusqlite::Error> for ReadError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Index(e.into())
    }
}

/// A read-only connection to an index file, beside the [`crate::Index`] that writes it.
pub struct Reader {
    conn: Connection,
}

/// A row a read took: its order in the file, line, turn, time, role, text.
type Row = (i64, u64, u32, Option<i64>, Role, String);

impl Reader {
    /// Opens the index at `path` (made by [`crate::Index::open`]) for reading.
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        conn.busy_timeout(Duration::from_secs(30))?;
        Ok(Self { conn })
    }

    /// The transcripts of harness session `session` the index holds: its own first.
    pub fn files(&self, session: &str) -> Result<Vec<FileRef>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id, path, harness, subagent, seq, line, turn FROM files WHERE session = ?1
             ORDER BY subagent, id",
        )?;
        let rows = stmt.query_map(params![session], |r| {
            let path = PathBuf::from(r.get::<_, String>(1)?);
            let harness: String = r.get(2)?;
            Ok(FileRef {
                name: path
                    .file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                path,
                harness: Harness::parse(&harness).unwrap_or(Harness::Claude),
                subagent: r.get(3)?,
                docs: r.get(4)?,
                lines: r.get::<_, i64>(5)?.max(0) as u64,
                turns: r.get::<_, i64>(6)?.clamp(0, i64::from(u32::MAX)) as u32,
                id: r.get(0)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    /// Reads `q` (see the module docs).
    pub fn read(&self, q: &ReadQuery) -> std::result::Result<Read, ReadError> {
        // One snapshot: a catch-up writing the same file between two probes changes nothing here.
        let tx = self.conn.unchecked_transaction()?;
        let files = self.files(&q.session)?;
        if files.is_empty() {
            return Err(ReadError::NotFound(format!(
                "no transcript of session {} is indexed on this machine",
                q.session
            )));
        }
        let file = pick(&files, q.subagent.as_deref())?.clone();
        let max_bytes = q.max_bytes.clamp(1, MAX_BYTES);
        let before = q.before.min(MAX_AROUND);
        let after = q.after.min(MAX_AROUND);
        let out = match q.at {
            At::Line(line) => self.around_line(&file, line, before, after, q.tools, max_bytes)?,
            At::Turn(turn) => self.turns(&file, turn, before, after, q.tools, max_bytes)?,
        };
        drop(tx);
        let (messages, truncated, first, last) = out;
        Ok(Read {
            more_before: first.is_some_and(|s| s > 1),
            more_after: last.is_some_and(|s| s < file.docs),
            file,
            files,
            messages,
            truncated,
        })
    }

    /// The message at `line` and up to `before` and `after` messages next to it, nearest first
    /// into the budget.
    fn around_line(
        &self,
        file: &FileRef,
        line: u64,
        before: usize,
        after: usize,
        tools: bool,
        max_bytes: usize,
    ) -> std::result::Result<Taken, ReadError> {
        let target = i64::try_from(line).unwrap_or(i64::MAX);
        let Some((start, found)) = self.first_at_least(file, "line", target)? else {
            return Err(ReadError::NotFound(format!(
                "line {line} is past the {} lines indexed of {}",
                file.lines, file.name
            )));
        };
        if found != target {
            return Err(ReadError::NotFound(format!(
                "line {line} of {} holds no message (the next one is at line {found})",
                file.name
            )));
        }
        let end = match self.first_at_least(file, "line", target.saturating_add(1))? {
            Some((next, _)) => next - 1,
            None => file.docs,
        };
        let anchor = self.rows(file, start, end, false, MAX_SCAN)?;
        let mut truncated = (end - start + 1) > MAX_SCAN;
        let keep = |r: &Row| tools || r.4 != Role::Tool;
        let older: Vec<Row> = self
            .rows(file, 1, start - 1, true, MAX_SCAN)?
            .into_iter()
            .filter(keep)
            .take(before)
            .collect();
        let newer: Vec<Row> = self
            .rows(file, end + 1, file.docs, false, MAX_SCAN)?
            .into_iter()
            .filter(keep)
            .take(after)
            .collect();
        let mut budget = Budget::new(max_bytes);
        let mut kept_anchor = Vec::new();
        for row in anchor {
            if budget.left == 0 {
                truncated = true;
                break;
            }
            kept_anchor.push(budget.take_cut(row, true));
        }
        // Nearest first, the next message and then the one before, each whole or not at all.
        let (mut kept_older, mut kept_newer) = (Vec::new(), Vec::new());
        let mut nearest = Vec::with_capacity(older.len() + newer.len());
        let (mut older, mut newer) = (older.into_iter(), newer.into_iter());
        loop {
            let (next, prev) = (newer.next(), older.next());
            if next.is_none() && prev.is_none() {
                break;
            }
            nearest.extend(next);
            nearest.extend(prev);
        }
        for row in nearest {
            if !budget.fits(&row) {
                truncated = true;
                break;
            }
            let into = if row.0 > end { &mut kept_newer } else { &mut kept_older };
            into.push(budget.take_cut(row, false));
        }
        kept_older.reverse();
        let mut messages = kept_older;
        messages.extend(kept_anchor);
        messages.extend(kept_newer);
        Ok(finish(messages, truncated))
    }

    /// Turns `turn - before` to `turn + after`, in order, as far as the budget goes.
    fn turns(
        &self,
        file: &FileRef,
        turn: u32,
        before: usize,
        after: usize,
        tools: bool,
        max_bytes: usize,
    ) -> std::result::Result<Taken, ReadError> {
        let Some((anchor_start, found)) = self.first_at_least(file, "turn", i64::from(turn))?
        else {
            return Err(ReadError::NotFound(format!(
                "turn {turn} is past the {} turns indexed of {}",
                file.turns, file.name
            )));
        };
        if found != i64::from(turn) {
            return Err(ReadError::NotFound(format!(
                "turn {turn} of {} holds no message",
                file.name
            )));
        }
        let anchor_end = match self.first_at_least(file, "turn", i64::from(turn) + 1)? {
            Some((next, _)) => next - 1,
            None => file.docs,
        };
        let from_turn = i64::from(turn).saturating_sub(before as i64).max(0);
        let start = match self.first_at_least(file, "turn", from_turn)? {
            Some((s, _)) => s.min(anchor_start),
            None => anchor_start,
        };
        let end = match self.first_at_least(file, "turn", i64::from(turn) + 1 + after as i64)? {
            Some((next, _)) => (next - 1).max(anchor_end),
            None => file.docs,
        };
        let rows = self.rows(file, start, end, false, MAX_SCAN)?;
        let mut truncated = (end - start + 1) > MAX_SCAN;
        let mut budget = Budget::new(max_bytes);
        let mut messages = Vec::new();
        for row in rows {
            if !tools && row.4 == Role::Tool {
                continue;
            }
            if budget.left == 0 {
                truncated = true;
                break;
            }
            let anchor = row.2 == turn;
            messages.push(budget.take_cut(row, anchor));
            if messages.last().is_some_and(|m: &(i64, Message)| m.1.cut) {
                truncated = true;
                break;
            }
        }
        Ok(finish(messages, truncated))
    }

    /// The first doc of `file` whose `column` (`line` or `turn`, which only grow with a doc's
    /// order) is at least `target`: its order and that value. A binary search, one seek a probe.
    fn first_at_least(
        &self,
        file: &FileRef,
        column: &str,
        target: i64,
    ) -> std::result::Result<Option<(i64, i64)>, ReadError> {
        let sql = format!(
            "SELECT rowid, {column} FROM docs WHERE rowid >= ?1 AND rowid <= ?2 ORDER BY rowid LIMIT 1"
        );
        let mut stmt = self.conn.prepare_cached(&sql)?;
        let base = file.id << 32;
        let top = base | file.docs;
        let mut at_or_after = |seq: i64| -> rusqlite::Result<Option<(i64, i64)>> {
            stmt.query_row(params![base | seq, top], |r| {
                Ok((r.get::<_, i64>(0)? & 0xFFFF_FFFF, r.get::<_, i64>(1)?))
            })
            .optional()
        };
        let (mut lo, mut hi) = (1i64, file.docs + 1);
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            match at_or_after(mid)? {
                None => hi = mid,
                Some((_, value)) if value >= target => hi = mid,
                Some((seq, _)) => lo = seq + 1,
            }
        }
        Ok(at_or_after(lo)?.filter(|(_, value)| *value >= target))
    }

    /// The docs of `file` with order `from..=to`, at most `limit`, newest first when `desc`.
    fn rows(
        &self,
        file: &FileRef,
        from: i64,
        to: i64,
        desc: bool,
        limit: i64,
    ) -> std::result::Result<Vec<Row>, ReadError> {
        if from > to || to < 1 {
            return Ok(Vec::new());
        }
        let order = if desc { "DESC" } else { "ASC" };
        let sql = format!(
            "SELECT rowid, line, turn, at, role, text FROM docs WHERE rowid BETWEEN ?1 AND ?2
             ORDER BY rowid {order} LIMIT ?3"
        );
        let mut stmt = self.conn.prepare_cached(&sql)?;
        let base = file.id << 32;
        let rows = stmt.query_map(params![base | from.max(1), base | to, limit], |r| {
            Ok((
                r.get::<_, i64>(0)? & 0xFFFF_FFFF,
                r.get::<_, i64>(1)?.max(0) as u64,
                r.get::<_, i64>(2)?.clamp(0, i64::from(u32::MAX)) as u32,
                r.get::<_, Option<i64>>(3)?,
                Role::from_code(r.get(4)?),
                r.get::<_, String>(5)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }
}

/// Messages with their order in the file, whether any was left out, and the first and last order.
type Taken = (Vec<Message>, bool, Option<i64>, Option<i64>);

fn finish(messages: Vec<(i64, Message)>, truncated: bool) -> Taken {
    let first = messages.first().map(|m| m.0);
    let last = messages.last().map(|m| m.0);
    (messages.into_iter().map(|m| m.1).collect(), truncated, first, last)
}

/// The session's own transcript, or the subagent's `name` names.
fn pick<'a>(
    files: &'a [FileRef],
    name: Option<&str>,
) -> std::result::Result<&'a FileRef, ReadError> {
    let names = || files.iter().filter(|f| f.subagent).map(|f| f.name.as_str()).collect::<Vec<_>>();
    match name.map(|n| n.trim().trim_end_matches(".jsonl")).filter(|n| !n.is_empty()) {
        Some(name) => files.iter().find(|f| f.subagent && f.name == name).ok_or_else(|| {
            ReadError::NotFound(format!(
                "session has no subagent transcript {name:?} (it has: {})",
                names().join(", ")
            ))
        }),
        None => files.iter().filter(|f| !f.subagent).max_by_key(|f| f.docs).ok_or_else(|| {
            ReadError::NotFound(format!(
                "only subagent transcripts of this session are indexed: name one ({})",
                names().join(", ")
            ))
        }),
    }
}

struct Budget {
    left: usize,
}

impl Budget {
    fn new(max: usize) -> Self {
        Self { left: max }
    }

    fn fits(&self, row: &Row) -> bool {
        row.5.len() <= self.left
    }

    /// The row as a message, its text cut to what is left.
    fn take_cut(&mut self, row: Row, anchor: bool) -> (i64, Message) {
        let (seq, line, turn, at_ms, role, mut text) = row;
        let cap = if role == Role::Tool { MAX_TOOL_BYTES } else { MAX_MESSAGE_BYTES };
        // The index cut a longer text at a character boundary at most 3 bytes before its cap.
        let capped = text.len() + 3 >= cap;
        let mut cut = false;
        if text.len() > self.left {
            let mut end = self.left;
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            text.truncate(end);
            cut = true;
        }
        self.left -= text.len();
        (seq, Message { line, turn, at_ms, role, text, capped, cut, anchor })
    }
}

#[cfg(test)]
#[path = "read_tests.rs"]
mod tests;
