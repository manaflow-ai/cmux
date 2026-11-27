//! Which binary a command starts the daemon from, and whether the daemon that answers after a
//! restart runs it.
//!
//! A command starts the daemon from its own binary (`SelfCommand::current`), never from whatever
//! `acpmux` names on PATH. For the person's shared home (`~/.acpmux`) a strictly newer install
//! wins over the caller's own build: the installed cmux NIGHTLY bundle's `acpmux` and
//! `~/.local/bin/acpmux`, compared by the commit time each binary carries
//! (`acpmux-commit-time=<secs>;`, acpmux-build-id's `COMMIT_STAMP`). An older client then
//! starts the newer build instead of bringing its own back. A tie, an unknown commit time or any
//! other home keeps the caller's own binary.
//!
//! On 2026-11-22 a `daemon restart` from the NIGHTLY bundle (build 9d9419a91) came back as
//! `~/.local/bin/acpmux daemon run --ready-fd 13`, an older build (75d22c950): between the old
//! daemon's exit and the restart's own start, a client of that older build reconnected and
//! started its own binary. `restart` therefore checks the daemon that answers
//! ([`stale_winner`]) and restarts once more when an older build won the race.

#![cfg_attr(not(unix), allow(dead_code))]

use std::io::Read as _;
use std::path::{Path, PathBuf};

use crate::self_command::SelfCommand;

/// The bundled `acpmux` of the installed cmux NIGHTLY app.
#[cfg(target_os = "macos")]
const NIGHTLY_ACPMUX: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";

/// A binary the daemon could start from, with its embedded commit time (None: unreadable or
/// unstamped).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Candidate {
    pub exe: PathBuf,
    pub commit_time: Option<u64>,
}

/// The binary a start runs and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Choice {
    pub this: SelfCommand,
    /// The chosen binary's commit time, when known.
    pub commit_time: Option<u64>,
    pub why: String,
}

/// Pick between this command's own binary and `others`: the newest strictly newer one, else
/// `own`. A candidate whose commit time is unknown is never picked, and nothing replaces an own
/// binary whose commit time is unknown (no guess).
pub(crate) fn choose(own: &Candidate, others: &[Candidate]) -> (Option<usize>, String) {
    let Some(own_time) = own.commit_time.filter(|t| *t > 0) else {
        return (None, "this command's own binary (its commit time is unknown)".to_owned());
    };
    let newest = others
        .iter()
        .enumerate()
        .filter_map(|(i, c)| c.commit_time.filter(|t| *t > own_time).map(|t| (i, t)))
        .max_by_key(|(_, t)| *t);
    match newest {
        Some((i, t)) => (
            Some(i),
            format!(
                "{} is a newer build (commit time {t}) than this command's {} ({own_time})",
                others[i].exe.display(),
                own.exe.display()
            ),
        ),
        None => (None, "this command's own binary (no installed build is newer)".to_owned()),
    }
}

/// What this command starts the daemon of `home` from (see the module docs).
pub(crate) fn current(home: &Path) -> std::io::Result<Choice> {
    let this = SelfCommand::current()?;
    if !super::is_shared_home(home) {
        return Ok(Choice {
            this,
            commit_time: None,
            why: "this command's own binary (not the shared home)".to_owned(),
        });
    }
    let own = Candidate { commit_time: commit_time_of(&this.program()), exe: this.exe.clone() };
    let others: Vec<Candidate> = installed_candidates()
        .into_iter()
        .filter(|exe| usable(exe) && !same_file(exe, &own.exe))
        .map(|exe| Candidate { commit_time: commit_time_of(&exe), exe })
        .collect();
    let (picked, why) = choose(&own, &others);
    Ok(match picked {
        // A candidate is a standalone `acpmux`: no `acp` prefix.
        Some(i) => Choice {
            this: SelfCommand::new(others[i].exe.clone(), Vec::new()),
            commit_time: others[i].commit_time,
            why,
        },
        None => Choice { this, commit_time: own.commit_time, why },
    })
}

/// The installed builds a shared-home start considers beside its own.
fn installed_candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    #[cfg(target_os = "macos")]
    out.push(PathBuf::from(NIGHTLY_ACPMUX));
    if let Some(home) = dirs::home_dir() {
        out.push(home.join(".local/bin/acpmux"));
    }
    out
}

/// A runnable regular file at a stable install path (`exe_path::classify`).
fn usable(exe: &Path) -> bool {
    #[cfg(unix)]
    let runnable = {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::metadata(exe).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    #[cfg(not(unix))]
    let runnable = exe.is_file();
    runnable && super::exe_path::classify(exe, &std::env::temp_dir()).is_none()
}

/// Whether `a` and `b` resolve to the same file.
pub(crate) fn same_file(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

/// The commit time a binary's `acpmux-commit-time=<secs>;` stamp names, read from its bytes as
/// the host install script's `acpmux_ct` reads it; None without one.
pub(crate) fn embedded_commit_time(bytes: &[u8]) -> Option<u64> {
    const KEY: &[u8] = b"acpmux-commit-time=";
    let mut from = 0;
    while let Some(i) = memchr::memmem::find(bytes.get(from..)?, KEY) {
        let start = from.saturating_add(i).saturating_add(KEY.len());
        let rest = bytes.get(start..)?;
        let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
        if digits > 0 && rest.get(digits) == Some(&b';') {
            return std::str::from_utf8(rest.get(..digits)?).ok()?.parse().ok();
        }
        from = start;
    }
    None
}

/// [`embedded_commit_time`] of the file at `path`, read in chunks (a stamp split across two
/// chunks is still found); None when it cannot be read or carries none.
pub(crate) fn commit_time_of(path: &Path) -> Option<u64> {
    const CHUNK: usize = 1 << 20;
    // Longer than any stamp: `acpmux-commit-time=` and a u64 and `;`.
    const OVERLAP: usize = 64;
    let mut file = std::fs::File::open(path).ok()?;
    let mut buf = vec![0u8; CHUNK + OVERLAP];
    let mut kept = 0;
    loop {
        let n = file.read(&mut buf[kept..]).ok()?;
        if n == 0 {
            return embedded_commit_time(&buf[..kept]);
        }
        let filled = kept + n;
        if let Some(t) = embedded_commit_time(&buf[..filled]) {
            return Some(t);
        }
        kept = filled.min(OVERLAP);
        buf.copy_within(filled - kept..filled, 0);
    }
}

/// Whether the daemon that answered a restart (`status.exe`, `status.build`, the commit time of
/// its binary) is an older build than the one the restart chose: another client of an older
/// build started it first. The same file, the restarting command's own build, or an unknown
/// commit time on either side is never stale.
pub(crate) fn stale_winner(
    choice: &Choice,
    own_build: &str,
    daemon_exe: Option<&Path>,
    daemon_build: Option<&str>,
    daemon_commit_time: Option<u64>,
) -> bool {
    let Some(daemon_exe) = daemon_exe else { return false };
    if same_file(daemon_exe, &choice.this.exe) || daemon_build == Some(own_build) {
        return false;
    }
    matches!((daemon_commit_time, choice.commit_time), (Some(d), Some(c)) if d < c)
}

#[cfg(test)]
#[path = "start_exe_tests.rs"]
mod tests;
