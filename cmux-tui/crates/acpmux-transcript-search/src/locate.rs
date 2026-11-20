//! Where transcripts are: each Claude Code config dir's `projects/<cwd>/<id>.jsonl` (and the
//! subagents' `projects/<cwd>/<id>/subagents/*.jsonl`, searched as part of session `<id>`), and
//! each Codex home's `sessions/YYYY/MM/DD/rollout-*-<id>.jsonl` and `archived_sessions/`.

use std::fs;
use std::path::{Path, PathBuf};

use crate::parse::Harness;

/// One transcript file and the session it belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Source {
    pub path: PathBuf,
    pub harness: Harness,
    /// The harness's session id: the Claude Code session, the Codex thread. A subagent's
    /// transcript carries its parent's.
    pub session: String,
    pub subagent: bool,
}

/// The harness data dirs to look in.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Roots {
    /// Claude Code `projects` dirs (`~/.claude/projects`, `$CLAUDE_CONFIG_DIR/projects`).
    pub claude: Vec<PathBuf>,
    /// Codex homes (`~/.codex`, each `CODEX_HOME`): each holds `sessions/`.
    pub codex: Vec<PathBuf>,
}

impl Roots {
    /// `~/.claude/projects` and `~/.codex`, and those under `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.
    pub fn default_for(home: &Path, env: impl Fn(&str) -> Option<String>) -> Self {
        let mut roots = Self::default();
        roots.add_claude(home.join(".claude/projects"));
        if let Some(dir) = env("CLAUDE_CONFIG_DIR").filter(|d| !d.is_empty()) {
            roots.add_claude(PathBuf::from(dir).join("projects"));
        }
        roots.add_codex(home.join(".codex"));
        if let Some(dir) = env("CODEX_HOME").filter(|d| !d.is_empty()) {
            roots.add_codex(PathBuf::from(dir));
        }
        roots
    }

    pub fn add_claude(&mut self, dir: PathBuf) {
        let dir = fs::canonicalize(&dir).unwrap_or(dir);
        if !self.claude.contains(&dir) {
            self.claude.push(dir);
        }
    }

    pub fn add_codex(&mut self, dir: PathBuf) {
        let dir = fs::canonicalize(&dir).unwrap_or(dir);
        if !self.codex.contains(&dir) {
            self.codex.push(dir);
        }
    }

    /// Every transcript under the roots.
    pub fn all(&self) -> Vec<Source> {
        let mut out = Vec::new();
        for root in &self.claude {
            for project in dirs(root) {
                for entry in entries(&project) {
                    if let Some(session) = jsonl_stem(&entry) {
                        out.push(Source {
                            path: entry,
                            harness: Harness::Claude,
                            session,
                            subagent: false,
                        });
                    } else if entry.is_dir() {
                        let session = file_name(&entry);
                        out.extend(claude_subagents(&entry, &session));
                    }
                }
            }
        }
        for root in &self.codex {
            for dir in ["sessions", "archived_sessions"] {
                walk_codex(&root.join(dir), 0, &mut out);
            }
        }
        dedupe(out)
    }

    /// The transcripts of the harness session `id` (a Claude Code session or a Codex thread):
    /// its own file and its subagents'. Reads only the dirs that can hold it.
    pub fn session(&self, id: &str) -> Vec<Source> {
        if id.is_empty() || id.contains('/') || id.contains("..") {
            return Vec::new();
        }
        let mut out = Vec::new();
        for root in &self.claude {
            for project in dirs(root) {
                let file = project.join(format!("{id}.jsonl"));
                if file.is_file() {
                    out.push(Source {
                        path: file,
                        harness: Harness::Claude,
                        session: id.to_owned(),
                        subagent: false,
                    });
                }
                let dir = project.join(id);
                if dir.is_dir() {
                    out.extend(claude_subagents(&dir, id));
                }
            }
        }
        if !out.is_empty() {
            return dedupe(out);
        }
        let mut codex = Vec::new();
        for root in &self.codex {
            for dir in ["sessions", "archived_sessions"] {
                walk_codex(&root.join(dir), 0, &mut codex);
            }
        }
        out.extend(codex.into_iter().filter(|s| s.session == id));
        dedupe(out)
    }
}

fn claude_subagents(session_dir: &Path, session: &str) -> Vec<Source> {
    entries(&session_dir.join("subagents"))
        .into_iter()
        .filter(|p| jsonl_stem(p).is_some())
        .map(|path| Source {
            path,
            harness: Harness::Claude,
            session: session.to_owned(),
            subagent: true,
        })
        .collect()
}

/// `rollout-2026-10-29T18-17-41-<uuid>.jsonl` files under `dir`, at most 4 levels down.
fn walk_codex(dir: &Path, depth: usize, out: &mut Vec<Source>) {
    for entry in entries(dir) {
        if entry.is_dir() {
            if depth < 4 {
                walk_codex(&entry, depth + 1, out);
            }
            continue;
        }
        let Some(stem) = jsonl_stem(&entry) else { continue };
        if !stem.starts_with("rollout-") || stem.len() < 36 {
            continue;
        }
        let Some(session) = stem.get(stem.len() - 36..).map(str::to_owned) else { continue };
        out.push(Source { path: entry, harness: Harness::Codex, session, subagent: false });
    }
}

fn dedupe(mut sources: Vec<Source>) -> Vec<Source> {
    let mut seen = std::collections::HashSet::new();
    sources.retain(|s| seen.insert(s.path.clone()));
    sources
}

fn entries(dir: &Path) -> Vec<PathBuf> {
    let Ok(read) = fs::read_dir(dir) else { return Vec::new() };
    read.filter_map(Result::ok).map(|e| e.path()).collect()
}

fn dirs(dir: &Path) -> Vec<PathBuf> {
    entries(dir).into_iter().filter(|p| p.is_dir()).collect()
}

fn jsonl_stem(path: &Path) -> Option<String> {
    if path.extension()? != "jsonl" {
        return None;
    }
    Some(path.file_stem()?.to_string_lossy().into_owned())
}

fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}
