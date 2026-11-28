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
