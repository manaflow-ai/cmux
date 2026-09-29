// Stamp the binary with a build id so peers can tell whether they run the
// same code: <git short hash>[+dirty] <UTC date>. The crate lives inside the
// cmux repository, so git paths are resolved by git and the dirty check is
// limited to this crate's directory.
use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    Command::new("git").args(args).output().ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
}

fn main() {
    let hash = git(&["rev-parse", "--short=9", "HEAD"]).unwrap_or_else(|| "nogit".into());
    let dirty = git(&["status", "--porcelain", "--untracked-files=no", "--", "."]).is_some_and(|s| !s.is_empty());
    let date = Command::new("date").args(["-u", "+%Y-%m-%d"]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned()).unwrap_or_default();
    println!("cargo:rustc-env=ACPMUX_BUILD={hash}{} {date}", if dirty { "+dirty" } else { "" });
    for path in ["HEAD", "index"] {
        if let Some(p) = git(&["rev-parse", "--path-format=absolute", "--git-path", path]) {
            println!("cargo:rerun-if-changed={p}");
        }
    }
    println!("cargo:rerun-if-changed=src");
}
