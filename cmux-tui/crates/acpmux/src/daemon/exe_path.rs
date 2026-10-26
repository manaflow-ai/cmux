//! Whether the daemon's own executable lives at a stable install path.
//!
//! A long-lived daemon must run from an install that outlives it:
//! `~/.local/bin/acpmux` (what `host setup`, `host enroll` and `host update`
//! install) or an installed cmux app bundle. On 2026-10-23 a sweep ran
//! `find ~ -name acpmux -exec {} ls --json` over ssh on the CI minis; each
//! `ls` auto-started the shared `~/.acpmux` daemon from a CI runner checkout
//! (`actions-runner-*/_work/.../target/hosted/tree/<sha>/acpmux`). The
//! runner's `_work` cleanup then deleted a live daemon's binary, and the daemon
//! pinned 6-10 GB of `_work` it could not free.
//!
//! So a daemon for the person's own home (`~/.acpmux`) refuses to start from
//! a runner `_work` folder or a temporary folder unless
//! `--allow-unstable-path` (or [`ALLOW_ENV`]`=1`) says so, and warns from a
//! build tree (`target/`, `DerivedData`). Every other home (a tagged Debug
//! app's, an iOS e2e rig's, a test's, which run from build trees on purpose)
//! starts quietly; `daemon status` still reports `exeUnstable`.

use std::path::{Component, Path};

/// Set to `1` to start a daemon from an unstable path anyway.
pub const ALLOW_ENV: &str = "ACPMUX_ALLOW_UNSTABLE_PATH";

/// The flag `daemon run` takes for the same.
pub const ALLOW_FLAG: &str = "--allow-unstable-path";

/// Why an executable's location is not a stable install.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unstable {
    /// Under a CI runner's `_work` folder, which the runner cleans.
    RunnerWork,
    /// Under `/tmp`, `/private/tmp`, `/var/folders` or the temp folder.
    Temp,
    /// Under a build tree: a cargo `target` folder or Xcode's `DerivedData`.
    BuildTree,
}

impl Unstable {
    pub fn word(self) -> &'static str {
        match self {
            Self::RunnerWork => "runner-work",
            Self::Temp => "temp",
            Self::BuildTree => "build-tree",
        }
    }

    fn phrase(self) -> &'static str {
        match self {
            Self::RunnerWork => "a CI runner's _work folder, which the runner deletes",
            Self::Temp => "a temporary folder",
            Self::BuildTree => "a build tree",
        }
    }
}

/// Where `path` lives, when that is not a stable install.
pub fn classify(path: &Path, temp_dir: &Path) -> Option<Unstable> {
    let names: Vec<&std::ffi::OsStr> = path
        .components()
        .filter_map(|c| match c {
            Component::Normal(n) => Some(n),
            _ => None,
        })
        .collect();
    if names.iter().any(|n| *n == "_work") {
        return Some(Unstable::RunnerWork);
    }
    let temp_roots = [
        Path::new("/tmp"),
        Path::new("/private/tmp"),
        Path::new("/var/folders"),
        Path::new("/private/var/folders"),
    ];
    if temp_roots.iter().any(|root| path.starts_with(root))
        || (temp_dir.components().count() > 1 && path.starts_with(temp_dir))
    {
        return Some(Unstable::Temp);
    }
    if names.iter().any(|n| *n == "target" || *n == "DerivedData") {
        return Some(Unstable::BuildTree);
    }
    None
}

/// What starting a daemon from `exe` for state folder `home` does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// A stable install, or a home other than the person's own.
    Stable,
    Warn(String),
    Refuse(String),
}

/// The verdict for a daemon of `home` run from `exe`. `default_home` is the
/// person's `~/.acpmux`; a default home that itself sits in a temporary
/// folder (a test's `HOME`) is not the person's.
pub fn verdict(
    exe: &Path,
    home: &Path,
    default_home: &Path,
    temp_dir: &Path,
    allow: bool,
) -> Verdict {
    let Some(why) = classify(exe, temp_dir) else { return Verdict::Stable };
    if home != default_home || classify(home, temp_dir).is_some() {
        return Verdict::Stable;
    }
    let line = format!(
        "acpmux: this daemon's executable {} is in {}; a long-lived daemon should run from a stable \
         install (~/.local/bin/acpmux, or an installed cmux app)",
        exe.display(),
        why.phrase()
    );
    match why {
        Unstable::RunnerWork | Unstable::Temp if !allow => Verdict::Refuse(format!(
            "{line}. Refused for {}: install acpmux (`acpmux host setup HOST` from another machine, \
             or copy it to ~/.local/bin/acpmux) and run that, give this one its own ACPMUX_HOME, \
             or pass {ALLOW_FLAG} ({ALLOW_ENV}=1)",
            home.display()
        )),
        _ => Verdict::Warn(line),
    }
}

/// Whether this process was told to start from an unstable path anyway.
pub fn allowed_by_env() -> bool {
    std::env::var(ALLOW_ENV).as_deref() == Ok("1")
}

/// The verdict for this process's own executable and home.
pub fn current(allow: bool) -> Verdict {
    let Ok(exe) = std::env::current_exe() else { return Verdict::Stable };
    verdict(
        &exe,
        &crate::config::home(),
        &crate::config::default_home(),
        &std::env::temp_dir(),
        allow || allowed_by_env(),
    )
}

/// Why this process's executable is not a stable install (`daemon status`'s
/// `exeUnstable`), or None.
pub fn current_unstable() -> Option<&'static str> {
    std::env::current_exe()
        .ok()
        .and_then(|e| classify(&e, &std::env::temp_dir()))
        .map(Unstable::word)
}

/// Before starting a daemon (a client's auto-start, `daemon start`, `daemon
/// run`): refuse, or print and log the warning. A client allowed by
/// [`ALLOW_ENV`] hands it to the daemon it starts (its environment, or the
/// launchd job's in `login_session.rs`).
pub fn check_start(allow: bool) -> anyhow::Result<()> {
    match current(allow) {
        Verdict::Stable => Ok(()),
        Verdict::Warn(line) => {
            eprintln!("{line}");
            tracing::warn!("{line}");
            Ok(())
        }
        Verdict::Refuse(line) => Err(anyhow::anyhow!(line)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const TMP: &str = "/var/folders/xc/abc/T";

    fn v(exe: &str, home: &str, allow: bool) -> Verdict {
        verdict(
            Path::new(exe),
            Path::new(home),
            Path::new("/Users/cmux/.acpmux"),
            Path::new(TMP),
            allow,
        )
    }

    #[test]
    fn the_runner_checkout_daemon_of_2026_10_23_is_refused_in_the_default_home() {
        let exe = "/Users/cmux/actions-runner-glaeda-2/_work/cmux/cmux/cmux-tui/target/hosted/tree/1e704e95/acpmux";
        assert_eq!(classify(Path::new(exe), Path::new(TMP)), Some(Unstable::RunnerWork));
        assert!(matches!(v(exe, "/Users/cmux/.acpmux", false), Verdict::Refuse(_)));
        assert!(matches!(v(exe, "/Users/cmux/.acpmux", true), Verdict::Warn(_)));
        // Its own home (a CI step's): quiet.
        assert_eq!(v(exe, "/Users/cmux/ci-home/.acpmux", false), Verdict::Stable);
    }

    #[test]
    fn temp_folders_are_refused_in_the_default_home() {
        for exe in [
            "/tmp/abr-1/app/bin/acpmux",
            "/private/tmp/x/acpmux",
            "/var/folders/xc/abc/T/a/acpmux",
            "/private/var/folders/xc/abc/T/a/acpmux",
        ] {
            assert_eq!(classify(Path::new(exe), Path::new(TMP)), Some(Unstable::Temp), "{exe}");
            assert!(matches!(v(exe, "/Users/cmux/.acpmux", false), Verdict::Refuse(_)), "{exe}");
        }
        let linux_tmp = verdict(
            Path::new("/run/user/1000/tmp/acpmux"),
            Path::new("/home/l/.acpmux"),
            Path::new("/home/l/.acpmux"),
            Path::new("/run/user/1000/tmp"),
            false,
        );
        assert!(matches!(linux_tmp, Verdict::Refuse(_)));
    }

    #[test]
    fn build_trees_only_warn_even_in_the_default_home() {
        for exe in [
            "/Users/leo/cmux/cmux-tui/target/release/acpmux",
            "/Users/cmux/Library/Developer/Xcode/DerivedData/cmux-x/Build/Products/Debug/cmux DEV x.app/Contents/Resources/bin/acpmux",
        ] {
            assert_eq!(
                classify(Path::new(exe), Path::new(TMP)),
                Some(Unstable::BuildTree),
                "{exe}"
            );
            assert!(matches!(v(exe, "/Users/cmux/.acpmux", false), Verdict::Warn(_)), "{exe}");
        }
    }

    #[test]
    fn stable_installs_pass() {
        for exe in [
            "/Users/cmux/.local/bin/acpmux",
            "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux",
            "/home/leo/.local/share/acpmux-supervised/acpmux",
            "/opt/cmux/bin/cmux-tui",
        ] {
            assert_eq!(classify(Path::new(exe), Path::new(TMP)), None, "{exe}");
            assert_eq!(v(exe, "/Users/cmux/.acpmux", false), Verdict::Stable, "{exe}");
        }
        // A word that only contains `target` or `_work` is not one of those folders.
        assert_eq!(classify(Path::new("/opt/targets/my_work/acpmux"), Path::new(TMP)), None);
    }

    #[test]
    fn a_test_home_under_a_temp_folder_is_not_the_persons() {
        // cargo tests on a runner: the binary under _work, HOME and the home in a temp folder.
        let home = PathBuf::from(TMP).join("t1/.acpmux");
        let exe =
            "/Users/cmux/actions-runner-glaeda-2/_work/cmux/cmux/cmux-tui/target/debug/acpmux";
        let got = verdict(Path::new(exe), &home, &home, Path::new(TMP), false);
        assert_eq!(got, Verdict::Stable);
    }
}
