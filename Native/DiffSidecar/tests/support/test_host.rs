//! Stands in for the bundled cmux CLI that `--cmux` names in integration
//! tests. Branch facts come from cmux-git now, so the sidecar does not run it;
//! it still answers `git status --path <repo> --json` with the shape of the
//! session host's `git.status` result, reporting `HEAD` as the base branch.

fn main() {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    let arguments = arguments.iter().map(String::as_str).collect::<Vec<_>>();
    match arguments.as_slice() {
        ["git", "status", "--path", path, "--json"] => {
            if path.ends_with("no-base") {
                println!(
                    "{}",
                    serde_json::json!({"root": path, "detached": true, "ahead": 0, "behind": 0})
                );
                return;
            }
            println!(
                "{}",
                serde_json::json!({
                    "root": path,
                    "detached": false,
                    "ahead": 0,
                    "behind": 0,
                    "branch": "main",
                    "base": "HEAD",
                })
            );
        }
        _ => std::process::exit(2),
    }
}
