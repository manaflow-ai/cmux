//! The last pass over a Chief reply before it is posted: what the model still wrote bare
//! becomes a link (Lawrence, 2026-10-26: "reply with links to stuff properly"; the profile:
//! "never write a raw URL, id, sha or path"). `workspaces::link_subagents` links the subagent
//! ids first; this pass links
//! - a cmux object id (`ws_…`, `tab_…`, `pane_…`) as its `cmux://` deeplink, which Home, the
//!   Mac app and iOS open (DeepLink `.workspace`, `.tab`, `.pane`);
//! - an absolute or `~/` path that exists on this machine, bare or alone in a code span, as a
//!   `file://` link named by its last part (a `:LINE` after a file stays in the name).
//!
//! Code fences, code spans holding more than one path, existing links (text and target) and
//! URLs are left as written. Ids and paths inside a longer word are not ids or paths.

use std::path::{Path, PathBuf};

/// The cmux object ids this pass links: (prefix, deeplink kind, link text).
const IDS: &[(&str, &str, &str)] = &[
    ("ws_", "workspace", "workspace"),
    ("tab_", "tab", "tab"),
    ("pane_", "pane", "pane"),
];

/// `text` with bare cmux ids and existing paths written as links. `home` expands `~/`;
/// `exists` says whether a path is there (the real file system in the host).
pub fn link_refs(text: &str, home: &Path, exists: &dyn Fn(&Path) -> bool) -> String {
    let b = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let (mut i, mut copied) = (0, 0);
    let mut fence = false;
    while i < b.len() {
        let line_start = i == 0 || b[i - 1] == b'\n';
        if line_start && text[i..].starts_with("```") {
            fence = !fence;
            i += 3;
            continue;
        }
        if fence {
            i += 1;
            continue;
        }
        match b[i] {
            b'`' => {
                let end = text[i + 1..].find(['`', '\n']).map(|e| i + 1 + e);
                match end {
                    Some(end) if b[end] == b'`' => {
                        // A code span that is one path that exists: its link instead.
                        let inner = &text[i + 1..end];
                        if let Some(link) = path_link(inner, home, exists)
                            .filter(|_| {
                                !inner.contains(char::is_whitespace) || inner.starts_with('/')
                            })
                            .filter(|_| inner.trim() == inner)
                        {
                            out.push_str(&text[copied..i]);
                            out.push_str(&link);
                            copied = end + 1;
                        }
                        i = end + 1;
                    }
                    _ => i += 1,
                }
            }
            b'[' => {
                // An existing link `[..](..)`: skipped whole.
                let close = text[i + 1..].find([']', '\n']).map(|e| i + 1 + e);
                match close {
                    Some(c) if b[c] == b']' && b.get(c + 1) == Some(&b'(') => {
                        i = text[c..].find(')').map_or(c + 1, |e| c + e + 1);
                    }
                    _ => i += 1,
                }
            }
            _ if starts_word(b, i) => {
                if let Some((end, link)) = id_at(text, i) {
                    out.push_str(&text[copied..i]);
                    out.push_str(&link);
                    copied = end;
                    i = end;
                } else if let Some((end, link)) = bare_path_at(text, i, home, exists) {
                    out.push_str(&text[copied..i]);
                    out.push_str(&link);
                    copied = end;
                    i = end;
                } else if b[i].is_ascii_alphanumeric() {
                    // Past the whole word, so a URL's path is never taken for one.
                    i += word_len(b, i).max(1);
                } else {
                    // A mark (`**`, `(`, `_`): the word may start after it.
                    i += 1;
                }
            }
            _ => i += 1,
        }
    }
    out.push_str(&text[copied..]);
    out
}

/// Whether a word may start at `i`: the text's start, or after a space or opening mark.
fn starts_word(b: &[u8], i: usize) -> bool {
    i == 0
        || matches!(
            b[i - 1],
            b' ' | b'\t' | b'\n' | b'(' | b'*' | b'_' | b'"' | b'\'' | b'|' | b'>'
        )
}

/// The bytes of the word at `i` (to the next space, or a mark that ends a word).
fn word_len(b: &[u8], i: usize) -> usize {
    b[i..]
        .iter()
        .take_while(|c| !matches!(c, b' ' | b'\t' | b'\n' | b'`' | b'[' | b'('))
        .count()
}

/// A cmux id at `i` and the end of it: `ws_` and 32 lowercase hex digits (cmux's public ids),
/// not followed by another word character.
fn id_at(text: &str, i: usize) -> Option<(usize, String)> {
    let rest = &text[i..];
    let (prefix, kind, name) = IDS.iter().find(|(p, _, _)| rest.starts_with(p))?;
    let body = rest[prefix.len()..]
        .bytes()
        .take_while(u8::is_ascii_alphanumeric)
        .count();
    let end = i + prefix.len() + body;
    let next = text.as_bytes().get(end);
    let id = &text[i..end];
    let hex = id[prefix.len()..]
        .bytes()
        .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c));
    if body != 32 || !hex || next.is_some_and(|c| *c == b'_' || *c == b'/' || *c == b'-') {
        return None;
    }
    Some((end, format!("[{name}](cmux://{kind}/{id})")))
}

/// A bare path at `i` (`/a/b…` or `~/…`) that exists, and where it ends; trailing sentence
/// marks are not part of it.
fn bare_path_at(
    text: &str,
    i: usize,
    home: &Path,
    exists: &dyn Fn(&Path) -> bool,
) -> Option<(usize, String)> {
    let rest = &text[i..];
    if !(rest.starts_with('/') || rest.starts_with("~/")) {
        return None;
    }
    let len = rest
        .bytes()
        .take_while(|c| {
            !matches!(
                c,
                b' ' | b'\t'
                    | b'\n'
                    | b'`'
                    | b')'
                    | b']'
                    | b'>'
                    | b'"'
                    | b'\''
                    | b','
                    | b';'
                    | b'|'
                    | b'*'
            )
        })
        .count();
    let mut word = &rest[..len];
    while let Some(w) = word.strip_suffix(['.', ':', '!', '?']) {
        word = w;
    }
    let link = path_link(word, home, exists)?;
    Some((i + word.len(), link))
}

/// The `file://` link of `word` (a path, maybe with `:LINE[:COL]`) when it exists.
fn path_link(word: &str, home: &Path, exists: &dyn Fn(&Path) -> bool) -> Option<String> {
    let full = |p: &str| -> Option<PathBuf> {
        if let Some(rel) = p.strip_prefix("~/") {
            Some(home.join(rel))
        } else if p.starts_with('/') && p[1..].contains('/') {
            Some(PathBuf::from(p))
        } else {
            None
        }
    };
    let mut path = word;
    let mut found = full(path).filter(|p| exists(p));
    // `file.rs:42` or `file.rs:42:7`: the file, the line stays in the name.
    for _ in 0..2 {
        if found.is_some() {
            break;
        }
        let (head, tail) = path.rsplit_once(':')?;
        if tail.is_empty() || !tail.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        path = head;
        found = full(path).filter(|p| exists(p));
    }
    let abs = found?;
    let abs = abs.to_str()?.trim_end_matches('/').to_owned();
    let last = path
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .filter(|s| !s.is_empty())?;
    let name = format!("{last}{}", &word[path.len()..]);
    Some(format!(
        "[{}](file://{})",
        escape_text(&name),
        escape_url(&abs)
    ))
}

/// Link text with the Markdown marks that would end it escaped.
fn escape_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if matches!(c, '[' | ']' | '`') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// A path as a URL path: bytes outside the unreserved set and `/` are percent-encoded.
fn escape_url(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'/' | b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}
