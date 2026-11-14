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
mod tests;
