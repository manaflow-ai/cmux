use super::Reply;
#[test]
fn takeaway_matches_trimmed_text_across_streamed_whitespace() {
    for (text, expected) in [
        (format!("{}checking it{}", " ".repeat(200), " ".repeat(200)), false),
        ("Checking it\n\n".into(), false),
        ("Checking it\n \nanswer".into(), true),
        (format!("{}- item", " ".repeat(100)), true),
        ("-\titem".into(), true),
        ("1.\titem".into(), true),
        // Not a list, but not narration either: a brief answer.
        ("1. ".into(), true),
        ("note".into(), true),
        ("checking one\nchecking two\nchecking three".into(), false),
        ("checking one\nchecking two\nchecking three\nfour".into(), true),
        ("Let me check the cache.".into(), false),
        ("Let me check. The cache is stale.".into(), true),
        (format!("Reading {}", "x".repeat(152)), false),
        (format!("Reading {}", "x".repeat(153)), true),
    ] {
        let mut reply = Reply::default();
        for ch in text.chars() {
            reply.push(ch);
        }
        assert_eq!(reply.takeaway(), expected, "{text:?}");
    }
}
