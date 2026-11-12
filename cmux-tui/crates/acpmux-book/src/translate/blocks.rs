//! Incremental Markdown boundary facts. Retains no line/body; prefixes are capped.
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Block {
    prefix: String,
    line_bytes: u64,
    nonwhite: bool,
    fence: Option<char>,
    fence_len: usize,
    list: bool,
}
impl Block {
    pub fn fence_marker(&self) -> Option<String> {
        self.fence.map(|c| std::iter::repeat_n(c, self.fence_len).collect())
    }
    pub fn push(&mut self, ch: char) -> bool {
        if ch != '\n' {
            self.line_bytes = self.line_bytes.saturating_add(ch.len_utf8() as u64);
            self.nonwhite |= !ch.is_whitespace();
            if self.prefix.len() < 64 {
                self.prefix.push(ch);
            }
            return false;
        }
        let trimmed = self.prefix.trim_start();
        let indent = self.prefix.len().saturating_sub(trimmed.len());
        let marker = trimmed.chars().next().filter(|c| matches!(c, '`' | '~'));
        let run = marker.map(|c| trimmed.chars().take_while(|v| *v == c).count()).unwrap_or(0);
        if indent <= 3 && run >= 3 {
            if self.fence.is_none() {
                self.fence = marker;
                self.fence_len = run;
            } else if self.fence == marker
                && run >= self.fence_len
                && trimmed.chars().skip(run).all(char::is_whitespace)
            {
                self.fence = None;
                self.fence_len = 0;
            }
        }
        let blank = !self.nonwhite;
        let boundary = blank && self.fence.is_none() && !self.list;
        if self.fence.is_none() && !blank {
            let ordered = trimmed.trim_start_matches(|c: char| c.is_ascii_digit());
            let bullet = ["- ", "* ", "+ "].iter().any(|p| trimmed.starts_with(p));
            let number = ordered.len() < trimmed.len()
                && (ordered.starts_with(". ") || ordered.starts_with(") "));
            if bullet || number {
                self.list = true;
            } else if indent == 0 {
                self.list = false;
            }
        }
        self.prefix.clear();
        self.line_bytes = 0;
        self.nonwhite = false;
        boundary
    }
}
