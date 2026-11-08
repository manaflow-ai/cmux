//! Slash skills: the person types `/name` in a Chief composer (Home chat,
//! floating Chief, iPhone) and the Chief runs that skill on this message, as
//! Claude Code's slash commands do (Lawrence 2026-11-07: "i want to be able
//! to invoke / skills from chief and have chief skills, like i want all the
//! emil skills in chief").
//!
//! - What `/` lists ([`catalog`]): the Chief's own skills (skills.rs: its
//!   `$MUX_HOME/skills`, then the shared `~/.cmux/chief/skills`), then the
//!   person's Claude Code skills (`<Claude home>/skills/<name>/SKILL.md`), then
//!   the skills of their installed Claude Code plugins, named
//!   `<plugin>:<skill>` as Claude Code names them. A name is listed once; the
//!   first source that has it wins. The Mac composer lists the same folders
//!   (MessagesLab `SlashSkillCatalog`).
//! - What an invocation does ([`invocation_line`]): the message keeps the
//!   person's words as typed, and the host adds one line naming the skill's
//!   SKILL.md, which the turn reads in full before it answers (the same way it
//!   opens an attached file, brain/files.rs). The skill's text is not copied
//!   into the memory log: a 14 KB SKILL.md in every invoking message would
//!   fill the log and every view built from it.
//! - Default Chief skills ([`link_claude_skills`]): every person skill whose
//!   folder name matches `chief.claudeSkills` (cmux.json; default
//!   `["emil-*"]`) is linked into the shared Chief skills folder at host
//!   start, so every Chief finds it with its other skills (prompt.rs: "read a
//!   skill's SKILL.md before doing what its description names") with no
//!   per-turn prompt cost. `[]` links none.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::skills::{Skill, front_matter};

/// The cmux.json key of the person skills linked into the Chief skills.
pub const CLAUDE_SKILLS_KEY: &str = "chief.claudeSkills";

/// The patterns used when cmux.json does not set `chief.claudeSkills`.
pub const DEFAULT_CLAUDE_SKILLS: [&str; 1] = ["emil-*"];

/// Where a listed skill comes from, in the order a name is looked up.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// The Chief's own or shared skills (skills.rs), links included.
    Chief,
    /// The person's Claude Code skills folder.
    Claude,
    /// A skill of an installed Claude Code plugin.
    Plugin,
}

/// A skill the composer lists and a message can invoke.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SlashSkill {
    pub skill: Skill,
    pub source: Source,
}

/// The skills under `dir` (`<dir>/<folder>/SKILL.md`), sorted by name; a
/// folder without a valid SKILL.md is skipped. `prefix` goes before each
/// name (`plugin:`).
fn folder(dir: &Path, prefix: &str) -> Vec<Skill> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<Skill> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path().join("SKILL.md");
            let text = std::fs::read_to_string(&path).ok()?;
            let (name, description) = front_matter(&text)?;
            Some(Skill {
                name: format!("{prefix}{name}"),
                description,
                path,
            })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// The installed plugins of `claude_home` as `(plugin name, install path)`,
/// from `plugins/installed_plugins.json` (version 2: `plugins` maps
/// `<plugin>@<marketplace>` to its installs), each path once.
pub fn installed_plugins(claude_home: &Path) -> Vec<(String, PathBuf)> {
    let Ok(bytes) = std::fs::read(claude_home.join("plugins").join("installed_plugins.json"))
    else {
        return Vec::new();
    };
    let Ok(doc) = serde_json::from_slice::<Value>(&bytes) else {
        return Vec::new();
    };
    let Some(plugins) = doc.get("plugins").and_then(Value::as_object) else {
        return Vec::new();
    };
    let mut out: Vec<(String, PathBuf)> = Vec::new();
    for (key, installs) in plugins {
        let name = key.split('@').next().unwrap_or(key).to_owned();
        for install in installs.as_array().into_iter().flatten() {
            let Some(path) = install.get("installPath").and_then(Value::as_str) else {
                continue;
            };
            let path = PathBuf::from(path);
            if !out.iter().any(|(_, p)| *p == path) {
                out.push((name.clone(), path));
            }
        }
    }
    out.sort();
    out
}

/// Every skill `/` lists for the Chief of `mux_home`, in lookup order (see
/// the module doc); each name once.
pub fn catalog(mux_home: &Path, claude_home: &Path) -> Vec<SlashSkill> {
    let chief = crate::skills::load(
        &crate::skills::shared_dir(mux_home),
        &crate::skills::chief_dir(mux_home),
    );
    let mut out: Vec<SlashSkill> = chief
        .into_iter()
        .map(|skill| SlashSkill {
            skill,
            source: Source::Chief,
        })
        .collect();
    let mut add = |skills: Vec<Skill>, source: Source| {
        for skill in skills {
            if !out.iter().any(|s| s.skill.name == skill.name) {
                out.push(SlashSkill { skill, source });
            }
        }
    };
    add(folder(&claude_home.join("skills"), ""), Source::Claude);
    for (plugin, path) in installed_plugins(claude_home) {
        add(
            folder(&path.join("skills"), &format!("{plugin}:")),
            Source::Plugin,
        );
    }
    out
}

/// The skill name a message invokes and the words after it: the message
/// starts (after blank space) with `/name`, then blank space or its end.
/// A name is letters, digits, `-`, `_`, `.` and `:`; a path (`/tmp/x`) or a
/// lone `/` invokes nothing.
pub fn invoked(text: &str) -> Option<(&str, &str)> {
    let rest = text.trim_start().strip_prefix('/')?;
    let end = rest.find(|c: char| c.is_whitespace()).unwrap_or(rest.len());
    let name = &rest[..end];
    let valid = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ':'))
        && name
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphanumeric());
    valid.then(|| (name, rest[end..].trim()))
}

/// The line the host adds to a message that invokes a listed skill, None
/// when the message invokes none (or a name nobody has: it stays a message).
pub fn invocation_line(text: &str, skills: &[SlashSkill]) -> Option<String> {
    let (name, rest) = invoked(text)?;
    let found = skills
        .iter()
        .find(|s| s.skill.name.eq_ignore_ascii_case(name))?;
    let input = if rest.is_empty() {
        "it has no other words: ask what to apply it to only when the conversation does not say"
            .to_owned()
    } else {
        "the words after the command are its input".to_owned()
    };
    Some(format!(
        "[skill /{}] The person invoked the skill {}: read {} in full now and follow it for this message; {input}.",
        found.skill.name,
        found.skill.name,
        found.skill.path.display()
    ))
}

/// `text` with the invocation line of the skill it invokes after it, as the
/// turn sees it; `text` itself when it invokes none.
pub fn with_invocation(text: &str, skills: &[SlashSkill]) -> String {
    match invocation_line(text, skills) {
        Some(line) => format!("{text}\n{line}"),
        None => text.to_owned(),
    }
}

/// Whether `name` matches `pattern`: `*` stands for any run of characters,
/// every other character for itself.
pub fn glob(pattern: &str, name: &str) -> bool {
    fn go(p: &[u8], n: &[u8]) -> bool {
        match p.split_first() {
            None => n.is_empty(),
            Some((b'*', rest)) => (0..=n.len()).any(|k| go(rest, &n[k..])),
            Some((c, rest)) => n
                .split_first()
                .is_some_and(|(d, tail)| c == d && go(rest, tail)),
        }
    }
    go(pattern.as_bytes(), name.as_bytes())
}

/// The `chief.claudeSkills` patterns of the settings document: its strings
/// when it sets an array, else [`DEFAULT_CLAUDE_SKILLS`].
pub fn claude_skill_patterns(doc: Option<&Value>) -> Vec<String> {
    match doc.and_then(|d| crate::agent_memory::settings::value(d, CLAUDE_SKILLS_KEY)) {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|v| v.as_str().map(str::trim))
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect(),
        _ => DEFAULT_CLAUDE_SKILLS
            .iter()
            .map(|s| (*s).to_owned())
            .collect(),
    }
}

/// Makes `shared` hold a link to each skill folder of `<claude_home>/skills`
/// whose name matches one of `patterns` and has a SKILL.md, and no other
/// link into that folder. A real folder or another link of the same name
/// stays (the person's or cmux's own skill wins). Answers the names linked
/// now.
pub fn link_claude_skills(shared: &Path, claude_home: &Path, patterns: &[String]) -> Vec<String> {
    let source = claude_home.join("skills");
    let mut want: Vec<String> = std::fs::read_dir(&source)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.'))
        .filter(|n| patterns.iter().any(|p| glob(p, n)))
        .filter(|n| source.join(n).join("SKILL.md").is_file())
        .collect();
    want.sort();
    if let Ok(entries) = std::fs::read_dir(shared) {
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(target) = std::fs::read_link(&path) else {
                continue;
            };
            let name = entry.file_name().to_string_lossy().into_owned();
            let ours = target.parent() == Some(source.as_path());
            if ours && (!want.contains(&name) || target != source.join(&name)) {
                let _ = std::fs::remove_file(&path);
            }
        }
    }
    let mut linked = Vec::new();
    if want.is_empty() || std::fs::create_dir_all(shared).is_err() {
        return linked;
    }
    for name in want {
        let link = shared.join(&name);
        if std::fs::symlink_metadata(&link).is_ok() {
            continue;
        }
        if std::os::unix::fs::symlink(source.join(&name), &link).is_ok() {
            linked.push(name);
        }
    }
    linked
}

/// Host start: links the person skills cmux.json names (default: every
/// `emil-*` skill) into the shared Chief skills of `mux_home`.
pub fn link_default_claude_skills(mux_home: &Path) -> Vec<String> {
    let doc = std::env::var_os("HOME")
        .and_then(|home| crate::agent_memory::settings::document(Path::new(&home)));
    link_claude_skills(
        &crate::skills::shared_dir(mux_home),
        &crate::compactor::user_claude_home(),
        &claude_skill_patterns(doc.as_ref()),
    )
}
