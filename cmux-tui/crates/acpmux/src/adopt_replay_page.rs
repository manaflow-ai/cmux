//! A Claude Code transcript read from its end, a page of turns at a time (Leo 2026-10-29: "i
//! also like the way it just loads in the subagent stuff instantly :(" / "as in i want ours to
//! load fast too :(").
//!
//! A Claude Code transcript can be hundreds of megabytes (one on cosmic-gray was 739 MB). Adopting
//! or watching one read its newest 64 MiB and parsed every line of it before the chat showed
//! anything. A page here reads backwards from an offset in 1 MiB steps and stops once it holds
//! [`PAGE_TURNS`] prompts, or once it has read [`PAGE_BYTES`] and holds one; it never reads more
//! than [`PAGE_MAX_BYTES`]. Only the lines of the page are parsed, each once.
//!
//! [`ClaudePage::start`] is where the next older page ends, always before the page's own end, so
//! paging from it back to 0 reads every turn once, and nothing twice. A page starts at a prompt's
//! line unless one turn is bigger than [`PAGE_MAX_BYTES`]; then it is that turn's newest part,
//! shown as a turn with no prompt. A single line bigger than a page is never parsed: the page that
//! reaches its cap inside it is empty and ends its cursor there, inside the line, and the next
//! page drops the rest of that line as it drops a last line still being written.
//! [`newest_claude_page`] pages back past such empty pages, up to [`SCAN_MAX_BYTES`].
//!
//! Subagent transcripts are their own files, read on their own when one is opened
//! (`hub/subagent_transcript.rs`); a page never reads them.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

use super::{PastTurn, Step, add, claude_steps, record_time};

/// The most turns one page holds: as many as adopting showed before pages (`MAX_TURNS`).
pub const PAGE_TURNS: usize = super::MAX_TURNS;
/// Once a page has read this much and holds a prompt, it stops at its oldest prompt.
pub const PAGE_BYTES: u64 = 8 << 20;
/// The most one page reads, prompt or not.
pub const PAGE_MAX_BYTES: u64 = 16 << 20;
/// The most [`newest_claude_page`] and [`newest_prompt_start`] read, over all the pages they
/// try: what adopting read before pages.
pub const SCAN_MAX_BYTES: u64 = 64 << 20;
/// One backwards read.
const CHUNK: u64 = 1 << 20;

/// A page of a Claude Code transcript's turns, oldest first.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ClaudePage {
    pub turns: Vec<PastTurn>,
    /// Where the next older page ends: the offset of the page's first line, or a point inside a
    /// line bigger than a page. 0 when nothing is older.
    pub start: u64,
    /// How many bytes of the file the page read.
    pub read: u64,
}

/// The page of `file` (a Claude Code transcript) that ends at `end` (the file's end when `None`,
/// else a [`ClaudePage::start`]), with at most `want` turns. A last line still being written (no
/// line break yet) is left for a later read, as is the rest of a line `end` falls inside. Empty
/// when the file cannot be read. It never reads more than [`PAGE_MAX_BYTES`] and a step.
pub fn claude_page(file: &Path, end: Option<u64>, want: usize) -> ClaudePage {
    let Ok(mut f) = File::open(file) else { return ClaudePage::default() };
    claude_page_open(&mut f, end, want)
}

fn claude_page_open(f: &mut File, end: Option<u64>, want: usize) -> ClaudePage {
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let end = end.map_or(len, |end| end.min(len));
    let want = want.max(1);
    // The page's lines, newest first, with their offsets.
    let mut lines: Vec<(u64, Value)> = Vec::new();
    let mut prompts = 0usize;
    let mut oldest_prompt = None;
    // `[pos, end)` is read. `head` is `[pos, pos + head.len())`: the start of the file region
    // read whose first line may begin before `pos`.
    let mut pos = end;
    let mut head: Vec<u8> = Vec::new();
    // Bytes after the last break read so far are dropped: a line still being written, or the
    // rest of a line `end` falls inside.
    let mut skip = true;
    // A whole line was read (parsed or not).
    let mut whole = false;
    let start = 'scan: loop {
        if pos == 0 {
            // `head` begins the file: its line is whole.
            if let Some(record) = parse(&head) {
                if is_prompt(&record) {
                    oldest_prompt = Some(0);
                }
                lines.push((0, record));
            }
            break 'scan 0;
        }
        let take = CHUNK.min(pos);
        pos -= take;
        let mut buf = vec![0u8; take as usize];
        if f.seek(SeekFrom::Start(pos)).is_err() || f.read_exact(&mut buf).is_err() {
            return ClaudePage::default();
        }
        buf.extend_from_slice(&head);
        if skip {
            match memchr::memrchr(b'\n', &buf) {
                Some(i) => {
                    buf.truncate(i + 1);
                    skip = false;
                }
                // All of it is that line: read on for its start, within the page's cap.
                None => {
                    head = Vec::new();
                    if end - pos >= PAGE_MAX_BYTES {
                        break 'scan pos;
                    }
                    continue;
                }
            }
        }
        // Whole lines are the ones after a break in `buf`; the bytes up to the first break
        // (with it) may begin before `pos` and wait for the next read.
        let first_break = memchr::memchr(b'\n', &buf);
        let whole_from = first_break.map_or(buf.len(), |i| i + 1);
        let mut line_end = buf.len();
        while line_end > whole_from {
            // `line_end` is just past a break; the line is `[line_start, line_end - 1)`.
            let body_end = line_end - 1;
            let before = buf.get(..body_end).unwrap_or_default();
            let line_start = memchr::memrchr(b'\n', before).map_or(0, |i| i + 1);
            let offset = pos + line_start as u64;
            whole = true;
            if let Some(record) = before.get(line_start..).and_then(parse) {
                let prompt = is_prompt(&record);
                lines.push((offset, record));
                if prompt {
                    prompts += 1;
                    oldest_prompt = Some(offset);
                    if prompts >= want {
                        break 'scan offset;
                    }
                }
            }
            line_end = line_start;
        }
        head = buf.get(..whole_from).unwrap_or(buf.as_slice()).to_vec();
        if pos == 0 {
            continue;
        }
        let read = end - pos;
        if let Some(prompt) = oldest_prompt.filter(|_| read >= PAGE_BYTES) {
            break 'scan prompt;
        }
        if read >= PAGE_MAX_BYTES {
            // One turn bigger than a page: its newest part, from the oldest whole line read. With
            // no whole line, one line bigger than a page: the next page goes on from inside it.
            break 'scan oldest_prompt.unwrap_or(if whole { pos + head.len() as u64 } else { pos });
        }
    };
    let mut turns: Vec<PastTurn> = Vec::new();
    if oldest_prompt.is_none() && !lines.is_empty() {
        // Part of one turn whose prompt is older than the page.
        turns.push(PastTurn::default());
    }
    for (offset, record) in lines.into_iter().rev() {
        if offset < start {
            continue;
        }
        let at = record_time(&record);
        if let [only] = turns.as_mut_slice()
            && only.prompt.is_empty()
            && only.prompt_at.is_none()
        {
            only.prompt_at = at;
            only.answer_at = at;
        }
        for step in claude_steps(&record, at) {
            add(&mut turns, step, at);
        }
    }
    turns.retain(|t| !t.prompt.is_empty() || !t.tools.is_empty() || !t.answer.is_empty());
    ClaudePage { turns, start, read: end - pos }
}

/// The newest page of `file` that holds turns: pages that hold none (the end of a line bigger
/// than a page) are paged past, reading at most [`SCAN_MAX_BYTES`] in all. `read` counts every
/// page read.
pub fn newest_claude_page(file: &Path, want: usize) -> ClaudePage {
    claude_page_with_turns(file, None, want)
}

/// The newest page of `file` ending at `end` (as [`claude_page`]) that holds turns, paging past
/// pages that hold none as [`newest_claude_page`] does: the older history a chat pages in
/// (`hub/native_history.rs`). Empty with `start` 0 once nothing older holds a turn.
pub fn claude_page_with_turns(file: &Path, end: Option<u64>, want: usize) -> ClaudePage {
    let Ok(mut file) = File::open(file) else { return ClaudePage::default() };
    claude_page_with_turns_open(&mut file, end, want)
}

/// Reads all steps on one opened transcript, so rotation cannot switch files between pages.
pub(crate) fn claude_page_with_turns_open(
    file: &mut File,
    end: Option<u64>,
    want: usize,
) -> ClaudePage {
    let mut page = claude_page_open(file, end, want);
    let mut read = page.read;
    while page.turns.is_empty() && page.start > 0 && read < SCAN_MAX_BYTES {
        page = claude_page_open(file, Some(page.start), want);
        read += page.read;
    }
    page.read = read;
    page
}

/// Where following `file` from its newest turns starts (`hub/watch.rs`): the start of the newest
/// page that begins at a prompt, so the first turn followed has its prompt. None when no page
/// does within [`SCAN_MAX_BYTES`]; then the caller reads as before.
pub fn newest_prompt_start(file: &Path, want: usize) -> Option<u64> {
    let mut file = File::open(file).ok()?;
    newest_prompt_start_open(&mut file, want)
}

pub(crate) fn newest_prompt_start_open(file: &mut File, want: usize) -> Option<u64> {
    let (mut end, mut read) = (None, 0);
    loop {
        let page = claude_page_open(file, end, want);
        read += page.read;
        if page.turns.first().is_some_and(|t| !t.prompt.is_empty()) {
            return Some(page.start);
        }
        if page.start == 0 || read >= SCAN_MAX_BYTES {
            return None;
        }
        end = Some(page.start);
    }
}

/// A line that can add to a turn: a `user` or `assistant` record. Others (progress, snapshots,
/// summaries) are not parsed: neither word appears in them as a whole JSON string.
fn parse(line: &[u8]) -> Option<Value> {
    let finder = |needle: &[u8]| memchr::memmem::find(line, needle).is_some();
    if !finder(b"\"user\"") && !finder(b"\"assistant\"") {
        return None;
    }
    serde_json::from_slice(line).ok()
}

/// Whether `record` starts a turn (the rules `claude_steps` uses).
fn is_prompt(record: &Value) -> bool {
    record.get("type").and_then(Value::as_str) == Some("user")
        && claude_steps(record, None).iter().any(|s| matches!(s, Step::Prompt(_)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("acpmux-claude-page-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("s.jsonl")
    }

    fn prompt(n: usize) -> String {
        json!({"type": "user", "timestamp": "2026-10-29T10:00:00.000Z",
            "message": {"role": "user", "content": format!("prompt {n}")}})
        .to_string()
    }

    fn answer(n: usize) -> String {
        json!({"type": "assistant", "timestamp": "2026-10-29T10:00:01.000Z",
            "message": {"role": "assistant", "stop_reason": "end_turn",
                "content": [{"type": "text", "text": format!("answer {n}")}]}})
        .to_string()
    }

    /// `turns` turns, each a prompt, a progress line of `pad` bytes and an answer.
    fn transcript(file: &Path, turns: usize, pad: usize) {
        let mut f = std::io::BufWriter::new(File::create(file).unwrap());
        let filler = "x".repeat(pad);
        for n in 0..turns {
            writeln!(f, "{}", prompt(n)).unwrap();
            writeln!(f, "{}", json!({"type": "progress", "data": filler})).unwrap();
            writeln!(f, "{}", answer(n)).unwrap();
        }
    }

    fn prompts(page: &ClaudePage) -> Vec<String> {
        page.turns.iter().map(|t| t.prompt.clone()).collect()
    }

    #[test]
    fn a_page_is_the_newest_turns_and_paging_back_reads_each_once() {
        let file = scratch("paging");
        transcript(&file, 70, 10);
        let page = claude_page(&file, None, 30);
        let want: Vec<String> = (40..70).map(|n| format!("prompt {n}")).collect();
        assert_eq!(prompts(&page), want);
        assert_eq!(page.turns[29].answer, "answer 69");
        assert!(page.start > 0);
        let mut all = prompts(&page);
        let mut end = page.start;
        while end > 0 {
            let older = claude_page(&file, Some(end), 30);
            assert!(older.start < end, "a page moves back");
            let mut got = prompts(&older);
            got.extend(all);
            all = got;
            end = older.start;
        }
        let every: Vec<String> = (0..70).map(|n| format!("prompt {n}")).collect();
        assert_eq!(all, every);
    }

    #[test]
    fn a_page_of_a_big_transcript_reads_only_its_tail() {
        let file = scratch("big");
        // 600 turns of 100 KiB: about 60 MB.
        transcript(&file, 600, 100 << 10);
        let len = std::fs::metadata(&file).unwrap().len();
        let page = claude_page(&file, None, PAGE_TURNS);
        assert_eq!(page.turns.last().unwrap().prompt, "prompt 599");
        assert!(page.read <= PAGE_BYTES + CHUNK, "read {} of {len}", page.read);
        assert!(page.start > len - PAGE_BYTES - CHUNK);
        // Every turn of the page is whole: it starts at a prompt.
        assert!(page.turns.iter().all(|t| t.prompt.starts_with("prompt ")));
    }

    #[test]
    fn a_line_still_being_written_waits() {
        let file = scratch("partial");
        transcript(&file, 3, 4);
        let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
        write!(f, "{}", &prompt(3)[..20]).unwrap();
        let page = claude_page(&file, None, 30);
        assert_eq!(prompts(&page), ["prompt 0", "prompt 1", "prompt 2"]);
        assert_eq!(page.start, 0);
    }

    #[test]
    fn a_turn_bigger_than_a_page_shows_its_newest_part() {
        let file = scratch("one-turn");
        let mut f = std::io::BufWriter::new(File::create(&file).unwrap());
        writeln!(f, "{}", prompt(0)).unwrap();
        let filler = "y".repeat(1 << 20);
        for _ in 0..20 {
            writeln!(f, "{}", json!({"type": "progress", "data": filler})).unwrap();
        }
        writeln!(f, "{}", answer(0)).unwrap();
        drop(f);
        let page = claude_page(&file, None, 30);
        assert!(page.read <= PAGE_MAX_BYTES + CHUNK, "read {}", page.read);
        assert!(page.start > 0);
        assert_eq!(page.turns.len(), 1);
        assert_eq!(page.turns[0].prompt, "");
        assert_eq!(page.turns[0].answer, "answer 0");
        // The older page holds the prompt.
        let older = claude_page(&file, Some(page.start), 30);
        assert_eq!(prompts(&older), ["prompt 0"]);
    }

    #[test]
    fn a_turn_bigger_than_a_page_is_followed_from_its_prompt() {
        let file = scratch("one-turn-watch");
        let mut f = std::io::BufWriter::new(File::create(&file).unwrap());
        writeln!(f, "{}", prompt(0)).unwrap();
        writeln!(f, "{}", answer(0)).unwrap();
        let at = f.get_ref().metadata().unwrap().len() + f.buffer().len() as u64;
        writeln!(f, "{}", prompt(1)).unwrap();
        let filler = "y".repeat(1 << 20);
        for _ in 0..20 {
            writeln!(f, "{}", json!({"type": "progress", "data": filler})).unwrap();
        }
        writeln!(f, "{}", answer(1)).unwrap();
        drop(f);
        // The newest page has no prompt; the one before it starts at prompt 1.
        assert!(claude_page(&file, None, 1).turns[0].prompt.is_empty());
        assert_eq!(newest_prompt_start(&file, 1), Some(at));
    }

    /// One complete line bigger than a page, after turns: each page moves back, and the newest
    /// page with turns is the one before it.
    #[test]
    fn a_line_bigger_than_a_page_is_paged_past() {
        let file = scratch("big-line");
        transcript(&file, 5, 4);
        let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(f, "{}", json!({"type": "progress", "data": "z".repeat(20 << 20)})).unwrap();
        drop(f);
        let len = std::fs::metadata(&file).unwrap().len();
        let page = claude_page(&file, None, 30);
        assert!(page.turns.is_empty());
        assert!(page.start < len, "a page moves back: {} of {len}", page.start);
        assert!(page.read <= PAGE_MAX_BYTES + CHUNK, "read {}", page.read);
        let newest = newest_claude_page(&file, 30);
        let want: Vec<String> = (0..5).map(|n| format!("prompt {n}")).collect();
        assert_eq!(prompts(&newest), want);
        assert_eq!(newest.start, 0);
    }

    /// A last line still being written that is bigger than a page: the page stays within its cap.
    #[test]
    fn an_unfinished_line_bigger_than_a_page_keeps_the_cap() {
        let file = scratch("big-partial");
        transcript(&file, 5, 4);
        let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
        write!(f, "{{\"type\":\"progress\",\"data\":\"{}", "z".repeat(20 << 20)).unwrap();
        drop(f);
        let len = std::fs::metadata(&file).unwrap().len();
        let page = claude_page(&file, None, 30);
        assert!(page.read <= PAGE_MAX_BYTES + CHUNK, "read {}", page.read);
        assert!(page.start < len);
        assert_eq!(prompts(&newest_claude_page(&file, 30)).len(), 5);
    }

    #[test]
    fn an_unreadable_file_is_an_empty_page() {
        let page = claude_page(Path::new("/nonexistent/acpmux/s.jsonl"), None, 30);
        assert_eq!(page, ClaudePage::default());
    }
}
