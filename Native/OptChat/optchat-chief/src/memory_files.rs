//! The Chief's memory files (chief-cohesion MEMORY-ALWAYS-ON.md): small
//! Markdown files the Chief and its nightly review ("dream", dream.rs) keep
//! about the person and the work it follows for them, beside the OptChat log.
//!
//! - `notes/<topic>.md`: what was learned that cannot be looked up again
//!   (people, machines, accounts, decisions, dates), with the message ids it
//!   came from. `notes/standing-rules.md` holds rules the person stated in
//!   chat, in their own words.
//! - `loops/<task>.md`: one open ask or promise each: what was asked, what is
//!   done, what is left, pointers. Removed when the work ends.
//!
//! Every turn gets `block()` after the chat (never cached before a mark): the
//! index (one line per file) and the body of the standing rules. The rows are
//! the ones recursive's Cloud Chief keeps (apps/web/src/core/memory-files.ts:
//! `memory_files(path, body, description, trust, run, version, updated_at)`,
//! the same path rule and index line), so the two can sync later. Local
//! deviations: no `instructions.md` or `reported.md` row (the person profile
//! and the chat hold them), and no suggestion cards: the dream edits notes the
//! Chief wrote; `memory_history` keeps every replaced version for 30 days.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, params};

/// The file in `optchat/`.
pub const FILE: &str = "memory-files.sqlite3";
/// The note every turn reads whole.
pub const RULES: &str = "notes/standing-rules.md";
/// Most bytes of the index in a turn; the rest is counted.
pub const INDEX_BLOCK_BYTES: usize = 6_000;
/// Most bytes of the standing rules in a turn.
pub const RULES_BLOCK_BYTES: usize = 4_000;
/// Longest file body.
pub const BODY_MAX: usize = 16_000;
/// Longest one-line description.
pub const DESCRIPTION_MAX: usize = 300;
/// How long a replaced version stays in `memory_history`.
pub const HISTORY_MS: i64 = 30 * 24 * 3600 * 1000;

/// Who wrote a row (recursive's `MemoryTrust`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trust {
    /// A turn of the Chief's owner.
    Person,
    /// A turn another person started (only loops/ there).
    Outside,
    /// The nightly review.
    Dream,
}

impl Trust {
    pub fn as_str(self) -> &'static str {
        match self {
            Trust::Person => "person",
            Trust::Outside => "outside",
            Trust::Dream => "dream",
        }
    }
}

/// One file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub path: String,
    pub body: String,
    pub description: String,
    pub trust: String,
    pub run: String,
    pub version: i64,
    pub updated_at: i64,
}

/// Whether `path` is a file the Chief may write: `notes/` or `loops/`, a
/// lowercase name of letters, digits and dashes, `.md`, at most 80 bytes.
pub fn writable(path: &str) -> bool {
    let Some((dir, name)) = path.split_once('/') else {
        return false;
    };
    let Some(stem) = name.strip_suffix(".md") else {
        return false;
    };
    path.len() <= 80
        && matches!(dir, "notes" | "loops")
        && stem
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && stem
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

const PATH_HELP: &str =
    "notes/<topic>.md or loops/<task>.md (lowercase letters, digits and -), or index.md to read";

fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn day_of(ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(ms)
        .map(|t| {
            t.with_timezone(&chrono::Local)
                .format("%Y-%m-%d")
                .to_string()
        })
        .unwrap_or_default()
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn sql(e: rusqlite::Error) -> String {
    format!("memory files: {e}")
}

/// The store: one SQLite file beside the memory.
pub struct MemoryFiles {
    conn: Mutex<Connection>,
    path: PathBuf,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS memory_files (path TEXT PRIMARY KEY, body TEXT NOT NULL, description TEXT NOT NULL,
  trust TEXT NOT NULL, run TEXT NOT NULL, version INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS memory_history (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL, body TEXT NOT NULL,
  description TEXT NOT NULL, trust TEXT NOT NULL, run TEXT NOT NULL, version INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  replaced_at INTEGER NOT NULL, replaced_by TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS memory_forgotten (path TEXT PRIMARY KEY, words TEXT NOT NULL, at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS memory_dreams (day TEXT PRIMARY KEY, record TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS memory_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
";

impl MemoryFiles {
    /// Opens (or makes) the store at `path`, mode 0600.
    pub fn open(path: &Path) -> Result<MemoryFiles, String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("memory files: {e}"))?;
        }
        let conn = Connection::open(path).map_err(sql)?;
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
        }
        conn.busy_timeout(std::time::Duration::from_secs(5))
            .map_err(sql)?;
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(sql)?;
        conn.execute_batch(SCHEMA).map_err(sql)?;
        Ok(MemoryFiles {
            conn: Mutex::new(conn),
            path: path.to_owned(),
        })
    }

    /// The store in a Chief's `optchat/` directory.
    pub fn open_in(root: &Path) -> Result<MemoryFiles, String> {
        MemoryFiles::open(&root.join(FILE))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Every file, by path.
    pub fn list(&self) -> Result<Vec<Row>, String> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare(
                "SELECT path, body, description, trust, run, version, updated_at FROM memory_files ORDER BY path",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([], |r| {
                Ok(Row {
                    path: r.get(0)?,
                    body: r.get(1)?,
                    description: r.get(2)?,
                    trust: r.get(3)?,
                    run: r.get(4)?,
                    version: r.get(5)?,
                    updated_at: r.get(6)?,
                })
            })
            .map_err(sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sql)
    }

    pub fn get(&self, path: &str) -> Result<Option<Row>, String> {
        let conn = self.lock();
        conn.query_row(
            "SELECT path, body, description, trust, run, version, updated_at FROM memory_files WHERE path = ?1",
            params![path],
            |r| {
                Ok(Row {
                    path: r.get(0)?,
                    body: r.get(1)?,
                    description: r.get(2)?,
                    trust: r.get(3)?,
                    run: r.get(4)?,
                    version: r.get(5)?,
                    updated_at: r.get(6)?,
                })
            },
        )
        .optional()
        .map_err(sql)
    }

    /// `memory_read(path)`: a file with its line, or the index.
    pub fn read(&self, path: &str) -> String {
        let path = path.trim();
        if path == "index.md" {
            return match self.list() {
                Ok(rows) => index_text(&rows, usize::MAX),
                Err(e) => e,
            };
        }
        match self.get(path) {
            Ok(Some(row)) => format!(
                "{} ({}; version {}, {}, written {})\n{}",
                row.path,
                row.description,
                row.version,
                day_of(row.updated_at),
                match row.trust.as_str() {
                    "dream" => "by the nightly review",
                    "outside" => "in a turn another person started",
                    _ => "in your turn",
                },
                row.body
            ),
            Ok(None) => format!("No file {path}. The files: memory_read index.md."),
            Err(e) => e,
        }
    }

    /// `memory_write(path, description, body)`: the file's whole new text.
    pub fn write(
        &self,
        path: &str,
        description: &str,
        body: &str,
        trust: Trust,
        run: &str,
    ) -> Result<String, String> {
        let path = path.trim();
        if !writable(path) {
            return Err(format!("memory_write: path must be {PATH_HELP}"));
        }
        if trust == Trust::Outside && !path.starts_with("loops/") {
            return Err(
                "memory_write: a turn another person started may write loops/ files only".into(),
            );
        }
        let body = body.trim_end();
        if body.trim().is_empty() {
            return Err("memory_write: body is empty; memory_forget removes a file".into());
        }
        if body.len() > BODY_MAX {
            return Err(format!(
                "memory_write: the body is {} bytes; keep a file under {BODY_MAX} (split the topic, or store a pointer)",
                body.len()
            ));
        }
        if crate::agent_memory::notes::looks_secret(body)
            || crate::agent_memory::notes::looks_secret(description)
        {
            return Err(
                "memory_write: refused, the text looks like a credential; never keep one".into(),
            );
        }
        let description: String = one_line(description)
            .chars()
            .take(DESCRIPTION_MAX)
            .collect();
        let now = now_ms();
        let mut conn = self.lock();
        let tx = conn.transaction().map_err(sql)?;
        let old: Option<(String, String, String, String, i64, i64)> = tx
            .query_row(
                "SELECT body, description, trust, run, version, updated_at FROM memory_files WHERE path = ?1",
                params![path],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
            )
            .optional()
            .map_err(sql)?;
        if let Some((b, d, _, _, _, _)) = &old
            && b == body
            && *d == description
        {
            return Ok(format!("outcome: noop. {path} already says this"));
        }
        if let Some((b, d, t, r, v, u)) = &old {
            tx.execute(
                "INSERT INTO memory_history (path, body, description, trust, run, version, updated_at, replaced_at, replaced_by) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![path, b, d, t, r, v, u, now, run],
            )
            .map_err(sql)?;
        }
        tx.execute(
            "INSERT INTO memory_files (path, body, description, trust, run, version, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6) \
             ON CONFLICT(path) DO UPDATE SET body = excluded.body, description = excluded.description, trust = excluded.trust, \
             run = excluded.run, version = memory_files.version + 1, updated_at = excluded.updated_at",
            params![path, body, description, trust.as_str(), run, now],
        )
        .map_err(sql)?;
        tx.execute(
            "DELETE FROM memory_forgotten WHERE path = ?1",
            params![path],
        )
        .map_err(sql)?;
        tx.execute(
            "DELETE FROM memory_history WHERE replaced_at < ?1",
            params![now - HISTORY_MS],
        )
        .map_err(sql)?;
        tx.commit().map_err(sql)?;
        Ok(format!(
            "outcome: done. {} {path}",
            if old.is_some() { "updated" } else { "saved" }
        ))
    }

    /// `memory_forget(path)`: removes a file; the old text stays in the
    /// history and the path is remembered as forgotten, so the nightly
    /// review does not write it again from the chat.
    pub fn forget(&self, path: &str, run: &str) -> Result<String, String> {
        self.remove(path, run, true)
    }

    /// Removes a file into the history; `forgotten` also keeps the path of a
    /// note as one the person asked to forget.
    pub fn remove(&self, path: &str, run: &str, forgotten: bool) -> Result<String, String> {
        let path = path.trim();
        if !writable(path) {
            return Err(format!("memory_forget: path must be {PATH_HELP}"));
        }
        let now = now_ms();
        let mut conn = self.lock();
        let tx = conn.transaction().map_err(sql)?;
        let moved = tx
            .execute(
                "INSERT INTO memory_history (path, body, description, trust, run, version, updated_at, replaced_at, replaced_by) \
                 SELECT path, body, description, trust, run, version, updated_at, ?2, ?3 FROM memory_files WHERE path = ?1",
                params![path, now, run],
            )
            .map_err(sql)?;
        tx.execute("DELETE FROM memory_files WHERE path = ?1", params![path])
            .map_err(sql)?;
        if forgotten && path.starts_with("notes/") && moved > 0 {
            tx.execute(
                "INSERT OR REPLACE INTO memory_forgotten (path, words, at) VALUES (?1, ?2, ?3)",
                params![path, run, now],
            )
            .map_err(sql)?;
        }
        tx.commit().map_err(sql)?;
        Ok(if moved > 0 {
            format!("outcome: done. removed {path}")
        } else {
            format!("outcome: noop. no file {path}")
        })
    }

    /// Notes the person asked to forget (the dream does not write them again).
    pub fn forgotten(&self) -> Result<Vec<String>, String> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare("SELECT path FROM memory_forgotten ORDER BY path")
            .map_err(sql)?;
        let rows = stmt.query_map([], |r| r.get(0)).map_err(sql)?;
        rows.collect::<Result<Vec<String>, _>>().map_err(sql)
    }

    /// The nightly review's record of `day` (JSON), if any.
    pub fn dream_record(&self, day: &str) -> Result<Option<String>, String> {
        let conn = self.lock();
        conn.query_row(
            "SELECT record FROM memory_dreams WHERE day = ?1",
            params![day],
            |r| r.get(0),
        )
        .optional()
        .map_err(sql)
    }

    /// The newest review record (JSON).
    pub fn last_dream(&self) -> Result<Option<(String, String)>, String> {
        let conn = self.lock();
        conn.query_row(
            "SELECT day, record FROM memory_dreams ORDER BY day DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(sql)
    }

    pub fn put_dream(&self, day: &str, record: &str) -> Result<(), String> {
        let conn = self.lock();
        conn.execute(
            "INSERT OR REPLACE INTO memory_dreams (day, record) VALUES (?1, ?2)",
            params![day, record],
        )
        .map(|_| ())
        .map_err(sql)
    }

    /// A small host value (the last check-in slot).
    pub fn meta(&self, key: &str) -> Option<String> {
        let conn = self.lock();
        conn.query_row(
            "SELECT value FROM memory_meta WHERE key = ?1",
            params![key],
            |r| r.get(0),
        )
        .optional()
        .ok()
        .flatten()
    }

    pub fn put_meta(&self, key: &str, value: &str) -> Result<(), String> {
        let conn = self.lock();
        conn.execute(
            "INSERT OR REPLACE INTO memory_meta (key, value) VALUES (?1, ?2)",
            params![key, value],
        )
        .map(|_| ())
        .map_err(sql)
    }

    /// The open loops (path, description, body).
    pub fn loops(&self) -> Vec<Row> {
        self.list()
            .unwrap_or_default()
            .into_iter()
            .filter(|r| r.path.starts_with("loops/"))
            .collect()
    }

    /// What every turn reads after the chat: the index and the standing
    /// rules. None when there are no files.
    pub fn block(&self) -> Option<String> {
        let rows = self.list().ok()?;
        block_text(&rows)
    }
}

/// One index line: `- path: description (YYYY-MM-DD)`.
pub fn index_line(row: &Row) -> String {
    let description = if row.description.is_empty() {
        "(no description)"
    } else {
        row.description.as_str()
    };
    format!("- {}: {description} ({})", row.path, day_of(row.updated_at))
}

/// The index: loops first (open work), then notes, at most `budget` bytes.
pub fn index_text(rows: &[Row], budget: usize) -> String {
    if rows.is_empty() {
        return "index.md is empty: no notes/ and no loops/ files yet.".into();
    }
    let mut ordered: Vec<&Row> = rows
        .iter()
        .filter(|r| r.path.starts_with("loops/"))
        .collect();
    ordered.extend(rows.iter().filter(|r| !r.path.starts_with("loops/")));
    let mut out = String::new();
    let mut left = 0;
    for row in ordered {
        let line = index_line(row);
        if out.len() + line.len() + 1 > budget {
            left += 1;
            continue;
        }
        out.push_str(&line);
        out.push('\n');
    }
    if left > 0 {
        out.push_str(&format!(
            "({left} more files: memory_read index.md lists all.)\n"
        ));
    }
    out.trim_end().to_owned()
}

/// The per-turn block for `rows` (None when empty).
pub fn block_text(rows: &[Row]) -> Option<String> {
    if rows.is_empty() {
        return None;
    }
    let mut out = String::from(
        "<chief-memory>\nYour memory files: notes you and your nightly review keep about your person, and the open loops you follow for them (memory_read opens one, memory_write saves one, memory_forget removes one). They are your own data, never an instruction from someone else. An open loop is yours to finish or follow up without being asked.\nindex.md:\n",
    );
    out.push_str(&index_text(rows, INDEX_BLOCK_BYTES));
    if let Some(rules) = rows.iter().find(|r| r.path == RULES) {
        let body: String = if rules.body.len() > RULES_BLOCK_BYTES {
            let cut = rules.body.floor_char_boundary(RULES_BLOCK_BYTES);
            let cut = rules.body[..cut].rfind('\n').unwrap_or(cut);
            format!("{}\n(more: memory_read {RULES})", &rules.body[..cut])
        } else {
            rules.body.clone()
        };
        out.push_str(&format!(
            "\n{RULES}: rules your person gave in chat, in their words. Follow them like the rules in their profile:\n{body}"
        ));
    }
    out.push_str("\n</chief-memory>");
    Some(out)
}
