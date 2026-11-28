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
#[path = "paste_link_tests.rs"]
mod tests;
