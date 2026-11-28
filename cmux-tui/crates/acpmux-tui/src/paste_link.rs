//! A paste into a terminal chat's prompt that ends in a cmux link gets a trailing space, as the
//! GUI composer's paste does (cmux#42098, #49121, `composer/deeplinks.ts` `spacedAfterDeeplink`).
//! Leo, 2026-11-12: "pasting these types of links that get visually formatted should be
//! automatically adding a space after when pasting". A key typed right after the paste would
//! otherwise join the link, and the agent reads a different URL.

/// The characters a link ends at (the GUI's `RUN_END`, less its attachment marker).
fn ends_link(c: char) -> bool {
    c.is_whitespace() || matches!(c, '<' | '>' | '(' | ')' | '"' | '\'' | '`' | '[' | ']')
}

/// Whether `segment` is a locale path segment: `en` or `pt-BR`.
fn is_locale(segment: &str) -> bool {
    match segment.as_bytes() {
        [a, b] => a.is_ascii_lowercase() && b.is_ascii_lowercase(),
        [a, b, b'-', c, d] => {
            a.is_ascii_lowercase()
                && b.is_ascii_lowercase()
                && c.is_ascii_uppercase()
                && d.is_ascii_uppercase()
        }
        _ => false,
    }
}

/// Whether `run` (no link-ending characters in it) is a whole cmux deeplink: a cmux app link in any
/// build's scheme (`cmux://`, `cmux-nightly://`) or a web deeplink (`https://cmux.com/deeplink/…`,
/// a locale before `/deeplink` allowed), with something after the prefix.
fn is_cmux_link(run: &str) -> bool {
    let rest = if let Some((scheme, rest)) = run.split_once("://")
        && let Some(build) = scheme.strip_prefix("cmux")
        && (build.is_empty()
            || build.strip_prefix('-').is_some_and(|b| {
                !b.is_empty()
                    && b.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
            })) {
        rest
    } else if let Some(path) =
        run.strip_prefix("https://cmux.com/").or_else(|| run.strip_prefix("https://www.cmux.com/"))
    {
        // An optional locale segment: `en/` or `pt-BR/`.
        let path = match path.split_once('/') {
            Some((locale, after)) if locale != "deeplink" && is_locale(locale) => after,
            _ => path,
        };
        match path.strip_prefix("deeplink/") {
            Some(rest) => rest,
            None => return false,
        }
    } else {
        return false;
    };
    !rest.is_empty()
}

/// `pasted` with a space after it when it ends in a cmux link and `next` (the prompt's character
/// after the caret) is not already a space. Trailing sentence punctuation already ends a link, so it
/// gets none; a link begun before the paste (a paste into a link's middle) is never split.
pub(crate) fn spaced(pasted: &str, next: Option<char>) -> String {
    if pasted.ends_with(char::is_whitespace) || next.is_some_and(char::is_whitespace) {
        return pasted.to_owned();
    }
    // The run after the last link-ending character (`rsplit` always yields one).
    let run = pasted.rsplit(ends_link).next().unwrap_or(pasted);
    let punctuated = run.ends_with(['.', ',', ';', ':', '!', '?', '*', '_']);
    if !punctuated && is_cmux_link(run) { format!("{pasted} ") } else { pasted.to_owned() }
}

#[cfg(test)]
mod tests {
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
}
