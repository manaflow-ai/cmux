use super::spaced;

#[test]
fn every_cmux_link_kind_gets_a_space() {
    // deeplinks.test.ts's kinds.
    for link in [
        "cmux://workspace/ws_1",
        "cmux://pane/p1",
        "cmux://tab/t1",
        "cmux://session/s1",
        "cmux://agent/claude/abc",
        "cmux-nightly://agent/codex/abc",
        "cmux-dev-2://group/g1",
        "https://cmux.com/deeplink/agent?id=aid-1",
        "https://www.cmux.com/pt-BR/deeplink/agent?id=aid-1",
    ] {
        assert_eq!(spaced(link, None), format!("{link} "), "{link}");
        assert_eq!(spaced(&format!("see {link}"), None), format!("see {link} "), "{link}");
    }
}

#[test]
fn no_space_where_none_belongs() {
    // Already a space after the caret, or the paste ends in one.
    assert_eq!(spaced("cmux://pane/p1", Some(' ')), "cmux://pane/p1");
    assert_eq!(spaced("cmux://pane/p1\n", None), "cmux://pane/p1\n");
    // Not a cmux link, a link mid-paste, trailing punctuation, a bare scheme.
    assert_eq!(spaced("https://example.com/x", None), "https://example.com/x");
    assert_eq!(spaced("cmux://pane/p1 and more", None), "cmux://pane/p1 and more");
    assert_eq!(spaced("open cmux://pane/p1.", None), "open cmux://pane/p1.");
    assert_eq!(spaced("cmux://", None), "cmux://");
    assert_eq!(spaced("https://cmux.com/docs", None), "https://cmux.com/docs");
    // Part of a path or another URL.
    assert_eq!(spaced("/tmp/cmux://x", None), "/tmp/cmux://x");
    assert_eq!(
        spaced("https://e.com/?next=cmux://session/s1", None),
        "https://e.com/?next=cmux://session/s1"
    );
    // A link pasted before a word joins nothing: the next character is not a space, so the
    // space keeps it apart.
    assert_eq!(spaced("cmux://pane/p1", Some('x')), "cmux://pane/p1 ");
}
