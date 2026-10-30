//! The host's part of the Chief as a personal assistant (#25576: "remembers
//! preferences, follows up on open work unasked, anticipates the next step,
//! and keeps answers short and actionable"). Pure text rules; the brain
//! applies them (brain/assist.rs).
//!
//! - Learned preferences: `remember` writes a line under `## Learned` in the
//!   person profile, but the profile is in the system prompt, read once per
//!   host start (the cached prefix). Every line learned since then goes in
//!   each turn's tail and in each new subagent's task, so it holds in every
//!   chat at once, also after the view summarized the `remember` call away.
//! - Promises: a reply that says "I'll check back" in a turn that set no
//!   wake and left no subagent at work gets a wake from the host, so the
//!   Chief does come back (the gap list's "a promise in prose").
//! - Offers: a reply that ends with "Want me to ...?" when nothing in it
//!   needs the person (money, legal, destructive, sign-in) gets one host
//!   note that tells the Chief to pick the default and act.

use crate::remember::LEARNED_HEADING;

/// How long after a promise with no wake the host wakes the Chief.
pub const PROMISE_WAKE_SECS: u64 = 15 * 60;

/// The first word of the host's note after a reply that ended with an offer.
pub const DECIDE_TAG: &str = "[decide]";

/// Characters of a quoted sentence kept in a note.
const QUOTE_CHARS: usize = 160;

/// The preference lines under `## Learned` in `profile`, without their
/// bullet, in file order.
pub fn learned_lines(profile: &str) -> Vec<String> {
    let mut inside = false;
    let mut lines = Vec::new();
    for line in profile.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('#') {
            inside = trimmed == LEARNED_HEADING;
            continue;
        }
        if !inside {
            continue;
        }
        let text = trimmed.trim_start_matches(['-', '*']).trim();
        if !text.is_empty() {
            lines.push(text.to_owned());
        }
    }
    lines
}

/// The learned lines of `profile` that `start` (the system text the host
/// started with) does not hold: what was learned since.
pub fn learned_since(profile: &str, start: &str) -> Vec<String> {
    learned_lines(profile)
        .into_iter()
        .filter(|line| !start.contains(line.as_str()))
        .collect()
}

/// The turn's tail line for `lines`; None when there are none.
pub fn learned_note(lines: &[String]) -> Option<String> {
    if lines.is_empty() {
        return None;
    }
    let mut note = String::from(
        "Preferences the user gave since your prompt was made (they are in their profile now; apply them like it):",
    );
    for line in lines {
        note.push_str("\n- ");
        note.push_str(line);
    }
    Some(note)
}

/// Lowercase with typographic apostrophes as ASCII ones.
fn plain(text: &str) -> String {
    text.replace(['\u{2019}', '\u{2018}'], "'").to_lowercase()
}

/// The sentences of `text`, split at `.`, `!`, `?` before a space or the
/// end ("README.md" and "v2.1" stay whole), and at line ends.
fn sentences(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        let at_end = chars.peek().is_none_or(|(_, n)| n.is_whitespace());
        if c == '\n' || (matches!(c, '.' | '!' | '?') && at_end) {
            let s = text[start..i + c.len_utf8()].trim();
            if !s.is_empty() {
                out.push(s);
            }
            start = i + c.len_utf8();
        }
    }
    let rest = text[start..].trim();
    if !rest.is_empty() {
        out.push(rest);
    }
    out
}

/// What a promise to come back says.
const PROMISES: &[&str] = &[
    "i'll check back",
    "i will check back",
    "i'll check again",
    "i will check again",
    "i'll check in",
    "i'll look again",
    "i'll keep an eye",
    "i will keep an eye",
    "i'll keep watching",
    "i'll watch it",
    "i'll watch the",
    "i'll follow up",
    "i will follow up",
    "i'll report back",
    "i will report back",
    "i'll let you know",
    "i will let you know",
    "i'll ping you",
    "i'll update you",
    "i'll get back to you",
    "will report back",
    "will follow up",
];

/// The first sentence of `text` that promises to come back later, or None.
pub fn promise(text: &str) -> Option<String> {
    sentences(text)
        .into_iter()
        .find(|s| {
            let s = plain(s);
            PROMISES.iter().any(|p| s.contains(p))
        })
        .map(quote)
}

/// How an offer that hands the decision back starts.
const OFFERS: &[&str] = &[
    "want me to",
    "do you want me to",
    "would you like me to",
    "would you like",
    "should i",
    "shall i",
    "do you want to",
    "let me know if you want",
    "let me know if you'd like",
    "let me know whether",
    "ok to",
    "okay to",
    "ready for me to",
    "which one should",
    "which do you want",
    "which would you like",
];

/// Words that make an ask the person's to answer: money, legal,
/// destructive or sign-in steps (CHIEF_TURNS "Decide, do not ask"), and
/// steps that reach other people or shared state (push, merge, deploy,
/// messages).
const NEEDS_PERSON: &[&str] = &[
    "push",
    "merge",
    "deploy",
    "ship",
    "send",
    "message",
    "reply to",
    "post",
    "share",
    "invite",
    "tweet",
    "dm",
    "notify",
    "ping",
    "pay",
    "buy",
    "purchase",
    "charge",
    "billing",
    "invoice",
    "subscri",
    "upgrade",
    "plan",
    "price",
    "$",
    "€",
    "£",
    "legal",
    "contract",
    "license",
    "licence",
    "terms",
    "delete",
    "remove",
    "erase",
    "wipe",
    "drop",
    "destroy",
    "force",
    "reset",
    "revert",
    "overwrite",
    "close the",
    "kill",
    "uninstall",
    "production",
    "prod",
    "release",
    "publish",
    "send the email",
    "send it to",
    "email",
    "post it",
    "sign in",
    "sign-in",
    "signin",
    "log in",
    "login",
    "password",
    "passkey",
    "2fa",
    "verification code",
    "token",
    "secret",
    "credential",
];

/// Whether question `q` (lowercase) names a step only the person may take:
/// a phrase or symbol anywhere, a word at a word's start ("plan" is not in
/// "explain").
fn needs_person(q: &str) -> bool {
    let words: Vec<&str> = q
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect();
    NEEDS_PERSON.iter().any(|w| {
        if w.chars().all(char::is_alphanumeric) {
            words.iter().any(|t| t.starts_with(w))
        } else {
            q.contains(w)
        }
    })
}

/// The offer `text` ends with: its last line when that line is a question
/// that hands a decision back to the person and nothing in it needs them.
/// None otherwise.
pub fn trailing_offer(text: &str) -> Option<String> {
    let last = text.lines().rev().map(str::trim).find(|l| !l.is_empty())?;
    // Markdown emphasis around the question is not part of it.
    let last = last.trim_matches(['*', '_', '`', ' ']);
    if !last.ends_with('?') {
        return None;
    }
    // The question itself: the last sentence of the line.
    let question = sentences(last).into_iter().last().unwrap_or(last);
    let q = plain(question);
    let q = q.trim_start_matches(|c: char| !c.is_alphanumeric());
    if !OFFERS.iter().any(|o| q.starts_with(o)) {
        return None;
    }
    if needs_person(q) {
        return None;
    }
    Some(quote(question))
}

/// `text` cut to `QUOTE_CHARS` characters, quotes made plain.
fn quote(text: &str) -> String {
    let text = text
        .replace('"', "'")
        .replace(['\u{2019}', '\u{2018}'], "'");
    if text.chars().count() <= QUOTE_CHARS {
        return text;
    }
    let cut: String = text.chars().take(QUOTE_CHARS).collect();
    format!("{cut}…")
}

/// The note of the host's wake after promise `said`.
pub fn promise_wake_note(said: &str) -> String {
    format!(
        "You told the user \"{said}\" {PROMISE_MARK}. Look at it now and tell the user where it stands in one line; sleep() again if it is still running."
    )
}

/// The words that mark the host's promise wake note.
const PROMISE_MARK: &str = "and set no wake, so the host set this one";

/// Whether a queued text is the host's own nudge (a `[decide]` note or a
/// promise wake): the turn it starts gets no nudge again.
pub fn is_nudge(text: &str) -> bool {
    // `contains`: a resumed turn's prompt puts its own words first.
    text.contains(DECIDE_TAG) || text.contains(PROMISE_MARK)
}

/// The host's note after a reply that ended with offer `asked`.
pub fn decide_note(asked: &str) -> String {
    format!(
        "{DECIDE_TAG} Your last reply ended by asking \"{asked}\". When a sensible default exists, do not ask: do it now and say what you did in one line (\"Default picked: ...\"). Only when it needs the user (money, legal, destructive or sign-in steps) leave the question, post nothing and call stop()."
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn learned_lines_are_the_learned_section_only() {
        let profile = "# The user\n\n- Never force push.\n\n## Learned\n\n- Reply in bullets. (learned 2026-10-26)\n- Default project is cmux-next. (learned 2026-10-26)\n\n## Other\n\n- x\n";
        assert_eq!(
            learned_lines(profile),
            vec![
                "Reply in bullets. (learned 2026-10-26)",
                "Default project is cmux-next. (learned 2026-10-26)"
            ]
        );
    }

    #[test]
    fn only_lines_the_start_text_lacks_are_new() {
        let start = "system\n## Learned\n\n- Reply in bullets. (learned 2026-10-26)\n";
        let now = format!("{start}- Default project is cmux-next. (learned 2026-10-27)\n");
        assert_eq!(
            learned_since(&now, start),
            vec!["Default project is cmux-next. (learned 2026-10-27)"]
        );
        assert_eq!(learned_since(start, start), Vec::<String>::new());
        assert!(learned_note(&[]).is_none());
        let note = learned_note(&learned_since(&now, start)).unwrap();
        assert!(note.ends_with("\n- Default project is cmux-next. (learned 2026-10-27)"));
    }

    #[test]
    fn a_promise_to_come_back_is_found() {
        assert_eq!(
            promise("a12 is on the fix. I’ll check back when CI is done.").as_deref(),
            Some("I'll check back when CI is done.")
        );
        assert!(promise("I'll let you know once it lands").is_some());
        assert!(promise("Done: [abc1234](https://x). Nothing open.").is_none());
        assert!(promise("You check back later.").is_none());
    }

    #[test]
    fn an_offer_at_the_end_is_found() {
        assert_eq!(
            trailing_offer("Found it: the drag handler reloads the group.\n\nWant me to fix it?")
                .as_deref(),
            Some("Want me to fix it?")
        );
        assert!(trailing_offer("Fixed. Should I also add a test?").is_some());
        assert!(trailing_offer("**Shall I start a12 on it?**").is_some());
        assert!(trailing_offer("Want me to update README.md?").is_some());
        assert!(trailing_offer("Should I bump it to v2.1?").is_some());
    }

    #[test]
    fn a_question_that_needs_the_person_is_no_offer() {
        assert!(trailing_offer("Want me to delete the old branches?").is_none());
        assert!(trailing_offer("Should I upgrade you to Pro ($50/month)?").is_none());
        assert!(trailing_offer("Should I sign in to Stripe for you?").is_none());
        assert!(trailing_offer("Should I force push it?").is_none());
        assert!(trailing_offer("Want me to explain the plan file?").is_none());
        assert!(trailing_offer("Should I merge it?").is_none());
        assert!(trailing_offer("Want me to message Austin about it?").is_none());
        assert!(trailing_offer("Want me to deploy it?").is_none());
        assert!(trailing_offer("Want me to explain it?").is_some());
    }

    #[test]
    fn a_reply_that_ends_with_the_result_is_no_offer() {
        assert!(trailing_offer("Want me to fix it? Done: a12 fixed it.").is_none());
        assert!(trailing_offer("Which file is it in?").is_none());
        assert!(trailing_offer("Started a12 on it.").is_none());
        assert!(trailing_offer("").is_none());
    }
}
