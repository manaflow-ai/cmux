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
//! [`ALLOW_ENV`]`=1` says so, and warns from a
//! build tree (`target/`, `DerivedData`). Every other home (a tagged Debug
//! app's, an iOS e2e rig's, a test's, which run from build trees on purpose)
//! starts quietly; `daemon status` still reports `exeUnstable`.
//!
//! A DEV app (`cmux DEV.app`, `cmux DEV <tag>.app`, wherever it is installed)
//! has a home of its own. It neither starts nor stops a daemon of NIGHTLY's
//! homes (`~/.acpmux` and NIGHTLY's Chief's). The app's environment resolution
//! keeps it away. These checks are the backstop: a daemon refuses a stop from any
//! DEV build, even one from before this rule, and a DEV binary with this rule
//! refuses to start there (cmux#29050).

use std::path::{Component, Path};

/// Set to `1` to start a daemon from an unstable path anyway.
pub const ALLOW_ENV: &str = "ACPMUX_ALLOW_UNSTABLE_PATH";

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
        || names
            .windows(2)
            .any(|w| matches!(w, [app, next] if app.ends_with(".app") && *next == "Contents"))
}

/// Whether `exe` belongs to a DEV app: an app bundle (or its signing clone) named `cmux DEV`,
/// tagged (`cmux DEV <tag>`) or not.
fn dev_app(exe: &Path) -> bool {
    exe.components().any(|c| match c {
        Component::Normal(n) => {
            let name = n.to_string_lossy();
            let bundle = name.strip_suffix(".app.bundle").or_else(|| name.strip_suffix(".app"));
            bundle.is_some_and(|b| b == "cmux DEV" || b.starts_with("cmux DEV "))
        }
        _ => false,
    })
}

/// Whether `home` is one of NIGHTLY's daemon homes on this machine: `~/.acpmux`, or its Chief's
/// `~/.cmux/chief/default/acpmux`. A home in a temporary folder (a test's `HOME`) is not.
fn nightly_home(home: &Path, default_home: &Path, temp_dir: &Path) -> bool {
    if classify(home, temp_dir).is_some() {
        return false;
    }
    home == default_home
        || default_home.parent().is_some_and(|user| {
            home == cmux_agent_pane_policy::build_identity::chief_homes_root(user)
                .join("default/acpmux")
        })
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
/// person's `~/.acpmux`; `verified_clone` comes only from the signature verifier.
/// A default home that itself sits in a temporary
/// folder (a test's `HOME`) is not the person's.
pub fn verdict(
    exe: &Path,
    home: &Path,
    default_home: &Path,
    temp_dir: &Path,
    allow: bool,
    verified_clone: bool,
) -> Verdict {
    if !allow && dev_app(exe) && nightly_home(home, default_home, temp_dir) {
        return Verdict::Refuse(format!(
            "acpmux: refused to start a daemon for {} from the DEV build {}: that home is cmux \
             NIGHTLY's. A DEV build runs in an ACPMUX_HOME of its own; \
             {ALLOW_ENV}=1 overrides this",
            home.display(),
            exe.display()
        ));
    }
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
        Unstable::RunnerWork | Unstable::Temp
            if !(allow || bundled(exe) || why == Unstable::Temp && verified_clone) =>
        {
            Verdict::Refuse(format!(
                "{line}. Refused for {}: install acpmux (`acpmux machine setup HOST` from another machine, \
             or copy it to ~/.local/bin/acpmux) and run that, give this one its own ACPMUX_HOME, \
             or set {ALLOW_ENV}=1",
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
fn current(allow: bool) -> Verdict {
    let Ok(exe) = std::env::current_exe() else { return Verdict::Stable };
    verdict(
        &resolved(&exe),
        &resolved(&crate::config::home()),
        &resolved(&crate::config::default_home()),
        &resolved(&std::env::temp_dir()),
        allow || allowed_by_env(),
        cmux_link::app_caller::verified_clone_executable(&exe).is_some(),
    )
}

/// Why this process's executable is not a stable install (`daemon status`'s
/// `exeUnstable`), or None.
pub fn current_unstable() -> Option<&'static str> {
    let exe = std::env::current_exe().ok()?;
    classify(&resolved(&exe), &resolved(&std::env::temp_dir())).map(Unstable::word)
}

/// Before a client starts a daemon (its auto-start, `daemon start`): refuse,
/// or print and log the warning. A client allowed by [`ALLOW_ENV`] hands it to
/// the daemon it starts (its environment, or the launchd job's in
/// `login_session.rs`).
pub fn check_start() -> anyhow::Result<()> {
    match current(false) {
        Verdict::Stable => Ok(()),
        Verdict::Warn(line) => {
            eprintln!("{line}");
            tracing::warn!("{line}");
            Ok(())
        }
        Verdict::Refuse(line) => Err(anyhow::anyhow!(line)),
    }
}

/// `daemon run`, before it takes the lock: [`check_start`], and on a refusal
/// `{"ready":false,"refused":TEXT}` on the readiness descriptor, so the
/// launcher (a client, the app, the mux host) shows why ([`refused_line`]).
pub fn check_run(ready_fd: Option<i32>) -> anyhow::Result<()> {
    check_start().inspect_err(|e| {
        if let Some(fd) = ready_fd {
            super::write_ready(
                fd,
                &serde_json::json!({"ready": false, "refused": format!("{e:#}")}),
            );
        }
    })
}

/// The refusal a started daemon wrote on its readiness line, if it refused.
pub fn refused_line(ready: &str) -> Option<String> {
    let line: serde_json::Value = serde_json::from_str(ready.trim()).ok()?;
    line.get("refused").and_then(serde_json::Value::as_str).map(str::to_owned)
}

/// Test runners: `swift test` runs Swift Testing in `swiftpm-testing-helper`, XCTest in `xctest`.
const TEST_RUNNERS: &[&str] = &["swiftpm-testing-helper", "xctest"];

/// Why a client run from `peer_exe` may not stop the daemon of `home` (`_acpmux/shutdown`), or
/// None. Only the person's own home is guarded, as in [`verdict`]: a test runner never stops it,
/// and a client from a runner `_work` or a temporary folder does not unless `allow`
/// ([`ALLOW_ENV`] in the daemon's own environment; a client cannot grant it) or it is an app's
/// bundled binary. A tagged DEV app never stops a daemon of NIGHTLY's homes (`~/.acpmux`, its Chief's)
/// either, unless `allow`: on 2026-11-02 agent-launched DEV apps took `~/.acpmux` from NIGHTLY
/// mid-turn (cmux#29050). On 2026-10-26 a `cmux-next swift test` job on a CI mini
/// (`swiftpm-testing-helper`, no `ACPMUX_HOME`) handed the mini's own `~/.acpmux` daemon off and
/// cycled daemons there until the run ended.
pub fn shutdown_refusal(
    peer_exe: &Path,
    home: &Path,
    default_home: &Path,
    temp_dir: &Path,
    allow: bool,
    verified_clone: bool,
) -> Option<String> {
    if !allow && dev_app(peer_exe) && nightly_home(home, default_home, temp_dir) {
        return Some(format!(
            "acpmux: refused to stop the daemon of {}: the request came from the DEV build {}, and \
             that home is cmux NIGHTLY's. A DEV build runs in an ACPMUX_HOME of its own; \
             a daemon started with {ALLOW_ENV}=1 allows this",
            home.display(),
            peer_exe.display()
        ));
    }
    if home != default_home || classify(home, temp_dir).is_some() {
        return None;
    }
    let name = peer_exe.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let refused = if TEST_RUNNERS.contains(&name.as_str()) {
        Some("a test runner")
    } else {
        match classify(peer_exe, temp_dir) {
            Some(why @ (Unstable::RunnerWork | Unstable::Temp))
                if !(allow || bundled(peer_exe) || why == Unstable::Temp && verified_clone) =>
            {
                Some(why.phrase())
            }
            _ => None,
        }
    }?;
    Some(format!(
        "acpmux: refused to stop the daemon of {}: the request came from {} ({}). A test or CI \
         job gives its client its own ACPMUX_HOME; a daemon started with {ALLOW_ENV}=1 allows a \
         client from an unstable path",
        home.display(),
        peer_exe.display(),
        refused
    ))
}

/// Whether a daemon run from `own_exe` takes `home` back from the daemon run from `holder_exe`
/// that holds its lock: a DEV build holds a home of NIGHTLY's and this start is no DEV build.
/// [`verdict`] and [`shutdown_refusal`] keep a DEV build with those rules out, but a DEV build from
/// before them can still start there while the home is free, and clients then use it as the
/// home's daemon (cmux#29050: 28 DEV daemons in `~/.acpmux` between 2026-10-31 and 2026-11-03).
pub fn reclaims_home(holder_exe: &Path, own_exe: &Path, home: &Path, default_home: &Path, temp_dir: &Path) -> bool {
    dev_app(holder_exe) && !dev_app(own_exe) && nightly_home(home, default_home, temp_dir)
}

/// [`reclaims_home`] for this process's own executable and home.
pub fn current_reclaims_home(holder_exe: &Path) -> bool {
    let Ok(exe) = std::env::current_exe() else { return false };
    reclaims_home(
        &resolved(holder_exe),
        &resolved(&exe),
        &resolved(&crate::config::home()),
        &resolved(&crate::config::default_home()),
        &resolved(&std::env::temp_dir()),
    )
}

/// [`shutdown_refusal`] for this daemon's home and a Unix socket peer, whose executable its audit
/// token names (macOS; elsewhere, and for a peer that exec'd since it connected, nothing is
/// known and nothing is refused).
pub fn peer_shutdown_refusal(
    peer: Option<&cmux_link::app_caller::PeerToken>,
    allow: bool,
) -> Option<String> {
    let peer = peer?;
    let exe = cmux_link::app_caller::executable_path(peer)?;
    shutdown_refusal(
        &resolved(&exe),
        &resolved(&crate::config::home()),
        &resolved(&crate::config::default_home()),
        &resolved(&std::env::temp_dir()),
        allow,
        cmux_link::app_caller::verified_clone_peer(peer).is_some(),
    )
}

#[cfg(test)]
#[path = "exe_path_tests.rs"]
mod tests;
