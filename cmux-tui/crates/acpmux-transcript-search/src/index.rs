//! The index: one SQLite file per machine with an FTS5 trigram table of every doc
//! (`detail=none`: a trigram's posting list holds rows, not positions, so the index is about twice
//! the text it holds) and, per transcript, how far it was read.
//!
//! A doc's rowid is its file's id in the high 32 bits and its order in that file in the low 32, so
//! one session's docs are one rowid range: a search of one session reads that range only, newest
//! (highest) first, and stops at its limit.
//!
//! [`Index::catch_up`] reads a transcript from the byte its last read ended at, only whole lines,
//! and adds their docs and the new end in one transaction: the cost of a read is the bytes appended
//! since, whatever the transcript's size, and a read cut short (a quit, a crash) resumes where it
//! stopped and never adds a doc twice. A transcript replaced (another inode), cut shorter than that
//! byte, or rewritten under it (the bytes before it changed) is read again from the start.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OptionalExtension, params};

use crate::locate::Source;
use crate::parse::{self, Harness, LineState, Role};

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS files(
  id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, harness TEXT NOT NULL, session TEXT NOT NULL,
  subagent INTEGER NOT NULL, dev INTEGER NOT NULL, ino INTEGER NOT NULL, offset INTEGER NOT NULL,
  seq INTEGER NOT NULL, turn INTEGER NOT NULL, line INTEGER NOT NULL, guard BLOB NOT NULL);
CREATE INDEX IF NOT EXISTS files_session ON files(session);
CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
  text, role UNINDEXED, at UNINDEXED, turn UNINDEXED, line UNINDEXED,
  tokenize = 'trigram case_sensitive 0', detail = none);
PRAGMA user_version = 1;
";

/// The bytes before a read's end that the next read checks are unchanged.
const GUARD_BYTES: u64 = 64;
/// One transaction reads at most this many bytes of a transcript, so a first read of a large one
/// holds the write lock in short steps and a search between them sees what is done so far.
const STEP_BYTES: u64 = 32 << 20;

#[derive(Debug)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Self(format!("transcript index: {e}"))
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self(format!("transcript read: {e}"))
    }
}

pub type Result<T> = std::result::Result<T, Error>;

/// What one [`Index::catch_up`] did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CatchUp {
    /// The transcript bytes read.
    pub bytes: u64,
    /// The docs added.
    pub docs: u64,
    /// Whether it was read again from the start.
    pub reread: bool,
}

/// What to find.
#[derive(Clone, Debug)]
pub struct Query {
    /// The text, found as written (any case for ASCII letters), anywhere in a doc.
    pub text: String,
    /// Only these harness sessions (and their subagents); `None` is every one.
    pub sessions: Option<Vec<String>>,
    pub role: Option<Role>,
    /// Only docs written at or after this time (ms since the epoch).
    pub since_ms: Option<i64>,
    pub limit: usize,
    /// About this many bytes of text on each side of the match in a hit's snippet.
    pub context: usize,
}

impl Query {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            sessions: None,
            role: None,
            since_ms: None,
            limit: 20,
            context: 300,
        }
    }
}

/// One doc that holds the query.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hit {
    pub session: String,
    pub harness: Harness,
    pub path: PathBuf,
    pub subagent: bool,
    /// The person's prompts before it and its own: 1 for the first prompt and what answered it.
    pub turn: u32,
    /// Its line in the transcript, from 1.
    pub line: u64,
    pub at_ms: Option<i64>,
    pub role: Role,
    /// The match and up to [`Query::context`] bytes each side, as written (real line breaks).
    pub snippet: String,
    /// Where the match is in `snippet` (bytes).
    pub match_start: usize,
    pub match_len: usize,
    /// Whether the doc's text goes on before or after the snippet.
    pub cut_before: bool,
    pub cut_after: bool,
}

pub struct Index {
    conn: Connection,
}

struct FileRow {
    id: i64,
    dev: i64,
    ino: i64,
    offset: u64,
    seq: i64,
    turn: u32,
    line: u64,
    guard: Vec<u8>,
}

impl Index {
    /// Opens (or creates) the index at `path`, readable by its owner only.
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
        }
        Self::with(conn)
    }

    /// An index held in memory (tests).
    pub fn in_memory() -> Result<Self> {
        Self::with(Connection::open_in_memory()?)
    }

    fn with(conn: Connection) -> Result<Self> {
        conn.busy_timeout(Duration::from_secs(30))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn })
    }

    /// Reads what `source` appended since the last read (all of it the first time).
    pub fn catch_up(&self, source: &Source) -> Result<CatchUp> {
        let mut done = CatchUp::default();
        loop {
            let step = self.step(source)?;
            done.bytes += step.0.bytes;
            done.docs += step.0.docs;
            done.reread |= step.0.reread;
            if !step.1 {
                return Ok(done);
            }
        }
    }

    /// One transaction of [`Self::catch_up`]; the bool is whether more is left to read.
    fn step(&self, source: &Source) -> Result<(CatchUp, bool)> {
        let Ok(mut file) = File::open(&source.path) else {
            // Gone: what it said stays found until the index is rebuilt.
            return Ok((CatchUp::default(), false));
        };
        let meta = file.metadata()?;
        let (dev, ino) = file_id(&meta);
        let len = meta.len();
        let path = source.path.to_string_lossy();
        let tx = rusqlite::Transaction::new_unchecked(
            &self.conn,
            rusqlite::TransactionBehavior::Immediate,
        )?;
        let row = tx
            .query_row(
                "SELECT id, dev, ino, offset, seq, turn, line, guard FROM files WHERE path = ?1",
                params![path],
                |r| {
                    Ok(FileRow {
                        id: r.get(0)?,
                        dev: r.get(1)?,
                        ino: r.get(2)?,
                        offset: r.get::<_, i64>(3)? as u64,
                        seq: r.get(4)?,
                        turn: r.get::<_, i64>(5)? as u32,
                        line: r.get::<_, i64>(6)? as u64,
                        guard: r.get(7)?,
                    })
                },
            )
            .optional()?;
        let mut done = CatchUp::default();
        let mut row = match row {
            Some(row) => row,
            None => {
                tx.execute(
                    "INSERT INTO files(path, harness, session, subagent, dev, ino, offset, seq, turn, line, guard)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, 0, 0, 0, x'')",
                    params![path, source.harness.as_str(), source.session, source.subagent, dev, ino],
                )?;
                FileRow {
                    id: tx.last_insert_rowid(),
                    dev,
                    ino,
                    offset: 0,
                    seq: 0,
                    turn: 0,
                    line: 0,
                    guard: Vec::new(),
                }
            }
        };
        let same = row.dev == dev
            && row.ino == ino
            && len >= row.offset
            && read_guard(&mut file, row.offset)? == row.guard;
        if !same {
            let (lo, hi) = range(row.id);
            tx.execute("DELETE FROM docs WHERE rowid BETWEEN ?1 AND ?2", params![lo, hi])?;
            row =
                FileRow { dev, ino, offset: 0, seq: 0, turn: 0, line: 0, guard: Vec::new(), ..row };
            done.reread = true;
        }
        if len == row.offset {
            if done.reread {
                save(&tx, &row)?;
            }
            tx.commit()?;
            return Ok((done, false));
        }
        let want = (len - row.offset).min(STEP_BYTES);
        file.seek(SeekFrom::Start(row.offset))?;
        let mut buf = Vec::with_capacity(want as usize);
        file.by_ref().take(want).read_to_end(&mut buf)?;
        // Only whole lines: a line being written is read once it ends.
        let mut whole = memchr::memrchr(b'\n', &buf).map_or(0, |i| i + 1);
        if whole == 0 && want == STEP_BYTES {
            // One line longer than a step: read on to its end.
            let mut rest = Vec::new();
            file.read_to_end(&mut rest)?;
            buf.extend_from_slice(&rest);
            whole = memchr::memrchr(b'\n', &buf).map_or(0, |i| i + 1);
        }
        let mut state = LineState { turn: row.turn };
        {
            let mut insert = tx.prepare_cached(
                "INSERT INTO docs(rowid, text, role, at, turn, line) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )?;
            for raw in buf.get(..whole).unwrap_or_default().split(|b| *b == b'\n') {
                if raw.is_empty() {
                    continue;
                }
                row.line += 1;
                let parsed = parse::line(source.harness, raw, &mut state);
                for doc in parsed.docs {
                    row.seq += 1;
                    if row.seq >= 1 << 32 {
                        break;
                    }
                    let rowid = (row.id << 32) | row.seq;
                    insert.execute(params![
                        rowid,
                        doc.text,
                        doc.role.code(),
                        parsed.at_ms,
                        i64::from(state.turn),
                        row.line as i64
                    ])?;
                    done.docs += 1;
                }
            }
        }
        row.turn = state.turn;
        row.offset += whole as u64;
        done.bytes = whole as u64;
        row.guard = read_guard(&mut file, row.offset)?;
        save(&tx, &row)?;
        tx.commit()?;
        let more = whole > 0 && row.offset < len;
        Ok((done, more))
    }

    /// The docs that hold `q.text`, newest first.
    pub fn search(&self, q: &Query) -> Result<Vec<Hit>> {
        let needle = q.text.trim();
        if needle.is_empty() || q.limit == 0 {
            return Ok(Vec::new());
        }
        let files = self.files(q.sessions.as_deref())?;
        // No ESCAPE (FTS5 serves an escaped pattern with no index): a `%` or `_` in the text is a
        // wildcard here, so such a search reads more rows and keeps those holding the text itself.
        let pattern = format!("%{needle}%");
        let wild = needle.contains(['%', '_']);
        let mut filter = String::new();
        if let Some(role) = q.role {
            filter.push_str(&format!(" AND role = {}", role.code()));
        }
        if let Some(since) = q.since_ms {
            filter.push_str(&format!(" AND at >= {since}"));
        }
        let mut found: Vec<Found> = Vec::new();
        let read = |sql: &str, args: &[&dyn rusqlite::ToSql], out: &mut Vec<Found>| -> Result<()> {
            let mut stmt = self.conn.prepare_cached(sql)?;
            let rows = stmt.query_map(args, |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, Option<i64>>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, String>(5)?,
                ))
            })?;
            for row in rows {
                out.push(row?);
            }
            Ok(())
        };
        let limit = (if wild { q.limit * 8 + 64 } else { q.limit }) as i64;
        match &q.sessions {
            // One session: each of its files is a rowid range, read newest first up to the limit.
            Some(_) => {
                let sql = format!(
                    "SELECT rowid, at, role, turn, line, text FROM docs
                     WHERE text LIKE ?1 AND rowid BETWEEN ?2 AND ?3{filter}
                     ORDER BY rowid DESC LIMIT ?4"
                );
                for id in files.keys() {
                    let (lo, hi) = range(*id);
                    read(&sql, &[&pattern, &lo, &hi, &limit], &mut found)?;
                }
            }
            None => {
                let sql = format!(
                    "SELECT rowid, at, role, turn, line, text FROM docs
                     WHERE text LIKE ?1{filter}
                     ORDER BY at DESC, rowid DESC LIMIT ?2"
                );
                read(&sql, &[&pattern, &limit], &mut found)?;
            }
        }
        let lower = needle.to_ascii_lowercase();
        if wild {
            found.retain(|f| {
                memchr::memmem::find(f.5.to_ascii_lowercase().as_bytes(), lower.as_bytes())
                    .is_some()
            });
        }
        found.sort_by_key(|f| std::cmp::Reverse((f.1, f.0)));
        found.truncate(q.limit);
        let mut hits = Vec::with_capacity(found.len());
        for (rowid, at, role, turn, line, text) in found {
            let Some(file) = files.get(&(rowid >> 32)) else { continue };
            let (snippet, start, len, before, after) = snippet(&text, &lower, q.context);
            hits.push(Hit {
                session: file.session.clone(),
                harness: file.harness,
                path: file.path.clone(),
                subagent: file.subagent,
                turn: turn as u32,
                line: line as u64,
                at_ms: at,
                role: Role::from_code(role),
                snippet,
                match_start: start,
                match_len: len,
                cut_before: before,
                cut_after: after,
            });
        }
        Ok(hits)
    }

    /// How many transcripts and docs the index holds.
    pub fn stats(&self) -> Result<(u64, u64)> {
        let files: i64 = self.conn.query_row("SELECT count(*) FROM files", [], |r| r.get(0))?;
        let docs: i64 = self.conn.query_row("SELECT count(*) FROM docs", [], |r| r.get(0))?;
        Ok((files as u64, docs as u64))
    }

    fn files(&self, sessions: Option<&[String]>) -> Result<HashMap<i64, FileInfo>> {
        let mut out = HashMap::new();
        let mut add = |r: &rusqlite::Row<'_>| -> rusqlite::Result<()> {
            let harness: String = r.get(2)?;
            out.insert(
                r.get(0)?,
                FileInfo {
                    path: PathBuf::from(r.get::<_, String>(1)?),
                    harness: Harness::parse(&harness).unwrap_or(Harness::Claude),
                    session: r.get(3)?,
                    subagent: r.get(4)?,
                },
            );
            Ok(())
        };
        let sql = "SELECT id, path, harness, session, subagent FROM files";
        match sessions {
            None => {
                let mut stmt = self.conn.prepare_cached(sql)?;
                let mut rows = stmt.query([])?;
                while let Some(r) = rows.next()? {
                    add(r)?;
                }
            }
            Some(ids) => {
                let mut stmt = self.conn.prepare_cached(&format!("{sql} WHERE session = ?1"))?;
                for id in ids {
                    let mut rows = stmt.query(params![id])?;
                    while let Some(r) = rows.next()? {
                        add(r)?;
                    }
                }
            }
        }
        Ok(out)
    }
}

struct FileInfo {
    path: PathBuf,
    harness: Harness,
    session: String,
    subagent: bool,
}

fn save(tx: &rusqlite::Transaction<'_>, row: &FileRow) -> Result<()> {
    tx.execute(
        "UPDATE files SET dev = ?2, ino = ?3, offset = ?4, seq = ?5, turn = ?6, line = ?7, guard = ?8
         WHERE id = ?1",
        params![
            row.id,
            row.dev,
            row.ino,
            row.offset as i64,
            row.seq,
            i64::from(row.turn),
            row.line as i64,
            row.guard
        ],
    )?;
    Ok(())
}

/// The rowids of file `id`'s docs.
fn range(id: i64) -> (i64, i64) {
    (id << 32, (id << 32) | 0xFFFF_FFFF)
}

/// The [`GUARD_BYTES`] before `end`.
fn read_guard(file: &mut File, end: u64) -> Result<Vec<u8>> {
    let start = end.saturating_sub(GUARD_BYTES);
    let mut buf = vec![0; (end - start) as usize];
    file.seek(SeekFrom::Start(start))?;
    file.read_exact(&mut buf)?;
    Ok(buf)
}

#[cfg(unix)]
fn file_id(meta: &std::fs::Metadata) -> (i64, i64) {
    use std::os::unix::fs::MetadataExt;
    (meta.dev() as i64, meta.ino() as i64)
}

#[cfg(not(unix))]
fn file_id(_meta: &std::fs::Metadata) -> (i64, i64) {
    (0, 0)
}

/// The match in `text` and about `context` bytes each side (cut at character boundaries), where
/// the match is in it, and whether text was left out before and after.
fn snippet(text: &str, lower: &str, context: usize) -> (String, usize, usize, bool, bool) {
    let folded = text.to_ascii_lowercase();
    let (at, len) = memchr::memmem::find(folded.as_bytes(), lower.as_bytes())
        .map_or((0, 0), |at| (at, lower.len()));
    let mut start = at.saturating_sub(context);
    while !text.is_char_boundary(start) {
        start -= 1;
    }
    let mut end = (at + len + context).min(text.len());
    while !text.is_char_boundary(end) {
        end += 1;
    }
    (
        text.get(start..end).unwrap_or_default().to_owned(),
        at - start,
        len,
        start > 0,
        end < text.len(),
    )
}

/// A row a search read: rowid, time, role, turn, line, text.
type Found = (i64, Option<i64>, i64, i64, i64, String);
