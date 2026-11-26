//! A terminal chat's usage-limit error says when the limit resets, as the GUI chat's does
//! (cmux#52296, `webviews/.../failureCopy.ts` `limitResetsAt`). Leo, 2026-11-24: "in terminals and
//! guis alike perhaps terminal simply needs to also have the fixes and enhancements".
//!
//! Claude Code's subscription refusal reads "Claude AI usage limit reached|1764000000" (epoch
//! seconds) and other harnesses name a JSON `resets_at` / `resetsAt`. The TUI drew that raw text
//! alone; the GUI reads "… reached a usage limit that resets Nov 27, 7:00 AM. Switch model to keep
//! going now, or continue once it resets." Here the error card leads with the same sentence and
//! keeps the raw text under it, dimmed.

use chrono::{DateTime, TimeZone};

/// The reset time (epoch seconds) a refusal names, or None. Only a time counts: "in 3h" names none.
pub(crate) fn resets_at(message: &str) -> Option<i64> {
    let seconds = epoch_after_limit(message).or_else(|| reset_field(message))?;
    (seconds > 0).then_some(seconds)
}

/// "limit reached|1764000000": ten digits that end a word, any case.
fn epoch_after_limit(message: &str) -> Option<i64> {
    let lower = message.to_ascii_lowercase();
    let at = lower.find("limit reached|")? + "limit reached|".len();
    ten_digits(message.get(at..)?)
}

/// `"resets_at": "2026-11-27T07:00:00Z"` or `"resetsAt": 1764000000` (also `reset_at`, `resetAt`).
fn reset_field(message: &str) -> Option<i64> {
    // The field names only mean a reset in a refusal about a limit.
    let lower = message.to_ascii_lowercase();
    if !["limit", "rate", "quota"].iter().any(|w| lower.contains(w)) {
        return None;
    }
    ["\"resets_at\"", "\"resetsAt\"", "\"reset_at\"", "\"resetAt\""].iter().find_map(|key| {
        let rest = message.split_once(key)?.1.trim_start();
        let rest = rest.strip_prefix(':')?.trim_start();
        match rest.strip_prefix('"') {
            Some(quoted) => {
                let (value, _) = quoted.split_once('"')?;
                DateTime::parse_from_rfc3339(value).ok().map(|t| t.timestamp())
            }
            None => ten_digits(rest),
        }
    })
}

fn ten_digits(s: &str) -> Option<i64> {
    let digits = s.bytes().take_while(u8::is_ascii_digit).count();
    if digits != 10 {
        return None;
    }
    s.get(..digits)?.parse().ok()
}

/// The card's lead sentence for `message` in `tz`, or None when it names no reset.
pub(crate) fn note_in<Tz: TimeZone>(message: &str, tz: &Tz) -> Option<String>
where
    Tz::Offset: std::fmt::Display,
{
    let at = tz.timestamp_opt(resets_at(message)?, 0).single()?;
    Some(format!(
        "Usage limit reached. It resets {}. Switch model to keep going now, or continue once it resets.",
        at.format("%b %-d, %-I:%M %p")
    ))
}

/// The lead sentence in the machine's own time zone.
pub(crate) fn note(message: &str) -> Option<String> {
    note_in(message, &chrono::Local)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    #[test]
    fn reads_claudes_epoch_and_json_fields() {
        // failureCopy.test.ts's cases.
        assert_eq!(resets_at("Claude AI usage limit reached|1764000000"), Some(1_764_000_000));
        assert_eq!(resets_at("claude ai usage LIMIT REACHED|1764000000."), Some(1_764_000_000));
        assert_eq!(
            resets_at(r#"429 rate limit {"resets_at": "2026-11-27T07:00:00Z"}"#),
            Some(1_795_762_800)
        );
        assert_eq!(resets_at(r#"quota exceeded {"resetsAt":1764000000}"#), Some(1_764_000_000));
    }

    #[test]
    fn names_no_reset_without_a_time() {
        assert_eq!(resets_at("Rate limited, try again in 3h"), None);
        assert_eq!(resets_at("usage limit reached|17640"), None);
        assert_eq!(resets_at("usage limit reached|17640000001"), None);
        // A reset field outside a limit refusal is not a limit's reset.
        assert_eq!(resets_at(r#"{"resetsAt":1764000000}"#), None);
        assert_eq!(resets_at(""), None);
        assert_eq!(resets_at("使用量 limit reached|176400000🕐"), None);
    }

    #[test]
    fn note_says_when_and_what_to_do() {
        assert_eq!(
            note_in("Claude AI usage limit reached|1764000000", &Utc).as_deref(),
            Some(
                "Usage limit reached. It resets Nov 24, 4:00 PM. Switch model to keep going now, or continue once it resets."
            )
        );
        assert_eq!(note_in("API Error: 500", &Utc), None);
    }
}
