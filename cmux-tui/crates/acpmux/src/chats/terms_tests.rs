use super::*;

const NOW: i64 = 1_800_000_000_000;
const DAY: i64 = 86_400_000;

#[test]
fn plain_words_stay_words() {
    let terms = Terms::parse("Fix the  SIDEBAR fix", NOW);
    assert_eq!(terms.words, ["fix", "the", "sidebar"]);
    assert!(!terms.has_operators());
    assert_eq!(terms.rest(), "fix the sidebar");
}

#[test]
fn spans_count_back_from_now() {
    assert_eq!(Terms::parse("since:7d", NOW).since_ms, Some(NOW - 7 * DAY));
    assert_eq!(Terms::parse("after:2w", NOW).since_ms, Some(NOW - 14 * DAY));
    assert_eq!(Terms::parse("since:3h", NOW).since_ms, Some(NOW - 3 * 3_600_000));
    assert_eq!(Terms::parse("since:30m", NOW).since_ms, Some(NOW - 30 * 60_000));
    assert_eq!(Terms::parse("before:1mo", NOW).before_ms, Some(NOW - 30 * DAY));
    assert_eq!(Terms::parse("until:1y", NOW).before_ms, Some(NOW - 365 * DAY));
}

#[test]
fn dates_and_days_start_at_local_midnight() {
    let midnight = |date: NaiveDate| {
        Local
            .from_local_datetime(&date.and_hms_opt(0, 0, 0).expect("time"))
            .earliest()
            .expect("local")
            .timestamp_millis()
    };
    let date = NaiveDate::from_ymd_opt(2026, 11, 1).expect("date");
    assert_eq!(Terms::parse("since:2026-11-01", NOW).since_ms, Some(midnight(date)));
    let today = Local.timestamp_millis_opt(NOW).single().expect("now").date_naive();
    assert_eq!(Terms::parse("since:today", NOW).since_ms, Some(midnight(today)));
    let yesterday = today.pred_opt().expect("yesterday");
    assert_eq!(Terms::parse("before:yesterday", NOW).before_ms, Some(midnight(yesterday)));
}

#[test]
fn harness_by_id_or_its_start() {
    assert_eq!(Terms::parse("harness:codex", NOW).harness, Some(AdapterKind::Codex));
    assert_eq!(Terms::parse("agent:Claude", NOW).harness, Some(AdapterKind::ClaudeCode));
    // `kimi` starts two ids: a plain word, not a guess.
    let ambiguous = Terms::parse("harness:kimi", NOW);
    assert_eq!((ambiguous.harness, ambiguous.words), (None, vec!["harness:kimi".to_owned()]));
}

#[test]
fn folder_title_exclude_and_phrases() {
    let terms = Terms::parse(r#"in:cmux/ title:"new tab" -draft "two words" sidebar"#, NOW);
    assert_eq!(terms.folder, ["cmux"]);
    assert_eq!(terms.title, ["new tab"]);
    assert_eq!(terms.exclude, ["draft"]);
    assert_eq!(terms.words, ["two words", "sidebar"]);
    assert_eq!(terms.rest(), "\"two words\" sidebar");
    assert_eq!(Terms::parse("path:web folder:src", NOW).folder, ["web", "src"]);
}

#[test]
fn what_is_not_an_operator_is_a_word() {
    let terms = Terms::parse(r#"since:soon http://x.dev - --flag "-quoted" "in:x" nope:x"#, NOW);
    assert_eq!(terms.since_ms, None);
    assert!(terms.exclude.is_empty() && terms.folder.is_empty());
    assert_eq!(
        terms.words,
        ["since:soon", "http://x.dev", "-", "--flag", "-quoted", "in:x", "nope:x"]
    );
}

#[test]
fn operators_alone_leave_no_words() {
    let terms = Terms::parse("since:1d harness:codex", NOW);
    assert!(terms.words.is_empty() && terms.has_operators());
    assert_eq!(terms.rest(), "");
}

#[test]
fn a_huge_span_is_a_word_not_an_overflow() {
    let terms = Terms::parse("since:99999999999999y", NOW);
    assert_eq!((terms.since_ms, terms.words.len()), (None, 1));
}
