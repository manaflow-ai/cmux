//! The path that runs this program again: the Chief's own re-runs (`move
//! --detach`, `move watch`, the pack login poller, each turn's MCP server and
//! `chief` shim, the agent-memory MCP entry) and its siblings in the same
//! directory (`acpmux`, `cmux`, `chief-codex`).
//!
//! The standalone `optchat-chief` binary is [`std::env::current_exe`], as
//! before. In the app bundle the Chief can also be the multicall `bin/cmux`
//! run through a link named `optchat-chief` beside it (CMUX-570): its
//! executable is then `cmux` (Linux resolves the link; so does a
//! `canonicalize`), and running that would start the cmux CLI. The multicall
//! binary calls [`run_as`] with its argv[0] first, and every re-run here
//! takes the link instead, so it runs as the Chief again.

use std::ffi::{OsStr, OsString};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The link this process runs as, when a multicall binary runs the Chief.
static FOLDED: OnceLock<PathBuf> = OnceLock::new();

/// Called once, first, by a multicall binary that runs the Chief because
/// argv[0]'s file name is the Chief's: re-runs take that path from now on.
pub fn run_as(argv0: &OsStr) {
    let cwd = std::env::current_dir().ok();
    let path = std::env::var_os("PATH");
    let exe = std::env::current_exe().ok();
    let _ = FOLDED.set(resolve(
        argv0,
        cwd.as_deref(),
        path.as_deref(),
        exe.as_deref(),
    ));
}

/// Whether a multicall binary runs this Chief ([`run_as`]).
pub fn folded() -> bool {
    FOLDED.get().is_some()
}

/// The path that runs this program again: [`std::env::current_exe`] for the
/// standalone binary, the link it was started through when folded.
pub fn path() -> io::Result<PathBuf> {
    match FOLDED.get() {
        Some(link) => Ok(link.clone()),
        None => std::env::current_exe(),
    }
}

/// [`path`] with symlinks resolved, as the host pins it for its turns: the
/// standalone binary's real file; when folded, the link's directory resolved
/// and its own name kept (resolving the link itself would name `cmux`).
pub fn canonical() -> io::Result<PathBuf> {
    match FOLDED.get() {
        Some(link) => keep_name_canonical(link),
        None => std::env::current_exe()?.canonicalize(),
    }
}

fn keep_name_canonical(link: &Path) -> io::Result<PathBuf> {
    let name = link
        .file_name()
        .ok_or_else(|| io::Error::other(format!("{} has no file name", link.display())))?;
    let dir = match link.parent() {
        Some(dir) if !dir.as_os_str().is_empty() => dir.canonicalize()?,
        _ => std::env::current_dir()?,
    };
    Ok(dir.join(name))
}

/// The file argv[0] names: a path (relative ones against the start
/// directory), else the first `PATH` entry holding that name, else the name
/// beside the running executable, else the bare name (found on `PATH` when
/// it runs).
fn resolve(argv0: &OsStr, cwd: Option<&Path>, path: Option<&OsStr>, exe: Option<&Path>) -> PathBuf {
    let named = Path::new(argv0);
    if named.components().count() > 1 || argv0.as_encoded_bytes().contains(&b'/') {
        return match cwd {
            Some(cwd) if named.is_relative() => cwd.join(named),
            _ => named.to_path_buf(),
        };
    }
    let on_path = path.and_then(|path| {
        std::env::split_paths(path)
            .map(|dir| dir.join(named))
            .find(|candidate| candidate.is_file())
    });
    let beside = || {
        exe.and_then(Path::parent)
            .map(|dir| dir.join(named))
            .filter(|candidate| candidate.is_file())
    };
    on_path
        .or_else(beside)
        .unwrap_or_else(|| PathBuf::from(OsString::from(argv0)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_in_argv0_is_kept_and_a_relative_one_is_made_absolute() {
        let cwd = Path::new("/start");
        assert_eq!(
            resolve(OsStr::new("/app/bin/optchat-chief"), Some(cwd), None, None),
            PathBuf::from("/app/bin/optchat-chief")
        );
        assert_eq!(
            resolve(OsStr::new("bin/optchat-chief"), Some(cwd), None, None),
            PathBuf::from("/start/bin/optchat-chief")
        );
        assert_eq!(
            resolve(OsStr::new("./optchat-chief"), Some(cwd), None, None),
            PathBuf::from("/start/./optchat-chief")
        );
    }

    #[test]
    fn a_bare_name_is_found_on_path_then_beside_the_executable() {
        let dir = tempfile::tempdir().unwrap();
        let on_path = dir.path().join("on-path");
        let bundle = dir.path().join("bin");
        std::fs::create_dir_all(&on_path).unwrap();
        std::fs::create_dir_all(&bundle).unwrap();
        std::fs::write(bundle.join("cmux"), b"").unwrap();
        std::fs::write(bundle.join("optchat-chief"), b"").unwrap();
        let exe = bundle.join("cmux");
        let name = OsStr::new("optchat-chief");
        let path = std::env::join_paths([&on_path]).unwrap();
        // Not on PATH: the one beside the executable.
        assert_eq!(
            resolve(name, None, Some(&path), Some(&exe)),
            bundle.join("optchat-chief")
        );
        // On PATH: that one, as the shell ran it.
        std::fs::write(on_path.join("optchat-chief"), b"").unwrap();
        assert_eq!(
            resolve(name, None, Some(&path), Some(&exe)),
            on_path.join("optchat-chief")
        );
        // Nowhere: the bare name.
        assert_eq!(
            resolve(OsStr::new("absent"), None, Some(&path), Some(&exe)),
            PathBuf::from("absent")
        );
    }

    #[test]
    fn the_canonical_link_keeps_its_name_and_resolves_its_directory() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().canonicalize().unwrap().join("bin");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::write(real.join("cmux"), b"").unwrap();
        std::os::unix::fs::symlink("cmux", real.join("optchat-chief")).unwrap();
        let alias = dir.path().join("alias");
        std::os::unix::fs::symlink(&real, &alias).unwrap();
        assert_eq!(
            keep_name_canonical(&alias.join("optchat-chief")).unwrap(),
            real.join("optchat-chief")
        );
    }

    #[test]
    fn the_standalone_binary_is_its_own_executable() {
        // No multicall binary in a test process: the executable, as before.
        assert!(!folded());
        assert_eq!(path().unwrap(), std::env::current_exe().unwrap());
    }
}
