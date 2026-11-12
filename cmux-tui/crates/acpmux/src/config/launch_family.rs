//! The family of the program a launch really runs, judged when its agent starts
//! (`hub/lifecycle.rs`): the written name's family ([`super::program_family_of`]), confirmed by the
//! file the launch runs. A policy check reads it when the config entry names no family
//! (`web_modes::trusted_mode_family`).

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// The npm packages of the agents acpmux knows (the `name` of their `package.json`) and their
/// family: an npm, Volta or Homebrew install runs a file whose own name tells nothing
/// (`@anthropic-ai/claude-code/cli.js`, `@google/gemini-cli/dist/index.js`).
const PACKAGE_FAMILIES: &[(&str, &str)] = &[
    ("@anthropic-ai/claude-code", "claude"),
    ("@openai/codex", "codex"),
    ("opencode-ai", "opencode"),
    ("@google/gemini-cli", "gemini"),
    ("@earendil-works/pi-coding-agent", "pi"),
    ("@zed-industries/claude-code-acp", "claude"),
    ("@zed-industries/codex-acp", "codex"),
    ("@agentclientprotocol/codex-acp", "codex"),
];

/// How many folders above a program's real file its `package.json` is looked for.
const PACKAGE_DEPTH: usize = 8;

/// The family of the program `argv` runs from folder `cwd`, where `path` (the launch's `PATH`)
/// finds a bare program name: its written name's family, when the file it runs agrees.
///
/// The file is the program found, links resolved. Its own name ([`super::program_family`]) and
/// the `name` of the nearest `package.json` above it ([`PACKAGE_FAMILIES`]) each may give a
/// family:
/// - another known family than the written name's gives `None` (a link named `opencode` that
///   runs Codex), as do two that disagree;
/// - a file that gives none keeps the written name's family, unless the program found is in the
///   chat folder `cwd` (the project's own file, not an install);
/// - a package a runner fetches (`npx -y @scope/codex-acp`) or a Python module has no file to
///   read: its exact name decides.
///
/// `None` also when the written name is no program of the list, or the program is not found.
pub fn launch_family(argv: &[String], cwd: &Path, path: Option<&OsStr>) -> Option<String> {
    let written = super::program_family_of(argv)?;
    let found = match super::launch_target(argv)? {
        super::LaunchTarget::Program(word) => find_program(word, cwd, path)?,
        super::LaunchTarget::Script(word) => {
            let at = absolute(Path::new(word), cwd);
            at.is_file().then_some(at)?
        }
        super::LaunchTarget::Named(_) => return Some(written.to_owned()),
    };
    let real = std::fs::canonicalize(&found).ok()?;
    match file_family(&real) {
        Ok(Some(family)) => (family == written).then(|| written.to_owned()),
        Ok(None) => (!in_folder(&found, &real, cwd)).then(|| written.to_owned()),
        Err(Disagree) => None,
    }
}

/// The name and the package of one file gave two families.
struct Disagree;

/// The family file `real` is by its own name and by its package; `Ok(None)` when neither gives one.
fn file_family(real: &Path) -> Result<Option<&'static str>, Disagree> {
    let by_name = real.file_name().and_then(OsStr::to_str).and_then(super::program_family);
    match (by_name, package_family(real)) {
        (Some(name), Some(package)) if name != package => Err(Disagree),
        (name, package) => Ok(name.or(package)),
    }
}

/// The family of the npm package file `real` is in: the `name` of the nearest `package.json`
/// above it ([`PACKAGE_FAMILIES`]); `None` for no package, or a package of no known agent.
fn package_family(real: &Path) -> Option<&'static str> {
    let manifest = real
        .ancestors()
        .skip(1)
        .take(PACKAGE_DEPTH)
        .map(|dir| dir.join("package.json"))
        .find(|manifest| manifest.is_file())?;
    let text = std::fs::read_to_string(manifest).ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    let name = value.get("name")?.as_str()?;
    PACKAGE_FAMILIES.iter().find(|(package, _)| *package == name).map(|(_, family)| *family)
}

/// Whether the program found at `found` (its real file `real`) is in the chat folder `cwd`. The
/// root folder holds no program of its own.
fn in_folder(found: &Path, real: &Path, cwd: &Path) -> bool {
    let folder = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    if folder.parent().is_none() {
        return false;
    }
    let found_dir = found
        .parent()
        .and_then(|dir| std::fs::canonicalize(dir).ok())
        .unwrap_or_else(|| found.to_path_buf());
    found_dir.starts_with(&folder) || real.starts_with(&folder)
}

/// `word` from folder `cwd`.
fn absolute(word: &Path, cwd: &Path) -> PathBuf {
    if word.is_absolute() { word.to_path_buf() } else { cwd.join(word) }
}

/// The program a launch's program word `word` names: a path (from `cwd`), else the first
/// program of its name in a folder of `path`.
fn find_program(word: &str, cwd: &Path, path: Option<&OsStr>) -> Option<PathBuf> {
    if word.contains('/') {
        let at = absolute(Path::new(word), cwd);
        return is_program(&at).then_some(at);
    }
    // Windows finds `codex` as `codex.exe` or the npm shim `codex.cmd`.
    let names: &[&str] = if cfg!(windows) { &["", ".exe", ".cmd"] } else { &[""] };
    std::env::split_paths(path?)
        .flat_map(|dir| {
            names.iter().map(move |ext| absolute(&dir, cwd).join(format!("{word}{ext}")))
        })
        .find(|candidate| is_program(candidate))
}

/// Whether `at` is a file this user may run.
#[cfg(unix)]
fn is_program(at: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    at.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Whether `at` is a file (Windows runs any file of a program's extension).
#[cfg(not(unix))]
fn is_program(at: &Path) -> bool {
    at.is_file()
}

#[cfg(all(test, unix))]
#[path = "launch_family_tests.rs"]
mod tests;
