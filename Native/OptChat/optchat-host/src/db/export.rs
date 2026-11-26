//! The plain-text export: the database written back as the JSONL day files
//! the line store kept (`main/YYYY-MM-DD.jsonl` with `{i, kind, text, size,
//! date}`, `tree/YYYY-MM-DD.jsonl` with `{l, i, text, size}`), for reading,
//! `rg`, and the git backup. Deterministic: a day file holds that day's
//! messages in id order and its nodes in the order they were stored, so the
//! export of an imported home is byte-identical to the files it came from.
//!
//! `export_text` writes everything from one snapshot (a file whose bytes
//! did not change is left alone, so git sees no change). `Exporter` keeps a
//! watermark (`.export.json`) and afterwards appends only the rows stored
//! since: new message ids and node rowids are larger than every exported
//! one, so appending them gives the same bytes as a full export.

use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufWriter, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use optchat_core::{Kind, NodeId};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use super::{private_dir, sql};
use crate::lines;

/// What an export wrote.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ExportStats {
    pub messages: u64,
    pub nodes: u64,
    /// Day files created or rewritten (unchanged ones are not counted).
    pub files_written: usize,
}

const MARK: &str = ".export.json";

fn same_bytes(a: &Path, b: &Path) -> io::Result<bool> {
    let (ma, mb) = match (fs::metadata(a), fs::metadata(b)) {
        (Ok(ma), Ok(mb)) => (ma, mb),
        _ => return Ok(false),
    };
    if ma.len() != mb.len() {
        return Ok(false);
    }
    let (mut fa, mut fb) = (File::open(a)?, File::open(b)?);
    let (mut ba, mut bb) = (vec![0u8; 1 << 16], vec![0u8; 1 << 16]);
    loop {
        let n = fa.read(&mut ba)?;
        if n == 0 {
            return Ok(true);
        }
        fb.read_exact(&mut bb[..n])?;
        if ba[..n] != bb[..n] {
            return Ok(false);
        }
    }
}

/// One stream's day files during a full export.
struct DayFiles {
    dir: PathBuf,
    current: Option<(String, PathBuf, BufWriter<File>)>,
    seen: BTreeSet<String>,
    written: usize,
}

impl DayFiles {
    fn new(dir: PathBuf) -> io::Result<DayFiles> {
        private_dir(&dir)?;
        Ok(DayFiles {
            dir,
            current: None,
            seen: BTreeSet::new(),
            written: 0,
        })
    }

    fn write(&mut self, day: &str, line: &str) -> io::Result<()> {
        if self.current.as_ref().is_none_or(|(d, _, _)| d != day) {
            self.finish()?;
            let tmp = self.dir.join(format!("{day}.jsonl.export.tmp"));
            let file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp)?;
            self.current = Some((day.to_owned(), tmp, BufWriter::new(file)));
        }
        if let Some((_, _, w)) = self.current.as_mut() {
            w.write_all(line.as_bytes())?;
        }
        Ok(())
    }

    fn finish(&mut self) -> io::Result<()> {
        let Some((day, tmp, mut w)) = self.current.take() else {
            return Ok(());
        };
        w.flush()?;
        drop(w);
        let name = format!("{day}.jsonl");
        let dest = self.dir.join(&name);
        if same_bytes(&tmp, &dest)? {
            fs::remove_file(&tmp)?;
        } else {
            fs::rename(&tmp, &dest)?;
            self.written += 1;
        }
        self.seen.insert(name);
        Ok(())
    }

    /// Removes day files the database has no rows for.
    fn close(mut self) -> io::Result<usize> {
        self.finish()?;
        for entry in fs::read_dir(&self.dir)? {
            let path = entry?.path();
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if (name.ends_with(".jsonl") && !self.seen.contains(name))
                || name.ends_with(".export.tmp")
            {
                fs::remove_file(&path)?;
                self.written += 1;
            }
        }
        Ok(self.written)
    }
}

fn kind(text: &str) -> rusqlite::Result<Kind> {
    Kind::parse(text).ok_or_else(|| {
        rusqlite::Error::InvalidColumnType(
            1,
            format!("unknown kind {text:?}"),
            rusqlite::types::Type::Text,
        )
    })
}

/// Calls `line(day, rendered line)` for each message with id >= `from`,
/// by day, then id. Returns how many.
fn each_message(
    conn: &Connection,
    from: u64,
    mut line: impl FnMut(&str, &str) -> io::Result<()>,
) -> io::Result<u64> {
    let mut stmt = conn
        .prepare_cached(
            "SELECT day, id, kind, text, date FROM messages INDEXED BY messages_day \
             WHERE id >= ?1 ORDER BY day, id",
        )
        .map_err(sql)?;
    let mut rows = stmt.query([from as i64]).map_err(sql)?;
    let mut n = 0;
    while let Some(r) = rows.next().map_err(sql)? {
        let day: String = r.get(0).map_err(sql)?;
        let id: i64 = r.get(1).map_err(sql)?;
        let k = kind(&r.get::<_, String>(2).map_err(sql)?).map_err(sql)?;
        let text: String = r.get(3).map_err(sql)?;
        let date: String = r.get(4).map_err(sql)?;
        line(&day, &lines::main_line(id as u64, k, &text, &date)?)?;
        n += 1;
    }
    Ok(n)
}

/// Calls `line(day, rendered line)` for each node with rowid > `after`, by
/// day, then storage order. Returns how many and the largest rowid seen.
fn each_node(
    conn: &Connection,
    after: i64,
    mut line: impl FnMut(&str, &str) -> io::Result<()>,
) -> io::Result<(u64, i64)> {
    let mut stmt = conn
        .prepare_cached(
            "SELECT day, rowid, level, idx, text FROM nodes INDEXED BY nodes_day \
             WHERE rowid > ?1 ORDER BY day, rowid",
        )
        .map_err(sql)?;
    let mut rows = stmt.query([after]).map_err(sql)?;
    let (mut n, mut top) = (0, after);
    while let Some(r) = rows.next().map_err(sql)? {
        let day: String = r.get(0).map_err(sql)?;
        let rowid: i64 = r.get(1).map_err(sql)?;
        let l: i64 = r.get(2).map_err(sql)?;
        let i: i64 = r.get(3).map_err(sql)?;
        let text: String = r.get(4).map_err(sql)?;
        line(
            &day,
            &lines::tree_line(NodeId::new(l as u32, i as u64), &text)?,
        )?;
        n += 1;
        top = top.max(rowid);
    }
    Ok((n, top))
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Mark {
    /// The next message id to export.
    messages: u64,
    /// The largest node rowid exported.
    node_rowid: i64,
}

fn full(conn: &Connection, dir: &Path) -> io::Result<(ExportStats, Mark)> {
    private_dir(dir)?;
    // One snapshot for both streams and the watermark.
    let tx = conn.unchecked_transaction().map_err(sql)?;
    let mut main = DayFiles::new(dir.join("main"))?;
    let messages = each_message(&tx, 0, |day, line| main.write(day, line))?;
    let mut tree = DayFiles::new(dir.join("tree"))?;
    let (nodes, node_rowid) = each_node(&tx, 0, |day, line| tree.write(day, line))?;
    let files_written = main.close()? + tree.close()?;
    tx.finish().map_err(sql)?;
    let stats = ExportStats {
        messages,
        nodes,
        files_written,
    };
    Ok((
        stats,
        Mark {
            messages,
            node_rowid,
        },
    ))
}

/// Writes the whole database under `dir` as JSONL day files (see the module
/// doc), from one snapshot. Day files with no rows are removed.
pub fn export_text(conn: &Connection, dir: &Path) -> io::Result<ExportStats> {
    full(conn, dir).map(|(stats, _)| stats)
}

/// Keeps an export directory in step with the database.
pub struct Exporter {
    dir: PathBuf,
    mark: Option<Mark>,
}

fn append_line(dir: &Path, day: &str, line: &str) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(dir.join(format!("{day}.jsonl")))?;
    file.write_all(line.as_bytes())
}

impl Exporter {
    /// An exporter for `dir`; its watermark, if any, is read from
    /// `dir/.export.json`. Without one the first `sync` is a full export.
    pub fn new(dir: &Path) -> Exporter {
        let mark = fs::read(dir.join(MARK))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok());
        Exporter {
            dir: dir.to_owned(),
            mark,
        }
    }

    /// Brings the export up to date: a full export the first time, then
    /// only the rows stored since. A failure drops the watermark, so the
    /// next sync rewrites everything instead of appending twice.
    pub fn sync(&mut self, conn: &super::ReadOnly) -> io::Result<ExportStats> {
        let result = self.sync_inner(conn.connection());
        if result.is_err() {
            self.mark = None;
            let _ = fs::remove_file(self.dir.join(MARK));
        }
        result
    }

    fn sync_inner(&mut self, conn: &Connection) -> io::Result<ExportStats> {
        let (stats, mark) = match self.mark {
            None => full(conn, &self.dir)?,
            Some(mark) => {
                let tx = conn.unchecked_transaction().map_err(sql)?;
                let main = self.dir.join("main");
                let tree = self.dir.join("tree");
                private_dir(&main)?;
                private_dir(&tree)?;
                let mut days = BTreeSet::new();
                let messages = each_message(&tx, mark.messages, |day, line| {
                    days.insert(format!("m{day}"));
                    append_line(&main, day, line)
                })?;
                let (nodes, node_rowid) = each_node(&tx, mark.node_rowid, |day, line| {
                    days.insert(format!("t{day}"));
                    append_line(&tree, day, line)
                })?;
                tx.finish().map_err(sql)?;
                let stats = ExportStats {
                    messages,
                    nodes,
                    files_written: days.len(),
                };
                let mark = Mark {
                    messages: mark.messages + messages,
                    node_rowid,
                };
                (stats, mark)
            }
        };
        let tmp = self.dir.join(format!("{MARK}.tmp"));
        fs::write(&tmp, serde_json::to_vec(&mark).map_err(io::Error::other)?)?;
        fs::rename(&tmp, self.dir.join(MARK))?;
        self.mark = Some(mark);
        Ok(stats)
    }
}
