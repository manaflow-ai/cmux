//! A turn a move cut at a tool boundary goes on where the chat lands, with no prompt of acpmux's
//! (Leo, 2026-11-23: "you're not even interrupting them. You're just giving them a sort of
//! extended wait ... It's like an extended tool call. It's like you don't even add an additional
//! tool call almost. It's like boom, you just instantly resume").
//!
//! Claude Code resumes a cut turn by itself when it starts with [`ENV`] set and its transcript
//! ends at a tool result: the model then gets that result and Claude Code's own one line beside
//! it ("Continue from where you left off."), no user turn. Measured with Claude Code 2.1.330
//! (the request logged through a proxy): 0 added user turns, 0 calls run again.
//!
//! The Stop the move sent (`hub/transfer_out.rs`) left `[Request interrupted by user]` as the
//! transcript's last message, and with it Claude Code resumes nothing (measured: no turn starts).
//! [`prepare`] takes that one line out of the copy that landed here, and says whether the
//! transcript now ends at a tool result. Only then is the process started with [`env`]; anything
//! else keeps acpmux's continuation prompt (`hub/restart_resume.rs`).
//!
//! Why the transcript is not cut back to the tool call, with its result written on stdin (which
//! would leave not even Claude Code's line): Claude Code 2.1.330 does not take a result for a call
//! it resumed. With no [`ENV`] it answers the open call itself ("[Tool call interrupted: ...]")
//! and reads the written result as an empty user message; with [`ENV`] it drops the call and
//! starts from the prompt. Both run the call again (measured, the request logged through a proxy).
//!
//! The process runs the turn before the hub's prompt for it comes. That prompt is
//! `_meta.carried: true`, as a turn Claude Code runs on unread steers has (`carry.rs`): nothing is
//! written, and the turn's result answers it. Until it comes the process's output is held, as
//! after a carry ([`Translator::owe_resumed`]).

use super::*;
use std::io::{Read, Seek, SeekFrom, Write};

/// Claude Code resumes the turn its transcript was cut in.
pub const ENV: &str = "CLAUDE_CODE_RESUME_INTERRUPTED_TURN";
/// How old a cut turn Claude Code still resumes, in milliseconds.
pub const MAX_AGE_ENV: &str = "CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS";
/// A week: a chat moved to a machine that was asleep, or resumed after a weekend, still goes on.
pub const MAX_AGE_MS: &str = "604800000";

/// The transcript's last message after a Stop.
const INTERRUPTED: &str = "[Request interrupted by user]";
/// The first tail read, and the most read back for the last message (a long tool result).
const TAIL: u64 = 256 * 1024;
const TAIL_MAX: u64 = 16 * 1024 * 1024;

/// The environment a process that resumes a cut turn starts with.
pub fn env() -> [(&'static str, &'static str); 2] {
    [(ENV, "1"), (MAX_AGE_ENV, MAX_AGE_MS)]
}

/// What a transcript line is to the resume.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum Line {
    /// Not a message (a snapshot, a cost record, an attachment): it changes nothing.
    Other,
    /// The Stop's own line.
    Interrupted,
    /// A tool's result: the turn goes on from it.
    ToolResult,
    /// Any other message: the turn is not at a tool boundary.
    Message,
}

fn classify(line: &str) -> Line {
    let Ok(v) = serde_json::from_str::<Value>(line) else { return Line::Other };
    let kind = v.get("type").and_then(Value::as_str);
    if !matches!(kind, Some("user" | "assistant")) {
        return Line::Other;
    }
    if v.get("isSidechain").and_then(Value::as_bool) == Some(true) {
        return Line::Other;
    }
    let content = v.pointer("/message/content");
    let blocks = content.and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    let block_type = |b: &Value| b.get("type").and_then(Value::as_str).map(str::to_owned);
    if kind == Some("user") {
        let text = match content {
            Some(Value::String(s)) => Some(s.as_str()),
            _ => match blocks {
                [only] => only.get("text").and_then(Value::as_str),
                _ => None,
            },
        };
        if text == Some(INTERRUPTED) {
            return Line::Interrupted;
        }
        if !blocks.is_empty()
            && blocks.iter().all(|b| block_type(b).as_deref() == Some("tool_result"))
        {
            return Line::ToolResult;
        }
    }
    Line::Message
}

/// Takes the Stop's line out of the end of the transcript at `path`, and returns whether the
/// transcript then ends at a tool result, which Claude Code resumes from. `false` leaves the file
/// as it was.
pub fn prepare(path: &Path) -> std::io::Result<bool> {
    let mut file = crate::home_fs::OpenOptions::new().read(true).write(true).open(path)?;
    let len = file.metadata()?.len();
    let mut window = TAIL.min(len);
    loop {
        let start = len - window;
        file.seek(SeekFrom::Start(start))?;
        let mut bytes = Vec::with_capacity(window as usize);
        (&mut file).take(window).read_to_end(&mut bytes)?;
        // Whole lines only: the window's first line is whole when the window is the file, or
        // starts right after a line's end.
        let skip = if start == 0 {
            0
        } else {
            match bytes.iter().position(|b| *b == b'\n') {
                Some(i) => i + 1,
                None => bytes.len(),
            }
        };
        let Ok(text) = std::str::from_utf8(bytes.get(skip..).unwrap_or_default()) else {
            return Ok(false);
        };
        // The last message, and the Stop's line after it, by their place in the window.
        let mut at = 0usize;
        let mut cut: Option<(usize, usize)> = None;
        let mut last = None;
        for line in text.split_inclusive('\n') {
            let (from, to) = (at, at + line.len());
            at = to;
            match classify(line.trim_end()) {
                Line::Other => {}
                Line::Interrupted => {
                    cut = Some((from, to));
                }
                kind => {
                    last = Some(kind);
                    cut = None;
                }
            }
        }
        match last {
            Some(Line::ToolResult) => {
                let Some((from, to)) = cut else { return Ok(true) };
                let rest = text.as_bytes().get(to..).unwrap_or_default().to_vec();
                let keep = start + (skip + from) as u64;
                file.seek(SeekFrom::Start(keep))?;
                file.write_all(&rest)?;
                file.set_len(keep + rest.len() as u64)?;
                file.sync_data()?;
                return Ok(true);
            }
            Some(_) => return Ok(false),
            // No message in the window: read further back, up to the bound.
            None if window < len && window < TAIL_MAX => window = (window * 4).min(len),
            None => return Ok(false),
        }
    }
}

impl Translator {
    /// This process resumes a cut turn by itself ([`ENV`]): the hub's `_meta.carried` prompt for
    /// it is owed, and its output is held until that prompt comes (`carry.rs` `holding`). Called
    /// on a new translator, before its process writes anything.
    pub fn owe_resumed(&self) {
        let Ok(mut carry) = self.carry.try_lock() else { return };
        carry.owe_new();
        self.carry_owed.send_replace(carry.owed_now());
        self.in_turn.store(true, Ordering::SeqCst);
    }
}
