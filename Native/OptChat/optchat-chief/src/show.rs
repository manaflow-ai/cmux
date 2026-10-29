//! What a finished subagent's work leaves to show (Lawrence 2026-10-20: "as a
//! default behavior for the Chief, when submissions are done, think about what
//! else would be useful to show in the workspace ... a column to the right to
//! show a browser preview or a diff"). The host reads a report for the commit
//! ranges it landed, the pages it names and the preview files it made, and adds
//! a `<show>` block with the command that opens each one in the column right of
//! the Chief's chat. The Chief picks what is worth showing (the system prompt's
//! "After work" rule); the host only finds the candidates, with no I/O.
//! `show.afterReport` (default on) turns the block off.

/// The most items of one kind a block lists: a report that names more is a
/// list, and the Chief opens one or two anyway.
const MAX_EACH: usize = 3;

/// File kinds worth a preview tab: pages, pictures, videos, documents.
const PREVIEW_EXTENSIONS: &[&str] = &[
    "html", "htm", "png", "jpg", "jpeg", "gif", "webp", "svg", "mp4", "mov", "pdf", "md",
];

/// The candidates found in one report.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Shown {
    /// Landed commit ranges, `(old, new)`, as the report spells them.
    pub ranges: Vec<(String, String)>,
    /// `owner/name` of the GitHub repository the report links to, if any.
    pub repo: Option<String>,
    /// Pages to preview: http(s) URLs other than commit links.
    pub pages: Vec<String>,
    /// Absolute paths of preview files (decoded from `file://` links).
    pub files: Vec<String>,
}

impl Shown {
    pub fn is_empty(&self) -> bool {
        self.ranges.is_empty() && self.pages.is_empty() && self.files.is_empty()
    }
}

/// The candidates in `report`.
pub fn find(report: &str) -> Shown {
    let mut shown = Shown::default();
    for token in report.split(is_break) {
        let token = token.trim_end_matches(['.', ',', ';', ':', '!', '?']);
        if token.is_empty() {
            continue;
        }
        if let Some(range) = sha_range(token) {
            push(&mut shown.ranges, range);
        } else if let Some(path) = token.strip_prefix("file://") {
            let path = percent_decode(path);
            if path.starts_with('/') && is_preview(&path) {
                push(&mut shown.files, path);
            }
        } else if token.starts_with("https://") || token.starts_with("http://") {
            if let Some(repo) = github_repo(token) {
                shown.repo.get_or_insert(repo.clone());
                if let Some(range) = compare_range(token) {
                    push(&mut shown.ranges, range);
                }
                // A commit, a pull request or a run: the diff line covers it.
                if is_github_commit_like(token) {
                    continue;
                }
            }
            push(&mut shown.pages, token.to_owned());
        } else if token.starts_with('/') && is_preview(token) && !token.contains("://") {
            push(&mut shown.files, token.to_owned());
        }
    }
    shown
}

/// The `<show>` block for `report`, or None when it names nothing to show.
pub fn block(report: &str) -> Option<String> {
    let shown = find(report);
    if shown.is_empty() {
        return None;
    }
    let mut lines = vec![
        "<show>".to_owned(),
        "Done work to show (show.afterReport): open the one or two most useful in the column right of your chat, never the dock, without moving focus; show nothing if none helps."
            .to_owned(),
    ];
    for (old, new) in &shown.ranges {
        match &shown.repo {
            Some(repo) => lines.push(format!(
                "- diff {old}..{new}: cmux browser right navigate https://github.com/{repo}/compare/{old}...{new} --agent \"<your name>\""
            )),
            None => lines.push(format!(
                "- diff {old}..{new}: cmux tab create terminal --pane <pane_…> with `git log -p {old}..{new}` in the repo"
            )),
        }
    }
    for page in &shown.pages {
        lines.push(format!(
            "- page {page}: cmux browser right navigate {page} --agent \"<your name>\""
        ));
    }
    for file in &shown.files {
        lines.push(format!(
            "- file {file}: cmux action run file.open --target <pane_…> --path {} --where tab",
            shell_quote(file)
        ));
    }
    lines.push("</show>".to_owned());
    Some(lines.join("\n"))
}

fn is_break(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            '(' | ')' | '[' | ']' | '<' | '>' | '`' | '"' | '\'' | '{' | '}' | '|'
        )
}

fn push<T: PartialEq>(list: &mut Vec<T>, item: T) {
    if list.len() < MAX_EACH && !list.contains(&item) {
        list.push(item);
    }
}

fn is_sha(text: &str) -> bool {
    (7..=40).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_hexdigit())
        // A sha has a letter or is long; `1234567` alone is more likely a number.
        && text.bytes().any(|b| b.is_ascii_alphabetic())
}

/// `OLD..NEW` or `OLD...NEW`, two shas.
fn sha_range(token: &str) -> Option<(String, String)> {
    let (old, new) = token.split_once("..")?;
    let new = new.strip_prefix('.').unwrap_or(new);
    (is_sha(old) && is_sha(new)).then(|| (old.to_owned(), new.to_owned()))
}

/// `owner/name` of a github.com URL.
fn github_repo(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1.strip_prefix("github.com/")?;
    let mut parts = rest.split('/');
    let (owner, name) = (parts.next()?, parts.next()?);
    (!owner.is_empty() && !name.is_empty()).then(|| format!("{owner}/{name}"))
}

fn github_kind(url: &str) -> Option<&str> {
    url.split_once("://")?
        .1
        .strip_prefix("github.com/")?
        .split('/')
        .nth(2)
}

fn is_github_commit_like(url: &str) -> bool {
    matches!(github_kind(url), Some("commit" | "compare" | "commits"))
}

/// The range of a GitHub compare URL.
fn compare_range(url: &str) -> Option<(String, String)> {
    if github_kind(url) != Some("compare") {
        return None;
    }
    sha_range(url.rsplit('/').next()?)
}

fn is_preview(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.rsplit_once('.')
        .is_some_and(|(_, ext)| PREVIEW_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()))
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && bytes[i + 1].is_ascii_hexdigit()
            && bytes[i + 2].is_ascii_hexdigit()
            && let Ok(b) = u8::from_str_radix(&text[i + 1..i + 3], 16)
        {
            out.push(b);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn shell_quote(path: &str) -> String {
    if path
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b"/._-~+".contains(&b))
    {
        path.to_owned()
    } else {
        format!("'{}'", path.replace('\'', "'\\''"))
    }
}
