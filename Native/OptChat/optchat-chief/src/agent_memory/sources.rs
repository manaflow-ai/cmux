//! What the index is built from, one entry per memory unit, in a stable
//! order: each Claude Code project memory file, each task group of Codex's
//! consolidated memory, each Codex ad-hoc note, each `*.md` of the folders
//! `agents.memory.sources` names, and the notes agents saved (last, so a new
//! note appends one entry without renumbering the rest).

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use super::notes::{self, Note};

/// One memory unit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// Where it came from, `~`-relative (`~/.claude/projects/X/memory/a.md`,
    /// `note 3`): shown with every hit and the first line of the indexed text.
    pub source: String,
    /// When it was written (RFC 3339): a note's own date, else the file's mtime.
    pub date: String,
    pub text: String,
}

/// The places sources are read from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sources {
    /// The user's home (`~` in labels).
    pub home: PathBuf,
    /// Claude Code's config folder (`~/.claude`).
    pub claude: PathBuf,
    /// Codex's home (`~/.codex`).
    pub codex: PathBuf,
    /// `agents.memory.sources`.
    pub extra: Vec<PathBuf>,
    /// The notes log `remember` appends to.
    pub notes: PathBuf,
}

impl Sources {
    /// The sources under `home`. Never from the caller's `CLAUDE_CONFIG_DIR`
    /// or `CODEX_HOME`: a session with its own config folder would see a
    /// different source list than the CLI, and each switch would rebuild.
    pub fn new(home: &Path, extra: Vec<PathBuf>, notes: PathBuf) -> Sources {
        Sources {
            home: home.to_owned(),
            claude: home.join(".claude"),
            codex: home.join(".codex"),
            extra,
            notes,
        }
    }

    /// Every entry now, without the ones that look like credentials.
    pub fn entries(&self) -> Vec<Entry> {
        self.scan().0
    }

    /// Every entry now, and the sources left out because their text looks
    /// like a credential: memory files are written by hand and by agents,
    /// and the index serves them to every session (and machine).
    pub fn scan(&self) -> (Vec<Entry>, Vec<String>) {
        let (kept, skipped): (Vec<Entry>, Vec<Entry>) = self
            .all_entries()
            .into_iter()
            .partition(|e| !notes::looks_secret(&e.text));
        (kept, skipped.into_iter().map(|e| e.source).collect())
    }

    fn all_entries(&self) -> Vec<Entry> {
        let mut out = Vec::new();
        for path in self.claude_files() {
            self.push_file(&mut out, &path);
        }
        let consolidated = self.codex.join("memories").join("MEMORY.md");
        if let Ok(text) = std::fs::read_to_string(&consolidated) {
            let date = mtime(&consolidated);
            for (i, group) in split_groups(&text).into_iter().enumerate() {
                let title = group.lines().next().unwrap_or("").trim();
                out.push(Entry {
                    source: format!("{} group {i}: {title}", self.label(&consolidated)),
                    date: date.clone(),
                    text: group.to_owned(),
                });
            }
        }
        for path in self.codex_notes() {
            self.push_file(&mut out, &path);
        }
        for dir in &self.extra {
            for path in markdown_in(dir) {
                self.push_file(&mut out, &path);
            }
        }
        for (i, note) in notes::read(&self.notes).into_iter().enumerate() {
            out.push(note_entry(i, &note));
        }
        out
    }

    /// The newest modification time among the source files (not the notes
    /// log, which only `remember` writes): a cheap first check before
    /// comparing the entry list.
    pub fn newest(&self) -> Option<SystemTime> {
        let mut paths = self.claude_files();
        paths.push(self.codex.join("memories").join("MEMORY.md"));
        paths.extend(self.codex_notes());
        for dir in &self.extra {
            paths.extend(markdown_in(dir));
        }
        paths
            .iter()
            .filter_map(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok())
            .max()
    }

    fn claude_files(&self) -> Vec<PathBuf> {
        let mut out = Vec::new();
        for project in sorted_dir(&self.claude.join("projects")) {
            out.extend(
                markdown_in(&project.join("memory"))
                    .into_iter()
                    // The index file only points at the others.
                    .filter(|p| p.file_name().is_some_and(|n| n != "MEMORY.md")),
            );
        }
        out
    }

    fn codex_notes(&self) -> Vec<PathBuf> {
        markdown_in(
            &self
                .codex
                .join("memories")
                .join("extensions")
                .join("ad_hoc")
                .join("notes"),
        )
    }

    fn push_file(&self, out: &mut Vec<Entry>, path: &Path) {
        if let Ok(text) = std::fs::read_to_string(path) {
            out.push(Entry {
                source: self.label(path),
                date: mtime(path),
                text,
            });
        }
    }

    /// `path` with the home as `~`.
    pub fn label(&self, path: &Path) -> String {
        match path.strip_prefix(&self.home) {
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => path.display().to_string(),
        }
    }
}

/// The entry of note `i` (its position in the log).
pub fn note_entry(i: usize, note: &Note) -> Entry {
    Entry {
        source: format!("note {i}"),
        date: note.date.clone(),
        text: note.text.clone(),
    }
}

/// Codex's consolidated memory, one piece per `# Task Group:` heading (the
/// text before the first heading is a piece of its own).
pub fn split_groups(text: &str) -> Vec<&str> {
    let mut starts = vec![0];
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        if offset > 0 && line.starts_with("# Task Group:") {
            starts.push(offset);
        }
        offset += line.len();
    }
    starts.push(text.len());
    starts
        .windows(2)
        .map(|w| text[w[0]..w[1]].trim_end_matches('\n'))
        .filter(|g| !g.trim().is_empty())
        .collect()
}

fn sorted_dir(dir: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    out.sort();
    out
}

fn markdown_in(dir: &Path) -> Vec<PathBuf> {
    sorted_dir(dir)
        .into_iter()
        .filter(|p| p.extension().is_some_and(|e| e == "md") && p.is_file())
        .collect()
}

fn mtime(path: &Path) -> String {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .map(|t| {
            chrono::DateTime::<chrono::Local>::from(t)
                .to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_groups_split_on_headings() {
        let text = "preamble\n# Task Group: a\none\n# Task Group: b\ntwo\n";
        assert_eq!(
            split_groups(text),
            ["preamble", "# Task Group: a\none", "# Task Group: b\ntwo"]
        );
        assert_eq!(
            split_groups("# Task Group: only\nx"),
            ["# Task Group: only\nx"]
        );
        assert!(split_groups("\n\n").is_empty());
    }

    #[test]
    fn collects_every_source_in_order() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let write = |rel: &str, text: &str| {
            let p = h.join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        };
        write(".claude/projects/b/memory/two.md", "two");
        write(".claude/projects/a/memory/one.md", "one");
        write(".claude/projects/a/memory/MEMORY.md", "index");
        write(".codex/memories/MEMORY.md", "# Task Group: g\ncodex");
        write(".codex/memories/extensions/ad_hoc/notes/n.md", "adhoc");
        write("decisions/d.md", "decision");
        write("decisions/skip.txt", "not markdown");
        let notes = h.join("notes.jsonl");
        std::fs::write(
            &notes,
            "{\"date\":\"2026-10-18T10:00:00-07:00\",\"text\":\"lesson\"}\n",
        )
        .unwrap();
        let sources = Sources {
            home: h.to_owned(),
            claude: h.join(".claude"),
            codex: h.join(".codex"),
            extra: vec![h.join("decisions")],
            notes,
        };
        let labels: Vec<String> = sources.entries().into_iter().map(|e| e.source).collect();
        assert_eq!(
            labels,
            [
                "~/.claude/projects/a/memory/one.md",
                "~/.claude/projects/b/memory/two.md",
                "~/.codex/memories/MEMORY.md group 0: # Task Group: g",
                "~/.codex/memories/extensions/ad_hoc/notes/n.md",
                "~/decisions/d.md",
                "note 0",
            ]
        );
        assert!(sources.newest().is_some());
    }
}
