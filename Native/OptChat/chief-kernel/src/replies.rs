//! The reply length gate, shared by every Chief engine (Lawrence: "currently
//! i think the responses are generally too long"; a prompt rule alone did not
//! move the median reply). The send tool keeps that short-message intent by
//! splitting an over-limit reply at Markdown-safe sentence and paragraph
//! boundaries. An explicitly long answer may still be sent as one message.
//!
//! Words are counted as the person reads them (Nov 12-19: 112 refusals, most
//! of them a status list of short lines or a table of pictures): a table row,
//! a picture and a code span are no prose, and a list is read line by line,
//! so its total is not judged, only each line.

/// The target maximum prose words for each split reply part.
/// A link counts as its text, not its URL. 0 disables splitting.
pub const REPLY_MAX_WORDS: usize = 45;

/// Split a reply into short messages without cutting Markdown structures.
///
/// Fenced code blocks and individual list items stay together whenever that is
/// possible. Paragraphs are split at sentence boundaries, and parts are then
/// grouped up to `limit` words. An unusually long sentence, list item or code
/// block is kept whole because there is no safe boundary inside it.
pub fn split_reply(text: &str, limit: usize) -> Vec<String> {
    if text.trim().is_empty() || limit == 0 || reply_words(text) <= limit {
        return vec![text.to_owned()];
    }

    let atoms = reply_atoms(text);
    let mut parts = Vec::new();
    let mut current = String::new();
    for atom in atoms {
        for sentence in split_atom(&atom, limit) {
            let candidate = if current.is_empty() {
                sentence.clone()
            } else {
                format!("{current}\n\n{sentence}")
            };
            if !current.is_empty() && reply_words(&candidate) > limit {
                parts.push(current.trim().to_owned());
                current = sentence;
            } else {
                current = candidate;
            }
        }
    }
    if !current.trim().is_empty() {
        parts.push(current.trim().to_owned());
    }
    parts
}

fn reply_atoms(text: &str) -> Vec<String> {
    let mut atoms = Vec::new();
    let mut regular = String::new();
    let mut list = String::new();
    let mut code = String::new();
    let mut fenced: Option<(char, usize)> = None;

    let flush_regular = |atoms: &mut Vec<String>, regular: &mut String| {
        if !regular.trim().is_empty() {
            atoms.push(std::mem::take(regular));
        }
    };
    let flush_list = |atoms: &mut Vec<String>, list: &mut String| {
        if !list.trim().is_empty() {
            atoms.push(std::mem::take(list));
        }
    };

    for line in text.split_inclusive('\n') {
        let trimmed = line.trim_start();
        if let Some((fence_char, fence_len)) = fenced {
            code.push_str(line);
            if fence_marker(trimmed).is_some_and(|(ch, len)| ch == fence_char && len >= fence_len) {
                atoms.push(std::mem::take(&mut code));
                fenced = None;
            }
            continue;
        }
        if let Some(marker) = fence_marker(trimmed) {
            flush_regular(&mut atoms, &mut regular);
            flush_list(&mut atoms, &mut list);
            code.push_str(line);
            fenced = Some(marker);
        } else if list_line(line) {
            flush_regular(&mut atoms, &mut regular);
            flush_list(&mut atoms, &mut list);
            list.push_str(line);
        } else if !list.is_empty() && (line.starts_with([' ', '\t']) || line.trim().is_empty()) {
            list.push_str(line);
        } else if line.trim().is_empty() {
            flush_regular(&mut atoms, &mut regular);
            flush_list(&mut atoms, &mut list);
        } else {
            flush_list(&mut atoms, &mut list);
            regular.push_str(line);
        }
    }
    flush_regular(&mut atoms, &mut regular);
    flush_list(&mut atoms, &mut list);
    if fenced.is_some() && !code.is_empty() {
        atoms.push(code);
    }
    atoms
}

fn split_atom(atom: &str, limit: usize) -> Vec<String> {
    if fence_marker(atom.lines().next().unwrap_or("")).is_some() || atom.lines().any(list_line) {
        // The old gate judged list items one line at a time. Keep a list item
        // intact, including an unusually long item, instead of making its
        // continuation look like unrelated prose.
        return vec![atom.to_owned()];
    }
    if reply_words(atom) <= limit {
        return vec![atom.to_owned()];
    }
    let sentences = sentence_atoms(atom);
    if sentences.len() <= 1 {
        return vec![atom.to_owned()];
    }
    sentences
}

/// Return sentence-sized slices while ignoring punctuation inside code spans
/// and Markdown links. A paragraph with no safe break remains one slice.
fn sentence_atoms(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut code = false;
    let mut link_text = false;
    let mut link_parens = 0usize;
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    for (index, ch) in chars.iter().copied() {
        if ch == '`' && link_parens == 0 {
            code = !code;
            continue;
        }
        if code {
            continue;
        }
        if link_parens == 0 && ch == '[' {
            link_text = true;
            continue;
        }
        if link_text {
            if ch == ']' {
                link_text = false;
            }
            continue;
        }
        if ch == '(' && index > 0 && text[..index].ends_with(']') {
            link_parens = 1;
            continue;
        }
        if link_parens > 0 {
            if ch == '(' {
                link_parens += 1;
            } else if ch == ')' {
                link_parens -= 1;
            }
            continue;
        }
        let next = text[index + ch.len_utf8()..].chars().next();
        let boundary = matches!(ch, '.' | '!' | '?') && next.is_none_or(char::is_whitespace);
        if boundary {
            let end = index + ch.len_utf8();
            let piece = text[start..end].trim();
            if !piece.is_empty() {
                out.push(piece.to_owned());
            }
            start = end;
            while text[start..]
                .chars()
                .next()
                .is_some_and(char::is_whitespace)
            {
                start += text[start..].chars().next().unwrap().len_utf8();
            }
        }
    }
    let tail = text[start..].trim();
    if !tail.is_empty() {
        out.push(tail.to_owned());
    }
    out
}

fn fence_marker(line: &str) -> Option<(char, usize)> {
    let trimmed = line.trim_start();
    let ch = trimmed.chars().next()?;
    if ch != '`' && ch != '~' {
        return None;
    }
    let len = trimmed
        .chars()
        .take_while(|candidate| *candidate == ch)
        .count();
    (len >= 3).then_some((ch, len))
}

/// The most words of one list line, for `limit` prose words (35 for 45).
pub fn line_max_words(limit: usize) -> usize {
    limit * 7 / 9
}

/// `text` as the person reads it: a Markdown link `[t](url)` is `t`, a
/// picture `![alt](path)` and a table row are dropped, a code span is one word.
fn shown(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for line in text.lines() {
        if line.trim_start().starts_with('|') {
            out.push('\n');
            continue;
        }
        let mut rest = line;
        while !rest.is_empty() {
            let picture = rest.find("![");
            let link = rest.find("](");
            let code = rest.find('`');
            let next = [picture, link, code].into_iter().flatten().min();
            let Some(at) = next else {
                out.push_str(rest);
                break;
            };
            if Some(at) == picture
                && let Some(end) = rest[at..].find("](")
                && let Some(close) = rest[at + end + 2..].find(')')
            {
                out.push_str(&rest[..at]);
                out.push(' ');
                rest = &rest[at + end + 2 + close + 1..];
            } else if Some(at) == link
                && let Some(close) = rest[at + 2..].find(')')
            {
                out.push_str(&rest[..at]);
                out.push(' ');
                rest = &rest[at + 2 + close + 1..];
            } else if Some(at) == code
                && let Some(close) = rest[at + 1..].find('`')
            {
                out.push_str(&rest[..at]);
                out.push_str(" code ");
                rest = &rest[at + 1 + close + 1..];
            } else {
                out.push_str(&rest[..at + 1]);
                rest = &rest[at + 1..];
            }
        }
        out.push('\n');
    }
    out
}

fn count(text: &str) -> usize {
    text.split_whitespace()
        .filter(|w| w.chars().any(char::is_alphanumeric))
        .count()
}

/// A list line: `- `, `* `, `+ ` or `1. ` / `1) ` after any indent.
fn list_line(line: &str) -> bool {
    let t = line.trim_start();
    if let Some(rest) = t.strip_prefix(['-', '*', '+']) {
        return rest.starts_with(' ');
    }
    let digits = t.chars().take_while(char::is_ascii_digit).count();
    digits > 0 && {
        let rest = &t[digits..];
        (rest.starts_with(". ") || rest.starts_with(") ")) && digits < 4
    }
}

/// The prose words of `text` and the words of each list line (an indented
/// line after a list line continues it).
fn parts(text: &str) -> (usize, Vec<usize>) {
    let mut prose = String::new();
    let mut lines: Vec<String> = Vec::new();
    for line in shown(text).lines() {
        if list_line(line) {
            lines.push(line.to_owned());
        } else if let Some(last) = lines.last_mut()
            && line.starts_with([' ', '\t'])
            && !line.trim().is_empty()
        {
            last.push(' ');
            last.push_str(line);
        } else {
            prose.push_str(line);
            prose.push('\n');
        }
    }
    (count(&prose), lines.iter().map(|l| count(l)).collect())
}

/// The words of `text` as the person reads them: links count as their text;
/// tables and pictures count nothing; a code span counts as one word.
pub fn reply_words(text: &str) -> usize {
    count(&shown(text))
}

/// The refusal for `text` when its prose is over `limit` words or one list
/// line is over [`line_max_words`], and this turn has not been refused for
/// length yet (`refused_before`); None when it may post.
pub fn length_check(text: &str, limit: usize, refused_before: bool) -> Option<String> {
    if limit == 0 || refused_before {
        return None;
    }
    let (prose, lines) = parts(text);
    let line_limit = line_max_words(limit).max(1);
    let what = if prose > limit {
        format!("its prose is {prose} words and the limit is {limit}")
    } else if let Some((k, words)) = lines
        .iter()
        .enumerate()
        .find(|(_, words)| **words > line_limit)
    {
        format!(
            "list line {} is {words} words and the limit is {line_limit} a line",
            k + 1
        )
    } else {
        return None;
    };
    Some(format!(
        "send: refused, nothing was posted: {what}. Tables, pictures and code spans do not count, \
and a list counts line by line. \
Cut it to the answer and its links: one line per task, no cause, steps or test details unless the user asked why. \
Then send again; a second send this turn posts as is, for an answer the user asked to be long (or send it with `long: true` the first time)."
    ))
}
