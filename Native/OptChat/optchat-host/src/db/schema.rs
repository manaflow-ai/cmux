//! The memory database's schema and its migrations. `schema_version` holds
//! one row; each migration runs in its own transaction and moves it by one,
//! so a crash between two migrations resumes at the next.

use rusqlite::{Connection, OptionalExtension};

/// Each entry takes the schema from version `k` to `k + 1`.
const MIGRATIONS: [&str; 1] = [V1];

/// The current schema version.
pub const VERSION: i64 = MIGRATIONS.len() as i64;

/// Version 1 (2026-10-06).
///
/// - `messages`: the log (section 2). `id` is dense, 0..T. `day` is the
///   local day of the export's day file (the day of `date`, or the day file
///   an imported line came from). `conv_msg` is the conversation message a
///   human message came from (`<conversation>#<seq>`), unique, so the same
///   message is never logged twice. `attachments` is a JSON array of
///   attachment references (unused until images land).
/// - `nodes`: the tree (section 3). The rowid is the insertion order, which
///   the export keeps. `nodes_size` covers what `Memory::load` reads, so the
///   start reads no node text.
/// - `state`: the host's durable state, one JSON value per key.
/// - `messages_fts`, `nodes_fts`: full-text indexes over the texts, external
///   content (the text is stored once), kept by the insert triggers.
const V1: &str = "
CREATE TABLE messages (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    date TEXT NOT NULL,
    day TEXT NOT NULL,
    text TEXT NOT NULL,
    conv_msg TEXT UNIQUE,
    attachments TEXT
);
CREATE INDEX messages_day ON messages(day, id);
CREATE TABLE nodes (
    level INTEGER NOT NULL,
    idx INTEGER NOT NULL,
    bytes INTEGER NOT NULL,
    day TEXT NOT NULL,
    text TEXT NOT NULL,
    PRIMARY KEY (level, idx)
);
CREATE INDEX nodes_size ON nodes(level, idx, bytes);
CREATE INDEX nodes_day ON nodes(day);
CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE VIRTUAL TABLE messages_fts USING fts5(text, content='messages', content_rowid='id');
CREATE VIRTUAL TABLE nodes_fts USING fts5(text, content='nodes', content_rowid='rowid');
CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER nodes_fts_insert AFTER INSERT ON nodes BEGIN
    INSERT INTO nodes_fts(rowid, text) VALUES (new.rowid, new.text);
END;
";

/// The stored schema version (0 for a new file).
pub fn version(conn: &Connection) -> rusqlite::Result<i64> {
    let exists: Option<String> = conn
        .query_row(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'schema_version'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if exists.is_none() {
        return Ok(0);
    }
    conn.query_row("SELECT version FROM schema_version", [], |r| r.get(0))
        .optional()
        .map(|v| v.unwrap_or(0))
}

/// Brings the schema to `VERSION`. A file from a newer build is refused:
/// this build would not know its tables.
pub fn migrate(conn: &mut Connection) -> rusqlite::Result<()> {
    let mut at = version(conn)?;
    if at > VERSION {
        return Err(rusqlite::Error::InvalidParameterName(format!(
            "the memory database has schema version {at}; this build knows up to {VERSION}"
        )));
    }
    while at < VERSION {
        let tx = conn.transaction()?;
        tx.execute_batch(MIGRATIONS[at as usize])?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
             DELETE FROM schema_version;",
        )?;
        tx.execute("INSERT INTO schema_version (version) VALUES (?1)", [at + 1])?;
        tx.commit()?;
        at += 1;
    }
    Ok(())
}
