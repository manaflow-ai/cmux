//! Whether a short reply is progress narration that folds into the work around it, or a brief
//! answer that stays in sight. The daemon's copy of the page's `isWorkNarration` (turns.ts), made
//! the source (motion model step 9, "The daemon owns shape"): only recognizable short progress
//! notes ("Let me check the cache.") belong to the work; unknown prose can be a brief answer (Leo,
//! 2026-11-13). Every sentence is checked, so "Let me check. The cache is stale." keeps its finding.
//!
//! Word boundaries and case folding are ASCII, as in the page's regular expressions.

/// Actions a narration opens with after "let me", "I'll" or "I will".
const ACTIONS: &[&str] =
    &["check", "read", "look", "inspect", "search", "run", "test", "review", "verify", "wait"];
/// The same actions as the gerunds a narration opens with, maybe after "I'm" or "I am".
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
/// Words after the action that make the clause say something: "Running two tasks is faster".
const SAYING: &[&str] = &[
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

fn is_word(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}
fn any_eq(words: &[&str], word: &str) -> bool {
    !word.is_empty() && words.iter().any(|w| w.eq_ignore_ascii_case(word))
}

/// Whether trimmed reply `text` is work narration: one or two sentences, each a progress note.
pub(super) fn is_work_narration(text: &str) -> bool {
    let mut sentences = Vec::new();
    let mut part = String::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        // A run of three or more dots, or an ellipsis, is one stop.
        let stop = if ch == '…' {
            Some('.')
        } else if ch == '.' && chars.clone().take(2).filter(|c| *c == '.').count() == 2 {
            while chars.peek() == Some(&'.') {
                chars.next();
            }
            Some('.')
        } else {
            matches!(ch, '.' | '!' | '?').then_some(ch)
        };
        let Some(stop) = stop else {
            part.push(ch);
            continue;
        };
        if chars.peek().is_none_or(|next| next.is_whitespace()) {
            while chars.peek().is_some_and(|next| next.is_whitespace()) {
                chars.next();
            }
            sentences.push(std::mem::take(&mut part));
        } else {
            part.push(stop);
        }
    }
    sentences.push(part);
    sentences.retain(|part| !part.trim().is_empty());
    (1..=2).contains(&sentences.len()) && sentences.iter().all(|part| is_note(part.trim()))
}

fn is_note(note: &str) -> bool {
    if is_still_running(note) {
        return true;
    }
    let Some(action) = action_len(note) else {
        return false;
    };
    // An action prefix alone does not make a progress note: "Let me check; the cache is stale"
    // contains an answer. Ambiguous clauses stay visible.
    let rest = &note[action..];
    !rest.contains([',', ';', ':', '|'])
        && !rest.split(|c: char| !(c.is_ascii() && is_word(c as u8))).any(|w| any_eq(SAYING, w))
        && !has_finite_verb(rest)
}

/// "Both checks are still running", "The jobs still pending".
fn is_still_running(note: &str) -> bool {
    let lower = note.to_ascii_lowercase();
    let Some(after) = ["both ", "the ", "all "].iter().find_map(|p| lower.strip_prefix(p)) else {
        return false;
    };
    ["still running", "still pending", "are running", "are pending"].iter().any(|end| {
        after.strip_suffix(end).is_some_and(|middle| {
            middle.as_bytes().last().is_some_and(|b| !is_word(*b))
                && !middle.contains([',', ';', ':', '|'])
        })
    })
}

/// The byte length of the action a note opens with, if it opens with one.
fn action_len(note: &str) -> Option<usize> {
    let lower = note.to_ascii_lowercase();
    let bounded = |len: usize| lower.as_bytes().get(len).is_none_or(|b| !is_word(*b));
    for lead in ["let me ", "i'll ", "i’ll ", "i will "] {
        if let Some(after) = lower.strip_prefix(lead) {
            for action in ACTIONS {
                let len = lead.len() + action.len();
                if after.starts_with(action) && bounded(len) {
                    return Some(len);
                }
            }
        }
    }
    for lead in ["i'm ", "i’m ", "i am ", ""] {
        if let Some(after) = lower.strip_prefix(lead) {
            for gerund in GERUNDS {
                let len = lead.len() + gerund.len();
                if after.starts_with(gerund) && bounded(len) {
                    return Some(len);
                }
            }
        }
    }
    None
}

/// Whether the words after an action hold a finite verb: the action was a gerund subject and the
/// sentence says what it found. The first word is the action's object, never a verb.
fn has_finite_verb(rest: &str) -> bool {
    let words: Vec<String> = rest
        .split_whitespace()
        .map(|word| {
            word.chars().filter(|c| c.is_alphabetic() || matches!(c, '\'' | '’' | '-')).collect()
        })
        .collect();
    words.iter().enumerate().skip(1).any(|(at, word)| {
        any_eq(FINDING_VERBS, word)
            || (word.ends_with("ed")
                && word.chars().count() >= 4
                && word.chars().all(char::is_alphabetic)
                && !word.to_ascii_lowercase().ends_with("eed")
                && !any_eq(ED_ADJECTIVE_AFTER, &words[at - 1]))
    })
}

#[cfg(test)]
#[path = "narration_tests.rs"]
mod tests;
