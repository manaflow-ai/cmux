//! `_acpmux/customize_run`: the Try it on, Keep, Revert and Go buttons of a wrap-up card
//! (`wrap_up` actions of the form `{label, run}`, `acpmux_mcp_wrap_up.rs`). The page never names a
//! command: it sends one of four typed requests, which this turns into the argv of
//! `cmux customize try TARGET [--minutes N]`, `cmux customize keep`, `cmux customize revert` or
//! `cmux customize go pr:N` (the PR tried on is merge-ready at the head the person saw), run
//! without a shell. Leo, 2026-11-25: "have that one click merge ready, or like one click readiness
//! to merge, like the go button for that to happen". The card's own Share button sends a fifth,
//! `{customize: "share", target}` ([`share_plan`]): the line that puts the same target on another
//! cmux. Every field is checked against a short allowlist first, so a call cannot
//! carry a flag or a second command. Leo, 2026-11-24: "A MOTHERFUCKING THING AT TURN END OF A WAY
//! TO TRY ON THE CUSTOMIZATION. FUCKING BOOM. AND A WAY TO SAVE IT OR SHARE IT."

use serde_json::{Value, json};
use std::time::Duration;

/// The longest a customize command may run (a `pr:N` try waits for a download).
const LIMIT: Duration = Duration::from_secs(180);
/// The longest a try-on may last, in minutes.
pub(crate) const MAX_MINUTES: u64 = 240;

/// Whether `target` names code or a profile `cmux customize try` takes: `pr:N`, `branch:B`,
/// `sha:S`, `dir:PATH`, or a profile NAME. Never a flag, never a control character.
pub(crate) fn valid_target(target: &str) -> bool {
    if target.is_empty() || target.len() > 400 || target.starts_with('-') {
        return false;
    }
    if target.chars().any(char::is_control) {
        return false;
    }
    let word = |s: &str, ok: fn(char) -> bool| !s.is_empty() && s.chars().all(ok);
    match target.split_once(':') {
        Some(("pr", n)) => word(n, |c| c.is_ascii_digit()),
        Some(("sha", s)) => word(s, |c| c.is_ascii_hexdigit()) && (7..=40).contains(&s.len()),
        Some(("branch", b)) => {
            word(b, |c| c.is_ascii_alphanumeric() || "._/-".contains(c)) && !b.starts_with('-')
        }
        Some(("dir", p)) => !p.is_empty() && !p.starts_with('-'),
        Some(_) => false,
        None => {
            word(target, |c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
        }
    }
}

/// The argv after `cmux` for the typed request `run`, or why it is refused.
pub(crate) fn argv(run: &Value) -> Result<Vec<String>, String> {
    let verb = run.get("customize").and_then(Value::as_str).unwrap_or_default();
    let mut out = vec!["customize".to_owned(), verb.to_owned()];
    match verb {
        "keep" | "revert" => {}
        "go" => {
            let target = run.get("target").and_then(Value::as_str).unwrap_or_default();
            match target.split_once(':') {
                Some(("pr", n)) if valid_target(target) && n.len() <= 9 => {
                    out.push(target.to_owned());
                }
                _ => return Err("go takes the PR tried on: pr:N".into()),
            }
        }
        "try" => {
            let target = run.get("target").and_then(Value::as_str).unwrap_or_default();
            if !valid_target(target) {
                return Err(
                    "target must be pr:N, branch:B, sha:S, dir:PATH or a profile name".into()
                );
            }
            out.push(target.to_owned());
            if let Some(minutes) = run.get("minutes").filter(|v| !v.is_null()) {
                let minutes = minutes
                    .as_u64()
                    .filter(|m| (1..=MAX_MINUTES).contains(m))
                    .ok_or_else(|| format!("minutes is a whole number from 1 to {MAX_MINUTES}"))?;
                out.extend(["--minutes".to_owned(), minutes.to_string()]);
            }
        }
        _ => return Err("customize is try, keep, revert or go".into()),
    }
    Ok(out)
}

/// How Share puts `target` on another cmux (RFD 0150 Save and Share): the line itself for code
/// anyone with the repo can fetch, a setup repo written from a saved profile, or the branch a
/// folder's checkout is pushed to. A wrap-up action never carries it: only the card's own Share
/// button sends `{customize: "share", target}` ([`argv`] refuses it, so `wrap_up` drops it).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Share {
    /// `pr:N`, `branch:B`, `sha:S`: `cmux customize try TARGET` as it is.
    Line(String),
    /// A profile NAME: `cmux setup export` of that profile alone, then its install line.
    Profile(String),
    /// `dir:PATH`: the checkout's pushed branch, when it has one.
    Dir(std::path::PathBuf),
}

/// The share plan for the typed request `run`, or why it is refused.
pub(crate) fn share_plan(run: &Value) -> Result<Share, String> {
    let target = run.get("target").and_then(Value::as_str).unwrap_or_default();
    if run.get("customize").and_then(Value::as_str) != Some("share") || !valid_target(target) {
        return Err(
            "share takes a target: pr:N, branch:B, sha:S, dir:PATH or a profile name".into()
        );
    }
    Ok(match target.split_once(':') {
        Some(("dir", path)) => Share::Dir(path.into()),
        Some(_) => Share::Line(format!("cmux customize try {target}")),
        None => Share::Profile(target.to_owned()),
    })
}

/// The folder a profile's setup repo is written in: `~/cmux-setups/NAME`, where the person can
/// look at it, push it, or hand it over. Nothing is uploaded.
pub(crate) fn share_folder(home: &std::path::Path, name: &str) -> std::path::PathBuf {
    home.join("cmux-setups").join(name)
}

/// The argv after `cmux` that writes the profile `name` as a setup repo in `dir`: its id is
/// `local/NAME` (a folder is no one's repo yet), and only that profile goes in.
pub(crate) fn export_argv(name: &str, dir: &std::path::Path) -> Vec<std::ffi::OsString> {
    let mut out: Vec<std::ffi::OsString> = ["setup", "export"].map(Into::into).into();
    out.push(dir.as_os_str().to_owned());
    for word in ["--id", &format!("local/{name}"), "--name", name, "--profile", name] {
        out.push(word.into());
    }
    out
}

/// The branch of manaflow-ai/cmux a checkout's HEAD is pushed to, from `git status -b
/// --porcelain=v2` and the upstream remote's URL: `None` when it tracks none, tracks a fork, or
/// is ahead of it (what is not pushed would not reach the other cmux).
pub(crate) fn pushed_branch(status: &str, remote_url: &str) -> Option<String> {
    let header =
        |key: &str| status.lines().find_map(|line| line.strip_prefix(&format!("# branch.{key} ")));
    let upstream = header("upstream")?;
    let (_, branch) = upstream.split_once('/')?;
    let ahead = header("ab")?.split_whitespace().next()?;
    let url = remote_url.trim().trim_end_matches(".git").to_ascii_lowercase();
    let ours = url.ends_with("manaflow-ai/cmux");
    (ahead == "+0" && ours && valid_target(&format!("branch:{branch}"))).then(|| branch.to_owned())
}

fn cmux_binary() -> std::ffi::OsString {
    std::env::var_os("CMUX_BIN").filter(|v| !v.is_empty()).unwrap_or_else(|| "cmux".into())
}

async fn output_of(mut command: tokio::process::Command) -> Result<std::process::Output, String> {
    command.kill_on_drop(true).stdin(std::process::Stdio::null());
    tokio::time::timeout(LIMIT, command.output())
        .await
        .map_err(|_| "share took too long".to_owned())?
        .map_err(|e| format!("could not start: {e}"))
}

fn said(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).trim().chars().take(4000).collect()
}

/// Runs a Share: `{ok, output, line}`, `line` the one line the other person runs, `output` what
/// to tell this one (where the setup repo is, or why there is no line).
async fn share(run: &Value) -> Result<Value, String> {
    match share_plan(run)? {
        Share::Line(line) => Ok(json!({"ok": true, "output": "", "line": line})),
        Share::Profile(name) => {
            let home =
                std::env::var_os("HOME").filter(|v| !v.is_empty()).ok_or("no home folder")?;
            let dir = share_folder(std::path::Path::new(&home), &name);
            let mut command = tokio::process::Command::new(cmux_binary());
            command.args(export_argv(&name, &dir));
            if let Some(socket) = std::env::var_os("CMUX_SOCKET_PATH").filter(|v| !v.is_empty()) {
                command.env("CMUX_SOCKET_PATH", socket);
            }
            let output = output_of(command).await?;
            if !output.status.success() {
                return Ok(json!({"ok": false, "output": said(&output.stderr)}));
            }
            Ok(json!({
                "ok": true,
                "line": format!("cmux setup install {}", dir.display()),
                "folder": dir,
                "output": format!(
                    "{} is a setup repo of {name}: push it to GitHub and the line is cmux setup install github.com/OWNER/REPO",
                    dir.display()
                ),
            }))
        }
        Share::Dir(path) => {
            let git = |args: &[&str]| {
                let mut command = tokio::process::Command::new("git");
                command.arg("-C").arg(&path).args(args);
                command
            };
            let status = output_of(git(&["status", "-b", "--porcelain=v2"])).await?;
            let status = String::from_utf8_lossy(&status.stdout).into_owned();
            let remote = status
                .lines()
                .find_map(|line| line.strip_prefix("# branch.upstream "))
                .and_then(|upstream| upstream.split_once('/'))
                .map(|(remote, _)| remote.to_owned());
            let url = match remote {
                Some(remote) => {
                    let key = format!("remote.{remote}.url");
                    said(&output_of(git(&["config", "--get", &key])).await?.stdout)
                }
                None => String::new(),
            };
            Ok(match pushed_branch(&status, &url) {
                Some(branch) => json!({
                    "ok": true,
                    "output": "",
                    "line": format!("cmux customize try branch:{branch}"),
                }),
                None => json!({
                    "ok": false,
                    "output": "this folder's changes are not on a pushed branch of manaflow-ai/cmux: push them, then Share gives the line",
                }),
            })
        }
    }
}

/// Runs the typed request `params.run`: `{ok, output}`, `ok` false with the command's own words
/// when it failed. A Share (`{customize: "share", target}`) runs [`share`].
pub(crate) async fn run(params: &Value) -> Result<Value, String> {
    let request = params.get("run").unwrap_or(&Value::Null);
    if request.get("customize").and_then(Value::as_str) == Some("share") {
        return share(request).await;
    }
    let args = argv(request)?;
    let mut command = tokio::process::Command::new(cmux_binary());
    command.kill_on_drop(true).args(&args).stdin(std::process::Stdio::null());
    if let Some(socket) = std::env::var_os("CMUX_SOCKET_PATH").filter(|v| !v.is_empty()) {
        command.env("CMUX_SOCKET_PATH", socket);
    }
    let output = tokio::time::timeout(LIMIT, command.output())
        .await
        .map_err(|_| "customize took too long".to_owned())?
        .map_err(|e| format!("cmux customize did not start: {e}"))?;
    let text =
        |bytes: &[u8]| String::from_utf8_lossy(bytes).trim().chars().take(4000).collect::<String>();
    let said = if output.status.success() { text(&output.stdout) } else { text(&output.stderr) };
    Ok(json!({"ok": output.status.success(), "output": said}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_three_typed_requests_become_argv() {
        assert_eq!(
            argv(&json!({"customize": "try", "target": "pr:51234", "minutes": 15})).unwrap(),
            ["customize", "try", "pr:51234", "--minutes", "15"]
        );
        assert_eq!(
            argv(&json!({"customize": "try", "target": "darker"})).unwrap(),
            ["customize", "try", "darker"]
        );
        assert_eq!(argv(&json!({"customize": "keep"})).unwrap(), ["customize", "keep"]);
        assert_eq!(argv(&json!({"customize": "revert"})).unwrap(), ["customize", "revert"]);
        assert_eq!(
            argv(&json!({"customize": "go", "target": "pr:57001"})).unwrap(),
            ["customize", "go", "pr:57001"]
        );
    }

    #[test]
    fn share_puts_each_target_on_another_cmux() {
        let share = |target: &str| share_plan(&json!({"customize": "share", "target": target}));
        assert_eq!(share("pr:59130"), Ok(Share::Line("cmux customize try pr:59130".into())));
        assert_eq!(
            share("branch:lane/x"),
            Ok(Share::Line("cmux customize try branch:lane/x".into()))
        );
        assert_eq!(share("kept-night"), Ok(Share::Profile("kept-night".into())));
        assert_eq!(share("dir:/w/cmux"), Ok(Share::Dir("/w/cmux".into())));
        for bad in ["", "--help", "pr:x", "a b", "dir:--x"] {
            assert!(share(bad).is_err(), "{bad}");
        }
        assert!(share_plan(&json!({"customize": "try", "target": "pr:1"})).is_err());
        // A wrap-up action never carries a share: argv refuses it, so wrap_up drops it.
        assert!(argv(&json!({"customize": "share", "target": "pr:1"})).is_err());
        let dir = share_folder(std::path::Path::new("/home/a"), "kept-night");
        assert_eq!(dir, std::path::Path::new("/home/a/cmux-setups/kept-night"));
        assert_eq!(
            export_argv("kept-night", &dir),
            [
                "setup",
                "export",
                "/home/a/cmux-setups/kept-night",
                "--id",
                "local/kept-night",
                "--name",
                "kept-night",
                "--profile",
                "kept-night"
            ]
            .map(std::ffi::OsString::from)
        );
    }

    #[test]
    fn a_folder_shares_only_its_pushed_branch() {
        let status = |ab: &str| {
            format!(
                "# branch.oid abc\n# branch.head lane/x\n# branch.upstream origin/lane/x\n# branch.ab {ab} -0\n"
            )
        };
        let ours = "https://github.com/manaflow-ai/cmux.git\n";
        assert_eq!(pushed_branch(&status("+0"), ours).as_deref(), Some("lane/x"));
        assert_eq!(
            pushed_branch(&status("+0"), "git@github.com:manaflow-ai/cmux").as_deref(),
            Some("lane/x")
        );
        assert_eq!(pushed_branch(&status("+2"), ours), None, "unpushed commits");
        assert_eq!(pushed_branch(&status("+0"), "https://github.com/me/cmux.git"), None, "a fork");
        assert_eq!(
            pushed_branch("# branch.head lane/x\n# branch.oid abc\n", ours),
            None,
            "no upstream"
        );
    }

    #[test]
    fn anything_else_is_refused() {
        for bad in [
            json!({}),
            json!({"customize": "apply"}),
            json!({"customize": "try"}),
            json!({"customize": "try", "target": "--help"}),
            json!({"customize": "try", "target": "pr:x"}),
            json!({"customize": "try", "target": "sha:zz"}),
            json!({"customize": "try", "target": "dir:--x"}),
            json!({"customize": "try", "target": "a b"}),
            json!({"customize": "try", "target": "x;rm", "minutes": 5}),
            json!({"customize": "try", "target": "pr:1", "minutes": 0}),
            json!({"customize": "try", "target": "pr:1", "minutes": 241}),
            json!({"customize": "try", "target": "pr:1", "minutes": "5"}),
            json!({"customize": "go"}),
            json!({"customize": "go", "target": "branch:x"}),
            json!({"customize": "go", "target": "darker"}),
            json!({"customize": "go", "target": "pr:"}),
        ] {
            assert!(argv(&bad).is_err(), "{bad}");
        }
        assert!(valid_target("branch:lane/live-artifacts-chat") && valid_target("dir:/tmp/my dir"));
    }
}
