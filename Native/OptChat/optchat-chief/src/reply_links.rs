//! The last pass over a Chief reply before it is posted: what the model still wrote bare
//! becomes a link (Lawrence, 2026-10-26: "reply with links to stuff properly"; the profile:
//! "never write a raw URL, id, sha or path"). `workspaces::link_subagents` links the subagent
//! ids first; this pass links
//! - a cmux object id (`ws_…`, `tab_…`, `pane_…`) as its `cmux://` deeplink, which Home, the
//!   Mac app and iOS open (DeepLink `.workspace`, `.tab`, `.pane`);
//! - an absolute or `~/` path that exists on this machine, bare or alone in a code span, as a
//!   `file://` link named by its last part (a `:LINE` after a file stays in the name);
//! - a GitHub pull request, issue, commit or Actions run URL as a link named `#123`,
//!   `abc1234` or `run 39221907733` (`repo#123` when the reply names more than one
//!   repository), and `OWNER/REPO#123` as `repo#123` linked to that repository (cmux#25572);
//! - a bare `#123` (three digits or more) or full 40-digit commit sha only when the reply
//!   names exactly one repository, in a URL or an `OWNER/REPO#N`: a number with no
//!   repository stays as written rather than link to the wrong one.
//!
//! A workspace id the caller can name (`link_refs_named`: a subagent's workspace) is named
//! by its title instead of "workspace". Code fences, code spans holding more than one path,
//! existing links (text and target) and other URLs are left as written. Ids, numbers and
//! paths inside a longer word are not ids, numbers or paths.

use std::path::{Path, PathBuf};

mod markdown;

/// The cmux object ids this pass links: (prefix, deeplink kind, link text).
const IDS: &[(&str, &str, &str)] = &[
    ("ws_", "workspace", "workspace"),
    ("tab_", "tab", "tab"),
    ("pane_", "pane", "pane"),
];

/// `text` with bare cmux ids, GitHub references and existing paths written as links. `home`
/// expands `~/`; `exists` says whether a path is there (the real file system in the host).
pub fn link_refs(text: &str, home: &Path, exists: &dyn Fn(&Path) -> bool) -> String {
    link_refs_named(text, home, exists, &|_| None)
}

/// [`link_refs`], with `name_of` naming a cmux id it knows (a subagent's workspace: its
/// title), which its link shows instead of the kind.
pub fn link_refs_named(
    text: &str,
    home: &Path,
    exists: &dyn Fn(&Path) -> bool,
    name_of: &dyn Fn(&str) -> Option<String>,
) -> String {
    let repos = repos_named(text);
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
                i += markdown::link_end(&text[i..]).unwrap_or(1);
            }
            _ if starts_word(b, i) => {
                if let Some((end, link)) =
                    id_at(text, i, name_of).or_else(|| github_at(text, i, &repos))
                {
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
/// not followed by another word character. Its link is named by `name_of`, else its kind.
fn id_at(
    text: &str,
    i: usize,
    name_of: &dyn Fn(&str) -> Option<String>,
) -> Option<(usize, String)> {
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
    let name = name_of(id)
        .map(|n| n.trim().to_owned())
        .filter(|n| !n.is_empty())
        .map_or_else(|| (*name).to_owned(), |n| escape_text(&n));
    Some((end, format!("[{name}](cmux://{kind}/{id})")))
}

const GITHUB: &str = "https://github.com/";

/// The repositories (`owner/repo`, lowercase) `text` names in a GitHub URL or an
/// `OWNER/REPO#N`, in order, each once.
fn repos_named(text: &str) -> Vec<String> {
    let b = text.as_bytes();
    let mut repos: Vec<String> = Vec::new();
    let mut note = |repo: String| {
        if !repos.contains(&repo) {
            repos.push(repo);
        }
    };
    for (at, _) in text.match_indices(GITHUB) {
        if let Some((repo, _)) = owner_repo(&text[at + GITHUB.len()..]) {
            note(repo.to_ascii_lowercase());
        }
    }
    for (at, _) in text.match_indices('#') {
        let start = text[..at]
            .char_indices()
            .rev()
            .find(|(_, c)| !(c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_' | '.')))
            .map_or(0, |(p, c)| p + c.len_utf8());
        if start < at
            && starts_word(b, start)
            && let Some((repo, len)) = owner_repo(&text[start..])
            && start + len == at
            && number_at(text, at + 1).is_some()
        {
            note(repo.to_ascii_lowercase());
        }
    }
    repos
}

/// `owner/repo` at the start of `s` and its length: GitHub's owner and repository name
/// characters.
fn owner_repo(s: &str) -> Option<(&str, usize)> {
    let owner = s
        .bytes()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == b'-')
        .count();
    if owner == 0 || s.as_bytes().get(owner) != Some(&b'/') {
        return None;
    }
    let name = s[owner + 1..]
        .bytes()
        .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
        .count();
    let len = owner + 1 + name;
    let repo = s[..len].trim_end_matches('.');
    (name > 0 && repo.len() > owner + 1).then_some((repo, repo.len()))
}

/// The digits of an issue number at `i` and their end: no leading zero, not followed by
/// another word character.
fn number_at(text: &str, i: usize) -> Option<(&str, usize)> {
    let digits = text[i..].bytes().take_while(u8::is_ascii_digit).count();
    let end = i + digits;
    let next = text.as_bytes().get(end);
    (digits > 0
        && digits <= 9
        && !text[i..].starts_with('0')
        && !next.is_some_and(|c| c.is_ascii_alphanumeric() || *c == b'_'))
    .then(|| (&text[i..end], end))
}

/// A GitHub reference at `i` written bare, and its link (see the module docs). `repos`: the
/// repositories the whole reply names.
fn github_at(text: &str, i: usize, repos: &[String]) -> Option<(usize, String)> {
    let rest = &text[i..];
    let only = (repos.len() == 1).then(|| repos[0].as_str());
    let short = |repo: &str, number: &str| {
        if repos.len() > 1 {
            let name = repo.rsplit('/').next().unwrap_or(repo);
            format!("{name}#{number}")
        } else {
            format!("#{number}")
        }
    };
    if rest.starts_with(GITHUB) {
        let len = rest
            .bytes()
            .take_while(|c| {
                !c.is_ascii_whitespace()
                    && !matches!(
                        c,
                        b')' | b']' | b'<' | b'>' | b'"' | b'\'' | b'`' | b'|' | b'*'
                    )
            })
            .count();
        let url = rest[..len].trim_end_matches(['.', ',', ':', ';', '!', '?']);
        let (repo, repo_len) = owner_repo(&url[GITHUB.len()..])?;
        let parts: Vec<&str> = url[GITHUB.len() + repo_len..]
            .split(['/', '#', '?'])
            .filter(|p| !p.is_empty())
            .collect();
        let name = match parts.as_slice() {
            ["pull" | "issues", n, ..] if number_at(n, 0).is_some_and(|(d, _)| d == *n) => {
                short(&repo.to_ascii_lowercase(), n)
            }
            ["commit", sha, ..] if sha.len() >= 7 && sha.bytes().all(|c| c.is_ascii_hexdigit()) => {
                sha[..7].to_owned()
            }
            ["actions", "runs", n, ..] if n.bytes().all(|c| c.is_ascii_digit()) => {
                format!("run {n}")
            }
            _ => return None,
        };
        return Some((i + url.len(), format!("[{name}]({url})")));
    }
    if rest.starts_with('#') {
        let repo = only?;
        let (number, end) = number_at(text, i + 1)?;
        if number.len() < 3 {
            return None;
        }
        let url = format!("{GITHUB}{repo}/issues/{number}");
        return Some((end, format!("[#{number}]({url})")));
    }
    if let Some((repo, len)) = owner_repo(rest)
        && rest.as_bytes().get(len) == Some(&b'#')
        && let Some((number, end)) = number_at(text, i + len + 1)
    {
        let name = repo.rsplit('/').next().unwrap_or(repo);
        let url = format!("{GITHUB}{repo}/issues/{number}");
        return Some((end, format!("[{name}#{number}]({url})")));
    }
    // A full commit sha, with the one repository the reply names.
    let repo = only?;
    let hex = rest
        .bytes()
        .take_while(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(c))
        .count();
    let next = text.as_bytes().get(i + hex);
    if hex != 40 || next.is_some_and(|c| c.is_ascii_alphanumeric() || *c == b'_') {
        return None;
    }
    let sha = &rest[..40];
    Some((
        i + 40,
        format!("[{}]({GITHUB}{repo}/commit/{sha})", &sha[..7]),
    ))
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

/// Link text with the Markdown marks that would end it escaped. A backslash is escaped too, so
/// a title ending in `\` cannot escape the closing `]`, and a line break becomes a space, so a
/// title on two lines stays one link.
fn escape_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if matches!(c, '\n' | '\r') {
            out.push(' ');
            continue;
        }
        if matches!(c, '[' | ']' | '`' | '\\') {
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
