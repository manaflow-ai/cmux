//! Find in a terminal chat, as GUI chats find (webviews' `conversation/chatFind.ts`,
//! `ChatFindBar.tsx`). Leo, 2026-11-24: "in terminals and guis alike perhaps terminal simply
//! needs to also have the fixes and enhancements".
//!
//! The GUI searches prompts, replies and tool rows, shows "N of M", steps with Enter and
//! Shift-Enter (Cmd-G, Shift-Cmd-G), closes with Escape, and folds case the same way
//! (`foldFind`: U+0130 to "i", then lowercase). Here the same runs over the rows the transcript
//! draws, so a match is always a place on screen: the current one scrolls into view and is drawn
//! stronger than the rest.

use unicode_width::UnicodeWidthChar;

/// One match: the drawn row and its display columns `[start, end)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Match {
    pub row: usize,
    pub start: usize,
    pub end: usize,
}

/// The open find bar of one session's transcript.
#[derive(Debug, Default, Clone)]
pub struct Find {
    pub session: String,
    pub query: String,
    pub matches: Vec<Match>,
    /// Index into `matches`.
    pub current: usize,
    /// Matches need a new search: the query or the drawn rows changed.
    pub stale: bool,
    /// The current match must be scrolled into view at the next draw.
    pub reveal: bool,
}

impl Find {
    pub fn open(session: String) -> Self {
        Self { session, stale: true, ..Self::default() }
    }

    pub fn type_char(&mut self, c: char) {
        self.query.push(c);
        self.stale = true;
        self.reveal = true;
    }

    pub fn backspace(&mut self) {
        if self.query.pop().is_some() {
            self.stale = true;
            self.reveal = true;
        }
    }

    pub fn clear(&mut self) {
        if !self.query.is_empty() {
            self.query.clear();
            self.stale = true;
        }
    }

    /// Step to the next (`1`) or previous (`-1`) match, wrapping as the GUI does.
    pub fn step(&mut self, by: isize) {
        let n = self.matches.len();
        if n == 0 {
            return;
        }
        self.current = (self.current as isize + by).rem_euclid(n as isize) as usize;
        self.reveal = true;
    }

    pub fn current_match(&self) -> Option<Match> {
        self.matches.get(self.current).copied()
    }

    /// Search `rows` again. The current match becomes the first at or below `from_row` (the top
    /// of the viewport, so the reader's place holds), else the last one.
    pub fn refresh(&mut self, rows: &[String], from_row: usize) {
        let before = self.current_match();
        self.matches = search(rows, &self.query);
        self.stale = false;
        let keep = before.and_then(|b| self.matches.iter().position(|m| *m == b));
        self.current = keep
            .or_else(|| self.matches.iter().position(|m| m.row >= from_row))
            .unwrap_or(self.matches.len().saturating_sub(1));
    }

    /// "3 of 12", "No results", or nothing before a query.
    pub fn count_label(&self) -> String {
        if self.query.is_empty() {
            String::new()
        } else if self.matches.is_empty() {
            "No results".into()
        } else {
            format!("{} of {}", self.current + 1, self.matches.len())
        }
    }

    /// The viewport offset that shows the current match, or None when it already shows.
    pub fn reveal_offset(&self, offset: usize, visible: usize, total: usize) -> Option<usize> {
        let row = self.current_match()?.row;
        if visible == 0 || (row >= offset && row < offset + visible) {
            return None;
        }
        let max = total.saturating_sub(visible);
        Some(row.saturating_sub(visible / 3).min(max))
    }
}

/// The GUI's `foldFind`, one char at a time so folded bytes map back to the char they came from.
fn fold_char(c: char, out: &mut String) {
    if c == '\u{130}' {
        out.push('i');
    } else {
        out.extend(c.to_lowercase());
    }
}

fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    s.chars().for_each(|c| fold_char(c, &mut out));
    out
}

/// Every match of `query` in `rows`, in reading order, as display columns.
pub fn search(rows: &[String], query: &str) -> Vec<Match> {
    let needle = fold(query);
    if needle.trim().is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut folded = String::new();
    // Per folded byte: the display column its char starts at; one extra entry for the end.
    let mut col_at: Vec<usize> = Vec::new();
    let mut end_col: Vec<usize> = Vec::new();
    for (row, text) in rows.iter().enumerate() {
        folded.clear();
        col_at.clear();
        end_col.clear();
        let mut col = 0;
        for c in text.chars() {
            let w = c.width().unwrap_or(0);
            let at = folded.len();
            fold_char(c, &mut folded);
            for _ in at..folded.len() {
                col_at.push(col);
                end_col.push(col + w);
            }
            col += w;
        }
        for (start, _) in folded.match_indices(needle.as_str()) {
            let last = start.saturating_add(needle.len()).saturating_sub(1);
            let (Some(&s), Some(&e)) = (col_at.get(start), end_col.get(last)) else {
                continue;
            };
            out.push(Match { row, start: s, end: e.max(s.saturating_add(1)) });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(lines: &[&str]) -> Vec<String> {
        lines.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn finds_every_match_folded_like_the_gui() {
        let r = rows(&["› Fix the Build", "  the build is red; BUILD again", "İstanbul"]);
        let m = search(&r, "build");
        assert_eq!(
            m,
            vec![
                Match { row: 0, start: 10, end: 15 },
                Match { row: 1, start: 6, end: 11 },
                Match { row: 1, start: 20, end: 25 },
            ]
        );
        assert_eq!(search(&r, "istan"), vec![Match { row: 2, start: 0, end: 5 }]);
        assert!(search(&r, "").is_empty());
        assert!(search(&r, "   ").is_empty());
        assert!(search(&r, "missing").is_empty());
    }

    #[test]
    fn columns_count_wide_chars_as_drawn() {
        let r = rows(&["日本 ok"]);
        assert_eq!(search(&r, "ok"), vec![Match { row: 0, start: 5, end: 7 }]);
        assert_eq!(search(&r, "本"), vec![Match { row: 0, start: 2, end: 4 }]);
    }

    #[test]
    fn steps_wrap_and_count_like_the_bar() {
        let r = rows(&["a x", "b x", "c x"]);
        let mut f = Find::open("s".into());
        assert_eq!(f.count_label(), "");
        for c in "x".chars() {
            f.type_char(c);
        }
        f.refresh(&r, 1);
        assert_eq!(f.count_label(), "2 of 3", "starts at the viewport's top");
        f.step(1);
        f.step(1);
        assert_eq!(f.count_label(), "1 of 3", "wraps forward");
        f.step(-1);
        assert_eq!(f.count_label(), "3 of 3", "wraps back");
        f.type_char('z');
        f.refresh(&r, 0);
        assert_eq!(f.count_label(), "No results");
        f.step(1);
        assert_eq!(f.current_match(), None);
    }

    #[test]
    fn a_redraw_keeps_the_current_match() {
        let mut r = rows(&["x", "x", "x"]);
        let mut f = Find::open("s".into());
        f.type_char('x');
        f.refresh(&r, 0);
        f.step(1);
        r.push("x new reply".into());
        f.refresh(&r, 0);
        assert_eq!(f.count_label(), "2 of 4");
    }

    #[test]
    fn reveals_only_an_offscreen_match() {
        let r: Vec<String> = (0..100).map(|i| format!("row {i}")).collect();
        let mut f = Find::open("s".into());
        for c in "row 70".chars() {
            f.type_char(c);
        }
        f.refresh(&r, 0);
        assert_eq!(f.reveal_offset(65, 20, 100), None, "already on screen");
        assert_eq!(f.reveal_offset(0, 20, 100), Some(64), "a third down from the top");
        assert_eq!(f.reveal_offset(0, 60, 100), Some(40), "clamped to the last page");
    }
}
