//! The move from the JSONL line store to SQLite: a home with only the old
//! day files is imported once, verified, its files kept; the text export
//! gives the same files back. `fixtures/old-home` was written by the line
//! store itself (feat-cmux-next-home-chief-live at 07a17e8a78d, 40 messages,
//! every node built, view budget 3,000), its main stream then split over
//! two days with id 39 in the earlier file (a clock moved back).

mod common;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use common::*;
use optchat_host::db::{ReadOnly, MIGRATION_KEY};
use optchat_host::*;

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/old-home")
}

/// A copy of the fixture's day files in `dir`.
fn old_home(dir: &Path) {
    for stream in ["main", "tree"] {
        fs::create_dir_all(dir.join(stream)).unwrap();
        for f in fs::read_dir(fixture().join(stream)).unwrap() {
            let f = f.unwrap().path();
            fs::copy(&f, dir.join(stream).join(f.file_name().unwrap())).unwrap();
        }
    }
}

fn files(dir: &Path) -> Vec<(String, Vec<u8>)> {
    let mut out = Vec::new();
    for stream in ["main", "tree"] {
        let mut names: Vec<PathBuf> = fs::read_dir(dir.join(stream))
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
            .collect();
        names.sort();
        for p in names {
            let name = format!("{stream}/{}", p.file_name().unwrap().to_string_lossy());
            out.push((name, fs::read(&p).unwrap()));
        }
    }
    out
}

fn backups(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| {
            p.file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with("memory-jsonl-backup-"))
        })
        .collect()
}

fn open_reporting(chat_dir: &Path, db: &Path) -> (OptChat, Vec<Report>) {
    let (cfg, reports) = config(3_000);
    let cfg = Config {
        db: Some(db.to_owned()),
        ..cfg
    };
    let chat = OptChat::open_with(chat_dir, cfg, instant(180), Arc::new(SystemClock)).unwrap();
    let reports = reports.lock().unwrap().clone();
    (chat, reports)
}

#[test]
fn an_old_home_is_imported_once_verified_and_its_files_kept() {
    let home = tempfile::tempdir().unwrap();
    let chat_dir = home.path().join("chat");
    let db = home.path().join(DB_FILE);
    old_home(&chat_dir);
    let before = files(&chat_dir);

    let (chat, reports) = open_reporting(&chat_dir, &db);
    let migrated: Vec<&Report> = reports
        .iter()
        .filter(|r| matches!(r, Report::Migrated { .. }))
        .collect();
    assert_eq!(migrated.len(), 1, "{reports:?}");
    let Report::Migrated {
        messages,
        nodes,
        backup,
        ..
    } = migrated[0]
    else {
        unreachable!()
    };
    assert_eq!((*messages, *nodes), (40, 78));
    // The old files are untouched, and copied into the backup folder.
    assert_eq!(files(&chat_dir), before);
    assert_eq!(files(backup), before);
    // The memory is the old one: same view, messages, nodes and dates.
    let view = fs::read_to_string(fixture().join("view.txt")).unwrap();
    assert!(chat.settle(None, WAIT));
    assert_eq!(chat.render_view().text, view);
    let status = chat.status();
    assert_eq!((status.messages, status.built), (40, 78));
    assert_eq!(chat.message(39).unwrap().0, Kind::Note);
    assert!(chat.stamp(39).unwrap().starts_with("2026-10-04T"));
    let record: serde_json::Value =
        serde_json::from_str(&chat.state(MIGRATION_KEY).unwrap().unwrap()).unwrap();
    assert_eq!(
        (record["messages"].as_u64(), record["nodes"].as_u64()),
        (Some(40), Some(78))
    );
    // New messages go on from 40.
    assert_eq!(chat.append(Kind::User, "after the move").unwrap(), 40);
    drop(chat);

    // A second start imports nothing and makes no second backup.
    let (chat, reports) = open_reporting(&chat_dir, &db);
    assert!(
        !reports.iter().any(|r| matches!(r, Report::Migrated { .. })),
        "{reports:?}"
    );
    assert_eq!(backups(home.path()).len(), 1);
    assert_eq!(chat.status().messages, 41);
}

#[test]
fn the_export_of_a_migrated_home_is_byte_identical_to_its_old_files() {
    let home = tempfile::tempdir().unwrap();
    let chat_dir = home.path().join("chat");
    let db = home.path().join(DB_FILE);
    old_home(&chat_dir);
    let (chat, _) = open_reporting(&chat_dir, &db);
    assert!(chat.settle(None, WAIT));
    let reader = ReadOnly::open(&db).unwrap();
    let out = home.path().join("export");
    let stats = reader.export_text(&out).unwrap();
    assert_eq!((stats.messages, stats.nodes), (40, 78));
    assert_eq!(files(&out), files(&fixture()));
    // Exporting over the old files changes none of them (git sees nothing).
    let again = reader.export_text(&chat_dir).unwrap();
    assert_eq!(again.files_written, 0);

    // And the export imports into a fresh memory as the same memory.
    let other = tempfile::tempdir().unwrap();
    let fresh = OptChat::open_with(
        other.path().join("chat"),
        config(3_000).0,
        instant(180),
        Arc::new(SystemClock),
    )
    .unwrap();
    let imported = fresh.import_jsonl(&out).unwrap();
    assert_eq!((imported.messages, imported.nodes), (40, 78));
    assert_eq!(fresh.render_view(), chat.render_view());
    // An import into a memory that is not empty is refused.
    assert!(matches!(fresh.import_jsonl(&out), Err(Error::Io(_))));
}

#[test]
fn torn_and_stray_lines_of_an_old_home_are_reported_and_skipped() {
    let home = tempfile::tempdir().unwrap();
    let chat_dir = home.path().join("chat");
    old_home(&chat_dir);
    let main = chat_dir.join("main/2026-10-05.jsonl");
    let tree = chat_dir.join("tree/2026-10-05.jsonl");
    let mut tail = fs::read(&tree).unwrap();
    // A duplicate node, a node past the end, and a torn line in each stream.
    let first = fs::read_to_string(chat_dir.join("tree/2026-10-04.jsonl")).unwrap();
    tail.extend_from_slice(first.lines().next().unwrap().as_bytes());
    tail.extend_from_slice(b"\n{\"l\":0,\"i\":99,\"text\":\"x\",\"size\":1}\n{\"l\":0,\"i\"");
    fs::write(&tree, tail).unwrap();
    let mut m = fs::read(&main).unwrap();
    m.extend_from_slice(br#"{"i":40,"kind":"us"#);
    fs::write(&main, m).unwrap();

    let (chat, reports) = open_reporting(&chat_dir, &home.path().join(DB_FILE));
    let count = |f: fn(&Report) -> bool| reports.iter().filter(|r| f(r)).count();
    assert_eq!(
        count(|r| matches!(r, Report::InvalidLine { .. })),
        2,
        "{reports:?}"
    );
    assert_eq!(
        count(|r| matches!(r, Report::MissingNewline { .. })),
        2,
        "{reports:?}"
    );
    assert_eq!(
        count(|r| matches!(r, Report::IgnoredNode { .. })),
        2,
        "{reports:?}"
    );
    assert_eq!(chat.status().messages, 40);
    assert_eq!(chat.status().built, 78);
    // The import never edits the old files.
    assert!(!fs::read(&main).unwrap().ends_with(b"\n"));
}

#[test]
fn an_old_home_with_a_gap_in_its_ids_is_refused_and_imports_nothing() {
    let home = tempfile::tempdir().unwrap();
    let chat_dir = home.path().join("chat");
    fs::create_dir_all(chat_dir.join("main")).unwrap();
    fs::write(
        chat_dir.join("main/2026-01-01.jsonl"),
        "{\"i\":0,\"kind\":\"user\",\"text\":\"a\",\"size\":7,\"date\":\"2026-01-01T00:00:00Z\"}\n\
         {\"i\":2,\"kind\":\"user\",\"text\":\"b\",\"size\":7,\"date\":\"2026-01-01T00:00:01Z\"}\n",
    )
    .unwrap();
    let db = home.path().join(DB_FILE);
    let open = || {
        OptChat::open_with(
            &chat_dir,
            Config {
                db: Some(db.clone()),
                ..config(128_000).0
            },
            instant(200),
            Arc::new(SystemClock),
        )
    };
    assert!(matches!(open(), Err(Error::Io(_))));
    assert_eq!(ReadOnly::open(&db).unwrap().counts().unwrap().messages, 0);
    // Still refused on the next start: nothing was half-imported.
    assert!(matches!(open(), Err(Error::Io(_))));
}

/// The child of the migration crash tests: opens the old home, and is
/// aborted at the injected point.
#[test]
fn migration_crash_child() {
    let Some(dir) = crash_dir() else { return };
    let (cfg, _) = config(3_000);
    let cfg = Config {
        db: Some(dir.join(DB_FILE)),
        ..cfg
    };
    let chat = OptChat::open_with(dir.join("chat"), cfg, instant(180), Arc::new(SystemClock));
    drop(chat);
}

#[test]
fn a_crash_during_the_migration_leaves_nothing_half_done() {
    if crash_dir().is_some() {
        return;
    }
    for point in ["migrate:after-backup", "migrate:before-commit"] {
        let home = tempfile::tempdir().unwrap();
        old_home(&home.path().join("chat"));
        assert!(
            crash_child("migration_crash_child", point, home.path()),
            "{point}"
        );
        let db = home.path().join(DB_FILE);
        assert_eq!(
            ReadOnly::open(&db).unwrap().counts().unwrap().messages,
            0,
            "{point}: a crash before the commit stores nothing"
        );
        // The next start migrates, once.
        let (chat, reports) = open_reporting(&home.path().join("chat"), &db);
        assert_eq!(
            reports
                .iter()
                .filter(|r| matches!(r, Report::Migrated { .. }))
                .count(),
            1,
            "{point}: {reports:?}"
        );
        assert_eq!(
            (chat.status().messages, chat.status().built),
            (40, 78),
            "{point}"
        );
        drop(chat);
        let (_, reports) = open_reporting(&home.path().join("chat"), &db);
        assert!(!reports.iter().any(|r| matches!(r, Report::Migrated { .. })));
    }
}

/// Sets the migration record's date `days` back.
fn age_migration(chat: &OptChat, days: i64) {
    let mut record: serde_json::Value =
        serde_json::from_str(&chat.state(MIGRATION_KEY).unwrap().unwrap()).unwrap();
    let at = chrono::Local::now() - chrono::Duration::days(days);
    record["at"] = serde_json::json!(at.to_rfc3339());
    chat.put_state(&[(MIGRATION_KEY.to_owned(), Some(record.to_string()))])
        .unwrap();
}

/// Waits for a report the retiring thread sends.
fn wait_report(reports: &std::sync::Mutex<Vec<Report>>, want: fn(&Report) -> bool) -> Report {
    let until = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        if let Some(r) = reports.lock().unwrap().iter().find(|r| want(r)) {
            return r.clone();
        }
        assert!(std::time::Instant::now() < until, "no such report");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

fn open_collecting(chat_dir: &Path, db: &Path) -> (OptChat, Arc<std::sync::Mutex<Vec<Report>>>) {
    let (cfg, reports) = config(3_000);
    let cfg = Config {
        db: Some(db.to_owned()),
        ..cfg
    };
    let chat = OptChat::open_with(chat_dir, cfg, instant(180), Arc::new(SystemClock)).unwrap();
    (chat, reports)
}

#[test]
fn the_old_files_copy_is_checked_again_and_deleted_after_a_week() {
    let home = tempfile::tempdir().unwrap();
    let chat_dir = home.path().join("chat");
    let db = home.path().join(DB_FILE);
    old_home(&chat_dir);
    let (chat, _) = open_reporting(&chat_dir, &db);
    // Six days: kept.
    age_migration(&chat, 6);
    drop(chat);
    let (chat, reports) = open_collecting(&chat_dir, &db);
    std::thread::sleep(std::time::Duration::from_millis(200));
    assert!(!reports
        .lock()
        .unwrap()
        .iter()
        .any(|r| matches!(r, Report::BackupRetired { .. })));
    assert_eq!(backups(home.path()).len(), 1);
    age_migration(&chat, 8);
    drop(chat);
    // Eight days: imported again, same counts and hash, deleted, recorded.
    let (chat, reports) = open_collecting(&chat_dir, &db);
    let r = wait_report(&reports, |r| matches!(r, Report::BackupRetired { .. }));
    assert!(
        matches!(
            r,
            Report::BackupRetired {
                messages: 40,
                nodes: 78,
                ..
            }
        ),
        "{r:?}"
    );
    assert!(backups(home.path()).is_empty());
    let record: serde_json::Value =
        serde_json::from_str(&chat.state(MIGRATION_KEY).unwrap().unwrap()).unwrap();
    assert_eq!(record["backup_deleted"]["verified_messages"], 40);
    // The memory itself is untouched.
    assert_eq!(chat.status().messages, 40);
}

#[test]
fn a_copy_that_does_not_match_the_migration_is_kept() {
    let home = tempfile::tempdir().unwrap();
    let chat_dir = home.path().join("chat");
    let db = home.path().join(DB_FILE);
    old_home(&chat_dir);
    let (chat, _) = open_reporting(&chat_dir, &db);
    age_migration(&chat, 8);
    drop(chat);
    let backup = backups(home.path()).pop().unwrap();
    let day = backup.join("main/2026-10-05.jsonl");
    let mut text = fs::read_to_string(&day).unwrap();
    text.push_str("{\"i\":40,\"kind\":\"user\",\"text\":\"x\",\"size\":7,\"date\":\"2026-10-05T00:00:00Z\"}\n");
    fs::write(&day, text).unwrap();
    let (_chat, reports) = open_collecting(&chat_dir, &db);
    let r = wait_report(&reports, |r| matches!(r, Report::BackupKept { .. }));
    assert!(
        matches!(&r, Report::BackupKept { why, .. } if why.contains("41 messages")),
        "{r:?}"
    );
    assert!(backup.is_dir());
}
