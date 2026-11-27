//! Find the whole inline link before the reply pass considers its contents.

pub(super) fn link_end(text: &str) -> Option<usize> {
    let label_end = group_end(text, '[', ']')?;
    let target_end = group_end(text.get(label_end..)?, '(', ')')?;
    label_end.checked_add(target_end)
}

fn group_end(text: &str, open: char, close: char) -> Option<usize> {
    let mut chars = text.char_indices().peekable();
    if chars.next()?.1 != open {
        return None;
    }
    let mut depth = 1usize;
    let mut previous_whitespace = false;
    while let Some((at, c)) = chars.next() {
        if c == '\\' {
            chars.next();
            previous_whitespace = false;
            continue;
        }
        if open == '[' && c == '`' {
            // Brackets in a code span are label text. An unmatched backtick run
            // is literal, so search on a clone and consume only a matched span.
            let mut ticks = 1usize;
            while chars.next_if(|(_, c)| *c == '`').is_some() {
                ticks = ticks.checked_add(1)?;
            }
            let mut scan = chars.clone();
            while let Some((_, c)) = scan.next() {
                if c != '`' {
                    continue;
                }
                let mut closing_ticks = 1usize;
                while scan.next_if(|(_, c)| *c == '`').is_some() {
                    closing_ticks = closing_ticks.checked_add(1)?;
                }
                if closing_ticks == ticks {
                    chars = scan;
                    break;
                }
            }
            previous_whitespace = false;
            continue;
        }
        if open == '(' && (c == '<' || (previous_whitespace && matches!(c, '\'' | '"'))) {
            // Parentheses inside an angle destination or quoted title do not
            // close the link. Backslash escapes apply inside both as well.
            let delimiter = if c == '<' { '>' } else { c };
            loop {
                match chars.next()?.1 {
                    '\\' => {
                        chars.next();
                    }
                    c if c == delimiter => break,
                    _ => {}
                }
            }
            previous_whitespace = false;
            continue;
        }
        if c == open {
            depth = depth.checked_add(1)?;
        } else if c == close {
            depth = depth.checked_sub(1)?;
            if depth == 0 {
                return at.checked_add(c.len_utf8());
            }
        }
        previous_whitespace = c.is_whitespace();
    }
    None
}
