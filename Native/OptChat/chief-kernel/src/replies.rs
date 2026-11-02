//! The reply length gate, shared by every Chief engine (Lawrence: "currently
//! i think the responses are generally too long"; a prompt rule alone did not
//! move the median reply). The send tool checks a reply's length: the first
//! send of a turn over the limit is refused with its word count, so Chief cuts
//! it itself (no other model touches its facts); a second send in that turn
//! posts as is, so a long answer the user asked for still goes out.

/// The most words a reply may have before its first send is refused. A link
/// counts as its text, not its URL. 0 turns the gate off.
pub const REPLY_MAX_WORDS: usize = 45;

/// The words of `text` as the user reads them: a Markdown link `[t](url)`
/// counts as `t`.
pub fn reply_words(text: &str) -> usize {
    let mut shown = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find("](") {
        let Some(close) = rest[open + 2..].find(')') else {
            break;
        };
        shown.push_str(&rest[..open]);
        shown.push(' ');
        rest = &rest[open + 2 + close + 1..];
    }
    shown.push_str(rest);
    shown
        .split_whitespace()
        .filter(|w| w.chars().any(char::is_alphanumeric))
        .count()
}

/// The refusal for `text` when it is over `limit` words and this turn has not
/// been refused for length yet (`refused_before`); None when it may post.
pub fn length_check(text: &str, limit: usize, refused_before: bool) -> Option<String> {
    if limit == 0 || refused_before {
        return None;
    }
    let words = reply_words(text);
    (words > limit).then(|| {
        format!(
            "send: refused, nothing was posted: the reply is {words} words and the limit is {limit}. \
Cut it to the answer and its links: one line per task, no cause, steps or test details unless the user asked why. \
Then send again; a second send this turn posts as is, for an answer the user asked to be long."
        )
    })
}
