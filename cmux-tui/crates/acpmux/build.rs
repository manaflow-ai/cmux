// Stamp the binary with a build id so peers can tell whether they run the
// same code: <git short hash>[+dirty.<diff fingerprint>] <UTC date>, where the date
// comes from SOURCE_DATE_EPOCH when it is set. The crate lives inside the
// cmux repository, so git paths are resolved by git and the dirty check is
// limited to this crate's directory. Without git (a source archive) the hash
// comes from CMUX_GIT_SHORT_SHA and there is no dirty tag.
use std::process::Command;

#[path = "src/git_short_sha.rs"]
mod git_short_sha;
#[path = "src/source_date_epoch.rs"]
mod source_date_epoch;

fn git(args: &[&str]) -> Option<String> {
    Command::new("git")
        .args(args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
}

fn main() {
    // Git counts only when it tracks this crate, so an archive unpacked inside
    // some other repository does not take that repository's commit.
    let git_hash = git(&["ls-files", "--error-unmatch", "--", "build.rs"])
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
    for path in ["HEAD", "index"] {
        if let Some(p) = git(&["rev-parse", "--path-format=absolute", "--git-path", path]) {
            println!("cargo:rerun-if-changed={p}");
        }
    }
    // Everything the binary embeds, so the dirty check reruns for each.
    for dir in ["src", "docs", "web", "skills"] {
        println!("cargo:rerun-if-changed={dir}");
    }
}
