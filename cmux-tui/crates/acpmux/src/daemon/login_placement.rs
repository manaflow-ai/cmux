//! Where a daemon a command starts runs (`daemon/login_session.rs`, macOS): decided from a few
//! facts, so every platform's tests check the decision itself.

use std::path::Path;

/// Where [`placement`] starts the daemon.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Placement {
    /// Here: this command is in the login session already, or the home is not the person's own
    /// (a test's or a CI runner's temporary home).
    InPlace,
    /// As a job in the user's GUI login session, so its agents read the login keychain.
    LoginJob,
    /// Here, for want of a GUI login on this Mac: its agents cannot read the login keychain
    /// until someone logs in at the screen. Never silent: the command says so
    /// ([`NO_GUI_LOGIN`]) and `daemon status` shows it.
    NoGuiLogin,
    /// Here, because the start carries a person key (the app's restart over ssh), which a
    /// launchd job cannot be handed yet. Never silent: [`KEYED_IN_PLACE`].
    KeyedInPlace,
}

/// The reason [`Placement::NoGuiLogin`] names.
pub(crate) const NO_GUI_LOGIN: &str = "login_session.no_gui_login";
/// The reason [`Placement::KeyedInPlace`] names.
pub(crate) const KEYED_IN_PLACE: &str = "login_session.keyed_in_place";
/// The reason a start that should have gone to the login session but could not names.
pub(crate) const START_FAILED: &str = "login_session.start_failed";

/// The `ACPMUX_HOME` and `ACPMUX_SOCKET` a daemon this command starts is handed, as a detached
/// child or a login-session job, against `cwd` (this command's folder). Both are absolute: the
/// daemon changes into its home (launchd starts it in `/`), so a relative one would name
/// another file there. An empty `ACPMUX_SOCKET` is unset (`config::socket_path`).
pub(crate) fn daemon_env(
    home: &Path,
    socket: Option<&std::ffi::OsStr>,
    cwd: &Path,
) -> Vec<(&'static str, std::path::PathBuf)> {
    let absolute = |p: &Path| if p.is_relative() { cwd.join(p) } else { p.to_path_buf() };
    let mut env = vec![("ACPMUX_HOME", absolute(home))];
    let socket = socket.filter(|s| !s.is_empty());
    env.extend(socket.map(|s| ("ACPMUX_SOCKET", absolute(Path::new(s)))));
    env
}

/// The launchd job label for the daemon of `home`: one per home, however it is spelled (it is
/// resolved first: `..`, links, a relative path), so one home never gets two jobs.
pub(crate) fn job_label(home: &Path) -> String {
    let home = canonical(home);
    // The path's own bytes on Unix (the only place launchd runs it); any fixed bytes elsewhere.
    #[cfg(unix)]
    let bytes = std::os::unix::ffi::OsStrExt::as_bytes(home.as_os_str());
    #[cfg(not(unix))]
    let bytes = home.as_os_str().as_encoded_bytes();
    label_for_bytes(bytes)
}

/// Every daemon job's label starts so: the sweep ([`stale_daemon_labels`]) knows them by it.
pub(crate) const LABEL_PREFIX: &str = "com.cmux.acpmux.daemon.";

/// The label of a canonical home's bytes: FNV-1a 64, fixed by this code, so a toolchain bump
/// never gives one home a second label (std's `DefaultHasher` may change between releases).
pub(crate) fn label_for_bytes(bytes: &[u8]) -> String {
    let h = bytes.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, b| {
        (h ^ u64::from(*b)).wrapping_mul(0x0000_0100_0000_01b3)
    });
    format!("{LABEL_PREFIX}{h:016x}")
}

/// The label builds before the FNV one gave `home` (std's `DefaultHasher`), so a start finds
/// the job such a build left: running, it is the daemon; ended, it is booted out.
pub(crate) fn legacy_job_label(home: &Path) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    canonical(home).hash(&mut h);
    format!("{LABEL_PREFIX}{:016x}", h.finish())
}

fn canonical(home: &Path) -> std::path::PathBuf {
    std::fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf())
}

/// At most this many stale jobs are looked at per start: each costs two `launchctl` calls.
pub(crate) const STALE_SWEEP_MAX: usize = 16;

/// From `launchctl print gui/<uid>`: the daemon jobs listed with no process (pid 0 or `-`),
/// at most [`STALE_SWEEP_MAX`]. Only candidates: each one's own print decides
/// ([`stale_job_program`]).
pub(crate) fn stale_daemon_labels(domain_print: &str) -> Vec<String> {
    let mut lines = domain_print.lines();
    // The `services = {` block only: other blocks name labels too (endpoints, disabled).
    lines.by_ref().find(|l| l.trim() == "services = {");
    lines
        .take_while(|l| l.trim() != "}")
        .filter_map(|l| {
            let mut fields = l.split_whitespace();
            let (pid, _status, label) = (fields.next()?, fields.next()?, fields.next()?);
            ((pid == "0" || pid == "-") && label.starts_with(LABEL_PREFIX))
                .then(|| label.to_owned())
        })
        .take(STALE_SWEEP_MAX)
        .collect()
}

/// From `launchctl print gui/<uid>/<label>`: the program of a job that has ended (`state =
/// not running`) and whose program no longer exists (`exists`), the app copy it ran from
/// deleted. Such a job never runs again and only sits loaded. None for any other job: one
/// running, one whose program is there, one whose program cannot be read.
pub(crate) fn stale_job_program(
    job_print: &str,
    exists: impl Fn(&Path) -> bool,
) -> Option<std::path::PathBuf> {
    let lines: Vec<&str> = job_print.lines().map(str::trim).collect();
    if !lines.contains(&"state = not running") {
        return None;
    }
    let program = lines.iter().find_map(|l| l.strip_prefix("program = ")).or_else(|| {
        let at = lines.iter().position(|l| *l == "arguments = {")?;
        lines.get(at + 1).filter(|l| **l != "}").copied()
    })?;
    let program = Path::new(program);
    (program.is_absolute() && !exists(program)).then(|| program.to_path_buf())
}

/// What a `launchctl bootstrap` left: the job, or nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Bootstrap {
    Job,
    Failed,
}

/// `answered`: the bootstrap's exit (true: it loaded the job), None when it did not answer in
/// time. One that did not answer may still have loaded the job, so `loaded` (launchd asked
/// again) decides then: a loaded job is waited for, never raced by a second daemon here.
pub(crate) fn bootstrap_outcome(
    answered: Option<bool>,
    loaded: impl FnOnce() -> bool,
) -> Bootstrap {
    match answered {
        Some(true) => Bootstrap::Job,
        Some(false) => Bootstrap::Failed,
        None if loaded() => Bootstrap::Job,
        None => Bootstrap::Failed,
    }
}

/// The one line the starting command prints when the login-session start failed (`error`)
/// and the daemon starts here instead.
pub(crate) fn start_failed_warning(error: &str) -> String {
    format!(
        "acpmux: {START_FAILED}: the daemon could not start in the login session ({error}), so \
         it starts in this ssh session and its agents cannot read the login keychain (gh, \
         codex, claude and git credential helpers fail). `acpmux daemon status` says so while \
         it runs"
    )
}

/// `daemon status`'s keychain line: `in_login_session` as the daemon reports it (None: it
/// could not read its session), `own_home` whether its home is the person's own (only such
/// a daemon moves to the login session, so only it is told how). None when there is nothing
/// to say.
pub(crate) fn keychain_line(in_login_session: Option<bool>, own_home: bool) -> Option<String> {
    match in_login_session {
        Some(true) => None,
        Some(false) if !own_home => Some(
            "keychain: unreadable from sessions: this daemon runs outside the login session \
             with a home that is not the person's own ~/.acpmux, so it stays where it starts \
             and gh, codex, claude and git credential helpers cannot read the login keychain"
                .into(),
        ),
        None => Some(
            "keychain: unknown: this daemon's security session could not be read, so whether \
             its agents can read the login keychain is not known"
                .into(),
        ),
        Some(false) => Some(
            "keychain: unreadable from sessions: this daemon runs outside the login session \
             (started over ssh), so gh, codex, claude and git credential helpers cannot read the \
             login keychain. Fix: with someone logged in at the screen, `acpmux daemon shutdown \
             --end-agents` (agents keep the session they started in), then run any acpmux \
             command (it starts the daemon in the login session)"
                .into(),
        ),
    }
}

/// Where a daemon goes: `in_login_session` (this command's security session reaches the GUI;
/// None when it could not be read), `own_home` ([`own_home`]), `gui_login` (the user's
/// `gui/<uid>` launchd domain exists: someone is logged in at the screen), `keyed` (the start
/// carries a person key).
pub(crate) fn placement(
    in_login_session: Option<bool>,
    own_home: bool,
    gui_login: bool,
    keyed: bool,
) -> Placement {
    // A session that cannot be read counts as outside it: the daemon moves to the GUI session
    // (where it is in any case) or says why it cannot, never silently stays.
    if in_login_session == Some(true) || !own_home {
        Placement::InPlace
    } else if keyed {
        Placement::KeyedInPlace
    } else if gui_login {
        Placement::LoginJob
    } else {
        Placement::NoGuiLogin
    }
}

/// Whether `home` is the person's own acpmux home (`default`, or a per-build home under it).
/// Both are resolved first (`..`, links): a home that leads elsewhere is not the person's own.
/// Either one unreadable: not.
pub(crate) fn own_home(home: &Path, default: &Path) -> bool {
    match (std::fs::canonicalize(home), std::fs::canonicalize(default)) {
        (Ok(home), Ok(default)) => home.starts_with(default),
        _ => false,
    }
}

/// The one line the starting command prints for [`Placement::NoGuiLogin`].
pub(crate) fn no_gui_login_warning() -> String {
    format!(
        "acpmux: {NO_GUI_LOGIN}: no one is logged in at this Mac's screen, so the daemon starts \
         in this ssh session and its agents cannot read the login keychain (gh, codex, claude \
         and git credential helpers fail). Fix: log in at the screen, then `acpmux daemon \
         shutdown --end-agents` (agents keep the session they started in) and run any acpmux \
         command"
    )
}

/// The one line the starting command prints for [`Placement::KeyedInPlace`].
pub(crate) fn keyed_in_place_warning() -> String {
    format!(
        "acpmux: {KEYED_IN_PLACE}: this keyed daemon (the app's restart over ssh) starts in this \
         ssh session: a person key cannot be handed to a login-session job yet, so its agents \
         cannot read the login keychain (gh, codex, claude and git credential helpers fail). \
         `acpmux daemon status` says so while it runs"
    )
}

/// The home of a daemon job from its `launchctl print`: the folder of its plist (`path = `),
/// which a start writes as `<home>/daemon-login-session.plist`. None for any other plist.
pub(crate) fn job_home(job_print: &str) -> Option<std::path::PathBuf> {
    let plist = job_print.lines().find_map(|l| l.trim().strip_prefix("path = "))?;
    let plist = Path::new(plist);
    (plist.is_absolute() && plist.file_name()? == "daemon-login-session.plist")
        .then(|| plist.parent().map(Path::to_path_buf))
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ssh_started_daemon_goes_to_the_gui_session_only_when_there_is_one() {
        // Over ssh (not in the login session), the person's own home:
        assert_eq!(placement(Some(false), true, true, false), Placement::LoginJob);
        assert_eq!(placement(Some(false), true, false, false), Placement::NoGuiLogin);
        // In the login session already, or a test's home: here, as before.
        assert_eq!(placement(Some(true), true, true, false), Placement::InPlace);
        assert_eq!(placement(Some(true), true, false, false), Placement::InPlace);
        assert_eq!(placement(Some(false), false, true, false), Placement::InPlace);
        assert_eq!(placement(Some(false), false, false, false), Placement::InPlace);
    }

    #[test]
    fn a_session_that_cannot_be_read_counts_as_outside_the_login_session() {
        assert_eq!(placement(None, true, true, false), Placement::LoginJob);
        assert_eq!(placement(None, true, false, false), Placement::NoGuiLogin);
        assert_eq!(placement(None, false, true, false), Placement::InPlace);
    }

    #[test]
    fn a_keyed_start_over_ssh_stays_here_and_says_so() {
        assert_eq!(placement(Some(false), true, true, true), Placement::KeyedInPlace);
        assert_eq!(placement(Some(false), true, false, true), Placement::KeyedInPlace);
        assert_eq!(placement(Some(true), true, true, true), Placement::InPlace);
        assert_eq!(placement(Some(false), false, true, true), Placement::InPlace);
        let line = keyed_in_place_warning();
        assert!(line.contains(KEYED_IN_PLACE), "{line}");
        assert!(line.contains("keychain"), "{line}");
    }

    #[test]
    fn a_home_that_leaves_the_persons_own_by_dot_dot_is_not_theirs() {
        let dir = std::env::temp_dir().join(format!("acpmux-own-{}", std::process::id()));
        let default = dir.join("home");
        std::fs::create_dir_all(default.join("dev")).unwrap();
        std::fs::create_dir_all(dir.join("outside")).unwrap();
        assert!(own_home(&default, &default));
        assert!(own_home(&default.join("dev"), &default));
        assert!(!own_home(&default.join("../outside"), &default));
        assert!(!own_home(&dir.join("outside"), &default));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_started_daemon_gets_this_commands_home_and_socket_absolute() {
        let cwd = Path::new("/work/here");
        let os = |s: &'static str| Some(std::ffi::OsStr::new(s));
        let env = daemon_env(Path::new(".acpmux-x"), os("run/a.sock"), cwd);
        assert_eq!(
            env,
            [
                ("ACPMUX_HOME", "/work/here/.acpmux-x".into()),
                ("ACPMUX_SOCKET", "/work/here/run/a.sock".into())
            ]
        );
        assert_eq!(daemon_env(Path::new("/abs/h"), None, cwd), [("ACPMUX_HOME", "/abs/h".into())]);
    }

    #[test]
    fn equivalent_home_spellings_share_one_launchd_label() {
        let dir = std::env::temp_dir().join(format!("acpmux-label-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("h")).unwrap();
        std::fs::create_dir_all(dir.join("x")).unwrap();
        assert_eq!(job_label(&dir.join("h")), job_label(&dir.join("x/../h")));
        assert_ne!(job_label(&dir.join("h")), job_label(&dir.join("x")));
        assert_eq!(legacy_job_label(&dir.join("h")), legacy_job_label(&dir.join("x/../h")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_homes_label_is_fixed_by_this_code_not_the_toolchain() {
        // FNV-1a 64 reference values: a std hasher change cannot move them.
        assert_eq!(label_for_bytes(b""), "com.cmux.acpmux.daemon.cbf29ce484222325");
        assert_eq!(label_for_bytes(b"a"), "com.cmux.acpmux.daemon.af63dc4c8601ec8c");
        assert_eq!(label_for_bytes(b"/Users/a/home"), "com.cmux.acpmux.daemon.3af804ca21d020f0");
        // A home that cannot be resolved is labelled as spelled.
        assert_eq!(
            job_label(Path::new("/nonexistent-acpmux-home/a")),
            label_for_bytes(b"/nonexistent-acpmux-home/a")
        );
        let legacy = legacy_job_label(Path::new("/nonexistent-acpmux-home/a"));
        assert!(legacy.starts_with(LABEL_PREFIX) && legacy.len() == LABEL_PREFIX.len() + 16);
    }

    const DOMAIN_PRINT: &str = "gui/501 = {
\ttype = gui
\tservices = {
\t\t       0      0 \tai.leo-workspace.memory-sync
\t\t       0     75 \tcom.cmux.acpmux.daemon.4ae0f8d39eeff3d2
\t\t   12345      - \tcom.cmux.acpmux.daemon.1111111111111111
\t\t       -      - \tcom.cmux.acpmux.daemon.2222222222222222
\t}

\tendpoints = {
\t\t       0      0 \tcom.cmux.acpmux.daemon.3333333333333333
\t}
}
";

    #[test]
    fn only_listed_daemon_jobs_with_no_process_are_sweep_candidates() {
        assert_eq!(
            stale_daemon_labels(DOMAIN_PRINT),
            ["com.cmux.acpmux.daemon.4ae0f8d39eeff3d2", "com.cmux.acpmux.daemon.2222222222222222"]
        );
        assert!(stale_daemon_labels("").is_empty());
        let many: String =
            (0..40).map(|i| format!("\t\t       0      0 \t{LABEL_PREFIX}{i:016x}\n")).collect();
        let print = format!("\tservices = {{\n{many}\t}}\n");
        assert_eq!(stale_daemon_labels(&print).len(), STALE_SWEEP_MAX);
    }

    #[cfg(unix)]
    const JOB_PRINT: &str = "gui/501/com.cmux.acpmux.daemon.x = {
\tactive count = 0
\tpath = /Users/a/home/dev/daemon-login-session.plist
\ttype = LaunchAgent
\tstate = not running

\tprogram = /Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux
\targuments = {
\t\t/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux
\t\tdaemon
\t\trun
\t}
\tlast exit code = 75: EX_TEMPFAIL
}
";

    // Unix paths: on Windows they are not absolute (no drive), and launchd is macOS-only.
    #[cfg(unix)]
    #[test]
    fn only_an_ended_job_whose_program_is_gone_is_stale() {
        let app = Path::new("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux");
        assert_eq!(stale_job_program(JOB_PRINT, |_| false).as_deref(), Some(app));
        // Its program is there: kept.
        assert_eq!(stale_job_program(JOB_PRINT, |p| p == app), None);
        // Running: kept, whatever its program.
        let running = JOB_PRINT.replace("state = not running", "state = running");
        assert_eq!(stale_job_program(&running, |_| false), None);
        // No `program = ` line: the first argument is the program.
        let no_program = JOB_PRINT.replace("\tprogram = ", "\tprogram_was = ");
        assert_eq!(stale_job_program(&no_program, |_| false).as_deref(), Some(app));
        // Nothing to read the program from: kept.
        assert_eq!(stale_job_program("state = not running\n", |_| false), None);
    }

    // Unix paths: on Windows they are not absolute (no drive), and launchd is macOS-only.
    #[cfg(unix)]
    #[test]
    fn a_jobs_home_is_the_folder_of_the_plist_a_start_wrote() {
        assert_eq!(job_home(JOB_PRINT).as_deref(), Some(Path::new("/Users/a/home/dev")));
        let other = JOB_PRINT.replace("daemon-login-session.plist", "other.plist");
        assert_eq!(job_home(&other), None);
        assert_eq!(job_home("state = not running\n"), None);
    }

    #[test]
    fn an_empty_acpmux_socket_is_not_handed_to_the_daemon() {
        let env = daemon_env(Path::new("/abs/h"), Some(std::ffi::OsStr::new("")), Path::new("/w"));
        assert_eq!(env, [("ACPMUX_HOME", "/abs/h".into())]);
    }

    #[test]
    fn a_bootstrap_that_did_not_answer_but_loaded_the_job_is_waited_for() {
        assert_eq!(bootstrap_outcome(Some(true), || unreachable!()), Bootstrap::Job);
        assert_eq!(bootstrap_outcome(Some(false), || unreachable!()), Bootstrap::Failed);
        assert_eq!(bootstrap_outcome(None, || true), Bootstrap::Job);
        assert_eq!(bootstrap_outcome(None, || false), Bootstrap::Failed);
    }

    #[test]
    fn a_failed_login_session_start_is_said_by_name_before_starting_here() {
        let line = start_failed_warning("launchctl bootstrap gui/501: 5: Input/output error");
        assert!(line.contains(START_FAILED), "{line}");
        assert!(line.contains("keychain"), "{line}");
        assert!(line.contains("Input/output error"), "{line}");
    }

    #[test]
    fn status_tells_only_a_daemon_that_can_move_how_to_move_it() {
        assert_eq!(keychain_line(Some(true), true), None);
        let own = keychain_line(Some(false), true).unwrap();
        assert!(own.contains("--end-agents"), "{own}");
        let other = keychain_line(Some(false), false).unwrap();
        assert!(other.contains("keychain"), "{other}");
        assert!(!other.contains("--end-agents"), "{other}");
        assert!(!other.contains("in the login session)"), "{other}");
        assert!(keychain_line(None, false).unwrap().contains("unknown"));
    }

    #[test]
    fn no_gui_login_is_said_by_name_with_its_consequence_and_fix() {
        let line = no_gui_login_warning();
        assert!(line.contains(NO_GUI_LOGIN), "{line}");
        assert!(line.contains("keychain"), "{line}");
        assert!(line.contains("log in at the screen"), "{line}");
        // Agents already running keep the session they started in: the fix says how to end them.
        assert!(line.contains("--end-agents"), "{line}");
    }
}
