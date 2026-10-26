//! The daemon runs in the user's login (Aqua) session on macOS, so every agent it
//! starts reads the login keychain: "i did that... but acpmux itslef needs to fix
//! that stuff.." (Leo, 2026-10-22, about `gh` failing in agent sessions).
//!
//! A process started from an ssh login is in that login's security session, where
//! the login keychain is not readable: `security find-generic-password` fails with
//! errSecInteractionNotAllowed (36), so `gh auth token`, Codex, Claude and git
//! credential helpers fail for every agent that daemon starts. A daemon an ssh
//! client starts (a remote `acpmux` command, a peer's restart) therefore goes to the
//! user's GUI launchd domain instead, as a job that loads only in the Aqua session
//! (`LimitLoadToSessionType`). With no one logged in at the screen there is no such
//! domain, and the daemon starts in place as before. Only the person's own homes
//! (`~/.acpmux` and the per-build homes under it) move: a test's or a CI runner's
//! temporary home keeps its daemon in place. `acpmux daemon status` says
//! when a daemon still runs outside the login session (`keychain` in the status).

use anyhow::{Context, Result, anyhow};
use std::path::Path;

/// `SessionAttributeBits.sessionHasGraphicAccess` (Security/AuthSession.h).
const HAS_GRAPHIC_ACCESS: u32 = 0x0010;
/// `callerSecuritySession` (Security/AuthSession.h).
const CALLER_SECURITY_SESSION: i32 = -1;

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SessionGetInfo(session: i32, session_id: *mut u32, attributes: *mut u32) -> i32;
}

/// Whether this process's security session reaches the login GUI (and so the
/// login keychain). True when it cannot be read: nothing changes then.
pub(crate) fn in_login_session() -> bool {
    let mut id = 0u32;
    let mut attributes = 0u32;
    // SAFETY: both out pointers are valid for the call.
    let status = unsafe { SessionGetInfo(CALLER_SECURITY_SESSION, &mut id, &mut attributes) };
    status != 0 || attributes & HAS_GRAPHIC_ACCESS != 0
}

/// The user's GUI launchd domain, `gui/<uid>`.
fn gui_domain() -> String {
    // SAFETY: getuid has no preconditions.
    format!("gui/{}", unsafe { libc::getuid() })
}

/// Whether the user has a GUI login now (its launchd domain exists).
fn gui_domain_up(domain: &str) -> bool {
    std::process::Command::new("/bin/launchctl")
        .args(["print", domain])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// The job label for the daemon of `home` (one per acpmux home).
fn label(home: &Path) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    home.hash(&mut h);
    format!("com.cmux.acpmux.daemon.{:016x}", h.finish())
}

/// What [`start_in_login_session`] did.
pub(crate) enum Started {
    /// Nothing: in the login session already, or not the person's own home. The
    /// daemon starts in place.
    No,
    /// No GUI login on this Mac: the daemon starts in place, and its agents
    /// cannot read the login keychain (`login_placement::NO_GUI_LOGIN`).
    NoGuiLogin,
    /// The job `gui/<uid>/<label>` was bootstrapped.
    Job(String),
    /// This home's job is still running: another command's start, or a daemon
    /// that is stopping. It is never booted out; the caller waits for it as for a
    /// daemon that holds the lock.
    Running,
}

/// Whether launchd job `target` (`gui/<uid>/<label>`) has a process now.
pub(crate) fn job_running(target: &str) -> bool {
    std::process::Command::new("/bin/launchctl")
        .args(["print", target])
        .stderr(std::process::Stdio::null())
        .output()
        .is_ok_and(|out| {
            out.status.success()
                && String::from_utf8_lossy(&out.stdout)
                    .lines()
                    .any(|l| l.trim_start().starts_with("pid = "))
        })
}

/// Start `daemon run` for `home` as a job in the user's GUI domain when this
/// process is outside the login session and the user has one.
pub(crate) fn start_in_login_session(
    this: &crate::self_command::SelfCommand,
    home: &Path,
    log: &Path,
) -> Result<Started> {
    use super::login_placement::{Placement, placement};
    let (here, own) = (in_login_session(), home.starts_with(crate::config::default_home()));
    let domain = gui_domain();
    // Only asked when it decides anything (one `launchctl print`).
    let gui_login = !here && own && gui_domain_up(&domain);
    match placement(here, own, gui_login) {
        Placement::InPlace => return Ok(Started::No),
        Placement::NoGuiLogin => return Ok(Started::NoGuiLogin),
        Placement::LoginJob => {}
    }
    let label = label(home);
    let target = format!("{domain}/{label}");
    if job_running(&target) {
        return Ok(Started::Running);
    }
    let mut argv = vec![this.exe.to_string_lossy().into_owned()];
    argv.extend(this.args_lossy(&["daemon", "run"]));
    // The job's environment is launchd's, not this ssh login's: only what the
    // daemon needs to find its home and the agent CLIs (no secrets on disk).
    let mut env = vec![("ACPMUX_HOME".to_owned(), home.to_string_lossy().into_owned())];
    for key in ["ACPMUX_SOCKET", "PATH", "LANG", "SHELL"] {
        if let Ok(v) = std::env::var(key) {
            env.push((key.to_owned(), v));
        }
    }
    let plist = home.join("daemon-login-session.plist");
    {
        use std::io::Write;
        let mut file = crate::config::private_state_rw(&plist)?;
        file.set_len(0)?;
        file.write_all(job_plist(&label, &argv, &env, log).as_bytes())
            .with_context(|| format!("write {}", plist.display()))?;
    }
    // A finished job of the same label (the last daemon's) is removed first; a
    // running one was never reached here.
    let _ = std::process::Command::new("/bin/launchctl")
        .args(["bootout", &target])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    let out = std::process::Command::new("/bin/launchctl")
        .arg("bootstrap")
        .arg(&domain)
        .arg(&plist)
        .output()
        .context("launchctl bootstrap")?;
    if !out.status.success() {
        return Err(anyhow!(
            "launchctl bootstrap {domain} {}: {}",
            plist.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(Started::Job(target))
}

fn xml(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// A launchd job that runs `argv` once, in the Aqua session only, and leaves the
/// daemon's agent hosts running when the daemon exits.
fn job_plist(label: &str, argv: &[String], env: &[(String, String)], log: &Path) -> String {
    let args: String =
        argv.iter().map(|a| format!("<string>{}</string>", xml(a))).collect::<Vec<_>>().join("");
    let vars: String = env
        .iter()
        .map(|(k, v)| format!("<key>{}</key><string>{}</string>", xml(k), xml(v)))
        .collect::<Vec<_>>()
        .join("");
    let log = xml(&log.to_string_lossy());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{label}</string>
<key>ProgramArguments</key><array>{args}</array>
<key>EnvironmentVariables</key><dict>{vars}</dict>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><false/>
<key>AbandonProcessGroup</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>{log}</string>
<key>StandardErrorPath</key><string>{log}</string>
</dict></plist>
"#,
        label = xml(label)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_job_loads_only_in_the_aqua_session_and_escapes_its_values() {
        let p = job_plist(
            "com.cmux.acpmux.daemon.x",
            &["/Apps/a&b/acpmux".into(), "daemon".into(), "run".into()],
            &[("ACPMUX_HOME".into(), "/h/<x>".into())],
            Path::new("/h/daemon.log"),
        );
        assert!(p.contains("<key>LimitLoadToSessionType</key><string>Aqua</string>"));
        assert!(p.contains(
            "<string>/Apps/a&amp;b/acpmux</string><string>daemon</string><string>run</string>"
        ));
        assert!(p.contains("<key>ACPMUX_HOME</key><string>/h/&lt;x&gt;</string>"));
        assert!(p.contains("<key>KeepAlive</key><false/>"));
    }

    #[test]
    fn each_home_has_its_own_job_label() {
        assert_ne!(label(Path::new("/a/.acpmux")), label(Path::new("/b/.acpmux")));
        assert_eq!(label(Path::new("/a/.acpmux")), label(Path::new("/a/.acpmux")));
    }
}
