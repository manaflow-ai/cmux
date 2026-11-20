//! Share Screen with Chief (docs/chief-screen-share.md): what the person's
//! screen showed while they shared it becomes the Chief's memory.
//!
//! The app (CmuxNextChiefScreenShare `ChiefScreenJournal`) writes one JSON
//! entry per changed frame whose text changed into `optchat/screen/inbox/`,
//! each whole (a temporary file, then a rename), and the frame itself under
//! `optchat/screen/frames/<day>/`. At each turn start the brain takes every
//! entry into quiet notes of at most [`PER_NOTE`] frames (one note for a short
//! share, never a cut): the time span, then one line per frame (time, app,
//! window, its text cut short, the frame's file), so the turn's delta
//! carries what was on screen and compaction folds it into the view like any
//! other line. The entries leave the inbox; the frames stay on disk, named in
//! the note. Nothing here wakes the Chief, and an entry that does not parse is
//! dropped (the app never writes half of one).

use std::path::{Path, PathBuf};

use serde::Deserialize;

/// Most frames one note lists; a longer share is several notes.
pub const PER_NOTE: usize = 20;
/// Most characters of one frame's text in the note.
pub const MAX_TEXT: usize = 280;

/// One inbox entry (`ChiefScreenObservation` in the app).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Entry {
    pub day: String,
    pub time: String,
    #[serde(default)]
    pub app: Option<String>,
    #[serde(default)]
    pub window: Option<String>,
    #[serde(default)]
    pub text: String,
    pub frame: String,
}

/// One note to log: its text and its dedupe key (its first and last entry names).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Note {
    pub text: String,
    pub key: String,
}

/// What one ingest takes: the notes to log, oldest first, and the inbox
/// files they consumed (the unreadable ones too).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Taken {
    pub notes: Vec<Note>,
    pub files: Vec<PathBuf>,
}

/// The inbox under a Chief home's `optchat/screen` directory.
pub fn inbox(screen: &Path) -> PathBuf {
    screen.join("inbox")
}

/// Reads the inbox of `screen` (the `optchat/screen` directory): None when
/// it holds no entry. The files are not deleted here; the caller deletes
/// [`Taken::files`] once the note is logged, so a failed append retries.
pub fn take(screen: &Path) -> Option<Taken> {
    let dir = inbox(screen);
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .ok()?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    if files.is_empty() {
        return None;
    }
    // Names are epoch milliseconds: sort by number, not by text.
    files.sort_by_key(|p| {
        p.file_stem()
            .and_then(|s| s.to_str())
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(u64::MAX)
    });
    let entries: Vec<(String, Entry)> = files
        .iter()
        .filter_map(|p| {
            let entry = serde_json::from_slice(&std::fs::read(p).ok()?).ok()?;
            Some((stem(p), entry))
        })
        .collect();
    let notes = entries
        .chunks(PER_NOTE)
        .map(|chunk| {
            let list: Vec<Entry> = chunk.iter().map(|(_, e)| e.clone()).collect();
            Note {
                text: note(&list),
                key: format!("screen:{}-{}", chunk[0].0, chunk[chunk.len() - 1].0),
            }
        })
        .collect();
    Some(Taken { notes, files })
}

/// An inbox file's stem (its epoch milliseconds).
fn stem(p: &Path) -> String {
    p.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default()
        .to_owned()
}

/// The note for `entries`, oldest first (at least one).
pub fn note(entries: &[Entry]) -> String {
    let (first, last) = (&entries[0], &entries[entries.len() - 1]);
    let span = if first.day == last.day {
        format!(
            "{} {}–{}",
            first.day,
            short_time(&first.time),
            short_time(&last.time)
        )
    } else {
        format!(
            "{} {} – {} {}",
            first.day,
            short_time(&first.time),
            last.day,
            short_time(&last.time)
        )
    };
    let frames = if entries.len() == 1 {
        "frame"
    } else {
        "frames"
    };
    let mut out = format!(
        "screen share {span}, {} changed {frames} (what the person's screen showed while they shared it with you; \
         each frame's image is the file named):",
        entries.len()
    );
    for e in entries {
        out.push_str(&format!("\n- {}", line(e)));
    }
    out
}

/// `HH:MM` of an `HH:MM:SS` time.
fn short_time(time: &str) -> &str {
    time.get(..5).unwrap_or(time)
}

fn line(e: &Entry) -> String {
    let place = match (non_empty(&e.app), non_empty(&e.window)) {
        (Some(app), Some(window)) => format!("{app} — \"{}\"", one_line(window, 120)),
        (Some(app), None) => app.to_owned(),
        (None, Some(window)) => format!("\"{}\"", one_line(window, 120)),
        (None, None) => "screen".to_owned(),
    };
    let text = one_line(&e.text, MAX_TEXT);
    let text = if text.is_empty() {
        "(no text)".to_owned()
    } else {
        text
    };
    format!("{} {place}: {text} [{}]", short_time(&e.time), e.frame)
}

fn non_empty(s: &Option<String>) -> Option<&str> {
    s.as_deref().map(str::trim).filter(|s| !s.is_empty())
}

/// `s` on one line, cut to `max` characters with an ellipsis.
fn one_line(s: &str, max: usize) -> String {
    let joined = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if joined.chars().count() <= max {
        return joined;
    }
    let mut cut: String = joined.chars().take(max.saturating_sub(1)).collect();
    cut.push('…');
    cut
}

/// Deletes the consumed inbox files.
pub fn consume(taken: &Taken) {
    for file in &taken.files {
        let _ = std::fs::remove_file(file);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, name: &str, body: &str) {
        std::fs::create_dir_all(inbox(dir)).unwrap();
        std::fs::write(inbox(dir).join(name), body).unwrap();
    }

    fn entry(time: &str, text: &str) -> String {
        format!(
            r#"{{"at":"2026-10-30T17:40:00Z","day":"2026-10-30","time":"{time}","app":"Safari","window":"PR #12","text":"{text}","frame":"/h/optchat/screen/frames/2026-10-30/{}.jpg"}}"#,
            time.replace(':', "")
        )
    }

    #[test]
    fn an_empty_or_missing_inbox_takes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(take(dir.path()), None);
        std::fs::create_dir_all(inbox(dir.path())).unwrap();
        assert_eq!(take(dir.path()), None);
    }

    #[test]
    fn every_entry_becomes_one_note_in_time_order_and_frames_stay() {
        let dir = tempfile::tempdir().unwrap();
        // 900 sorts after 1000 as text; the number decides.
        write(
            dir.path(),
            "1793382125000.json",
            &entry("17:42:05", "Merged  pull\\nrequest #12"),
        );
        write(
            dir.path(),
            "999.json",
            &entry("17:40:01", "Review requested"),
        );
        std::fs::create_dir_all(dir.path().join("frames")).unwrap();
        std::fs::write(dir.path().join("frames/x.jpg"), b"jpeg").unwrap();
        let taken = take(dir.path()).unwrap();
        assert_eq!(taken.notes.len(), 1);
        assert_eq!(
            taken.notes[0].text,
            "screen share 2026-10-30 17:40–17:42, 2 changed frames (what the person's screen showed while they shared it \
             with you; each frame's image is the file named):\n\
             - 17:40 Safari — \"PR #12\": Review requested [/h/optchat/screen/frames/2026-10-30/174001.jpg]\n\
             - 17:42 Safari — \"PR #12\": Merged pull request #12 [/h/optchat/screen/frames/2026-10-30/174205.jpg]"
        );
        assert_eq!(taken.notes[0].key, "screen:999-1793382125000");
        consume(&taken);
        assert_eq!(take(dir.path()), None, "the inbox is empty after the note");
        assert!(dir.path().join("frames/x.jpg").exists(), "frames stay");
    }

    #[test]
    fn a_long_session_is_several_notes_and_loses_no_frame() {
        let dir = tempfile::tempdir().unwrap();
        let long = "word ".repeat(200);
        let n = PER_NOTE * 2 + 3;
        for i in 0..n {
            write(
                dir.path(),
                &format!("{}.json", 1000 + i),
                &entry(&format!("17:{:02}:00", i), long.trim()),
            );
        }
        let taken = take(dir.path()).unwrap();
        assert_eq!(taken.notes.len(), 3);
        assert_eq!(taken.files.len(), n);
        let lines: usize = taken
            .notes
            .iter()
            .map(|note| note.text.lines().count() - 1)
            .sum();
        assert_eq!(lines, n, "every frame has its line");
        assert_eq!(
            taken.notes[0].key,
            format!("screen:1000-{}", 1000 + PER_NOTE - 1)
        );
        assert!(taken.notes[2].text.contains("3 changed frames"));
        let first = taken.notes[0].text.lines().nth(1).unwrap();
        assert!(first.contains('…'));
        assert!(first.chars().count() < MAX_TEXT + 140);
    }

    #[test]
    fn an_unreadable_entry_is_consumed_without_a_note() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "1000.json", "{not json");
        let taken = take(dir.path()).unwrap();
        assert!(taken.notes.is_empty());
        assert_eq!(taken.files.len(), 1);
        consume(&taken);
        assert_eq!(take(dir.path()), None);
    }
}
