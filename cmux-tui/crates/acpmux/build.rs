// Stamp the binary with a build id so peers can tell whether they run the
// same code: <git short hash>[+dirty] <UTC date>.
use std::process::Command;

fn main() {
    let hash = Command::new("git").args(["rev-parse", "--short=9", "HEAD"]).output().ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned()).unwrap_or_else(|| "nogit".into());
    let dirty = Command::new("git").args(["status", "--porcelain", "--untracked-files=no"]).output().ok().map(|o| !o.stdout.is_empty()).unwrap_or(false);
    let date = Command::new("date").args(["-u", "+%Y-%m-%d"]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned()).unwrap_or_default();
    println!("cargo:rustc-env=ACPMUX_BUILD={hash}{} {date}", if dirty { "+dirty" } else { "" });
    println!("cargo:rerun-if-changed=.git/HEAD");
    println!("cargo:rerun-if-changed=.git/index");
    println!("cargo:rerun-if-changed=src");
}
