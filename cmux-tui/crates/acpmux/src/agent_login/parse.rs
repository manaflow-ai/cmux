//! Reading a sign-in's offer from an agent CLI's terminal output: the https
//! link to open (only on a host of [`ALLOWED_HOSTS`]) and, for Codex's device
//! flow, the one-time code. Escape sequences are dropped first; an OSC-8
//! hyperlink's target counts as a link too (Claude Code wraps its link in one
//! under a terminal). A link or code counts only once it is complete: followed
//! by whitespace, or the target of a finished OSC-8 sequence.

use super::Agent;

/// The hosts a sign-in link may point at. Anything else is never shown.
pub const ALLOWED_HOSTS: &[&str] = &[
    "claude.com",
    "claude.ai",
    "platform.claude.com",
    "console.anthropic.com",
    "auth.anthropic.com",
    "auth.openai.com",
];

/// The longest link accepted.
const MAX_URL: usize = 4096;

/// What a started sign-in asks the person to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Offer {
    pub url: String,
    /// The device flow's one-time code (Codex).
    pub user_code: Option<String>,
}

/// `text` without terminal escape sequences, and every OSC-8 hyperlink target
/// in it. CSI (`ESC [ ... final`), OSC (`ESC ] ... BEL` or `ESC ] ... ESC \`)
/// and two-byte escapes are dropped; an OSC still open at the end is dropped
/// with what follows it, as it is not complete yet.
pub fn strip_terminal(text: &str) -> (String, Vec<String>) {
    let mut plain = String::with_capacity(text.len());
    let mut links = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{9b}' {
            // An 8-bit CSI.
            skip_csi(&mut chars);
            continue;
        }
        if c != '\u{1b}' {
            if c == '\r' {
                continue;
            }
            plain.push(c);
            continue;
        }
        match chars.next() {
            Some('[') => skip_csi(&mut chars),
            Some(']') => {
                let mut body = String::new();
                let mut closed = false;
                while let Some(o) = chars.next() {
                    if o == '\u{7}' {
                        closed = true;
                        break;
                    }
                    if o == '\u{1b}' {
                        if chars.peek() == Some(&'\\') {
                            chars.next();
                        }
                        closed = true;
                        break;
                    }
                    body.push(o);
                }
                // `8;params;URI`: a hyperlink's start (an empty URI ends it).
                if closed
                    && let Some(rest) = body.strip_prefix("8;")
                    && let Some((_, uri)) = rest.split_once(';')
                    && !uri.is_empty()
                {
                    links.push(uri.to_owned());
                }
            }
            Some(_) | None => {}
        }
    }
    (plain, links)
}

fn skip_csi(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) {
    for c in chars.by_ref() {
        if ('\u{40}'..='\u{7e}').contains(&c) {
            break;
        }
    }
}

/// `candidate` when it is an https link to an allowed host: no user part, no
/// port, no whitespace, control or non-ASCII character, at most [`MAX_URL`].
pub fn allowed_url(candidate: &str) -> Option<String> {
    if candidate.len() > MAX_URL || !candidate.chars().all(|c| c.is_ascii_graphic()) {
        return None;
    }
    let rest = candidate.strip_prefix("https://")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    if authority.is_empty() || authority.contains(['@', ':', '\\']) {
        return None;
    }
    let host = authority.to_ascii_lowercase();
    ALLOWED_HOSTS.contains(&host.as_str()).then(|| candidate.to_owned())
}

/// The first complete allowed link: an OSC-8 target, else a word of `plain`
/// that is followed by whitespace.
pub fn first_url(plain: &str, links: &[String]) -> Option<String> {
    if let Some(url) = links.iter().find_map(|l| allowed_url(l)) {
        return Some(url);
    }
    complete_words(plain).find_map(|w| w.starts_with("https://").then(|| allowed_url(w)).flatten())
}

/// The words of `text` followed by whitespace (the last one may still be
/// arriving).
fn complete_words(text: &str) -> impl Iterator<Item = &str> {
    let ends_open = !text.ends_with(char::is_whitespace);
    let words: Vec<&str> = text.split_whitespace().collect();
    let keep = words.len().saturating_sub(usize::from(ends_open));
    words.into_iter().take(keep)
}

/// Codex's one-time code: the first non-empty line after the line naming the
/// "one-time code", once that line is complete: 4 to 32 of `A-Z`, `0-9` and
/// `-`, with at least one letter or digit.
pub fn device_code(plain: &str) -> Option<String> {
    let complete = match plain.rfind('\n') {
        Some(end) => plain.get(..end).unwrap_or_default(),
        None => return None,
    };
    let mut lines =
        complete.lines().skip_while(|l| !l.to_ascii_lowercase().contains("one-time code"));
    lines.next()?;
    let code = lines.map(str::trim).find(|l| !l.is_empty())?;
    let ok = (4..=32).contains(&code.len())
        && code.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '-')
        && code.chars().any(|c| c.is_ascii_alphanumeric());
    ok.then(|| code.to_owned())
}

/// What `agent`'s sign-in output offers so far, once it is complete: Claude's
/// link; Codex's link and code.
pub fn offer(agent: Agent, output: &str) -> Option<Offer> {
    let (plain, links) = strip_terminal(output);
    let url = first_url(&plain, &links)?;
    match agent {
        Agent::Claude => Some(Offer { url, user_code: None }),
        Agent::Codex => Some(Offer { url, user_code: Some(device_code(&plain)?) }),
    }
}

/// The page Claude Code asks `$BROWSER` to open (`agent_login`'s shim saved it, one argument per
/// line): its automatic sign-in link, whose approve sends the code straight back to the CLI's own
/// listener on this machine. Only an allowed link (``allowed_url``) whose `redirect_uri` is
/// exactly `http://localhost:<port>/callback` counts; the link and that port.
pub fn auto_url(saved: &str) -> Option<(String, u16)> {
    saved.lines().map(str::trim).find_map(|line| {
        let url = allowed_url(line)?;
        let port = callback_port(&url)?;
        Some((url, port))
    })
}

/// The port of `url`'s one `redirect_uri` when it is `http://localhost:<port>/callback`.
fn callback_port(url: &str) -> Option<u16> {
    let query = url.split_once('?')?.1.split('#').next().unwrap_or_default();
    let mut found = query.split('&').filter_map(|pair| pair.strip_prefix("redirect_uri="));
    let raw = found.next()?;
    if found.next().is_some() {
        return None;
    }
    let redirect = percent_decode(raw)?;
    let digits = redirect.strip_prefix("http://localhost:")?.strip_suffix("/callback")?;
    let port: u16 = digits.parse().ok().filter(|p| *p > 0)?;
    // No leading zeros, no sign: the port as it is written.
    (port.to_string() == digits).then_some(port)
}

/// `%XX` decoded; nil for a broken escape or a result that is not UTF-8.
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while let Some(&b) = bytes.get(i) {
        if b == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            if !hex.bytes().all(|c| c.is_ascii_hexdigit()) {
                return None;
            }
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(b);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}
