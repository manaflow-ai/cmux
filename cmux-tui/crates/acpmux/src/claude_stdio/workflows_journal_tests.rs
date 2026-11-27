use super::*;
use std::io::Write;

/// The journal is read from where the last read stopped, whole lines only.
#[test]
fn the_journal_is_read_once_in_all() {
    let dir = std::env::temp_dir().join(format!("acpmux-wf-tail-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("journal.jsonl");
    std::fs::write(
        &path,
        "{\"type\":\"launched\"}\n{\"type\":\"started\"}\n{\"type\":\"started\"}\n",
    )
    .unwrap();
    let tail = JournalTail::default().read(&dir).unwrap();
    assert_eq!((tail.started, tail.done), (2, 0));
    // A line still being written is left for the next read.
    let mut file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
    file.write_all(b"{\"type\":\"result\"}\n{\"type\":\"res").unwrap();
    let tail = tail.read(&dir).unwrap();
    assert_eq!((tail.started, tail.done), (2, 1));
    file.write_all(b"ult\"}\n").unwrap();
    let tail = tail.read(&dir).unwrap();
    assert_eq!((tail.started, tail.done), (2, 2));
    assert_eq!(tail.offset, std::fs::metadata(&path).unwrap().len());
    let _ = std::fs::remove_dir_all(dir);
}
