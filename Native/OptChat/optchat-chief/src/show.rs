//! What a finished subagent's work leaves to show (Lawrence 2026-10-20: "as a
//! default behavior for the Chief, when submissions are done, think about what
//! else would be useful to show in the workspace ... a column to the right to
//! show a browser preview or a diff"). The host reads a report for the commit
//! ranges it landed, the pages it names and the preview files it made, and adds
//! a `<show>` block with the command that opens each one in the subagent's own
//! workspace, else in one new workspace named for the work, which the Chief
//! links (2026-10-31: never Home's right column by default). The Chief picks what is worth showing (the system prompt's
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
    block_in(report, None)
}

/// `block` for a subagent whose cmux workspace is `workspace` (`ws_…`): each
/// item opens there as a new tab, and the Chief links that tab, so the person
/// finds the work beside the agent's chat (Lawrence, Oct 29: "diff should have
/// been opened in a845 workspace"). None: one new workspace named for the work.
pub fn block_in(report: &str, workspace: Option<&str>) -> Option<String> {
    let shown = find(report);
    if shown.is_empty() {
        return None;
    }
    if let Some(ws) = workspace {
        return Some(block_in_workspace(&shown, ws));
    }
    Some(block_in_new_workspace(&shown))
}

/// No subagent workspace (the Chief's own work, a headless subagent): one new
/// workspace named for the work holds the items, and the Chief links it
/// (Lawrence 2026-10-31: "by default chief should link to workspaces, and 'set
/// up workspaces' properly"). Home's right column is only for when the user
/// asks.
fn block_in_new_workspace(shown: &Shown) -> String {
    let ws = "<ws_…>";
    let mut lines = vec![
        "<show>".to_owned(),
        format!(
            "Done work to show (show.afterReport): open the one or two most useful in one new workspace named for the work, made once with `cmux --json workspace create --name \"<2-5 word title>\" --cwd <its repo or folder>` ({ws} from its answer), as new tabs, without moving focus; link it in your reply ([title](cmux://workspace/ws_…), or a tab in it). Never Home's column or the dock; show nothing if none helps."
        ),
    ];
    push_items(&mut lines, shown, ws);
    lines.push("</show>".to_owned());
    lines.join("\n")
}

fn block_in_workspace(shown: &Shown, ws: &str) -> String {
    let mut lines = vec![
        "<show>".to_owned(),
        format!(
            "Done work to show (show.afterReport): open the one or two most useful as new tabs in the subagent's own workspace {ws}, without moving focus, and link each tab in your reply ([diff](cmux://tab/tab_…), the id from the command's answer); show nothing if none helps."
        ),
    ];
    push_items(&mut lines, shown, ws);
    lines.push("</show>".to_owned());
    lines.join("\n")
}

/// The command that opens each item as a new tab in workspace `ws`.
fn push_items(lines: &mut Vec<String>, shown: &Shown, ws: &str) {
    for (old, new) in &shown.ranges {
        match &shown.repo {
            Some(repo) => lines.push(format!(
                "- diff {old}..{new}: cmux --json tab create browser --workspace {ws} --url https://github.com/{repo}/compare/{old}...{new}"
            )),
            None => lines.push(format!(
                "- diff {old}..{new}: cmux --json tab create terminal --workspace {ws} with `git log -p {old}..{new}` in the repo"
            )),
        }
    }
    for page in &shown.pages {
        lines.push(format!(
            "- page {page}: cmux --json tab create browser --workspace {ws} --url {page}"
        ));
    }
    for file in &shown.files {
        lines.push(format!(
            "- file {file}: cmux action run file.open --target <its pane: cmux pane list --workspace {ws}> --path {} --where tab",
            shell_quote(file)
        ));
    }
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
