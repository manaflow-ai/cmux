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
/// login keychain). None when it cannot be read (`SessionGetInfo` failed).
pub(crate) fn in_login_session() -> Option<bool> {
    let mut id = 0u32;
    let mut attributes = 0u32;
    // SAFETY: both out pointers are valid for the call.
    let status = unsafe { SessionGetInfo(CALLER_SECURITY_SESSION, &mut id, &mut attributes) };
    (status == 0).then_some(attributes & HAS_GRAPHIC_ACCESS != 0)
}

/// How long one `launchctl` call may take before it is killed: a stalled launchd never holds a
/// start past its budget.
const LAUNCHCTL_BUDGET: std::time::Duration = std::time::Duration::from_secs(2);

/// `launchctl ARGS`, killed after `budget`: its exit status and stdout, or an error (it could
/// not start, or it timed out).
pub(crate) fn launchctl(args: &[&str], budget: std::time::Duration) -> Result<(bool, String)> {
    use std::io::Read;
    let mut child = std::process::Command::new("/bin/launchctl")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("launchctl")?;
    // Drained while it runs: a `print` larger than the pipe never blocks it into the budget.
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut out = String::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.read_to_string(&mut out);
            }
            out
        })
    };
    let stdout = drain(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let stderr = drain(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let deadline = std::time::Instant::now() + budget;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(anyhow!("launchctl {} did not answer within {budget:?}", args.join(" ")));
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    };
    let mut out = stdout.join().unwrap_or_default();
    let err = stderr.join().unwrap_or_default();
    if !status.success() {
        out.push_str(&err);
    }
    Ok((status.success(), out))
}

/// The user's GUI launchd domain, `gui/<uid>`.
fn gui_domain() -> String {
    // SAFETY: getuid has no preconditions.
    format!("gui/{}", unsafe { libc::getuid() })
}

/// Whether the user has a GUI login now (its launchd domain exists).
fn gui_domain_up(domain: &str) -> bool {
    launchctl(&["print", domain], LAUNCHCTL_BUDGET).is_ok_and(|(ok, _)| ok)
}

/// What [`start_in_login_session`] did.
pub(crate) enum Started {
    /// Nothing: in the login session already, or not the person's own home. The
    /// daemon starts in place.
    No,
    /// A keyed start outside the login session: the daemon starts in place, and its
    /// agents cannot read the login keychain (`login_placement::KEYED_IN_PLACE`).
    KeyedInPlace,
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

/// Whether launchd job `target` (`gui/<uid>/<label>`) is loaded and not known to
/// have ended: running, or bootstrapped and about to spawn. Only a loaded job whose
/// state reads `not running` (its daemon exited) counts as ended. A `launchctl`
/// that does not answer counts as running: nothing is booted out on a guess.
pub(crate) fn job_running(target: &str, budget: std::time::Duration) -> bool {
    match launchctl(&["print", target], budget) {
        Ok((true, out)) => !out.lines().any(|l| l.trim() == "state = not running"),
        Ok((false, _)) => false,
        Err(_) => true,
    }
}

/// Start `daemon run` for `home` as a job in the user's GUI domain when this
/// process is outside the login session and the user has one.
pub(crate) fn start_in_login_session(
    this: &crate::self_command::SelfCommand,
    home: &Path,
    log: &Path,
    keyed: bool,
) -> Result<Started> {
    use super::login_placement::{Placement, own_home, placement};
    let (here, own) = (in_login_session(), own_home(home, &crate::config::default_home()));
    let domain = gui_domain();
    // Only asked when it decides anything (one `launchctl print`).
    let gui_login = here != Some(true) && own && !keyed && gui_domain_up(&domain);
    match placement(here, own, gui_login, keyed) {
        Placement::InPlace => return Ok(Started::No),
        Placement::KeyedInPlace => return Ok(Started::KeyedInPlace),
        Placement::NoGuiLogin => return Ok(Started::NoGuiLogin),
        Placement::LoginJob => {}
    }
    // One start per home at a time, from the check below through the bootstrap: a
    // second command waits here, then finds the first one's job and waits for it.
    let lock = crate::config::private_state_rw(&home.join("daemon-login-session.lock"))?;
    // SAFETY: flock on a descriptor this function owns; released when `lock` drops.
    if unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&lock), libc::LOCK_EX) } != 0 {
        return Err(anyhow!("lock {}: {}", home.display(), std::io::Error::last_os_error()));
    }
    let label = super::login_placement::job_label(home);
    let target = format!("{domain}/{label}");
    if job_running(&target, LAUNCHCTL_BUDGET) {
        return Ok(Started::Running);
    }
    let mut argv = vec![this.exe.to_string_lossy().into_owned()];
    argv.extend(this.args_lossy(&["daemon", "run"]));
    // The job's environment is launchd's, not this ssh login's: only what the
    // daemon needs to find its home and the agent CLIs (no secrets on disk).
    // Both against this command's folder: launchd starts the job in `/`.
    let cwd = std::env::current_dir().context("this command's folder")?;
    let socket = std::env::var_os("ACPMUX_SOCKET");
    let mut env: Vec<(String, String)> =
        super::login_placement::daemon_env(home, socket.as_deref(), &cwd)
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v.to_string_lossy().into_owned()))
            .collect();
    let log = &if log.is_relative() { cwd.join(log) } else { log.to_path_buf() };
    for key in ["PATH", "LANG", "SHELL", super::exe_path::ALLOW_ENV] {
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
    // running one never gets here, and none can start meanwhile (`lock`).
    let _ = launchctl(&["bootout", &target], LAUNCHCTL_BUDGET);
    let plist_arg = plist.to_string_lossy();
    let (answered, said) = match launchctl(&["bootstrap", &domain, &plist_arg], LAUNCHCTL_BUDGET) {
        Ok((ok, out)) => (Some(ok), out.trim().to_owned()),
        Err(e) => (None, format!("{e:#}")),
    };
    use super::login_placement::{Bootstrap, bootstrap_outcome};
    match bootstrap_outcome(answered, || job_running(&target, LAUNCHCTL_BUDGET)) {
        Bootstrap::Job => {
            drop(lock);
            Ok(Started::Job(target))
        }
        Bootstrap::Failed => Err(anyhow!("launchctl bootstrap {domain} {plist_arg}: {said}")),
    }
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
}
