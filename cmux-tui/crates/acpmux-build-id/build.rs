// Stamp acpmux with a build id so peers can tell whether they run the
// same code: <git short hash>[+dirty.<diff fingerprint>] <UTC date>, where the date
// comes from SOURCE_DATE_EPOCH when it is set. acpmux lives inside the
// cmux repository, so git paths are resolved by git and the dirty check is
// limited to the acpmux crate's directory (../acpmux). Without git (a source
// archive) the hash comes from CMUX_GIT_SHORT_SHA and there is no dirty tag.
//
// This script is in its own leaf crate, not in acpmux: a build script that
// reruns makes Cargo recompile every target of its package, and this one
// reruns on every new stamp (CMUX_GIT_SHORT_SHA, SOURCE_DATE_EPOCH) and every
// commit. See src/lib.rs.
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

#[path = "src/git_short_sha.rs"]
mod git_short_sha;
#[path = "src/source_date_epoch.rs"]
mod source_date_epoch;

/// The acpmux crate: every git call runs there, as when this script was
/// acpmux's own.
fn acpmux_dir() -> &'static Path {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        let manifest = std::env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is unset");
        Path::new(&manifest)
            .parent()
            .expect("acpmux-build-id has no parent directory")
            .join("acpmux")
    })
}

fn git(args: &[&str]) -> Option<String> {
    Command::new("git")
        .current_dir(acpmux_dir())
        .args(args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
}

fn main() {
    // Git counts only when it tracks this crate, so an archive unpacked inside
    // some other repository does not take that repository's commit.
    let git_hash = git(&["ls-files", "--error-unmatch", "--", "Cargo.toml"])
        .and_then(|_| git(&["rev-parse", "--short=9", "HEAD"]));
    println!("cargo:rerun-if-env-changed=CMUX_GIT_SHORT_SHA");
    let env_hash = match std::env::var("CMUX_GIT_SHORT_SHA") {
        Ok(raw) => match git_short_sha::validate(&raw) {
            Ok(v) => Some(v.to_owned()),
            Err(e) => panic!("acpmux build: {e}"),
        },
        Err(std::env::VarError::NotUnicode(raw)) => {
            panic!("acpmux build: CMUX_GIT_SHORT_SHA={raw:?} is not valid Unicode")
        }
        Err(std::env::VarError::NotPresent) => None,
    };
    let (hash, warning) = git_short_sha::choose(git_hash.as_deref(), env_hash.as_deref());
    if let Some(w) = warning {
        println!("cargo:warning={w}");
    }
    let dirty = git_hash.is_some()
        && git(&["status", "--porcelain", "--untracked-files=no", "--", "."])
            .is_some_and(|s| !s.is_empty());
    // Two dirty trees at one commit differ in their diff; fingerprint it so
    // their build ids differ too.
    let dirty_tag = if dirty {
        let diff = git(&["diff", "--no-ext-diff", "HEAD", "--", "."]).unwrap_or_default();
        let mut fp: u64 = 0xcbf2_9ce4_8422_2325;
        for b in diff.bytes() {
            fp ^= b as u64;
            fp = fp.wrapping_mul(0x0100_0000_01b3);
        }
        format!("+dirty.{:08x}", fp as u32)
    } else {
        String::new()
    };
    // Reproducible builds pin the date with SOURCE_DATE_EPOCH
    // (reproducible-builds.org/specs/source-date-epoch). A malformed value
    // fails the build, as that spec asks, rather than silently embedding the
    // wall-clock date into a build that was meant to be reproducible.
    println!("cargo:rerun-if-env-changed=SOURCE_DATE_EPOCH");
    let date = match std::env::var("SOURCE_DATE_EPOCH") {
        Ok(raw) => match source_date_epoch::parse(&raw) {
            Ok(secs) => source_date_epoch::utc_date(secs),
            Err(e) => panic!("acpmux build: {e}"),
        },
        Err(std::env::VarError::NotUnicode(raw)) => {
            panic!("acpmux build: SOURCE_DATE_EPOCH={raw:?} is not valid Unicode")
        }
        Err(std::env::VarError::NotPresent) => Command::new("date")
            .args(["-u", "+%Y-%m-%d"])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
            .unwrap_or_default(),
    };
    println!("cargo:rustc-env=ACPMUX_BUILD={hash}{dirty_tag} {date}");
    // The commit: HEAD, the branch ref it names, packed-refs, and logs/HEAD
    // (every commit, amend, reset, rebase and checkout appends to it, also
    // when the branch ref is packed and no loose ref file exists yet). Not
    // .git/index: `git status` and `git diff HEAD` rewrite it on a stat
    // refresh, including the calls in this script and cmux-remote's, so
    // tracking it reran both scripts on an unchanged tree (bin no-op 6.2-6.4 s,
    // 0.22 s without it, measured on a Testbox 2026-10-13). Cost: staging
    // alone (`git add` of a new file, `git rm --cached`) no longer refreshes
    // the dirty tag until the next source change or commit; the binary is the
    // same. Only paths that exist: Cargo reruns a script on every build for a
    // missing path.
    // reftable/tables.list is the ref store of a reftable repository.
    let mut git_paths = vec![
        "HEAD".to_owned(),
        "packed-refs".to_owned(),
        "logs/HEAD".to_owned(),
        "reftable/tables.list".to_owned(),
    ];
    if let Some(reference) = git(&["symbolic-ref", "-q", "HEAD"]) {
        git_paths.push(reference);
    }
    for path in &git_paths {
        if let Some(p) = git(&["rev-parse", "--path-format=absolute", "--git-path", path])
            && Path::new(&p).exists()
        {
            println!("cargo:rerun-if-changed={p}");
        }
    }
    // Everything the binary embeds, so the dirty check reruns for each.
    for dir in
        ["src", "docs", "web", "skills", "catalog", "data", "harnesses", "sandbox", "Cargo.toml"]
    {
        println!("cargo:rerun-if-changed={}", acpmux_dir().join(dir).display());
    }
}
