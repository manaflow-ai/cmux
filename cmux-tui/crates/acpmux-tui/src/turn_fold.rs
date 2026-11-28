//! What a finished turn's "Worked for" fold hides and what it leaves in sight, as the GUI chat's
//! fold decides it (`webviews/.../conversation/turns.ts`). Leo, 2026-11-24: "in terminals and guis
//! alike perhaps terminal simply needs to also have the fixes and enhancements".
//!
//! - cmux#42279, #42466: a reply the agent wrote between tool runs stays in sight when it is a
//!   takeaway, not narration. Only up to two short progress sentences ("Let me check the logs.",
//!   "Running the tests.") fold with the work; a finding, a question, a list or a link never does.
//! - cmux#44475: a turn that died on an error reads "Failed after", not "Worked for".
//! - cmux#41774, #41537: the final reply is the last reply with words in it, and calls, plans,
//!   thoughts and notes the harness sent after it fold with the work instead of trailing under it.

use acpmux::transcript::{Item, Transcript};

/// An error card a later turn has gone past (cmux#48464): once the chat went on and a later turn
/// answered, a failed turn's "ran into a problem" card no longer draws. The live turn has not
/// completed yet, so it supersedes nothing while it runs.
pub(crate) fn superseded_error(t: &Transcript, i: usize) -> bool {
    let prompt = |x: &Item| matches!(x, Item::User { queued: false, steer: false, .. });
    let mut at = i + 1;
    while let Some(off) = t.items.get(at..).and_then(|rest| rest.iter().position(prompt)) {
        let start = at + off + 1;
        let rest = t.items.get(start..).unwrap_or_default();
        let end = rest.iter().position(prompt).map_or(t.items.len(), |p| start + p);
        let live = end == t.items.len() && t.status == "running";
        let turn = t.items.get(start..end).unwrap_or_default();
        if !live
            && !turn.iter().any(|x| matches!(x, Item::Error { .. }))
            && turn.iter().any(|x| matches!(x, Item::Assistant { text } if !text.trim().is_empty()))
        {
            return true;
        }
        at = end;
    }
    false
}

/// A reply this long stays in sight (`SHORT_NOTE_CHARS`).
const SHORT_NOTE_CHARS: usize = 160;
/// A reply over this many lines stays in sight (`TAKEAWAY_LINES`).
const TAKEAWAY_LINES: usize = 3;

/// A reply that reads as a takeaway, not narration of the work (`isTakeaway`).
pub(crate) fn is_takeaway(text: &str) -> bool {
    let text = text.trim();
    if text.is_empty() {
        return false;
    }
    text.chars().count() > SHORT_NOTE_CHARS
        || text.split('\n').count() > TAKEAWAY_LINES
        || text.contains('?')
        || text.contains("```")
        || text.contains("~~~")
        || has_blank_line(text)
        || text.lines().any(is_list_line)
        || text.contains("](")
        || text.contains("http://")
        || text.contains("https://")
        || !is_work_narration(text)
}

/// `\n\s*\n`: a second paragraph.
fn has_blank_line(text: &str) -> bool {
    let lines: Vec<&str> = text.split('\n').collect();
    lines.len() > 2
        && lines
            .get(1..lines.len().saturating_sub(1))
            .is_some_and(|inner| inner.iter().any(|l| l.trim().is_empty()))
}

/// `^\s*(?:[-*+]|\d+[.)])\s`: a list item.
fn is_list_line(line: &str) -> bool {
    let l = line.trim_start();
    let rest = if let Some(r) = l.strip_prefix(['-', '*', '+']) {
        r
    } else {
        let digits = l.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 {
            return false;
        }
        match l.get(digits..).and_then(|r| r.strip_prefix(['.', ')'])) {
            Some(r) => r,
            None => return false,
        }
    };
    rest.starts_with(char::is_whitespace)
}

/// Sentences split at `.`, `!` or `?` followed by space or the end; an ellipsis counts as a stop.
fn sentences(text: &str) -> Vec<String> {
    let text = text.replace('…', ".");
    let chars: Vec<char> = text.chars().collect();
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut i = 0;
    while let Some(&ch) = chars.get(i) {
        if matches!(ch, '.' | '!' | '?') {
            // An ellipsis ("...") is one stop.
            let mut j = i;
            while ch == '.' && chars.get(j + 1) == Some(&'.') {
                j += 1;
            }
            if chars.get(j + 1).is_none_or(|c| c.is_whitespace()) {
                out.push(std::mem::take(&mut cur));
                i = j + 1;
                while chars.get(i).is_some_and(|c| c.is_whitespace()) {
                    i += 1;
                }
                continue;
            }
            cur.extend(chars.get(i..=j).unwrap_or_default());
            i = j + 1;
            continue;
        }
        cur.push(ch);
        i += 1;
    }
    out.push(cur);
    out.into_iter().filter(|s| !s.trim().is_empty()).collect()
}

const ACTIONS: &[&str] =
    &["check", "read", "look", "inspect", "search", "run", "test", "review", "verify", "wait"];
const GERUNDS: &[&str] = &[
    "checking",
    "reading",
    "looking",
    "inspecting",
    "searching",
    "running",
    "testing",
    "reviewing",
    "verifying",
    "waiting",
];
/// Words after the action that make the sentence say something (an answer, not narration).
const CLAUSE_WORDS: &[&str] = &[
    "am",
    "is",
    "are",
    "was",
    "were",
    "has",
    "have",
    "had",
    "can",
    "could",
    "should",
    "would",
    "will",
    "because",
    "but",
    "however",
    "therefore",
    "mean",
    "means",
    "show",
    "shows",
    "reveal",
    "reveals",
    "than",
];
/// Words before which an "-ed" word is an adjective ("the failed jobs"), not a verb.
const ED_ADJECTIVE_AFTER: &[&str] = &[
    "the", "a", "an", "its", "this", "that", "these", "those", "each", "every", "all", "any", "my",
    "your", "our", "their", "some", "both", "for", "of", "in", "on", "from", "with", "to", "at",
    "by", "and", "or", "newly", "recently",
];
/// Verbs a gerund subject takes: "Checking the cache found no errors." reports a result.
const FINDING_VERBS: &[&str] = &[
    "found", "took", "made", "gave", "got", "came", "went", "ran", "saw", "left", "broke", "said",
    "told", "kept", "held", "brought", "knew", "lost", "won", "beat", "fell", "grew", "stood",
    "meant", "cost", "finds", "takes", "makes", "gives", "gets", "works", "fails", "passes",
    "helps", "saves", "costs", "beats", "wins", "needs", "breaks", "returns", "stays", "matches",
    "fixes", "causes", "leads", "keeps", "hides", "drops", "skips", "hangs", "crashes", "seems",
    "looks", "turns", "proves", "confirms",
];

/// The action that opens a narration sentence, as its byte length, or None.
fn action_len(lower: &str) -> Option<usize> {
    let word_end = |s: &str, at: usize| {
        s.get(at..).and_then(|r| r.chars().next()).is_none_or(|c| !c.is_alphanumeric())
    };
    for lead in ["let me ", "i'll ", "i’ll ", "i will "] {
        if let Some(rest) = lower.strip_prefix(lead) {
            for a in ACTIONS {
                if rest.starts_with(a) && word_end(rest, a.len()) {
                    return Some(lead.len() + a.len());
                }
            }
        }
    }
    for lead in ["i'm ", "i’m ", "i am ", ""] {
        if let Some(rest) = lower.strip_prefix(lead) {
            for g in GERUNDS {
                if rest.starts_with(g) && word_end(rest, g.len()) {
                    return Some(lead.len() + g.len());
                }
            }
        }
    }
    None
}

fn words(s: &str) -> Vec<String> {
    s.split_whitespace()
        .map(|w| w.chars().filter(|c| c.is_alphabetic() || matches!(c, '\'' | '’' | '-')).collect())
        .collect()
}

/// "Both … still running": a progress note about background work.
fn is_still_running(lower: &str) -> bool {
    let Some(rest) = ["both ", "the ", "all "].iter().find_map(|p| lower.strip_prefix(p)) else {
        return false;
    };
    ["still running", "still pending", "are running", "are pending"].iter().any(|tail| {
        rest.strip_suffix(tail).is_some_and(|mid| {
            !mid.trim().is_empty() && mid.ends_with(' ') && !mid.contains([',', ';', ':', '|'])
        })
    })
}

fn has_finite_verb(rest: &str) -> bool {
    let w = words(rest);
    w.iter().enumerate().any(|(at, word)| {
        if at == 0 {
            return false;
        }
        let lower = word.to_lowercase();
        if FINDING_VERBS.contains(&lower.as_str()) {
            return true;
        }
        let letters = lower.chars().count();
        letters >= 4
            && lower.chars().all(char::is_alphabetic)
            && lower.ends_with("ed")
            && !lower.ends_with("eed")
            && at
                .checked_sub(1)
                .and_then(|p| w.get(p))
                .is_none_or(|prev| !ED_ADJECTIVE_AFTER.contains(&prev.to_lowercase().as_str()))
    })
}

/// Only recognizable short progress narration belongs to the work (`isWorkNarration`).
fn is_work_narration(text: &str) -> bool {
    let sentences = sentences(text);
    !sentences.is_empty()
        && sentences.len() <= 2
        && sentences.iter().all(|part| {
            let note = part.trim();
            let lower = note.to_lowercase();
            if is_still_running(&lower) {
                return true;
            }
            let Some(len) = action_len(&lower) else { return false };
            let Some(rest) = lower.get(len..) else { return false };
            !rest.contains([',', ';', ':', '|'])
                && !words(rest).iter().any(|w| CLAUSE_WORDS.contains(&w.as_str()))
                && !has_finite_verb(rest)
        })
}

#[cfg(test)]
#[path = "turn_fold_tests.rs"]
mod tests;
