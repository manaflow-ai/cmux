// Stamp the binary with a build id so peers can tell whether they run the
// same code: <git short hash>[+dirty.<diff fingerprint>] <UTC date>. The crate lives inside the
// cmux repository, so git paths are resolved by git and the dirty check is
// limited to this crate's directory.
use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    Command::new("git")
        .args(args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
}

fn main() {
    let hash = git(&["rev-parse", "--short=9", "HEAD"]).unwrap_or_else(|| "nogit".into());
    let dirty = git(&["status", "--porcelain", "--untracked-files=no", "--", "."])
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
    let date = Command::new("date")
        .args(["-u", "+%Y-%m-%d"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default();
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
