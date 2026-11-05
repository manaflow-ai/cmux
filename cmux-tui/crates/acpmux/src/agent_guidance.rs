//! cmux's built-in guidance for the agents it runs, and the person's own skills.
//!
//! Leo, 2026-11-05, on the Claude Code desktop app's task list, session cards, session links
//! and wrap-up box: "presumably specifically in the claude code desktop there are a few
//! skills/system prompts that let you guys know about them... cmux-next should add a few and
//! we can think about extending them as well and letting other users define stuff too!"
//! Design: plans/cmux-next/agent-guidance-DESIGN.md.
//!
//! Each harness gets it through its own mechanism:
//! - Claude Code: the `cmux:cmux-chat` skill in the session plugin (`agent_tools::SKILL_FILES`;
//!   only its description reaches the prompt) plus [`CLAUDE_GUIDANCE`], a few lines of
//!   first-turn context that say when to read it. The person's skills are a second session
//!   plugin, `cmux-user` ([`materialize_user_plugin`]), so Claude Code lists them natively.
//! - Codex and every other harness: [`AGENT_GUIDANCE`] in the first-turn context, the channel
//!   Codex itself uses for AGENTS.md (a hidden user-role block), and an index of the person's
//!   skills (name, description, path) so the agent reads one when it applies.
//!
//! The text is captured when the session is created (`context_inventory::snapshot_session`),
//! so the Context viewer shows exactly what the chat got. Switches, all on by default, are
//! settings keys (schemas/settings/source/agent-guidance.json):
//! `agents.guidance.claude`, `agents.guidance.codex`, `agents.guidance.otherAgents` and
//! `agents.guidance.userSkills`.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// The second Claude Code plugin, holding the person's skills (`cmux-user:<name>`).
pub const USER_PLUGIN_NAME: &str = "cmux-user";
/// Overrides the folder of the person's skills (tests, and a person who keeps them elsewhere).
pub const USER_SKILLS_DIR_ENV: &str = "CMUX_AGENT_SKILLS_DIR";

/// At most this many of the person's skills reach a session (a name order cut).
const MAX_USER_SKILLS: usize = 64;
/// At most this many files, and bytes per file, are copied from one skill's folder.
const MAX_FILES_PER_SKILL: usize = 200;
const MAX_FILE_BYTES: u64 = 1024 * 1024;
/// A skill folder deeper than this is not walked further.
const MAX_DEPTH: usize = 4;
/// A skill's description in the first-turn index is cut to this many characters.
const MAX_DESCRIPTION_CHARS: usize = 300;

/// Claude Code's first-turn guidance: when to read the `cmux:cmux-chat` skill.
pub const CLAUDE_GUIDANCE: &str = "This chat runs in cmux NEXT, which draws your TodoWrite list as a checklist, your sub-sessions in a tray and session links as chips. Read the cmux:cmux-chat skill before a task with more than one step, before starting or offering another session, and before ending a turn that changed files (it says how to end with a short recap). cmux defaults; the person's own instructions win.";

/// Every other harness's first-turn guidance (Codex: `update_plan` is its plan tool).
pub const AGENT_GUIDANCE: &str = "cmux chat guidance (cmux defaults; the person's own instructions win). This chat runs in cmux NEXT, which draws your work in the chat:
- Plan: for a task with more than one step, keep a plan with your plan tool (Codex: update_plan). cmux draws it as a checklist. Write the whole plan first, short items, one in progress; mark each done as you start the next; rewrite it when the plan changes. Do not also write it as a numbered list.
- Side sessions (only with the tools listed; skip this when they are not): start a sub-session (start_session, worktree: true when it edits files yours may touch) only when the person asked for parallel or background work, and give it the whole task. For work you noticed outside the task, offer it instead (offer_session mid-turn, suggest_tasks at the end of a turn) and do not do it here. Never use a session for a quick lookup or a step you need the answer to now.
- Links: when you mention another session, write its HOST/NAME or its agent link (cmux://agent/<harness>/<sessionId>) in inline code; cmux makes it a link. Never invent an id.
- Recap: end a turn that changed files or ran commands with a two-or-three-sentence recap: what is now true, what you verified, what is not done, and the one decision the person must make, if any.
- Editing cmux itself: when asked to change how cmux looks or behaves, use the cmux-live and cmux-customization guides (`cmux docs search live`).";

/// The harness families the switches name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Family {
    Claude,
    Codex,
    Other,
}

impl Family {
    /// From a profile's family (`config::derive_family`), e.g. `claude`, `codex`, `gemini`.
    pub fn of(family: &str) -> Self {
        if family.starts_with("claude") {
            Family::Claude
        } else if family.starts_with("codex") {
            Family::Codex
        } else {
            Family::Other
        }
    }
}

/// The settings switches, read when a session is created.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Switches {
    pub claude: bool,
    pub codex: bool,
    pub other: bool,
    pub user_skills: bool,
}

impl Default for Switches {
    fn default() -> Self {
        Switches { claude: true, codex: true, other: true, user_skills: true }
    }
}

impl Switches {
    /// From the settings file's text. A missing or unreadable file, or a key that is not a
    /// boolean, keeps the default (on): these keys only add text an agent reads.
    pub fn from_settings_text(text: Option<&str>) -> Self {
        let doc = text.and_then(crate::user_settings::document);
        let on = |key: &str| match doc.as_ref().and_then(|d| crate::user_settings::value(d, key)) {
            Some(Value::Bool(b)) => b,
            _ => true,
        };
        Switches {
            claude: on("agents.guidance.claude"),
            codex: on("agents.guidance.codex"),
            other: on("agents.guidance.otherAgents"),
            user_skills: on("agents.guidance.userSkills"),
        }
    }

    pub fn current() -> Self {
        Self::from_settings_text(crate::user_settings::text().as_deref())
    }

    pub fn builtin_for(&self, family: Family) -> bool {
        match family {
            Family::Claude => self.claude,
            Family::Codex => self.codex,
            Family::Other => self.other,
        }
    }
}

/// One of the person's skills: `<dir>/SKILL.md` with `name` and `description` frontmatter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserSkill {
    pub name: String,
    pub description: String,
    pub dir: PathBuf,
}

/// `$CMUX_AGENT_SKILLS_DIR`, else `$XDG_CONFIG_HOME/cmux/skills`, else `~/.config/cmux/skills`.
pub fn user_skills_dir() -> Option<PathBuf> {
    let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from);
    if let Some(dir) = var(USER_SKILLS_DIR_ENV) {
        return Some(dir);
    }
    if let Some(xdg) = var("XDG_CONFIG_HOME") {
        return Some(xdg.join("cmux/skills"));
    }
    var("HOME").or_else(dirs::home_dir).map(|home| home.join(".config/cmux/skills"))
}

/// The person's skills in `dir`, in name order. A folder without a readable `SKILL.md`, or one
/// whose frontmatter lacks a valid `name` or a `description`, is skipped (and logged).
pub fn user_skills(dir: &Path) -> Vec<UserSkill> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut skills: Vec<UserSkill> = entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter_map(|e| {
            let skill_dir = e.path();
            let file = skill_dir.join("SKILL.md");
            // `symlink_metadata`: a symlinked SKILL.md is refused, so the index never points an
            // agent outside the skills folder.
            if std::fs::symlink_metadata(&file)
                .map_or(true, |m| !m.file_type().is_file() || m.len() > MAX_FILE_BYTES)
            {
                return None;
            }
            let text = std::fs::read_to_string(&file).ok()?;
            match frontmatter(&text) {
                Some((name, description)) if valid_name(&name) => {
                    let description = cap_description(&description);
                    Some(UserSkill { name, description, dir: skill_dir })
                }
                _ => {
                    tracing::warn!(
                        "agent guidance: {} has no valid name and description frontmatter",
                        file.display()
                    );
                    None
                }
            }
        })
        .collect();
    skills.sort_by(|a, b| a.name.cmp(&b.name));
    skills.dedup_by(|a, b| a.name == b.name);
    skills.truncate(MAX_USER_SKILLS);
    skills
}

/// `description` cut to `MAX_DESCRIPTION_CHARS`, with an ellipsis when cut.
fn cap_description(description: &str) -> String {
    let mut chars = description.chars();
    let head: String = chars.by_ref().take(MAX_DESCRIPTION_CHARS).collect();
    if chars.next().is_some() { format!("{head}…") } else { head }
}

/// A skill name Claude Code accepts: lowercase letters, digits and `-`, at most 64.
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// `name` and `description` from a `---` frontmatter block (one line each, quotes removed).
fn frontmatter(text: &str) -> Option<(String, String)> {
    let body = text.strip_prefix("---\n").or_else(|| text.strip_prefix("---\r\n"))?;
    let (block, _) = body.split_once("\n---")?;
    let field = |key: &str| {
        block.lines().find_map(|line| {
            let value = line.strip_prefix(key)?.strip_prefix(':')?.trim();
            let value = value
                .strip_prefix('"')
                .and_then(|v| v.strip_suffix('"'))
                .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
                .unwrap_or(value);
            (!value.is_empty()).then(|| value.to_owned())
        })
    };
    Some((field("name")?, field("description")?))
}

/// The first-turn guidance for a session of `family`, or `None` when nothing is on.
/// Claude Code gets the person's skills as a plugin, so only other harnesses get the index.
pub fn first_turn_text(
    family: Family,
    switches: &Switches,
    skills: &[UserSkill],
) -> Option<String> {
    let mut out = String::new();
    if switches.builtin_for(family) {
        out.push_str(if family == Family::Claude { CLAUDE_GUIDANCE } else { AGENT_GUIDANCE });
    }
    if switches.user_skills && family != Family::Claude && !skills.is_empty() {
        if !out.is_empty() {
            out.push_str("\n\n");
        }
        out.push_str(
            "The person's own skills (cmux user skills). When one's description matches the task, read its SKILL.md first and follow it:",
        );
        for skill in skills {
            let file = skill.dir.join("SKILL.md");
            out.push_str(&format!(
                "\n- {}: {} ({})",
                skill.name,
                skill.description,
                file.display()
            ));
        }
    }
    (!out.is_empty()).then_some(out)
}

/// The guidance for a new session of profile `harness`, read now.
pub fn for_session(cfg: &crate::config::Config, harness: &str) -> Option<String> {
    let family = Family::of(&cfg.family(harness).unwrap_or_else(|| harness.to_owned()));
    let switches = Switches::current();
    let skills = if switches.user_skills {
        user_skills_dir().map(|d| user_skills(&d)).unwrap_or_default()
    } else {
        Vec::new()
    };
    first_turn_text(family, &switches, &skills)
}

/// The person's skills as a Claude Code plugin under `state_dir`, written once per content hash
/// (to a temporary folder, then renamed). `None` with no skills. Only regular files are copied,
/// never a symlink's target, so a skill cannot pull in files from outside its folder.
pub fn materialize_user_plugin(
    state_dir: &Path,
    skills: &[UserSkill],
) -> anyhow::Result<Option<PathBuf>> {
    if skills.is_empty() {
        return Ok(None);
    }
    let mut files: Vec<(String, Vec<u8>)> = Vec::new();
    for skill in skills {
        let mut found = Vec::new();
        collect_files(&skill.dir, Path::new(""), 0, &mut found);
        found.sort();
        for rel in found.into_iter().take(MAX_FILES_PER_SKILL) {
            if let Ok(bytes) = std::fs::read(skill.dir.join(&rel)) {
                files.push((format!("skills/{}/{}", skill.name, rel.to_string_lossy()), bytes));
            }
        }
    }
    let manifest = json!({
        "name": USER_PLUGIN_NAME,
        "description": "Your own skills from ~/.config/cmux/skills, for agents cmux starts",
        "version": env!("CARGO_PKG_VERSION"),
    });
    files.push((".claude-plugin/plugin.json".to_owned(), manifest.to_string().into_bytes()));
    let mut all = Vec::new();
    for (path, bytes) in &files {
        all.extend_from_slice(path.as_bytes());
        all.push(0);
        all.extend_from_slice(bytes);
        all.push(0);
    }
    let hash = crate::sha256::sha256_hex(&all);
    let dir = state_dir.join(format!("user-{}", hash.get(..16).unwrap_or(&hash)));
    if dir.join(".claude-plugin/plugin.json").is_file() {
        return Ok(Some(dir));
    }
    crate::config::refuse_lost_home(state_dir)?;
    std::fs::create_dir_all(state_dir)?;
    let tmp = state_dir.join(format!(".tmp-user-{}", uuid::Uuid::now_v7()));
    let write = || -> anyhow::Result<()> {
        for (path, bytes) in &files {
            let file = tmp.join(path);
            if let Some(parent) = file.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(file, bytes)?;
        }
        Ok(())
    };
    if let Err(e) = write() {
        let _ = std::fs::remove_dir_all(&tmp);
        return Err(e);
    }
    match std::fs::rename(&tmp, &dir) {
        Ok(()) => Ok(Some(dir)),
        Err(_) if dir.join(".claude-plugin/plugin.json").is_file() => {
            let _ = std::fs::remove_dir_all(&tmp);
            Ok(Some(dir))
        }
        Err(e) => {
            let _ = std::fs::remove_dir_all(&tmp);
            Err(e.into())
        }
    }
}

/// Regular files under `root/rel`, as paths relative to `root`; hidden entries and symlinks skipped.
fn collect_files(root: &Path, rel: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth > MAX_DEPTH || out.len() >= MAX_FILES_PER_SKILL {
        return;
    }
    let Ok(entries) = std::fs::read_dir(root.join(rel)) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        let Ok(kind) = entry.file_type() else { continue };
        let child = rel.join(&name);
        if kind.is_dir() {
            collect_files(root, &child, depth + 1, out);
        } else if kind.is_file() && entry.metadata().is_ok_and(|m| m.len() <= MAX_FILE_BYTES) {
            out.push(child);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn skill(root: &Path, dir: &str, text: &str) {
        std::fs::create_dir_all(root.join(dir)).unwrap();
        std::fs::write(root.join(dir).join("SKILL.md"), text).unwrap();
    }

    #[test]
    fn families_get_their_own_guidance() {
        let on = Switches::default();
        // Claude Code: only when to read the skill (its own prompt covers TodoWrite).
        let claude = first_turn_text(Family::Claude, &on, &[]).unwrap();
        assert!(claude.contains("cmux:cmux-chat") && claude.contains("recap"), "{claude}");
        assert!(claude.len() < 500, "the pointer stays short: {} bytes", claude.len());
        let codex = first_turn_text(Family::Codex, &on, &[]).unwrap();
        for tool in [
            "update_plan",
            "start_session",
            "offer_session",
            "suggest_tasks",
            "recap",
            "inline code",
        ] {
            assert!(codex.contains(tool), "{tool} missing: {codex}");
        }
        assert!(codex.contains("skip this when they are not"), "{codex}");
    }

    #[test]
    fn switches_turn_off_per_family_and_default_on() {
        assert_eq!(Switches::from_settings_text(None), Switches::default());
        assert_eq!(Switches::from_settings_text(Some("not json")), Switches::default());
        let sw = Switches::from_settings_text(Some(
            r#"{"agents": {"guidance": {"codex": false}}, "agents.guidance.userSkills": false}"#,
        ));
        assert!(sw.claude && !sw.codex && sw.other && !sw.user_skills);
        assert_eq!(first_turn_text(Family::Codex, &sw, &[]), None);
        assert!(first_turn_text(Family::Other, &sw, &[]).is_some());
    }

    #[test]
    fn user_skills_are_read_validated_and_indexed_for_codex_only() {
        let root = tempfile::tempdir().unwrap();
        skill(
            root.path(),
            "deploy",
            "---\nname: deploy\ndescription: \"Ship the app to staging.\"\n---\n\nSteps.",
        );
        skill(root.path(), "bad", "---\nname: Bad Name\ndescription: x\n---\n");
        skill(root.path(), "nofront", "just text");
        std::fs::create_dir_all(root.path().join("empty")).unwrap();
        let skills = user_skills(root.path());
        assert_eq!(skills.len(), 1, "{skills:?}");
        assert_eq!(skills[0].description, "Ship the app to staging.");

        let on = Switches::default();
        let codex = first_turn_text(Family::Codex, &on, &skills).unwrap();
        assert!(codex.contains("- deploy: Ship the app to staging. ("), "{codex}");
        assert!(codex.contains("deploy/SKILL.md"), "{codex}");
        let claude = first_turn_text(Family::Claude, &on, &skills).unwrap();
        assert!(!claude.contains("Ship the app"), "Claude gets them as a plugin: {claude}");
        let off = Switches { codex: false, ..on };
        let only_index = first_turn_text(Family::Codex, &off, &skills).unwrap();
        assert!(only_index.starts_with("The person's own skills"), "{only_index}");
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_skill_md_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let target = outside.path().join("SKILL.md");
        std::fs::write(&target, "---\nname: outside\ndescription: Not in the folder.\n---\n")
            .unwrap();
        std::fs::create_dir_all(root.path().join("outside")).unwrap();
        std::os::unix::fs::symlink(&target, root.path().join("outside/SKILL.md")).unwrap();
        assert!(user_skills(root.path()).is_empty(), "the index must not point outside the folder");
    }

    #[test]
    fn a_long_description_is_cut_in_the_index() {
        let root = tempfile::tempdir().unwrap();
        let long = "word ".repeat(2000);
        skill(root.path(), "long", &format!("---\nname: long\ndescription: {long}\n---\n"));
        let skills = user_skills(root.path());
        assert_eq!(skills[0].description.chars().count(), MAX_DESCRIPTION_CHARS + 1);
        assert!(skills[0].description.ends_with('…'));
        let codex = first_turn_text(Family::Codex, &Switches::default(), &skills).unwrap();
        assert!(codex.len() < AGENT_GUIDANCE.len() + 1000, "{} bytes", codex.len());
    }

    #[test]
    fn user_plugin_copies_regular_files_once_per_content() {
        let root = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        skill(root.path(), "notes", "---\nname: notes\ndescription: Take notes.\n---\n");
        std::fs::create_dir_all(root.path().join("notes/references")).unwrap();
        std::fs::write(root.path().join("notes/references/more.md"), "more").unwrap();
        std::fs::write(root.path().join("notes/.secret"), "hidden").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/etc/hosts", root.path().join("notes/hosts")).unwrap();

        assert_eq!(materialize_user_plugin(state.path(), &[]).unwrap(), None);
        let skills = user_skills(root.path());
        let dir = materialize_user_plugin(state.path(), &skills).unwrap().unwrap();
        assert!(dir.join("skills/notes/SKILL.md").is_file());
        assert_eq!(
            std::fs::read_to_string(dir.join("skills/notes/references/more.md")).unwrap(),
            "more"
        );
        assert!(!dir.join("skills/notes/.secret").exists());
        assert!(!dir.join("skills/notes/hosts").exists());
        let manifest: Value = serde_json::from_str(
            &std::fs::read_to_string(dir.join(".claude-plugin/plugin.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(manifest["name"], USER_PLUGIN_NAME);
        assert_eq!(materialize_user_plugin(state.path(), &skills).unwrap().unwrap(), dir);
    }
}
