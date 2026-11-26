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
    /// Where Claude Code compacted the conversation (its `isCompactSummary` line), as the index
    /// of the turn after it (`turns.len()` for one after the page's last turn), ascending.
    pub compactions: Vec<usize>,
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
    read_claude_page(f, end, want).unwrap_or_default()
}

fn read_claude_page(f: &mut File, end: u64, want: usize) -> std::io::Result<ClaudePage> {
    let raw = scan_page(f, end, want, false, parse, |record| Prompt::from(is_prompt(record)))?;
    let RawPage { lines, start, read, has_prompt, .. } = raw;
    let mut turns: Vec<PastTurn> = Vec::new();
    // Beside `turns`: whether a compaction came just before each.
    let mut compacted: Vec<bool> = Vec::new();
    let mut pending = false;
    if !has_prompt && !lines.is_empty() {
        // Part of one turn whose prompt is older than the page.
        turns.push(PastTurn::default());
        compacted.push(false);
    }
    for (offset, record) in lines.into_iter().rev() {
        if offset < start {
            continue;
        }
        if record.get("isCompactSummary").and_then(Value::as_bool) == Some(true) {
            pending = true;
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
            while compacted.len() < turns.len() {
                compacted.push(std::mem::take(&mut pending));
            }
        }
    }
    let mut kept = Vec::with_capacity(turns.len());
    let mut compactions = Vec::new();
    for (turn, after) in turns.into_iter().zip(compacted) {
        if after {
            compactions.push(kept.len());
        }
        if !turn.prompt.is_empty() || !turn.tools.is_empty() || !turn.answer.is_empty() {
            kept.push(turn);
        }
    }
    if pending {
        compactions.push(kept.len());
    }
    compactions.dedup();
    Ok(ClaudePage { turns: kept, start, read, compactions })
}

pub(super) struct RawPage {
    pub lines: Vec<(u64, Value)>,
    pub start: u64,
    pub read: u64,
    pub has_prompt: bool,
    /// A completed line whose older bytes lie beyond the page budget.
    pub clipped_head: Option<std::ops::Range<u64>>,
    /// The newest newline encountered, expressed as the offset immediately after it.
    pub last_break: Option<u64>,
}

#[derive(PartialEq)]
pub(super) enum Prompt {
    New,
    Mirror,
    Other,
}

impl From<bool> for Prompt {
    fn from(is_prompt: bool) -> Self {
        if is_prompt { Self::New } else { Self::Other }
    }
}

/// One scanner for adopted Claude chats and terminal transcripts. Errors stay distinguishable
/// from day one for clients using a byte cursor.
pub(super) fn scan_page(
    f: &mut File,
    end: u64,
    want: usize,
    codex: bool,
    parse: impl Fn(&[u8]) -> Option<Value>,
    mut classify: impl FnMut(&Value) -> Prompt,
) -> std::io::Result<RawPage> {
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
    let mut boundary = None;
    let mut last_break = None;
    let mut clipped_head = None;
    let start = 'scan: loop {
        if pos == 0 {
            // `head` begins the file: its line is whole.
            if let Some(record) = parse(&head) {
                match classify(&record) {
                    Prompt::New => oldest_prompt = Some(0),
                    Prompt::Mirror if boundary.is_some() => boundary = Some(0),
                    _ => {}
                }
                lines.push((0, record));
            }
            break 'scan boundary.unwrap_or(0);
        }
        let take = CHUNK.min(pos);
        pos -= take;
        let mut buf = vec![0u8; take as usize];
        f.seek(SeekFrom::Start(pos))?;
        f.read_exact(&mut buf)?;
        buf.extend_from_slice(&head);
        if skip {
            match memchr::memrchr(b'\n', &buf) {
                Some(i) => {
                    last_break = Some(pos + i as u64 + 1);
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
            if let Some(record) = before.get(line_start..).and_then(&parse) {
                let prompt = classify(&record);
                // A legacy Codex turn may have both an event prompt and a response-item prompt.
                // Read through its mirror before publishing a cursor between logical turns.
                if let Some(previous) = boundary {
                    if prompt == Prompt::New {
                        break 'scan previous;
                    }
                    if prompt == Prompt::Mirror {
                        boundary = Some(offset);
                    }
                }
                lines.push((offset, record));
                if prompt == Prompt::New {
                    prompts += 1;
                    oldest_prompt = Some(offset);
                    if prompts >= want {
                        if !codex {
                            break 'scan offset;
                        }
                        boundary = Some(offset);
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
            break 'scan boundary.unwrap_or(prompt);
        }
        if read >= PAGE_MAX_BYTES {
            // One turn bigger than a page: its newest part, from the oldest whole line read. With
            // no whole line, one line bigger than a page: the next page goes on from inside it.
            if !whole && let Some(break_at) = last_break {
                clipped_head = Some(pos..break_at);
            }
            break 'scan oldest_prompt.unwrap_or(if whole { pos + head.len() as u64 } else { pos });
        }
    };
    Ok(RawPage {
        lines,
        start,
        read: end - pos,
        has_prompt: oldest_prompt.is_some(),
        clipped_head,
        last_break,
    })
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
pub(super) fn parse(line: &[u8]) -> Option<Value> {
    let finder = |needle: &[u8]| memchr::memmem::find(line, needle).is_some();
    if !finder(b"\"user\"") && !finder(b"\"assistant\"") {
        return None;
    }
    serde_json::from_slice(line).ok()
}

/// Whether `record` starts a turn (the rules `claude_steps` uses).
pub(super) fn is_prompt(record: &Value) -> bool {
    record.get("type").and_then(Value::as_str) == Some("user")
        && claude_steps(record, None).iter().any(|s| matches!(s, Step::Prompt(_)))
}

#[cfg(test)]
#[path = "adopt_replay_page_tests.rs"]
mod tests;
