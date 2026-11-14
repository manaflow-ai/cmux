//! Default worked-for fold. Children never move; the settled group names visible runs.
use serde::{Deserialize, Serialize};
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Run(pub u64, pub u64);
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Reply {
    pub runs: Vec<Run>,
    pub wide: bool,
    chars: u64,
    lines: u64,
    nonempty: bool,
    takeaway: bool,
    tail: String,
    // 0: leading whitespace, 1: digits, 2: list marker, 3: other text.
    list_prefix: u8,
    trailing_chars: u64,
    trailing_lines: u64,
    pending_takeaway: bool,
    last_newline: bool,
}
impl Reply {
    pub fn row(&mut self, id: u64) {
        if let Some(last) = self.runs.last_mut()
            && last.1.saturating_add(1) == id
        {
            last.1 = id;
            return;
        }
        if self.runs.len() == 8 {
            // Keep the bounded candidate state total: widening the final range
            // leaves the intervening rows visible rather than dropping an answer.
            if let Some(last) = self.runs.last_mut() {
                last.1 = id;
            }
            self.wide = true;
            return;
        }
        self.runs.push(Run(id, id));
    }
    pub fn push(&mut self, ch: char) {
        // R1 classifies text.trim(). Delay whitespace facts until a following word
        // makes them internal, without keeping the whitespace itself.
        if ch.is_whitespace() {
            if self.nonempty {
                self.trailing_chars = self.trailing_chars.saturating_add(ch.len_utf16() as u64);
                self.trailing_lines = self.trailing_lines.saturating_add(u64::from(ch == '\n'));
                self.pending_takeaway |= self.list_prefix == 2 || (ch == '\n' && self.last_newline);
            }
        } else {
            self.chars = self
                .chars
                .saturating_add(self.trailing_chars)
                .saturating_add(ch.len_utf16() as u64);
            self.lines = self.lines.saturating_add(self.trailing_lines);
            self.trailing_chars = 0;
            self.trailing_lines = 0;
            self.nonempty = true;
            self.takeaway |= self.pending_takeaway;
            self.pending_takeaway = false;
        }
        if ch == '\n' {
            self.last_newline = true;
            self.list_prefix = 0;
        } else {
            if !ch.is_whitespace() {
                self.last_newline = false;
            }
            self.list_prefix = match self.list_prefix {
                0 if ch.is_whitespace() => 0,
                0 | 1 if ch.is_ascii_digit() => 1,
                0 if matches!(ch, '-' | '*' | '+') => 2,
                1 if matches!(ch, '.' | ')') => 2,
                _ => 3,
            };
        }
        self.tail.push(ch);
        if self.tail.chars().count() > 8 {
            let n = self.tail.chars().next().map(char::len_utf8).unwrap_or(0);
            self.tail.drain(..n);
        }
        self.takeaway |= ch == '?'
            || ["```", "~~~", "](", "http://", "https://"].iter().any(|p| self.tail.ends_with(p));
    }
    fn takeaway(&self) -> bool {
        self.nonempty && (self.takeaway || self.chars > 160 || self.lines >= 3)
    }
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Fold {
    takeaway: Vec<Run>,
    since_work: Vec<Run>,
    last_reply: Vec<Run>,
    steers: Vec<Vec<Run>>,
    extras: Vec<Run>,
    pub dropped_steers: u64,
}
impl Fold {
    pub fn reply(&mut self, reply: &Reply) {
        if !reply.nonempty {
            return;
        }
        self.last_reply.clone_from(&reply.runs);
        self.since_work.clone_from(&reply.runs);
        if reply.takeaway() {
            self.takeaway.clone_from(&reply.runs);
        }
    }
    pub fn work(&mut self) {
        self.since_work.clear();
    }
    pub fn steer(&mut self) {
        if !self.last_reply.is_empty() {
            if self.steers.len() == 64 {
                self.steers.remove(0);
                self.dropped_steers = self.dropped_steers.saturating_add(1);
            }
            self.steers.push(std::mem::take(&mut self.last_reply));
        }
        self.takeaway.clear();
        self.since_work.clear();
    }
    pub fn extra(&mut self, id: u64) {
        if let Some(last) = self.extras.last_mut()
            && last.1.saturating_add(1) == id
        {
            last.1 = id;
            return;
        }
        if self.extras.len() == 64 {
            if let Some(last) = self.extras.last_mut() {
                last.1 = id;
            }
            return;
        }
        self.extras.push(Run(id, id));
    }
    pub fn forget(&mut self, runs: &[Run]) {
        let contains = |id: u64| runs.iter().any(|r| r.0 <= id && id <= r.1);
        for list in [&mut self.takeaway, &mut self.since_work, &mut self.last_reply] {
            list.retain(|r| !contains(r.0));
        }
        self.steers.retain(|list| !list.iter().any(|r| contains(r.0)));
    }
    pub fn out(&self) -> Vec<Run> {
        let mut out: Vec<_> = self.steers.iter().flatten().copied().collect();
        out.extend(self.extras.iter().copied());
        out.extend(if self.since_work.is_empty() { &self.takeaway } else { &self.since_work });
        out.sort_by_key(|r| r.0);
        let mut merged: Vec<Run> = Vec::new();
        for run in out {
            if let Some(last) = merged.last_mut()
                && run.0 <= last.1.saturating_add(1)
            {
                last.1 = last.1.max(run.1);
                continue;
            }
            merged.push(run);
        }
        merged
    }
}

#[cfg(test)]
mod tests;
