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
//! [`ClaudePage::start`] is the offset of the page's first line: the next older page ends there,
//! so paging from it back to 0 reads every turn once, and nothing twice. A page starts at a
//! prompt's line unless one turn is bigger than [`PAGE_MAX_BYTES`]; then it is that turn's newest
//! part, shown as a turn with no prompt.
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
/// One backwards read.
const CHUNK: u64 = 1 << 20;

/// A page of a Claude Code transcript's turns, oldest first.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ClaudePage {
    pub turns: Vec<PastTurn>,
    /// The offset of the page's first line: where the next older page ends. 0 when nothing is
    /// older.
    pub start: u64,
    /// How many bytes of the file the page read.
    pub read: u64,
}

/// The page of `file` (a Claude Code transcript) that ends at `end` (the file's end when `None`,
/// else a [`ClaudePage::start`]), with at most `want` turns. A last line still being written (no
/// line break yet) is left for a later read. Empty when the file cannot be read.
pub fn claude_page(file: &Path, end: Option<u64>, want: usize) -> ClaudePage {
    let Ok(mut f) = File::open(file) else { return ClaudePage::default() };
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
    let mut newest = true;
    let start = 'scan: loop {
        if pos == 0 {
            // `head` begins the file: its line is whole.
            if let Some(record) = parse(&head) {
                if is_prompt(&record) {
                    prompts += 1;
                    oldest_prompt = Some(0);
                }
                lines.push((0, record));
            }
            break 'scan if prompts >= want { oldest_prompt.unwrap_or(0) } else { 0 };
        }
        let take = CHUNK.min(pos);
        pos -= take;
        let mut buf = vec![0u8; take as usize];
        if f.seek(SeekFrom::Start(pos)).is_err() || f.read_exact(&mut buf).is_err() {
            return ClaudePage::default();
        }
        buf.extend_from_slice(&head);
        // The newest read drops a last line with no break yet: it is still being written.
        if newest {
            match memchr::memrchr(b'\n', &buf) {
                Some(i) => {
                    buf.truncate(i + 1);
                    newest = false;
                }
                // All of it is that last line: read on for its start.
                None => {
                    head = Vec::new();
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
            let line_start = memchr::memrchr(b'\n', &buf[..body_end]).map_or(0, |i| i + 1);
            let offset = pos + line_start as u64;
            if let Some(record) = parse(&buf[line_start..body_end]) {
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
        head = buf[..whole_from.min(buf.len())].to_vec();
        if pos == 0 {
            continue;
        }
        let read = end - pos;
        if let Some(prompt) = oldest_prompt.filter(|_| read >= PAGE_BYTES) {
            break 'scan prompt;
        }
        if read >= PAGE_MAX_BYTES {
            // One turn bigger than a page: its newest part, from the oldest whole line read.
            break 'scan oldest_prompt.unwrap_or(pos + head.len() as u64);
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
        if turns.len() == 1 && turns[0].prompt.is_empty() && turns[0].prompt_at.is_none() {
            turns[0].prompt_at = at;
            turns[0].answer_at = at;
        }
        for step in claude_steps(&record, at) {
            add(&mut turns, step, at);
        }
    }
    turns.retain(|t| !t.prompt.is_empty() || !t.tools.is_empty() || !t.answer.is_empty());
    ClaudePage { turns, start, read: end - pos }
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
        let dir = std::env::temp_dir()
            .join(format!("acpmux-claude-page-{}-{name}", std::process::id()));
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
    fn an_unreadable_file_is_an_empty_page() {
        let page = claude_page(Path::new("/nonexistent/acpmux/s.jsonl"), None, 30);
        assert_eq!(page, ClaudePage::default());
    }
}
