//! The reply length gate, shared by every Chief engine (Lawrence: "currently
//! i think the responses are generally too long"; a prompt rule alone did not
//! move the median reply). The send tool checks a reply's length: the first
//! send of a turn over the limit is refused with its word count, so Chief cuts
//! it itself (no other model touches its facts); a second send in that turn
//! posts as is, so a long answer the user asked for still goes out.
//!
//! Words are counted as the person reads them (Nov 12-19: 112 refusals, most
//! of them a status list of short lines or a table of pictures): a table row,
//! a picture and a code span are no prose, and a list is read line by line,
//! so its total is not judged, only each line.

/// The most prose words a reply may have before its first send is refused.
/// A link counts as its text, not its URL. 0 turns the gate off.
pub const REPLY_MAX_WORDS: usize = 45;

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
