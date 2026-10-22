//! A fork of a Chief's memory: a new memory database that holds the source's
//! log up to a cut, and the summaries that lie wholly before it.
//!
//! The person forks a Chief at one message of its conversation ("Fork to New
//! Chief" in Home), or a Chief forks itself now (the `chiefs` tool). The new
//! Chief starts with the source's memory as it was at that point and nothing
//! after: messages from the cut on are left out, and so is every summary that
//! covers one of them. A summary that spans the cut is not copied; the new
//! Chief's compactor builds it again from the copied messages, so no line of
//! the new view ever summarizes what the new Chief does not have.
//!
//! Nothing is shared afterwards: the copy is a new file (rows, not a link),
//! the attachment files it names are copied into the new home and its log
//! names the copies, and none of the source's host state comes along (its
//! conversation, outbox, turns, subagents). The one host value that is kept
//! is the next subagent number, so a new subagent never takes a number the
//! copied memory already uses for one of the source's subagents.
//!
//! The source is read in one read transaction of its own connection, so the
//! copy is consistent while the source's brain keeps writing (WAL).

use std::io;
use std::path::Path;

use optchat_core::{Kind, NodeId};
use rusqlite::{params, Connection, OptionalExtension};

use super::{decode_imported, encode_imported, open_read_only, sql, Db, IMPORTED_KEY};

/// The state key of a forked memory's provenance (a JSON object, [`Provenance`]).
pub const FORK_KEY: &str = "fork/from";
/// The host state key whose value a fork keeps (the next subagent number).
pub const NEXT_SUBAGENT_KEY: &str = "host/next_subagent";

/// Where the cut goes: right after one conversation message, or now.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ForkPoint {
    /// The message's log key (`<conversation>#<seq>`): a person's message
    /// the source logged has one, and the cut goes right after it.
    pub key: Option<String>,
    /// The message's commit time (RFC 3339). A message the source did not
    /// log under its key (its own reply, another Chief's message) cuts after
    /// the last entry logged at or before this time: a reply is logged before
    /// it is posted, the next turn's entries after.
    pub at: Option<String>,
}

impl ForkPoint {
    /// The whole memory as it is now.
    pub fn now() -> ForkPoint {
        ForkPoint::default()
    }

    fn is_now(&self) -> bool {
        self.key.is_none() && self.at.is_none()
    }
}

/// Where the fork came from, kept in the new memory (`fork/from`) and said in
/// its last entry, a note the new Chief reads in its view.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Provenance {
    /// The source Chief's participant id.
    pub chief: String,
    /// The source Chief's display name.
    pub name: String,
    /// The conversation message the fork was made at (`<conversation>#<seq>`),
    /// or None for "now".
    pub message: Option<String>,
    /// Who forked it: `person`, or the Chief's own id.
    pub by: String,
}

/// What a fork copied.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ForkStats {
    /// The source's message count when it was read.
    pub source_messages: u64,
    /// The first source message left out (messages `0..cut` were copied).
    pub cut: u64,
    /// Summaries copied.
    pub nodes: u64,
    /// Summaries left out because they cover a message at or after the cut.
    pub nodes_left_out: u64,
    /// The attachment folders (content hashes) the copied messages name.
    pub attachments: Vec<String>,
    /// The id of the provenance note (the new memory's last entry).
    pub note: u64,
}

/// Why a fork did not happen.
#[derive(Debug)]
pub enum ForkError {
    /// The message is not in the source's memory (another Chief's
    /// conversation, a message from before this memory, a wrong key).
    NotInMemory(String),
    /// The destination already holds a memory.
    DestinationExists(String),
    Io(io::Error),
}

impl std::fmt::Display for ForkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ForkError::NotInMemory(why) => write!(f, "not in the memory: {why}"),
            ForkError::DestinationExists(path) => {
                write!(f, "a memory already exists at {path}")
            }
            ForkError::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for ForkError {}

impl From<io::Error> for ForkError {
    fn from(e: io::Error) -> ForkError {
        ForkError::Io(e)
    }
}

impl From<rusqlite::Error> for ForkError {
    fn from(e: rusqlite::Error) -> ForkError {
        ForkError::Io(sql(e))
    }
}

/// The first message a fork at `point` leaves out, read on `conn` (inside the
/// caller's read transaction). `0..cut` is the forked log.
pub fn resolve_cut(conn: &Connection, point: &ForkPoint) -> Result<u64, ForkError> {
    let t: i64 = conn.query_row("SELECT COALESCE(MAX(id) + 1, 0) FROM messages", [], |r| {
        r.get(0)
    })?;
    let t = t as u64;
    if point.is_now() {
        return Ok(t);
    }
    if let Some(key) = &point.key {
        let id: Option<i64> = conn
            .query_row("SELECT id FROM messages WHERE conv_msg = ?1", [key], |r| {
                r.get(0)
            })
            .optional()?;
        if let Some(id) = id {
            return Ok(id as u64 + 1);
        }
    }
    let Some(at) = &point.at else {
        return Err(ForkError::NotInMemory(format!(
            "no message is logged as {}",
            point.key.as_deref().unwrap_or("?")
        )));
    };
    let at = chrono::DateTime::parse_from_rfc3339(at)
        .map_err(|e| ForkError::NotInMemory(format!("bad time {at}: {e}")))?;
    // Dates are ascending with ids, except across a clock change; scan back
    // from the end for the last entry at or before `at` (a fork is rare, the
    // log is read by key from the newest end, and stops at the first match).
    let mut statement = conn.prepare("SELECT id, date FROM messages ORDER BY id DESC")?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        let (id, date): (i64, String) = (row.get(0)?, row.get(1)?);
        let Ok(date) = chrono::DateTime::parse_from_rfc3339(&date) else {
            continue;
        };
        if date <= at {
            return Ok(id as u64 + 1);
        }
    }
    Err(ForkError::NotInMemory(format!(
        "the memory holds nothing from before {at}"
    )))
}

/// Forks the memory at `source` into a new database at `destination` (which
/// must not exist): the log before the cut [`resolve_cut`] finds for `point`,
/// the summaries wholly before it, the imported ranges clipped to it, the
/// next subagent number, and a last note that says where the memory came
/// from. Attachment paths under `attachments.0` (the source's attachment
/// folder) are rewritten to `attachments.1` (the new home's); the caller
/// copies the folders [`ForkStats::attachments`] names.
///
/// Atomic: the new database is built beside `destination` and linked into
/// place (never over a file that is there), so a failed fork leaves nothing
/// a brain would open.
pub fn fork_memory(
    source: &Path,
    destination: &Path,
    point: &ForkPoint,
    provenance: &Provenance,
    attachments: Option<(&str, &str)>,
) -> Result<ForkStats, ForkError> {
    // A stale -wal or -shm would be read into the new file as its own.
    for path in [
        destination.to_owned(),
        wal_of(destination, "-wal"),
        wal_of(destination, "-shm"),
    ] {
        if path.exists() {
            return Err(ForkError::DestinationExists(path.display().to_string()));
        }
    }
    let building = destination.with_extension(format!("forking-{}", std::process::id()));
    for stale in [
        building.clone(),
        wal_of(&building, "-wal"),
        wal_of(&building, "-shm"),
    ] {
        let _ = std::fs::remove_file(stale);
    }
    let placed = build(source, &building, point, provenance, attachments).and_then(|stats| {
        // A hard link never replaces a file another writer put there since
        // the check above (a rename would); then the build name goes.
        match std::fs::hard_link(&building, destination) {
            Ok(()) => Ok(stats),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Err(
                ForkError::DestinationExists(destination.display().to_string()),
            ),
            Err(e) => Err(ForkError::Io(e)),
        }
    });
    for file in [
        building.clone(),
        wal_of(&building, "-wal"),
        wal_of(&building, "-shm"),
    ] {
        let _ = std::fs::remove_file(file);
    }
    let stats = placed?;
    if let Some(Ok(dir)) = destination.parent().map(std::fs::File::open) {
        let _ = dir.sync_all();
    }
    Ok(stats)
}

fn wal_of(path: &Path, suffix: &str) -> std::path::PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

fn build(
    source: &Path,
    building: &Path,
    point: &ForkPoint,
    provenance: &Provenance,
    attachments: Option<(&str, &str)>,
) -> Result<ForkStats, ForkError> {
    let mut src = open_read_only(source)?;
    // One read transaction: every read below sees the same snapshot.
    let read = src.transaction()?;
    let cut = resolve_cut(&read, point)?;
    let source_messages: i64 =
        read.query_row("SELECT COALESCE(MAX(id) + 1, 0) FROM messages", [], |r| {
            r.get(0)
        })?;
    let mut db = Db::open(building)?;
    let mut stats = ForkStats {
        source_messages: source_messages as u64,
        cut,
        ..ForkStats::default()
    };
    let mut hashes = std::collections::BTreeSet::new();
    let tx = db.conn_mut().transaction()?;
    {
        let mut insert = tx.prepare(
            "INSERT INTO messages (id, kind, date, day, text, conv_msg, attachments) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        )?;
        let mut rows = read.prepare(
            "SELECT id, kind, date, day, text, conv_msg, attachments FROM messages \
             WHERE id < ?1 ORDER BY id",
        )?;
        let mut rows = rows.query([cut as i64])?;
        while let Some(row) = rows.next()? {
            let id: i64 = row.get(0)?;
            let kind: String = row.get(1)?;
            let date: String = row.get(2)?;
            let day: String = row.get(3)?;
            let mut text: String = row.get(4)?;
            let key: Option<String> = row.get(5)?;
            let files: Option<String> = row.get(6)?;
            if let Some((from, to)) = attachments {
                collect_hashes(&text, from, &mut hashes);
                if text.contains(from) {
                    text = text.replace(from, to);
                }
            }
            insert.execute(params![id, kind, date, day, text, key, files])?;
        }
        let mut insert = tx.prepare(
            "INSERT INTO nodes (level, idx, bytes, day, text) VALUES (?1, ?2, ?3, ?4, ?5)",
        )?;
        let mut nodes =
            read.prepare("SELECT level, idx, bytes, day, text FROM nodes ORDER BY rowid")?;
        let mut nodes = nodes.query([])?;
        while let Some(row) = nodes.next()? {
            let (level, idx): (i64, i64) = (row.get(0)?, row.get(1)?);
            let node = NodeId::new(level as u32, idx as u64);
            if node.checked_end().is_none_or(|end| end > cut) {
                stats.nodes_left_out += 1;
                continue;
            }
            let (bytes, day, text): (i64, String, String) = (row.get(2)?, row.get(3)?, row.get(4)?);
            insert.execute(params![level, idx, bytes, day, text])?;
            stats.nodes += 1;
        }
        let state = |key: &str| -> rusqlite::Result<Option<String>> {
            read.query_row("SELECT value FROM state WHERE key = ?1", [key], |r| {
                r.get(0)
            })
            .optional()
        };
        let mut put = tx.prepare("INSERT INTO state (key, value) VALUES (?1, ?2)")?;
        if let Some(ranges) = state(IMPORTED_KEY)? {
            let clipped: Vec<(u64, u64)> = decode_imported(&ranges)
                .into_iter()
                .filter(|(from, _)| *from < cut)
                .map(|(from, to)| (from, to.min(cut)))
                .collect();
            if !clipped.is_empty() {
                put.execute(params![IMPORTED_KEY, encode_imported(&clipped)])?;
            }
        }
        if let Some(next) = state(NEXT_SUBAGENT_KEY)? {
            put.execute(params![NEXT_SUBAGENT_KEY, next])?;
        }
        let note_id = cut;
        let note = provenance_note(provenance, cut, source_messages as u64);
        let date = crate::lines::now_iso();
        insert_note(&tx, note_id, &date, &note)?;
        stats.note = note_id;
        let record = serde_json::json!({
            "chief": provenance.chief,
            "name": provenance.name,
            "message": provenance.message,
            "by": provenance.by,
            "cut": cut,
            "source_messages": source_messages,
            "forked_at": date,
        });
        put.execute(params![FORK_KEY, record.to_string()])?;
    }
    tx.commit()?;
    drop(read);
    // The WAL goes into the file before the rename: a renamed database whose
    // -wal stayed behind under the old name would lose its rows.
    db.conn_mut()
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))?;
    drop(db);
    for suffix in ["-wal", "-shm"] {
        let _ = std::fs::remove_file(wal_of(building, suffix));
    }
    stats.attachments = hashes.into_iter().collect();
    Ok(stats)
}

fn insert_note(tx: &Connection, id: u64, date: &str, text: &str) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT INTO messages (id, kind, date, day, text) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            id as i64,
            Kind::Note.as_str(),
            date,
            crate::lines::day_of(date),
            text
        ],
    )
    .map(|_| ())
}

/// The note that ends a forked memory: where it came from, and what is not
/// in it. The new Chief reads it in its view.
pub fn provenance_note(p: &Provenance, cut: u64, source_messages: u64) -> String {
    let at = match &p.message {
        Some(message) => format!("at conversation message {message}"),
        None => "at the moment of the fork".to_owned(),
    };
    let by = if p.by == "person" {
        "the person".to_owned()
    } else if p.by == p.chief {
        format!("{} itself", p.name)
    } else {
        p.by.clone()
    };
    let left = source_messages.saturating_sub(cut);
    format!(
        "Forked from the Chief {} ({}) {at}, by {by}. This memory is {}'s up to that point \
(messages 0 to {}); its {left} later messages are not in it. You are a new Chief with your \
own conversation: the subagents a<N> named above are {}'s, and their chats are not here.",
        p.name,
        p.chief,
        p.name,
        cut.saturating_sub(1),
        p.name
    )
}

/// The content-hash folders under `root` (`<root><hash>/<file>`) that `text` names.
fn collect_hashes(text: &str, root: &str, out: &mut std::collections::BTreeSet<String>) {
    let mut rest = text;
    while let Some(at) = rest.find(root) {
        let after = &rest[at + root.len()..];
        let hash: String = after
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect();
        if !hash.is_empty() && after[hash.len()..].starts_with('/') {
            out.insert(hash);
        }
        rest = after;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_are_found_once() {
        let mut out = std::collections::BTreeSet::new();
        collect_hashes(
            "see /h/att/ab12/x.png and /h/att/ab12/y.png and /h/att/cd34/z.txt, /h/att/bad",
            "/h/att/",
            &mut out,
        );
        assert_eq!(out.into_iter().collect::<Vec<_>>(), vec!["ab12", "cd34"]);
    }
}
