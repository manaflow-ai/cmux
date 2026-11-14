use super::Reply;
#[test]
fn takeaway_matches_trimmed_text_across_streamed_whitespace() {
    for (text, expected) in [
        (format!("{}note{}", " ".repeat(200), " ".repeat(200)), false),
        ("note\n\n".into(), false),
        ("note\n \nanswer".into(), true),
        (format!("{}- item", " ".repeat(100)), true),
        ("-\titem".into(), true),
        ("1.\titem".into(), true),
        ("1. ".into(), false),
        ("one\ntwo\nthree".into(), false),
        ("one\ntwo\nthree\nfour".into(), true),
    ] {
        let mut reply = Reply::default();
        for ch in text.chars() {
            reply.push(ch);
        }
        assert_eq!(reply.takeaway(), expected, "{text:?}");
    }
}
