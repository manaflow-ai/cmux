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
    if runner_work(path) {
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

/// Whether `path` is under a CI runner's `_work` folder: an `_work` inside an
/// `actions-runner*` folder, or one with the runner's `_diag` beside it. A
/// person's own folder named `_work` is not one.
fn runner_work(path: &Path) -> bool {
    path.ancestors().skip(1).any(|dir| {
        dir.file_name() == Some(std::ffi::OsStr::new("_work"))
            && dir.parent().is_some_and(|runner| {
                runner
                    .file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with("actions-runner"))
                    || runner.join("_diag").is_dir()
            })
    })
}

/// Whether `exe` is an app's bundled binary (`X.app/Contents/...`), or runs
/// from macOS App Translocation (a quarantined app opened where it was
/// downloaded runs from `/private/var/folders/.../AppTranslocation/<id>/d/`).
/// The app owns such a daemon's life: never refused, only warned about.
fn bundled(exe: &Path) -> bool {
    let names: Vec<_> = exe
        .components()
        .filter_map(|c| match c {
            Component::Normal(n) => Some(n.to_string_lossy()),
            _ => None,
        })
        .collect();
    names.iter().any(|n| n == "AppTranslocation")
        || names.windows(2).any(|w| w[0].ends_with(".app") && w[1] == "Contents")
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
        Unstable::RunnerWork | Unstable::Temp if !allow && !bundled(exe) => {
            Verdict::Refuse(format!(
                "{line}. Refused for {}: install acpmux (`acpmux host setup HOST` from another machine, \
             or copy it to ~/.local/bin/acpmux) and run that, give this one its own ACPMUX_HOME, \
             or pass {ALLOW_FLAG} ({ALLOW_ENV}=1)",
                home.display()
            ))
        }
        _ => Verdict::Warn(line),
    }
}

/// Whether this process was told to start from an unstable path anyway.
pub fn allowed_by_env() -> bool {
    std::env::var(ALLOW_ENV).as_deref() == Ok("1")
}

/// `path` with links, `.` and `..` resolved: the path itself when it exists, else its folder's
/// resolution and its name (a home not created yet), else as given. So `~/x/../.acpmux` is the
/// default home and a linked `$TMPDIR` is the folder it names.
fn resolved(path: &Path) -> std::path::PathBuf {
    if let Ok(real) = std::fs::canonicalize(path) {
        return real;
    }
    match (path.parent().and_then(|p| std::fs::canonicalize(p).ok()), path.file_name()) {
        (Some(parent), Some(name)) => parent.join(name),
        _ => path.to_path_buf(),
    }
}

/// The verdict for this process's own executable and home.
pub fn current(allow: bool) -> Verdict {
    let Ok(exe) = std::env::current_exe() else { return Verdict::Stable };
    verdict(
        &resolved(&exe),
        &resolved(&crate::config::home()),
        &resolved(&crate::config::default_home()),
        &resolved(&std::env::temp_dir()),
        allow || allowed_by_env(),
    )
}

/// Why this process's executable is not a stable install (`daemon status`'s
/// `exeUnstable`), or None.
pub fn current_unstable() -> Option<&'static str> {
    let exe = std::env::current_exe().ok()?;
    classify(&resolved(&exe), &resolved(&std::env::temp_dir())).map(Unstable::word)
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
    fn an_app_bundle_is_never_refused_even_translocated() {
        // A quarantined cmux.app opened from ~/Downloads: its first launch must start the daemon.
        let translocated = "/private/var/folders/xc/abc/T/AppTranslocation/0F1E2D3C/d/cmux.app/Contents/Resources/bin/acpmux";
        assert!(matches!(v(translocated, "/Users/cmux/.acpmux", false), Verdict::Warn(_)));
        let dev_app_in_tmp = "/tmp/abr-1/app/cmux DEV x.app/Contents/Resources/bin/acpmux";
        assert!(matches!(v(dev_app_in_tmp, "/Users/cmux/.acpmux", false), Verdict::Warn(_)));
        // Not a bundle: a folder that only ends in .app, with no Contents under it.
        assert!(matches!(v("/tmp/x.app/acpmux", "/Users/cmux/.acpmux", false), Verdict::Refuse(_)));
    }

    #[test]
    fn only_a_runner_work_folder_counts_not_any_folder_named_work() {
        assert_eq!(
            classify(Path::new("/Users/leo/clients/_work/bin/acpmux"), Path::new(TMP)),
            None
        );
        assert_eq!(
            v("/Users/leo/clients/_work/bin/acpmux", "/Users/cmux/.acpmux", false),
            Verdict::Stable
        );
        // An `_work` with the runner's `_diag` beside it, whatever the runner folder is called.
        let root = std::env::temp_dir().join(format!("acpmux-exe-path-{}", std::process::id()));
        std::fs::create_dir_all(root.join("runner/_diag")).unwrap();
        let exe = root.join("runner/_work/cmux/target/release/acpmux");
        assert_eq!(classify(&exe, Path::new(TMP)), Some(Unstable::RunnerWork));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_home_spelled_with_dot_dot_or_through_a_link_is_resolved() {
        let root = std::env::temp_dir().join(format!("acpmux-exe-resolve-{}", std::process::id()));
        std::fs::create_dir_all(root.join("home/x")).unwrap();
        let real = resolved(&root.join("home"));
        // A home not created yet, spelled with `..`, is the default home.
        assert_eq!(resolved(&root.join("home/x/../.acpmux")), real.join(".acpmux"));
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.join("home"), root.join("link")).unwrap();
            assert_eq!(resolved(&root.join("link/.acpmux")), real.join(".acpmux"));
        }
        let _ = std::fs::remove_dir_all(&root);
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
