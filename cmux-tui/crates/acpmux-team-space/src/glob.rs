//! The small glob a person's areas are written in: `*` matches within one path segment, `**`
//! matches across segments, `?` matches one character. `dir/**` also matches `dir` itself.
//! Matching is case-insensitive, so `label:Forum` and `label:forum` are one area.

/// Whether `text` matches `pattern`.
pub fn matches(pattern: &str, text: &str) -> bool {
    let pattern: Vec<char> = pattern.to_lowercase().chars().collect();
    let text: Vec<char> = text.to_lowercase().chars().collect();
    if let Some(prefix) = pattern.strip_suffix(&['/', '*', '*'])
        && prefix == text.as_slice()
    {
        return true;
    }
    matches_at(&pattern, &text)
}

fn matches_at(pattern: &[char], text: &[char]) -> bool {
    // Iterative with one backtrack point per star kind keeps this linear-ish on long tokens.
    let (mut p, mut t) = (0, 0);
    let mut star: Option<(usize, usize, bool)> = None;
    while t < text.len() {
        if pattern.get(p) == Some(&'*') {
            let double = pattern.get(p + 1) == Some(&'*');
            p += if double { 2 } else { 1 };
            star = Some((p, t, double));
            continue;
        }
        if let Some(c) = pattern.get(p)
            && (*c == '?' || text.get(t) == Some(c))
        {
            p += 1;
            t += 1;
            continue;
        }
        match star {
            // A single star never swallows a '/'.
            Some((sp, st, double)) if double || text.get(st) != Some(&'/') => {
                star = Some((sp, st + 1, double));
                p = sp;
                t = st + 1;
            }
            _ => return false,
        }
    }
    pattern.get(p..).is_some_and(|rest| rest.iter().all(|c| *c == '*'))
}

#[cfg(test)]
mod tests {
    use super::matches;

    #[test]
    fn segment_and_tree_stars() {
        assert!(matches("cmux-tui/crates/acpmux/**", "cmux-tui/crates/acpmux/src/hub/inbox.rs"));
        assert!(matches("cmux-tui/crates/acpmux/**", "cmux-tui/crates/acpmux"));
        assert!(!matches("cmux-tui/crates/acpmux/**", "cmux-tui/crates/acpmux-core/src/lib.rs"));
        assert!(matches("cmux-tui/crates/*/Cargo.toml", "cmux-tui/crates/acpmux/Cargo.toml"));
        assert!(!matches("cmux-tui/crates/*/Cargo.toml", "cmux-tui/crates/a/b/Cargo.toml"));
        assert!(matches("label:forum*", "label:Forum-hosted"));
        assert!(matches("?ebviews/**", "webviews/src/x.tsx"));
        assert!(!matches("label:forum", "label:forums"));
        assert!(matches("**", "anything/at/all"));
    }
}
