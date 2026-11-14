//! Incremental lexical facts for streamed markdown blocks.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Event {
    None,
    BeforeLine,
    LineEnd,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Block {
    fence: Option<char>,
    fence_len: u32,
    last_blank: bool,
    at_line_start: bool,
    line_indent: u8,
    line_nonwhite: bool,
    first_nonspace: Option<char>,
    marker_run: u32,
    marker_run_ended: bool,
    marker_other_nonwhite: bool,
    line_bytes: u64,
    cut_inside_line: bool,
}

impl Default for Block {
    fn default() -> Self {
        Self {
            fence: None,
            fence_len: 0,
            last_blank: false,
            at_line_start: true,
            line_indent: 0,
            line_nonwhite: false,
            first_nonspace: None,
            marker_run: 0,
            marker_run_ended: false,
            marker_other_nonwhite: false,
            line_bytes: 0,
            cut_inside_line: false,
        }
    }
}

impl Block {
    pub fn fence_marker(&self) -> Option<String> {
        self.fence.map(|c| std::iter::repeat_n(c, self.fence_len as usize).collect())
    }
    pub fn line_bytes(&self) -> u64 {
        self.line_bytes
    }
    /// Cut the current body segment while preserving fence and line lexical state.
    pub fn mark_cut_inside_line(&mut self) {
        self.cut_inside_line = true;
        self.line_bytes = 0;
    }
    pub fn take_cut_inside_line(&mut self) -> bool {
        let value = self.cut_inside_line;
        self.cut_inside_line = false;
        value
    }

    /// Consume one decoded character. `BeforeLine` is emitted before the character is appended.
    /// After a blank top-level line, only a byte that cannot begin a list or indentation starts
    /// the next block immediately; no lookahead or pending body range is required.
    pub fn push(&mut self, ch: char) -> Event {
        let boundary = if self.at_line_start {
            self.at_line_start = false;
            self.reset_line();
            let boundary = self.last_blank && self.fence.is_none() && !can_begin_list_or_indent(ch);
            if boundary {
                self.last_blank = false;
            }
            boundary
        } else {
            false
        };

        self.line_bytes = self.line_bytes.saturating_add(ch.len_utf8() as u64);
        if is_line_nonwhite(ch) {
            self.line_nonwhite = true;
            if self.first_nonspace.is_none() {
                self.first_nonspace = Some(ch);
                if matches!(ch, '`' | '~') {
                    self.marker_run = 1;
                }
            } else if let Some(marker) = self.first_nonspace.filter(|c| matches!(c, '`' | '~')) {
                if self.marker_run > 0 && !self.marker_run_ended {
                    if ch == marker {
                        self.marker_run = self.marker_run.saturating_add(1);
                    } else {
                        self.marker_run_ended = true;
                        self.marker_other_nonwhite = true;
                    }
                } else {
                    self.marker_other_nonwhite = true;
                }
            }
        } else if self.first_nonspace.is_none() && matches!(ch, ' ' | '\t') {
            self.line_indent =
                self.line_indent.saturating_add(if ch == '\t' { 4 } else { 1 }).min(4);
        } else if self.first_nonspace.is_some() && self.marker_run > 0 && !self.marker_run_ended {
            self.marker_run_ended = true;
        }
        if ch == '\n' {
            self.finish_line();
            return Event::LineEnd;
        }
        if boundary { Event::BeforeLine } else { Event::None }
    }

    fn reset_line(&mut self) {
        self.line_indent = 0;
        self.line_nonwhite = false;
        self.first_nonspace = None;
        self.marker_run = 0;
        self.marker_run_ended = false;
        self.marker_other_nonwhite = false;
        self.line_bytes = 0;
    }
    fn finish_line(&mut self) {
        let marker = self.first_nonspace;
        let run = self.marker_run;
        let marker_line = self.line_indent <= 3 && run >= 3 && marker.is_some();
        if marker_line && let Some(marker) = marker {
            if self.fence.is_none() {
                // An opening fence may carry an info string; the marker itself decides it.
                self.fence = Some(marker);
                self.fence_len = run;
            } else if self.fence == Some(marker)
                && run >= self.fence_len
                && !self.marker_other_nonwhite
            {
                self.fence = None;
                self.fence_len = 0;
            }
        }
        self.last_blank = !self.line_nonwhite && self.fence.is_none();
        self.at_line_start = true;
        self.reset_line();
    }
}

fn can_begin_list_or_indent(ch: char) -> bool {
    matches!(ch, ' ' | '\t' | '\r' | '\n' | '-' | '*' | '+' | '0'..='9')
}
fn is_line_nonwhite(ch: char) -> bool {
    !matches!(ch, ' ' | '\t' | '\r' | '\n')
}

#[cfg(test)]
mod tests {
    use super::{Block, Event};
    fn events(s: &str) -> Vec<Event> {
        let mut b = Block::default();
        s.chars().map(|c| b.push(c)).collect()
    }

    #[test]
    fn first_byte_after_blank_decides_without_lookahead() {
        let e = events("one\n\nnext");
        assert!(matches!(e[5], Event::BeforeLine));
        assert!(!events("one\n\n-x").iter().any(|e| matches!(e, Event::BeforeLine)));
        assert!(!events("one\n\n1986").iter().any(|e| matches!(e, Event::BeforeLine)));
    }
    #[test]
    fn spaces_tabs_and_cr_are_blank_or_indent() {
        assert!(events("one\n \t\r\nnext").iter().any(|e| matches!(e, Event::BeforeLine)));
        assert!(!events("one\n\n\tnext").iter().any(|e| matches!(e, Event::BeforeLine)));
        let mut b = Block::default();
        for c in "one\n\n`".chars() {
            let _ = b.push(c);
        }
        assert_eq!(b.line_bytes(), 1);
    }
    #[test]
    fn tab_is_four_columns_and_marker_run_ends_on_space_or_text() {
        assert!(!events("one\n\n\ttext").iter().any(|e| matches!(e, Event::BeforeLine)));
        let mut b = Block::default();
        for c in "```\n``` x\n".chars() {
            let _ = b.push(c);
        }
        assert_eq!(b.fence_marker().as_deref(), Some("```"));
    }
    #[test]
    fn fences_suppress_blank_boundary_and_reject_nonmatching_close() {
        let mut b = Block::default();
        for c in "```rust\n\ninside\n\n```  x\n\n".chars() {
            let _ = b.push(c);
        }
        assert_eq!(b.fence_marker().as_deref(), Some("```"));
        for c in "```\n\n".chars() {
            let _ = b.push(c);
        }
        assert_eq!(b.fence_marker(), None);
    }
    #[test]
    fn cut_inside_line_resets_segment_counter_not_fence_state() {
        let mut b = Block::default();
        for c in "```\nbody".chars() {
            let _ = b.push(c);
        }
        b.mark_cut_inside_line();
        assert_eq!(b.line_bytes(), 0);
        assert_eq!(b.fence_marker().as_deref(), Some("```"));
        assert!(b.take_cut_inside_line());
    }
}
