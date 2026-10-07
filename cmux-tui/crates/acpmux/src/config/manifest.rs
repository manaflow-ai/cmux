//! Harness manifests: a folder per harness with `harness.json` and an icon,
//! so a harness is added by writing files instead of changing acpmux.
//!
//! Manifests live next to the app's `cmux.json`, in
//! `$XDG_CONFIG_HOME/cmux/harnesses/<id>/` (`~/.config/cmux/harnesses/<id>/`).
//! acpmux also ships some (`bundled`). A config.json entry with the same id
//! wins over a user manifest, which wins over a bundled one, which wins over
//! PATH discovery. `acpmux harness check` validates a folder with errors
//! that name the field.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::{DeclaredModel, HarnessKind, HarnessProfile, PermissionPolicy};

pub const MANIFEST_FILE: &str = "harness.json";
pub const SCHEMA: u32 = 1;
const MAX_MANIFEST_BYTES: u64 = 64 * 1024;
const MAX_ICON_BYTES: u64 = 64 * 1024;

/// `harness.json`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    /// Manifest format version; this build reads 1.
    pub schema: u32,
    /// Must equal the folder name: lowercase letters, digits and `-`.
    pub id: String,
    /// What pickers show.
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub homepage: Option<String>,
    /// An SVG file in the folder, drawn in `currentColor` so it follows the theme.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    pub run: Run,
    #[serde(default, skip_serializing_if = "Auth::is_empty")]
    pub auth: Auth,
    #[serde(default, skip_serializing_if = "Models::is_default")]
    pub models: Models,
    #[serde(default, skip_serializing_if = "Capabilities::is_empty")]
    pub capabilities: Capabilities,
    #[serde(default, skip_serializing_if = "Defaults::is_empty")]
    pub defaults: Defaults,
    /// Model family for `defaults` and `-u FAMILY`; the id when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Run {
    /// `acp` (Agent Client Protocol over stdio) or `claude-stdio`.
    #[serde(default)]
    pub protocol: HarnessKind,
    /// A program name looked up on PATH, or an absolute path.
    pub command: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    /// Shown when the command is missing, e.g. `curl -fsSL https://… | bash`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub install: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Auth {
    /// Ways to sign in. The app runs `command args…` in a terminal tab.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub logins: Vec<Login>,
    /// Args for `command` that exit 0 when signed in (optional).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<Vec<String>>,
}

impl Auth {
    fn is_empty(&self) -> bool {
        self.logins.is_empty() && self.status.is_none()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Login {
    pub id: String,
    pub label: String,
    pub args: Vec<String>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ModelSource {
    /// What the harness reports over ACP (`session/new` models or config options).
    #[default]
    Acp,
    /// Only `list`.
    Static,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Models {
    #[serde(default)]
    pub source: ModelSource,
    /// Shown ahead of what the harness reports (required for `static`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub list: Vec<DeclaredModel>,
}

impl Models {
    fn is_default(&self) -> bool {
        *self == Models::default()
    }
}

/// ACP config option ids that carry a feature, so the app shows its control.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Capabilities {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// Whether the harness asks before tools run (ACP `session/request_permission`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permissions: Option<bool>,
    /// Whether `session/load` resumes a chat after a restart.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<bool>,
}

impl Capabilities {
    fn is_empty(&self) -> bool {
        *self == Capabilities::default()
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Defaults {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<PermissionPolicy>,
}

impl Defaults {
    fn is_empty(&self) -> bool {
        *self == Defaults::default()
    }
}

/// Where a manifest came from.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Origin {
    Bundled,
    User,
}

/// A manifest that passed `check`, with what pickers need.
#[derive(Debug, Clone, PartialEq)]
pub struct Loaded {
    pub manifest: Manifest,
    pub origin: Origin,
    /// The folder, for user manifests.
    pub dir: Option<PathBuf>,
    /// The icon's SVG text.
    pub icon_svg: Option<String>,
}

impl Loaded {
    /// The profile acpmux runs; `which` resolves a bare command on PATH.
    /// Returns the reason it cannot run yet alongside, when the command is missing.
    pub fn profile(
        &self,
        which: &dyn Fn(&str) -> Option<String>,
    ) -> (HarnessProfile, Option<String>) {
        let run = &self.manifest.run;
        let (program, missing) = if Path::new(&run.command).is_absolute() {
            let found = Path::new(&run.command).is_file();
            (run.command.clone(), !found)
        } else {
            match which(&run.command) {
                Some(path) => (path, false),
                None => (run.command.clone(), true),
            }
        };
        let mut argv = vec![program];
        argv.extend(run.args.iter().cloned());
        let reason = missing.then(|| match &run.install {
            Some(install) => format!("{}: not found on PATH; install: {install}", run.command),
            None => format!("{}: not found on PATH", run.command),
        });
        let m = &self.manifest;
        let profile = HarnessProfile {
            kind: run.protocol,
            argv,
            env: run.env.clone(),
            description: m.description.clone().or_else(|| Some(m.name.clone())),
            fallback: None,
            family: Some(m.family.clone().unwrap_or_else(|| m.id.clone())),
            models: m.models.list.clone(),
            model: m.defaults.model.clone(),
            effort: m.defaults.effort.clone(),
            policy: m.defaults.policy,
        };
        (profile, reason)
    }

    /// What `_acpmux/harnesses` adds for a manifest harness.
    pub fn summary(&self) -> serde_json::Value {
        let m = &self.manifest;
        serde_json::json!({
            "name": m.name,
            "origin": self.origin,
            "dir": self.dir,
            "homepage": m.homepage,
            "icon": self.icon_svg,
            "install": m.run.install,
            "logins": m.auth.logins,
            "modelSource": m.models.source,
            "capabilities": m.capabilities,
        })
    }
}

/// One thing wrong with a manifest. `field` is a JSON path such as `run.command`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Problem {
    pub field: String,
    pub message: String,
}

impl std::fmt::Display for Problem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.field.is_empty() {
            write!(f, "{}", self.message)
        } else {
            write!(f, "{}: {}", self.field, self.message)
        }
    }
}

fn problem(field: &str, message: impl Into<String>) -> Problem {
    Problem { field: field.into(), message: message.into() }
}

/// `$XDG_CONFIG_HOME/cmux/harnesses`, next to the app's `cmux.json`.
pub fn user_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("CMUX_HARNESSES_DIR")
        && !dir.is_empty()
    {
        return Some(PathBuf::from(dir));
    }
    let base = match std::env::var("XDG_CONFIG_HOME") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => dirs::home_dir()?.join(".config"),
    };
    Some(base.join("cmux").join("harnesses"))
}

pub fn valid_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 32
        && bytes[0].is_ascii_lowercase()
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
        && !id.ends_with('-')
}

/// Parse and validate manifest text. `folder` is the folder name the id must
/// match (None for bundled text). Icons are checked by `check_dir`.
pub fn parse(text: &str, folder: Option<&str>) -> Result<Manifest, Vec<Problem>> {
    let manifest: Manifest = match serde_json::from_str(text) {
        Ok(m) => m,
        Err(e) => {
            return Err(vec![problem(
                "",
                format!(
                    "{} (line {}, column {})",
                    strip_position(&e.to_string()),
                    e.line(),
                    e.column()
                ),
            )]);
        }
    };
    let mut problems = Vec::new();
    if manifest.schema != SCHEMA {
        problems.push(problem(
            "schema",
            format!("this acpmux reads schema {SCHEMA}, not {}", manifest.schema),
        ));
    }
    if !valid_id(&manifest.id) {
        problems.push(problem(
            "id",
            "use 1-32 lowercase letters, digits and dashes, starting with a letter (e.g. \"acme-agent\")",
        ));
    } else if let Some(folder) = folder
        && folder != manifest.id
    {
        problems.push(problem(
            "id",
            format!("\"{}\" must match its folder name \"{folder}\"", manifest.id),
        ));
    }
    if manifest.name.trim().is_empty() || manifest.name.chars().count() > 40 {
        problems.push(problem("name", "1-40 characters"));
    }
    let run = &manifest.run;
    if run.command.trim().is_empty() {
        problems.push(problem("run.command", "required: the program to start, e.g. \"fx\""));
    } else if run.command.contains('/') && !Path::new(&run.command).is_absolute() {
        problems.push(problem(
            "run.command",
            "a program name on PATH or an absolute path, not a relative path",
        ));
    } else if run.command.contains(char::is_whitespace) && !Path::new(&run.command).is_absolute() {
        problems.push(problem("run.command", "one program, no spaces; put arguments in run.args"));
    }
    for key in run.env.keys() {
        if key.is_empty() || key.contains('=') || key.starts_with("ACPMUX_") {
            problems.push(problem(
                &format!("run.env.{key}"),
                "names may not be empty, contain '=' or start with ACPMUX_",
            ));
        }
    }
    let mut ids = std::collections::BTreeSet::new();
    for (i, login) in manifest.auth.logins.iter().enumerate() {
        let field = format!("auth.logins[{i}]");
        if !valid_id(&login.id) {
            problems.push(problem(&format!("{field}.id"), "lowercase letters, digits and dashes"));
        } else if !ids.insert(login.id.clone()) {
            problems
                .push(problem(&format!("{field}.id"), format!("\"{}\" appears twice", login.id)));
        }
        if login.label.trim().is_empty() {
            problems
                .push(problem(&format!("{field}.label"), "required: what the sign-in menu shows"));
        }
    }
    if manifest.models.source == ModelSource::Static && manifest.models.list.is_empty() {
        problems.push(problem("models.list", "required when models.source is \"static\""));
    }
    for (i, model) in manifest.models.list.iter().enumerate() {
        if model.id().trim().is_empty() {
            problems.push(problem(&format!("models.list[{i}]"), "a model id may not be empty"));
        }
    }
    if let Some(family) = &manifest.family
        && !valid_id(family)
    {
        problems.push(problem("family", "lowercase letters, digits and dashes"));
    }
    if let Some(icon) = &manifest.icon
        && (icon.contains('/') || icon.contains('\\') || !icon.ends_with(".svg"))
    {
        problems
            .push(problem("icon", "an .svg file name in the harness folder, e.g. \"icon.svg\""));
    }
    if problems.is_empty() { Ok(manifest) } else { Err(problems) }
}

/// serde_json puts "at line X column Y" at the end; `parse` says it its own way.
fn strip_position(message: &str) -> String {
    match message.rfind(" at line ") {
        Some(i) => message[..i].to_string(),
        None => message.to_string(),
    }
}

/// An icon pickers can render inline: an `<svg>` with no scripts, event
/// handlers, embedded HTML or outside references.
pub fn check_icon(svg: &str) -> Result<(), String> {
    let lower = svg.to_ascii_lowercase();
    if !lower.contains("<svg") {
        return Err("not an SVG (no <svg> element)".into());
    }
    for (needle, why) in [
        ("<script", "has a <script>"),
        ("<foreignobject", "has a <foreignObject>"),
        ("javascript:", "has a javascript: link"),
        ("<!entity", "declares XML entities"),
        ("<image", "embeds an <image>; draw it with paths"),
        ("<use", "uses <use>; inline the shape instead"),
        ("@import", "imports a stylesheet"),
    ] {
        if lower.contains(needle) {
            return Err(why.into());
        }
    }
    if lower.contains("href=\"http") || lower.contains("href='http") || lower.contains("url(http") {
        return Err("references an outside URL".into());
    }
    // An `on…=` attribute is an event handler.
    let bytes = lower.as_bytes();
    for (i, w) in bytes.windows(3).enumerate() {
        if w[0].is_ascii_whitespace() && w[1] == b'o' && w[2] == b'n' {
            let rest = &lower[i + 3..];
            let name: String = rest.chars().take_while(|c| c.is_ascii_alphabetic()).collect();
            if !name.is_empty() && rest[name.len()..].trim_start().starts_with('=') {
                return Err(format!("has an on{name}= event handler"));
            }
        }
    }
    Ok(())
}

/// Read and validate one harness folder.
pub fn check_dir(dir: &Path) -> Result<Loaded, Vec<Problem>> {
    let folder = dir.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
    let path = dir.join(MANIFEST_FILE);
    let text = match read_capped(&path, MAX_MANIFEST_BYTES) {
        Ok(t) => t,
        Err(e) => return Err(vec![problem("", format!("{}: {e}", path.display()))]),
    };
    let manifest = parse(&text, Some(&folder))?;
    let icon_svg = match &manifest.icon {
        None => None,
        Some(name) => match read_capped(&dir.join(name), MAX_ICON_BYTES) {
            Err(e) => return Err(vec![problem("icon", format!("{name}: {e}"))]),
            Ok(svg) => match check_icon(&svg) {
                Ok(()) => Some(svg),
                Err(why) => return Err(vec![problem("icon", format!("{name} {why}"))]),
            },
        },
    };
    Ok(Loaded { manifest, origin: Origin::User, dir: Some(dir.to_path_buf()), icon_svg })
}

fn read_capped(path: &Path, cap: u64) -> std::io::Result<String> {
    let meta = std::fs::metadata(path)?;
    if meta.len() > cap {
        return Err(std::io::Error::other(format!("larger than {} KB", cap / 1024)));
    }
    std::fs::read_to_string(path)
}

/// Every harness folder under `root` that checks out, by id, and the
/// problems of those that do not (logged, and shown by `acpmux harness check`).
pub fn load_dir(root: &Path) -> (BTreeMap<String, Loaded>, BTreeMap<String, Vec<Problem>>) {
    let mut loaded = BTreeMap::new();
    let mut failed = BTreeMap::new();
    let Ok(entries) = std::fs::read_dir(root) else {
        return (loaded, failed);
    };
    let mut dirs: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_dir() && p.join(MANIFEST_FILE).exists())
        // `.<id>.installing-…` folders are `install`'s staging.
        .filter(|p| !p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with('.')))
        .collect();
    dirs.sort();
    for dir in dirs {
        let name = dir.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
        match check_dir(&dir) {
            Ok(m) => {
                loaded.insert(m.manifest.id.clone(), m);
            }
            Err(problems) => {
                tracing::warn!(harness = %name, problems = ?problems, "harness manifest skipped");
                failed.insert(name, problems);
            }
        }
    }
    (loaded, failed)
}

/// Manifests shipped with acpmux, as (folder, harness.json, icon.svg).
const BUNDLED: &[(&str, &str, &str)] = &[];

pub fn bundled() -> BTreeMap<String, Loaded> {
    let mut out = BTreeMap::new();
    for &(folder, text, icon) in BUNDLED {
        match parse(text, Some(folder)) {
            Ok(manifest) => {
                let icon_svg =
                    (!icon.is_empty() && check_icon(icon).is_ok()).then(|| icon.to_string());
                out.insert(
                    manifest.id.clone(),
                    Loaded { manifest, origin: Origin::Bundled, dir: None, icon_svg },
                );
            }
            Err(problems) => {
                tracing::error!(harness = folder, ?problems, "bundled harness manifest is invalid")
            }
        }
    }
    out
}

/// Bundled manifests overlaid by the user folder's.
pub fn all() -> (BTreeMap<String, Loaded>, BTreeMap<String, Vec<Problem>>) {
    let mut manifests = bundled();
    let (user, failed) = user_dir().map(|d| load_dir(&d)).unwrap_or_default();
    manifests.extend(user);
    (manifests, failed)
}

/// The folder a project ships harnesses in: `.cmux/harnesses/` in `cwd` or
/// the nearest parent that has one, stopping at the repository root (a
/// folder with `.git`) and never above the home folder.
pub fn project_dir(cwd: &Path) -> Option<PathBuf> {
    let home = dirs::home_dir();
    let mut dir = Some(cwd);
    while let Some(d) = dir {
        let candidate = d.join(".cmux").join("harnesses");
        if candidate.is_dir() {
            return Some(candidate);
        }
        if d.join(".git").exists() || Some(d) == home.as_deref() {
            return None;
        }
        dir = d.parent();
    }
    None
}

/// A harness a project ships. Nothing in a project runs until the user
/// installs it into their own folder (`acpmux harness add --from`), the same
/// explicit step as any other harness; the app offers that step.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Offer {
    pub id: String,
    pub name: String,
    pub dir: PathBuf,
    pub icon: Option<String>,
    /// The user's folder has a harness with this id.
    pub installed: bool,
    /// ... and its harness.json differs from the project's.
    pub differs: bool,
    /// Why the project's manifest cannot be installed, when it fails `check`.
    pub problems: Vec<Problem>,
}

pub fn offers(cwd: &Path) -> Vec<Offer> {
    let Some(root) = project_dir(cwd) else {
        return Vec::new();
    };
    let user = user_dir();
    let (loaded, failed) = load_dir(&root);
    let mut out = Vec::new();
    for (id, m) in loaded {
        let mine = user.as_ref().map(|u| u.join(&id));
        let installed = mine.as_ref().is_some_and(|d| d.join(MANIFEST_FILE).exists());
        let differs = installed
            && mine.as_ref().and_then(|d| std::fs::read(d.join(MANIFEST_FILE)).ok())
                != m.dir.as_ref().and_then(|d| std::fs::read(d.join(MANIFEST_FILE)).ok());
        out.push(Offer {
            id: id.clone(),
            name: m.manifest.name.clone(),
            dir: m.dir.clone().unwrap_or_default(),
            icon: m.icon_svg.clone(),
            installed,
            differs,
            problems: vec![],
        });
    }
    for (id, problems) in failed {
        out.push(Offer {
            id: id.clone(),
            name: id.clone(),
            dir: root.join(&id),
            icon: None,
            installed: false,
            differs: false,
            problems,
        });
    }
    out
}

/// Copy a checked harness folder into `dest_root/<id>`: only harness.json
/// and its icon, written beside the target and renamed into place.
pub fn install(src: &Loaded, dest_root: &Path, replace: bool) -> std::io::Result<PathBuf> {
    let id = &src.manifest.id;
    let from =
        src.dir.as_ref().ok_or_else(|| std::io::Error::other("bundled harnesses are built in"))?;
    let dest = dest_root.join(id);
    if dest.exists() && !replace {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            format!("{} already exists (--replace to overwrite it)", dest.display()),
        ));
    }
    std::fs::create_dir_all(dest_root)?;
    let staging = dest_root.join(format!(".{id}.installing-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging)?;
    let mut files = vec![MANIFEST_FILE.to_string()];
    files.extend(src.manifest.icon.clone());
    for file in &files {
        std::fs::copy(from.join(file), staging.join(file))?;
    }
    if dest.exists() {
        let old = dest_root.join(format!(".{id}.replaced-{}", std::process::id()));
        std::fs::rename(&dest, &old)?;
        std::fs::rename(&staging, &dest)?;
        let _ = std::fs::remove_dir_all(&old);
    } else {
        std::fs::rename(&staging, &dest)?;
    }
    Ok(dest)
}

/// Harness folders in a source tree: the folder itself, or the ones under
/// `.cmux/harnesses/`, `harnesses/` or directly inside it.
pub fn find_in(src: &Path) -> Vec<PathBuf> {
    if src.join(MANIFEST_FILE).exists() {
        return vec![src.to_path_buf()];
    }
    for sub in [src.join(".cmux").join("harnesses"), src.join("harnesses"), src.to_path_buf()] {
        let Ok(entries) = std::fs::read_dir(&sub) else {
            continue;
        };
        let mut dirs: Vec<PathBuf> = entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_dir() && p.join(MANIFEST_FILE).exists())
            .collect();
        if !dirs.is_empty() {
            dirs.sort();
            return dirs;
        }
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    const FX: &str = r#"{
      "schema": 1, "id": "fx", "name": "fx", "icon": "icon.svg",
      "run": {"command": "fx", "args": ["acp"], "install": "curl -fsSL https://fx.sh/setup.sh | bash"},
      "auth": {"logins": [{"id": "gateway", "label": "Vercel AI Gateway", "args": ["login"]},
                          {"id": "chatgpt", "label": "ChatGPT", "args": ["login", "codex"]}]},
      "capabilities": {"fast": "fast"}
    }"#;
    const ICON: &str = r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="currentColor" d="M4 4h16v16H4z"/></svg>"#;

    fn folder(name: &str, manifest: &str, icon: Option<&str>) -> PathBuf {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!("acpmux-manifest-{}-{n}", std::process::id()));
        let dir = root.join(name);
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(MANIFEST_FILE), manifest).unwrap();
        if let Some(icon) = icon {
            std::fs::write(dir.join("icon.svg"), icon).unwrap();
        }
        dir
    }

    fn fields(problems: &[Problem]) -> Vec<&str> {
        problems.iter().map(|p| p.field.as_str()).collect()
    }

    #[test]
    fn manifest_parses_into_a_profile() {
        let dir = folder("fx", FX, Some(ICON));
        let loaded = check_dir(&dir).unwrap();
        assert_eq!(loaded.manifest.auth.logins.len(), 2);
        assert!(loaded.icon_svg.as_deref().unwrap().contains("currentColor"));
        let (profile, missing) =
            loaded.profile(&|bin| (bin == "fx").then(|| "/opt/fx/bin/fx".to_string()));
        assert_eq!(profile.argv, ["/opt/fx/bin/fx", "acp"]);
        assert_eq!(profile.kind, HarnessKind::Acp);
        assert_eq!(profile.family.as_deref(), Some("fx"));
        assert!(missing.is_none());
        let (_, missing) = loaded.profile(&|_| None);
        assert_eq!(
            missing.unwrap(),
            "fx: not found on PATH; install: curl -fsSL https://fx.sh/setup.sh | bash"
        );
        let summary = loaded.summary();
        assert_eq!(summary["logins"][1]["args"], serde_json::json!(["login", "codex"]));
        assert_eq!(summary["capabilities"]["fast"], "fast");
    }

    #[test]
    fn manifest_problems_name_the_field() {
        let problems = parse(
            r#"{"schema": 2, "id": "Acme", "name": "", "icon": "../x.png",
                "run": {"command": "bin/acme agent", "env": {"ACPMUX_X": "1"}},
                "auth": {"logins": [{"id": "a", "label": "", "args": []}, {"id": "a", "label": "B", "args": []}]},
                "models": {"source": "static"}}"#,
            Some("acme"),
        )
        .unwrap_err();
        assert_eq!(
            fields(&problems),
            [
                "schema",
                "id",
                "name",
                "run.command",
                "run.env.ACPMUX_X",
                "auth.logins[0].label",
                "auth.logins[1].id",
                "models.list",
                "icon"
            ]
        );
    }

    #[test]
    fn manifest_unknown_fields_and_folder_mismatch() {
        let err = parse(
            r#"{"schema": 1, "id": "fx", "name": "fx", "run": {"command": "fx", "argz": []}}"#,
            None,
        )
        .unwrap_err();
        assert!(err[0].message.contains("unknown field `argz`"), "{}", err[0].message);
        assert!(err[0].message.contains("line 1"), "{}", err[0].message);
        let err = parse(FX, Some("other")).unwrap_err();
        assert_eq!(err[0].field, "id");
        assert!(err[0].message.contains("folder name \"other\""));
    }

    #[test]
    fn manifest_icons_refuse_active_content() {
        assert!(check_icon(ICON).is_ok());
        for bad in [
            "<svg><script>alert(1)</script></svg>",
            "<svg onload=\"x()\"></svg>",
            "<svg><a href=\"javascript:x\"/></svg>",
            "<svg><image href=\"http://evil/x.png\"/></svg>",
            "<svg><foreignObject/></svg>",
            "<png/>",
        ] {
            assert!(check_icon(bad).is_err(), "{bad}");
        }
        // `on` inside a word or value is fine.
        assert!(check_icon("<svg><path d=\"M0 0\" data-icon=\"one\"/></svg>").is_ok());
        let dir = folder(
            "bad-icon",
            FX.replace("\"fx\"", "\"bad-icon\"").as_str(),
            Some("<svg onclick='x'/>"),
        );
        let err = check_dir(&dir).unwrap_err();
        assert_eq!(err[0].field, "icon");
    }

    #[test]
    fn manifest_folder_loads_good_and_reports_bad() {
        let good = folder("fx", FX, Some(ICON));
        let root = good.parent().unwrap();
        let bad = root.join("broken");
        std::fs::create_dir_all(&bad).unwrap();
        std::fs::write(bad.join(MANIFEST_FILE), "{ not json").unwrap();
        let (loaded, failed) = load_dir(root);
        assert_eq!(loaded.keys().collect::<Vec<_>>(), ["fx"]);
        assert_eq!(failed.keys().collect::<Vec<_>>(), ["broken"]);
    }

    #[test]
    fn manifest_harness_joins_between_config_and_path() {
        let dir = folder("fx", FX, Some(ICON));
        let loaded = check_dir(&dir).unwrap();
        let mut manifests = BTreeMap::new();
        manifests.insert("fx".to_string(), loaded.clone());
        let mut discovered = BTreeMap::new();
        discovered.insert(
            "fx".to_string(),
            HarnessProfile { argv: vec!["/path/fx".into()], ..super::super::tests_profile() },
        );
        // A manifest beats PATH discovery, and a missing command is unavailable.
        let mut cfg = super::super::Config::default();
        cfg.join_manifests(manifests.clone(), BTreeMap::new(), discovered.clone(), &|_| None);
        assert_eq!(cfg.harnesses["fx"].argv, ["fx", "acp"]);
        assert!(cfg.discovered.contains("fx"));
        assert!(cfg.unavailable["fx"].contains("install:"));
        assert_eq!(cfg.manifests["fx"].manifest.name, "fx");
        // config.json wins, and is not marked unavailable by the manifest.
        let mut cfg = super::super::Config::default();
        cfg.harnesses.insert(
            "fx".into(),
            HarnessProfile {
                argv: vec!["/mine/fx".into(), "acp".into()],
                ..super::super::tests_profile()
            },
        );
        cfg.join_manifests(manifests, BTreeMap::new(), discovered, &|_| None);
        assert_eq!(cfg.harnesses["fx"].argv, ["/mine/fx", "acp"]);
        assert!(!cfg.discovered.contains("fx"));
        assert!(!cfg.unavailable.contains_key("fx"));
        assert!(cfg.manifests.contains_key("fx"));
    }
}
