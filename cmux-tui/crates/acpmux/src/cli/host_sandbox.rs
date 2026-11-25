//! The join and remote doctor use the same Linux prerequisite and repair command.
use super::host_join_doctor::JoinStep;
use super::host_steps::StepState;

pub(super) const PROBE: &str = r#"printf 'bwrap\t%s\n' "$(if [ "$(uname -s)" != Linux ]; then echo n/a; elif /usr/bin/bwrap --unshare-user --unshare-net --disable-userns --ro-bind / / --bind-fd 3 /tmp --ro-bind-fd 4 /var true 3</tmp 4</var >/dev/null 2>&1; then echo ok; elif [ -x /usr/bin/bwrap ]; then echo broken; else echo missing; fi)"; "#;

// The package command is emitted, never an error message from the package manager. Keep this
// selection shared: the command the person sees is the same one --fix attempts without a prompt.
pub(super) const PACKAGE: &str = r#"
if command -v apt-get >/dev/null 2>&1; then echo 'apt-get install -y bubblewrap';
elif command -v dnf >/dev/null 2>&1; then echo 'dnf install -y bubblewrap';
elif command -v yum >/dev/null 2>&1; then echo 'yum install -y bubblewrap';
elif command -v apk >/dev/null 2>&1; then echo 'apk add bubblewrap';
elif command -v pacman >/dev/null 2>&1; then echo 'pacman -S --noconfirm bubblewrap';
elif command -v zypper >/dev/null 2>&1; then echo 'zypper --non-interactive install bubblewrap';
else exit 1; fi
"#;

pub(super) fn fix_script() -> String {
    format!(
        "package=$({PACKAGE}) || exit 1; if [ \"$(id -u)\" -ne 0 ]; then printf 'sudo '; fi; printf '%s\\n' \"$package\""
    )
}

pub(super) fn install_script() -> String {
    format!(
        "package=$({PACKAGE}) || exit 1; if [ \"$(id -u)\" -eq 0 ]; then $package; else sudo -n $package; fi >/dev/null 2>&1 && /usr/bin/bwrap --unshare-user --unshare-net --disable-userns --ro-bind / / --bind-fd 3 /tmp --ro-bind-fd 4 /var true 3</tmp 4</var"
    )
}

pub(super) fn detail(state: &str) -> &'static str {
    if state == "missing" {
        "bwrap is not installed: sessions another machine starts here are refused until it works"
    } else if state == "unknown" {
        "could not check the Linux sandbox: run acpmux machine doctor --json again"
    } else {
        "bwrap is installed but cannot make a sandbox (older than 0.9, or user namespaces are off): sessions another machine starts here are refused until it works"
    }
}

pub(super) fn fix(command: Option<&str>) -> String {
    match command.filter(|c| !c.trim().is_empty()) {
        Some(command) => format!("Run `{}`", command.trim()),
        None => "Install bubblewrap 0.9 or newer using this machine's package manager".into(),
    }
}

#[cfg(unix)]
pub(super) fn local_step(repair: bool) -> Option<JoinStep> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    let state = || {
        run(PROBE, 10).and_then(|(ok, text)| {
            ok.then(|| text.trim().strip_prefix("bwrap\t").map(str::to_owned)).flatten()
        })
    };
    let mut found = state().unwrap_or_else(|| "unknown".into());
    if found == "n/a" {
        return None;
    }
    if found == "ok" {
        return Some(JoinStep::new(
            "sandbox",
            StepState::Ok,
            "sessions from other machines can run sandboxed here",
        ));
    }
    if repair && found == "missing" {
        let installed = run(&install_script(), 120).is_some_and(|(ok, _)| ok);
        found = state().unwrap_or_else(|| "unknown".into());
        if installed && found == "ok" {
            return Some(JoinStep::new(
                "sandbox",
                StepState::Fixed,
                "installed bubblewrap: sessions from other machines can run sandboxed here",
            ));
        }
    }
    let command = run(&fix_script(), 5).filter(|(ok, _)| *ok).map(|(_, text)| text);
    Some(
        JoinStep::new("sandbox", StepState::Warn, detail(&found)).with_fix(fix(command.as_deref())),
    )
}

#[cfg(unix)]
fn run(script: &str, seconds: u64) -> Option<(bool, String)> {
    use cmux_process::{Command, Stdio};
    use std::io::Read as _;
    use std::time::Duration;
    let mut child = Command::new("sh")
        .args(["-c", script])
        // Join repair commands may run package-manager helpers. Do not expose the
        // cloud bearer token (or caller-controlled command lookup) to them.
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let status = match child.wait_timeout(Duration::from_secs(seconds)) {
        Ok(Some(status)) => status,
        _ => {
            // SAFETY: this is the process group created above for this command only.
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.wait();
            return None;
        }
    };
    let mut text = String::new();
    child.stdout.take()?.take(4096).read_to_string(&mut text).ok()?;
    Some((status.success(), text))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use cmux_process::Command;
    use std::os::unix::fs::PermissionsExt as _;

    fn script(dir: &std::path::Path, name: &str, body: &str) {
        let path = dir.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn sandbox_commands_do_not_inherit_cloud_access_token() {
        let previous = std::env::var_os("CMUX_CLOUD_ACCESS_TOKEN");
        // SAFETY: this test restores the process environment before returning.
        unsafe {
            std::env::set_var("CMUX_CLOUD_ACCESS_TOKEN", "test-secret");
        }
        let result = run("printf '%s' \"${CMUX_CLOUD_ACCESS_TOKEN-unset}\"", 5).unwrap();
        match previous {
            Some(value) => unsafe { std::env::set_var("CMUX_CLOUD_ACCESS_TOKEN", value) },
            None => unsafe { std::env::remove_var("CMUX_CLOUD_ACCESS_TOKEN") },
        }
        assert!(result.0);
        assert_eq!(result.1, "unset");
    }

    #[test]
    fn sandbox_repair_selects_root_or_noninteractive_sudo_and_reports_same_command() {
        for (uid, sudo_ok) in [("0", false), ("1000", true), ("1000", false)] {
            let tmp = tempfile::tempdir().unwrap();
            let dir = tmp.path();
            script(dir, "id", &format!("echo {uid}"));
            // Failing deliberately avoids invoking this test host's actual bwrap after the install.
            script(dir, "apt-get", "echo package >> \"$RECORD\"; exit 17");
            script(
                dir,
                "sudo",
                if sudo_ok {
                    "echo \"$*\" >> \"$RECORD\"; shift; exec \"$@\""
                } else {
                    "echo \"$*\" >> \"$RECORD\"; exit 1"
                },
            );
            let run = |text: &str| {
                Command::new("/bin/sh")
                    .args(["-c", text])
                    .env_clear()
                    .env("PATH", dir)
                    .env("RECORD", dir.join("calls"))
                    .output()
                    .unwrap()
            };
            let offered = run(&fix_script());
            assert!(offered.status.success());
            assert_eq!(
                String::from_utf8(offered.stdout).unwrap().trim(),
                if uid == "0" {
                    "apt-get install -y bubblewrap"
                } else {
                    "sudo apt-get install -y bubblewrap"
                }
            );
            assert!(!run(&install_script()).status.success());
            let calls = std::fs::read_to_string(dir.join("calls")).unwrap();
            assert_eq!(calls.contains("-n apt-get install -y bubblewrap"), uid != "0");
            assert_eq!(calls.contains("package"), uid == "0" || sudo_ok);
        }
    }
}
