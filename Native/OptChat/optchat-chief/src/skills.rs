//! Chief skills (plans/cmux-next/chief-toolpacks-DESIGN.md section 4a): Claude Code
//! format skill folders (`<name>/SKILL.md` with `name` and `description` in
//! its front matter) that every Chief and its subagents read on demand.
//!
//! - Shared, for every Chief of this user: `~/.cmux/chief/skills/` (the
//!   parent of the Chief homes, `$MUX_HOME/../skills`). The skills cmux
//!   ships are written there at host start ([`install_builtin`]).
//! - One Chief's own: `$MUX_HOME/skills/`; a skill there wins over a shared
//!   one of the same name ([`load`]).
//!
//! A shipped skill carries `cmux-managed: true`; the host rewrites it on
//! update. A user who edits one and drops that line keeps their copy.

use std::path::{Path, PathBuf};

/// A skill as the Chief sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Skill {
    pub name: String,
    pub description: String,
    /// Where its SKILL.md is.
    pub path: PathBuf,
}

/// The skills cmux ships, as `(name, SKILL.md text)`.
pub const BUILTIN: [(&str, &str); 5] = [
    (
        "chief-auth-escalation",
        include_str!("../skills/chief-auth-escalation/SKILL.md"),
    ),
    (
        "chief-cloud-machines",
        include_str!("../skills/chief-cloud-machines/SKILL.md"),
    ),
    (
        "cmux-adoption",
        include_str!("../skills/cmux-adoption/SKILL.md"),
    ),
    ("cmux-setup", include_str!("../skills/cmux-setup/SKILL.md")),
    ("paid-plans", include_str!("../skills/paid-plans/SKILL.md")),
];

/// Shipped skills that moved into tool packs (toolpacks.rs): a managed
/// shared copy is removed, so a Chief whose pack is off does not see it.
pub const RETIRED: [&str; 4] = ["browser", "cmux-cli", "github-signin", "vercel"];

/// The front-matter line that marks a skill the host may rewrite.
const MANAGED: &str = "cmux-managed: true";

/// `name` and `description` from a SKILL.md's front matter (`---` lines),
/// None when it has no front matter or lacks either.
pub fn front_matter(text: &str) -> Option<(String, String)> {
    let rest = text.strip_prefix("---")?;
    let end = rest.find("\n---")?;
    let (mut name, mut description) = (None, None);
    for line in rest[..end].lines() {
        if let Some(v) = line.strip_prefix("name:") {
            name = Some(v.trim().trim_matches('"').to_owned());
        } else if let Some(v) = line.strip_prefix("description:") {
            description = Some(v.trim().trim_matches('"').to_owned());
        }
    }
    Some((
        name.filter(|n| !n.is_empty())?,
        description.filter(|d| !d.is_empty())?,
    ))
}

/// The shared skills folder of the Chiefs under `mux_home`'s parent.
pub fn shared_dir(mux_home: &Path) -> PathBuf {
    mux_home.parent().unwrap_or(mux_home).join("skills")
}

/// One Chief's own skills folder.
pub fn chief_dir(mux_home: &Path) -> PathBuf {
    mux_home.join("skills")
}

/// Writes every shipped skill into `dir` (`<dir>/<name>/SKILL.md`): a new
/// one, or one that still carries `cmux-managed: true` and differs. A copy
/// the user took over (no marker) stays as it is. Answers the names written.
pub fn install_builtin(dir: &Path) -> std::io::Result<Vec<String>> {
    let mut written = Vec::new();
    for name in RETIRED {
        let path = dir.join(name).join("SKILL.md");
        if std::fs::read_to_string(&path).is_ok_and(|t| t.contains(MANAGED)) {
            std::fs::remove_dir_all(dir.join(name))?;
        }
    }
    for (name, text) in BUILTIN {
        let path = dir.join(name).join("SKILL.md");
        match std::fs::read_to_string(&path) {
            Ok(old) if old == text => continue,
            Ok(old) if !old.contains(MANAGED) => continue,
            _ => {}
        }
        std::fs::create_dir_all(dir.join(name))?;
        crate::session_dir::write_if_changed(&path, text.as_bytes())?;
        written.push(name.to_owned());
    }
    Ok(written)
}

/// The skills a Chief has: its own folder over the shared one, by name,
/// sorted by name. A folder without a valid SKILL.md is skipped.
pub fn load(shared: &Path, chief: &Path) -> Vec<Skill> {
    let mut by_name = std::collections::BTreeMap::new();
    for dir in [shared, chief] {
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path().join("SKILL.md");
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            if let Some((name, description)) = front_matter(&text) {
                by_name.insert(
                    name.clone(),
                    Skill {
                        name,
                        description,
                        path,
                    },
                );
            }
        }
    }
    by_name.into_values().collect()
}
