//! Why the doctor's command step failed: the exact problem with the
//! profile's program and the one change that fixes it.

use std::path::{Path, PathBuf};

use crate::config::Config;

/// (detail, fix) for a program that `resolve_program` did not accept.
/// `workdir` is a folder profile's folder (relative paths start there).
/// `profile_file` is the folder profile's file when it is one.
pub(crate) fn problem(
    cfg: &Config,
    id: &str,
    program: &str,
    workdir: Option<&Path>,
    profile_file: Option<&str>,
) -> (String, String) {
    let profile = profile_file
        .map(str::to_owned)
        .or_else(|| cfg.profile_meta.get(id).map(|m| m.source_path.clone()))
        .unwrap_or_else(|| "the profile".into());
    if program.is_empty() {
        return (
            "the profile has no command".into(),
            format!("set command = \"<program>\" in {profile}"),
        );
    }
    if !program.contains('/') {
        return (format!("`{program}` is not on PATH"), super::install_hint(cfg, id, program));
    }
    let path = match workdir {
        Some(base) if !Path::new(program).is_absolute() => base.join(program),
        _ => PathBuf::from(program),
    };
    let shown = path.display();
    if std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink())
        && std::fs::metadata(&path).is_err()
    {
        return (
            format!("{shown} is a link to a file that does not exist"),
            format!("reinstall the program, or set command to its real path in {profile}"),
        );
    }
    match std::fs::metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (
            format!("no file at {shown}"),
            format!("install the program there, or set command to its real path in {profile}"),
        ),
        Err(e) => (format!("{shown}: {e}"), format!("check the command path in {profile}")),
        Ok(m) if !m.is_file() => (
            format!("{shown} is not a file"),
            format!("set command to the program file, not a folder, in {profile}"),
        ),
        Ok(_) => (format!("{shown} is not executable"), format!("chmod +x {}", quoted(&path))),
    }
}

/// A path as one shell word.
fn quoted(path: &Path) -> String {
    let s = path.to_string_lossy();
    if s.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+@:,".contains(c)) {
        s.into_owned()
    } else {
        format!("'{}'", s.replace('\'', r"'\''"))
    }
}
