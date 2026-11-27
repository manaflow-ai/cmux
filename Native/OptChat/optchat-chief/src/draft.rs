//! The reply as it streams (parity item 4): drafts of the turn's reply,
//! published to every client of the conversation (`conversation.draft`, an
//! ephemeral event; the posted message stays the only authoritative reply).

/// One draft event of a turn's reply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Draft {
    /// The idempotency key of the reply the turn will post.
    pub turn: String,
    /// The reply segment (0-based; a new one starts after each tool call).
    pub segment: u64,
    /// 1, 2, 3 ... per turn, across segments.
    pub seq: u64,
    /// `talk` (thoughts are not drafted).
    pub kind: &'static str,
    /// The delta since the last event of the segment, or with `fresh` the
    /// whole segment so far.
    pub text: String,
    pub fresh: bool,
    /// The turn ended: clients drop the draft.
    pub done: bool,
    /// A fresh segment longer than the limit: `text` is its end.
    pub truncated: bool,
    /// The harness profile that runs the turn.
    pub harness: Option<String>,
}

use std::time::{Duration, Instant};

/// Longest delta text in one event; a longer one goes as a fresh segment.
pub const MAX_DELTA: usize = 16 * 1024;
/// Longest fresh text; a longer segment sends its end, `truncated`.
pub const MAX_FRESH: usize = 64 * 1024;
/// How often a segment that keeps growing is sent whole again, so a client
/// that missed an event (or subscribed late) catches up.
pub const FRESH_EVERY: Duration = Duration::from_secs(2);
/// The shortest gap between two reads of a streaming turn's events: at
/// most about 10 drafts a second.
pub const STREAM_GAP: Duration = Duration::from_millis(100);

/// Turns the fold's reply segments into draft events.
#[derive(Debug)]
pub struct Drafter {
    turn: String,
    harness: Option<String>,
    seq: u64,
    /// The segment drafted now and how many of its bytes went out.
    segment: Option<u64>,
    sent: usize,
    last_fresh: Option<Instant>,
}

impl Drafter {
    pub fn new(turn: &str, harness: Option<String>) -> Drafter {
        Drafter {
            turn: turn.to_owned(),
            harness,
            seq: 0,
            segment: None,
            sent: 0,
            last_fresh: None,
        }
    }

    /// The drafts for segments finished since the last call (`closed`) and
    /// the open one (`open`: its index and its text so far).
    pub fn update(
        &mut self,
        closed: Vec<(u64, String)>,
        open: (u64, &str),
        now: Instant,
    ) -> Vec<Draft> {
        let mut out = Vec::new();
        for (segment, text) in closed {
            self.segment_text(segment, &text, now, &mut out);
        }
        if !open.1.trim().is_empty() {
            self.segment_text(open.0, open.1, now, &mut out);
        }
        out
    }

    /// The last draft: the turn ended.
    pub fn done(&mut self) -> Draft {
        self.seq += 1;
        Draft {
            turn: self.turn.clone(),
            segment: self.segment.unwrap_or(0),
            seq: self.seq,
            kind: "talk",
            text: String::new(),
            fresh: false,
            done: true,
            truncated: false,
            harness: self.harness.clone(),
        }
    }

    fn segment_text(&mut self, segment: u64, text: &str, now: Instant, out: &mut Vec<Draft>) {
        let new = self.segment != Some(segment);
        if new {
            self.segment = Some(segment);
            self.sent = 0;
        }
        if text.len() <= self.sent {
            return;
        }
        let delta = &text[self.sent..];
        let stale = self
            .last_fresh
            .is_none_or(|t| now.duration_since(t) >= FRESH_EVERY);
        let fresh = new || stale || delta.len() > MAX_DELTA;
        let (text_out, truncated) = if fresh {
            let start = text.len().saturating_sub(MAX_FRESH);
            let start = (start..=text.len())
                .find(|i| text.is_char_boundary(*i))
                .unwrap_or(text.len());
            (text[start..].to_owned(), start > 0)
        } else {
            (delta.to_owned(), false)
        };
        if fresh {
            self.last_fresh = Some(now);
        }
        self.sent = text.len();
        self.seq += 1;
        out.push(Draft {
            turn: self.turn.clone(),
            segment,
            seq: self.seq,
            kind: "talk",
            text: text_out,
            fresh,
            done: false,
            truncated,
            harness: self.harness.clone(),
        });
    }
}
