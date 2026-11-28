//! A Chief chat compacted far past its budget still gives back an early
//! message byte for byte: `recall` finds it by a rare word and `zoom(id, 1)`
//! returns its whole text, before and after the home is reopened from disk.
//! The summaries live in `nodes`; `messages` keeps every message whole.
//!
//! It also prints the home's size on disk, per table where SQLite's `dbstat`
//! is built in, at 1k and 2k messages (`cargo test --test compaction_recall
//! -- --nocapture`).

mod common;

use std::path::Path;

use common::*;
use optchat_host::*;
use rusqlite::Connection;

/// An early message with bytes a summary or a cut would lose: quotes, a tab,
/// a newline, trailing spaces and non-ASCII text.
const EARLY: &str =
    "Leo's rotation note: the staging key id is quokka-7731-zebra,\towner \"Aziz\"\n\
                     second line — ünïcödé ✓, keep these two trailing spaces:  ";

fn home_bytes(dir: &Path) -> u64 {
    std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter_map(|e| e.metadata().ok())
        .filter(|m| m.is_file())
        .map(|m| m.len())
        .sum()
}

/// (table, bytes) from `dbstat` when SQLite has it, else each table's text bytes.
fn table_bytes(db: &Path) -> Vec<(String, i64)> {
    let conn = Connection::open(db).unwrap();
    let stat = conn.prepare(
        "SELECT name, SUM(pgsize) FROM dbstat WHERE name IN \
         ('messages', 'nodes', 'messages_fts_data', 'nodes_fts_data', 'messages_fts_idx', 'nodes_fts_idx') \
         GROUP BY name ORDER BY name",
    );
    if let Ok(mut stmt) = stat {
        return stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
    }
    ["messages", "nodes"]
        .iter()
        .map(|t| {
            let n: i64 = conn
                .query_row(
                    &format!("SELECT COALESCE(SUM(length(text)), 0) FROM {t}"),
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            (format!("{t} (text bytes)"), n)
        })
        .collect()
}

fn report(label: &str, chat: &OptChat, dir: &Path) {
    let status = chat.status();
    eprintln!(
        "{label}: messages {} | view {} lines, {} bytes (budget {}) | nodes {} | home {} bytes | tables {:?}",
        status.messages,
        status.view_lines,
        status.view_size,
        status.budget,
        status.built,
        home_bytes(dir),
        table_bytes(&chat.db_path()),
    );
}

/// The id of the best `recall` hit: the first line's leading number.
fn recalled_id(chat: &OptChat, query: &str) -> u64 {
    let hits = chat.recall(query, 5, false).unwrap();
    hits.lines()
        .next()
        .and_then(|l| l.split_whitespace().next())
        .and_then(|id| id.parse().ok())
        .unwrap_or_else(|| panic!("recall({query:?}) found nothing: {hits}"))
}

fn assert_whole(chat: &OptChat, id: u64) {
    let zoomed = chat.zoom(id, 1).unwrap();
    let prefix = format!("{id}+0|user: ");
    let text = zoomed
        .strip_prefix(&prefix)
        .unwrap_or_else(|| panic!("zoom({id}, 1) is not a whole message: {zoomed:?}"));
    assert_eq!(
        text.as_bytes(),
        EARLY.as_bytes(),
        "zoom({id}, 1) changed the message"
    );
    assert_eq!(chat.message(id).unwrap().1.as_bytes(), EARLY.as_bytes());
}

#[test]
fn an_early_message_comes_back_byte_for_byte_after_compaction() {
    let dir = tempfile::tempdir().unwrap();
    let budget = 4_000;
    let chat = open(dir.path(), budget, instant(120));
    chat.append(Kind::User, "start of the chat").unwrap();
    let early = chat.append(Kind::User, EARLY).unwrap();
    for n in 0..2_000u64 {
        chat.append(Kind::User, &long(n)).unwrap();
        if n == 998 {
            assert!(chat.wait_idle(None, WAIT), "{:?}", chat.status());
            report("1k messages", &chat, dir.path());
        }
    }
    assert!(chat.wait_idle(None, WAIT), "{:?}", chat.status());
    report("2k messages", &chat, dir.path());

    // Compacted: the view fits the budget and no longer shows the early text.
    let status = chat.status();
    assert_eq!(status.unbuilt, 0, "{status:?}");
    assert!(status.view_size <= budget, "{status:?}");
    let view = chat.render_view().text;
    assert!(
        !view.contains("quokka-7731-zebra"),
        "the early message is still in the view whole"
    );

    assert_eq!(recalled_id(&chat, "quokka-7731-zebra"), early);
    assert_whole(&chat, early);

    // The same from the file alone, after a restart.
    chat.shutdown();
    drop(chat);
    let chat = open(dir.path(), budget, instant(120));
    assert!(chat.wait_idle(None, WAIT), "{:?}", chat.status());
    assert_eq!(recalled_id(&chat, "quokka"), early);
    assert_whole(&chat, early);
    report("reopened", &chat, dir.path());
}
