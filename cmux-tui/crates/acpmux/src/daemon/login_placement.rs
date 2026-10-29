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
    use std::hash::{Hash, Hasher};
    let home = std::fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf());
    let mut h = std::collections::hash_map::DefaultHasher::new();
    home.hash(&mut h);
    format!("com.cmux.acpmux.daemon.{:016x}", h.finish())
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
        let _ = std::fs::remove_dir_all(&dir);
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
