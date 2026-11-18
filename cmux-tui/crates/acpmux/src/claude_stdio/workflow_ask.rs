//! What a Workflow call will run, for its permission ask: the workflow's name,
//! its description and its phase titles, read from the script's
//! `export const meta = {...}` literal (Claude Code requires it to be a pure
//! literal). The pane draws them on the approval card, so the person sees the
//! run's shape before answering Claude's own ask.
//!
//! The script is the call's inline `script`, else the file at its
//! `scriptPath`, else a saved workflow of its `name` in the chat's
//! `.claude/workflows/` or `~/.claude/workflows/`. A resumed run
//! (`resumeFromRunId`) or a name with no file found is described by its name
//! alone. Nothing here runs the script.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The most of a script file read for its `meta`.
const SCRIPT_BYTES: u64 = 512 << 10;
/// The most phases sent; a longer list says how many more.
const MAX_PHASES: usize = 24;
/// The longest name, description or phase title sent.
const MAX_CHARS: usize = 200;

/// The workflow a Workflow call's `input` asks to run, as `_meta.claude.workflow`:
/// `{name?, description?, phases: [title], morePhases?, resume?}`. None when
/// nothing names it.
pub(super) async fn workflow_ask(input: &Value, cwd: Option<&Path>) -> Option<Value> {
    let s = |k: &str| input.get(k).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty());
    let script = match (s("script"), s("scriptPath"), s("name")) {
        (Some(script), _, _) => Some(script.to_owned()),
        (None, Some(path), _) => read_script(Path::new(path)).await,
        (None, None, Some(name)) => saved_script(name, cwd).await,
        _ => None,
    };
    let meta = script.as_deref().and_then(meta_literal).map(parse_meta).unwrap_or_default();
    let name = meta.name.or(s("name").map(str::to_owned)).or(s("title").map(str::to_owned));
    let description = meta.description.or(s("description").map(str::to_owned));
    let resume = s("resumeFromRunId");
    if name.is_none() && meta.phases.is_empty() && resume.is_none() {
        return None;
    }
    let more = meta.phases.len().saturating_sub(MAX_PHASES);
    let phases: Vec<String> = meta.phases.into_iter().take(MAX_PHASES).map(|t| clip(&t)).collect();
    let mut out = json!({"phases": phases});
    if let Some(name) = name {
        out["name"] = json!(clip(&name));
    }
    if let Some(description) = description {
        out["description"] = json!(clip(&description));
    }
    if more > 0 {
        out["morePhases"] = json!(more);
    }
    if let Some(run) = resume {
        out["resume"] = json!(run);
    }
    Some(out)
}

fn clip(text: &str) -> String {
    let text = text.trim();
    if text.chars().count() <= MAX_CHARS {
        return text.to_owned();
    }
    let mut cut: String = text.chars().take(MAX_CHARS - 1).collect();
    cut.push('…');
    cut
}

async fn read_script(path: &Path) -> Option<String> {
    let size = tokio::fs::metadata(path).await.ok()?.len();
    if size > SCRIPT_BYTES {
        return None;
    }
    tokio::fs::read_to_string(path).await.ok()
}

/// A saved workflow's script: the project's first, then the person's own.
async fn saved_script(name: &str, cwd: Option<&Path>) -> Option<String> {
    // A name is one path component: never a way out of the workflows folder.
    if name.contains(['/', '\\']) || name.starts_with('.') {
        return None;
    }
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(cwd) = cwd {
        dirs.push(cwd.join(".claude/workflows"));
    }
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(home).join(".claude/workflows"));
    }
    for dir in dirs {
        for ext in ["js", "mjs"] {
            if let Some(script) = read_script(&dir.join(format!("{name}.{ext}"))).await {
                return Some(script);
            }
        }
    }
    None
}

#[derive(Debug, Default, PartialEq)]
pub(super) struct Meta {
    pub(super) name: Option<String>,
    pub(super) description: Option<String>,
    pub(super) phases: Vec<String>,
}

/// The `{...}` of `export const meta = {...}`, braces included.
pub(super) fn meta_literal(script: &str) -> Option<&str> {
    let at = script.find("const meta")?;
    let open = at + script[at..].find('{')?;
    let close = open + matching(&script[open..], '{', '}')?;
    Some(&script[open..=close])
}

/// The byte offset of the bracket closing the one `text` starts with, skipping strings and comments.
fn matching(text: &str, open: char, close: char) -> Option<usize> {
    let mut depth = 0usize;
    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        match c {
            '"' | '\'' | '`' => skip_string(&mut chars, c),
            '/' if chars.peek().map(|(_, n)| *n) == Some('/') => {
                for (_, n) in chars.by_ref() {
                    if n == '\n' {
                        break;
                    }
                }
            }
            '/' if chars.peek().map(|(_, n)| *n) == Some('*') => {
                chars.next();
                let mut star = false;
                for (_, n) in chars.by_ref() {
                    if star && n == '/' {
                        break;
                    }
                    star = n == '*';
                }
            }
            c if c == open => depth += 1,
            c if c == close => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
    }
    None
}

fn skip_string(chars: &mut std::iter::Peekable<std::str::CharIndices<'_>>, quote: char) {
    while let Some((_, c)) = chars.next() {
        if c == '\\' {
            chars.next();
        } else if c == quote {
            return;
        }
    }
}

/// The string literal `text` starts with (after blanks), unescaped; a template with `${` is no literal.
fn string_at(text: &str) -> Option<String> {
    let text = text.trim_start();
    let quote = text.chars().next().filter(|c| matches!(c, '"' | '\'' | '`'))?;
    let mut out = String::new();
    let mut chars = text[1..].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                other => out.push(other),
            },
            '$' if quote == '`' && chars.clone().next() == Some('{') => return None,
            c if c == quote => return Some(out),
            c => out.push(c),
        }
    }
    None
}

/// The value after `key:` at the object's top level (`depth` 1 inside its braces), as its offset.
fn top_level_key(object: &str, key: &str) -> Option<usize> {
    let mut depth = 0usize;
    let mut chars = object.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        match c {
            '"' | '\'' | '`' => {
                // A quoted key: `"phases": [...]`.
                let start = i;
                skip_string(&mut chars, c);
                let end = chars.peek().map(|(j, _)| *j).unwrap_or(object.len());
                if depth == 1 && object[start + 1..end.saturating_sub(1)] == *key {
                    let rest = &object[end..];
                    let colon = rest.len() - rest.trim_start().len();
                    if rest.trim_start().starts_with(':') {
                        return Some(end + colon + 1);
                    }
                }
            }
            '{' | '[' | '(' => depth += 1,
            '}' | ']' | ')' => depth = depth.saturating_sub(1),
            c if depth == 1 && (c.is_ascii_alphabetic() || c == '_') => {
                let before = object[..i].chars().next_back();
                if before.is_some_and(|b| b.is_ascii_alphanumeric() || b == '_' || b == '$') {
                    continue;
                }
                if object[i..].starts_with(key) {
                    let rest = &object[i + key.len()..];
                    let trimmed = rest.trim_start();
                    if trimmed.starts_with(':') {
                        return Some(object.len() - trimmed.len() + 1);
                    }
                }
            }
            _ => {}
        }
    }
    None
}

/// Each `{...}` element of the array literal `text` starts with.
fn array_objects(text: &str) -> Vec<&str> {
    let text = text.trim_start();
    if !text.starts_with('[') {
        return Vec::new();
    }
    let Some(end) = matching(text, '[', ']') else { return Vec::new() };
    let inner = &text[1..end];
    let mut out = Vec::new();
    let mut rest = inner;
    while let Some(open) = rest.find('{') {
        let Some(close) = matching(&rest[open..], '{', '}') else { break };
        out.push(&rest[open..=open + close]);
        rest = &rest[open + close + 1..];
    }
    out
}

pub(super) fn parse_meta(literal: &str) -> Meta {
    let field = |object: &str, key: &str| {
        top_level_key(object, key).and_then(|at| string_at(&object[at..]))
    };
    let phases = top_level_key(literal, "phases")
        .map(|at| array_objects(&literal[at..]))
        .unwrap_or_default()
        .into_iter()
        .filter_map(|phase| field(phase, "title"))
        .filter(|title| !title.trim().is_empty())
        .collect();
    Meta { name: field(literal, "name"), description: field(literal, "description"), phases }
}
