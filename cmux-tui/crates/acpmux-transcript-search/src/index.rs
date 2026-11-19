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
//!
//! A search ([`Index::page`]) first lists the matching docs' rowids and times only, up to
//! [`EXACT_DOCS`]: within that it orders them exactly (newest, or by transcript position), puts the
//! ones in its time window first, counts them (`total`) and reads the text of the page's docs alone.
//! A query that matches more is read in its order with bounded queries, and its total is not given.

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
  text, role UNINDEXED, at UNINDEXED, turn UNINDEXED, line UNINDEXED, message UNINDEXED,
  tokenize = 'trigram case_sensitive 0', detail = none);
PRAGMA user_version = 2;
";
/// The schema's `user_version`. An index of another one (version 1 kept no message ids) is
/// emptied and every transcript read again.
const VERSION: i64 = 2;

/// A search orders, counts and windows at most this many matching docs exactly; past it, its page
/// is read with bounded queries in its order and it has no total.
pub const EXACT_DOCS: usize = 10_000;

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
    /// More text each doc must also hold, anywhere in it (as `text` is found).
    pub also: Vec<String>,
    pub order: Order,
    /// Docs written within this span (ms since the epoch, both ends in) come first, each hit
    /// `in_window`, then the rest in `order`.
    pub window: Option<(i64, i64)>,
    /// Skips this many hits (in the order the hits come).
    pub offset: usize,
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
            also: Vec::new(),
            order: Order::Newest,
            window: None,
            offset: 0,
        }
    }
}

/// The order of a search's hits.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Order {
    /// Newest first: by the doc's time, then its place.
    #[default]
    Newest,
    /// Oldest first by place: the transcript's path, then its line (and a line's docs in order).
    Transcript,
}

impl Order {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Newest => "newest",
            Self::Transcript => "transcript",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "newest" => Some(Self::Newest),
            "transcript" => Some(Self::Transcript),
            _ => None,
        }
    }
}

/// One page of a search: its hits and, when the index counted them, how many docs match in all.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Page {
    pub hits: Vec<Hit>,
    /// Every doc in the query's scope that holds it (not only this page's); None when more than
    /// [`EXACT_DOCS`] do.
    pub total: Option<u64>,
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
    /// The reply's harness message id (`agent_message_chunk.messageId`), when the doc is one.
    pub message_id: Option<String>,
    /// How many times the doc holds the text (the snippet shows the first).
    pub matches: usize,
    /// The doc was written within [`Query::window`].
    pub in_window: bool,
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
        // In one write transaction: two connections opening an old index at once empty it once.
        let tx =
            rusqlite::Transaction::new_unchecked(&conn, rusqlite::TransactionBehavior::Immediate)?;
        let version: i64 = tx.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version != 0 && version != VERSION {
            tx.execute_batch("DROP TABLE IF EXISTS docs; DROP TABLE IF EXISTS files;")?;
        }
        tx.execute_batch(SCHEMA)?;
        tx.commit()?;
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
                "INSERT INTO docs(rowid, text, role, at, turn, line, message)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
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
                        row.line as i64,
                        doc.message
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

    /// The first page of docs that hold `q.text` (and each of `q.also`), in `q.order`.
    pub fn search(&self, q: &Query) -> Result<Vec<Hit>> {
        Ok(self.page(q)?.hits)
    }

    /// The docs that hold `q.text` (and each of `q.also`): those in `q.window` first, then the
    /// rest, each part in `q.order`; `q.offset` of them skipped, then at most `q.limit`. Reads the
    /// text of the page's docs only.
    pub fn page(&self, q: &Query) -> Result<Page> {
        let Some(words) = Words::of(q) else { return Ok(Page::default()) };
        if q.limit == 0 {
            return Ok(Page::default());
        }
        let files = self.files(q.sessions.as_deref())?;
        let scope = match &q.sessions {
            None => None,
            // A session's files in path order (as text: `<id>.jsonl` before `<id>/subagents/`):
            // its docs are one rowid range per file.
            Some(_) => {
                let mut ids: Vec<(&std::ffi::OsStr, i64)> =
                    files.iter().map(|(id, f)| (f.path.as_os_str(), *id)).collect();
                ids.sort();
                Some(ids.into_iter().map(|(_, id)| range(id)).collect::<Vec<_>>())
            }
        };
        let want = q.offset.saturating_add(q.limit);
        let listed = self.matching(&words, scope.as_deref(), "", None, EXACT_DOCS + 1)?;
        let (rows, total) = if listed.len() <= EXACT_DOCS {
            let total = listed.len() as u64;
            let mut rows: Vec<(i64, Option<i64>, bool)> =
                listed.into_iter().map(|(id, at)| (id, at, within(q.window, at))).collect();
            match q.order {
                Order::Newest => rows.sort_by_key(|r| std::cmp::Reverse((r.1, r.0))),
                Order::Transcript => rows.sort_by(|a, b| {
                    let path = |id: i64| files.get(&(id >> 32)).map(|f| f.path.as_os_str());
                    path(a.0).cmp(&path(b.0)).then(a.0.cmp(&b.0))
                }),
            }
            // Stable: each part keeps its order.
            rows.sort_by_key(|r| !r.2);
            (rows, Some(total))
        } else {
            let take = |extra: &str, inside: bool, n: usize| -> Result<Vec<_>> {
                let got = self.ordered(&words, scope.as_deref(), extra, q.order, n)?;
                Ok(got.into_iter().map(|(id, at)| (id, at, inside)).collect())
            };
            let rows: Vec<(i64, Option<i64>, bool)> = match q.window {
                Some((from, to)) => {
                    let mut rows = take(&format!(" AND at BETWEEN {from} AND {to}"), true, want)?;
                    let left = want.saturating_sub(rows.len());
                    if left > 0 {
                        let outside = format!(" AND (at IS NULL OR at < {from} OR at > {to})");
                        rows.extend(take(&outside, false, left)?);
                    }
                    rows
                }
                None => take("", false, want)?,
            };
            (rows, None)
        };
        let mut hits = Vec::with_capacity(q.limit.min(rows.len()));
        for (rowid, _, inside) in rows.into_iter().skip(q.offset).take(q.limit) {
            if let Some(hit) = self.hit(rowid, &files, &words.first, q.context, inside)? {
                hits.push(hit);
            }
        }
        Ok(Page { hits, total })
    }

    /// The newest prompt or reply in each session's own transcript (a subagent's left out) that
    /// holds every one of `words`, newest first, each with how many of the matching docs read are
    /// that session's. Reads at most `scan` matching docs, in no order: a session whose matches are
    /// all past them is not found. For the chats page's search of what was said
    /// (`acpmux` `chats/text.rs`).
    pub fn chats(&self, words: &[String], scan: usize, context: usize) -> Result<Vec<(Hit, u32)>> {
        let Some((first, rest)) = words.split_first() else { return Ok(Vec::new()) };
        let mut q = Query::new(first.clone());
        q.also = rest.to_vec();
        let Some(words) = Words::of(&q) else { return Ok(Vec::new()) };
        let files = self.files(None)?;
        let listed = self.matching(&words, None, " AND role < 2", Some("rowid DESC"), scan)?;
        let mut newest: HashMap<&str, (Option<i64>, i64, u32)> = HashMap::new();
        for (rowid, at) in listed {
            let Some(file) = files.get(&(rowid >> 32)).filter(|f| !f.subagent) else { continue };
            let best = newest.entry(file.session.as_str()).or_insert((at, rowid, 0));
            if (at, rowid) > (best.0, best.1) {
                (best.0, best.1) = (at, rowid);
            }
            best.2 = best.2.saturating_add(1);
        }
        let mut best: Vec<(Option<i64>, i64, u32)> = newest.into_values().collect();
        best.sort_by_key(|b| std::cmp::Reverse((b.0, b.1)));
        let mut out = Vec::with_capacity(best.len());
        for (_, rowid, count) in best {
            if let Some(hit) = self.hit(rowid, &files, &words.first, context, false)? {
                out.push((hit, count));
            }
        }
        Ok(out)
    }

    /// The rowids and times of up to `limit` docs in `scope` (rowid ranges; None: every doc) that
    /// hold `words` and pass `extra` (more SQL conditions), in no set order (`order` given: in it).
    fn matching(
        &self,
        words: &Words,
        scope: Option<&[(i64, i64)]>,
        extra: &str,
        order: Option<&str>,
        limit: usize,
    ) -> Result<Vec<(i64, Option<i64>)>> {
        let order = order.map(|o| format!(" ORDER BY {o}")).unwrap_or_default();
        let mut out = Vec::new();
        let read = |range: Option<(i64, i64)>,
                    n: usize,
                    out: &mut Vec<(i64, Option<i64>)>|
         -> Result<()> {
            let bound = if range.is_some() { " AND rowid BETWEEN ? AND ?" } else { "" };
            let sql = format!(
                "SELECT rowid, at FROM docs WHERE {}{bound}{extra}{order} LIMIT ?",
                words.sql
            );
            let mut args = words.args.clone();
            if let Some((lo, hi)) = range {
                args.push(lo.into());
                args.push(hi.into());
            }
            args.push((n as i64).into());
            let mut stmt = self.conn.prepare_cached(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(args), |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Option<i64>>(1)?))
            })?;
            for row in rows {
                out.push(row?);
            }
            Ok(())
        };
        match scope {
            None => read(None, limit, &mut out)?,
            Some(ranges) => {
                for range in ranges {
                    let left = limit.saturating_sub(out.len());
                    if left == 0 {
                        break;
                    }
                    read(Some(*range), left, &mut out)?;
                }
            }
        }
        Ok(out)
    }

    /// The first `n` matching docs in `order`, read with bounded queries: a search past
    /// [`EXACT_DOCS`].
    fn ordered(
        &self,
        words: &Words,
        scope: Option<&[(i64, i64)]>,
        extra: &str,
        order: Order,
        n: usize,
    ) -> Result<Vec<(i64, Option<i64>)>> {
        match (scope, order) {
            (None, Order::Newest) => {
                self.matching(words, None, extra, Some("at DESC, rowid DESC"), n)
            }
            // Every transcript's docs in the order their files were first read, then by line.
            (None, Order::Transcript) => self.matching(words, None, extra, Some("rowid"), n),
            (Some(ranges), Order::Transcript) => {
                self.matching(words, Some(ranges), extra, Some("rowid"), n)
            }
            (Some(ranges), Order::Newest) => {
                // Each file's newest by place (its time order), then all of them by time.
                let mut all = Vec::new();
                for range in ranges {
                    all.extend(self.matching(
                        words,
                        Some(std::slice::from_ref(range)),
                        extra,
                        Some("rowid DESC"),
                        n,
                    )?);
                }
                all.sort_by_key(|r| std::cmp::Reverse((r.1, r.0)));
                all.truncate(n);
                Ok(all)
            }
        }
    }

    /// Doc `rowid` as a hit for `lower` (the query's first text, ASCII-lowercased).
    fn hit(
        &self,
        rowid: i64,
        files: &HashMap<i64, FileInfo>,
        lower: &str,
        context: usize,
        in_window: bool,
    ) -> Result<Option<Hit>> {
        let Some(file) = files.get(&(rowid >> 32)) else { return Ok(None) };
        let mut stmt = self.conn.prepare_cached(
            "SELECT at, role, turn, line, text, message FROM docs WHERE rowid = ?1",
        )?;
        let row = stmt
            .query_row(params![rowid], |r| {
                Ok((
                    r.get::<_, Option<i64>>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, Option<String>>(5)?,
                ))
            })
            .optional()?;
        let Some((at, role, turn, line, text, message)) = row else { return Ok(None) };
        let (snippet, start, len, before, after) = snippet(&text, lower, context);
        let matches =
            memchr::memmem::find_iter(text.to_ascii_lowercase().as_bytes(), lower.as_bytes())
                .count()
                .max(1);
        Ok(Some(Hit {
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
            message_id: message,
            matches,
            in_window,
        }))
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

/// Whether a doc written at `at` is within `window`.
fn within(window: Option<(i64, i64)>, at: Option<i64>) -> bool {
    matches!((window, at), (Some((from, to)), Some(at)) if from <= at && at <= to)
}

/// What a doc must hold, as SQL: each text as a `LIKE` (which the trigram index serves), and the
/// query's role and time filters.
struct Words {
    /// The first text, ASCII-lowercased: a hit's snippet is cut around it.
    first: String,
    /// The conditions, `?` for each of `args` in order.
    sql: String,
    args: Vec<rusqlite::types::Value>,
}

impl Words {
    /// None when the query's text is empty.
    fn of(q: &Query) -> Option<Self> {
        let first = q.text.trim();
        if first.is_empty() {
            return None;
        }
        let mut words =
            Self { first: first.to_ascii_lowercase(), sql: String::new(), args: Vec::new() };
        let texts =
            std::iter::once(first).chain(q.also.iter().map(|w| w.trim()).filter(|w| !w.is_empty()));
        for (i, text) in texts.enumerate() {
            if i > 0 {
                words.sql.push_str(" AND ");
            }
            words.sql.push_str("text LIKE ?");
            words.args.push(format!("%{text}%").into());
            // No ESCAPE (FTS5 serves an escaped pattern with no index): a `%` or `_` is a wildcard
            // in the LIKE, so the text itself is checked too.
            if text.contains(['%', '_']) {
                words.sql.push_str(" AND instr(lower(text), ?) > 0");
                words.args.push(text.to_ascii_lowercase().into());
            }
        }
        if let Some(role) = q.role {
            words.sql.push_str(&format!(" AND role = {}", role.code()));
        }
        if let Some(since) = q.since_ms {
            words.sql.push_str(&format!(" AND at >= {since}"));
        }
        Some(words)
    }
}
