//! Where a daemon a command starts runs (`daemon/login_session.rs`, macOS): decided from three
//! facts, so every platform's tests check the decision itself.

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
}

/// The reason [`Placement::NoGuiLogin`] names, in the starting command's warning and in
/// `daemon status`.
pub(crate) const NO_GUI_LOGIN: &str = "login_session.no_gui_login";

/// Where a daemon goes: `in_login_session` (this command's security session reaches the GUI),
/// `own_home` (the home is under the person's `~/.acpmux`), `gui_login` (the user's `gui/<uid>`
/// launchd domain exists: someone is logged in at the screen).
pub(crate) fn placement(in_login_session: bool, own_home: bool, gui_login: bool) -> Placement {
    if in_login_session || !own_home || !gui_login {
        return Placement::InPlace;
    }
    Placement::LoginJob
}

/// The one line the starting command prints for [`Placement::NoGuiLogin`].
pub(crate) fn no_gui_login_warning() -> String {
    format!("acpmux: {NO_GUI_LOGIN}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ssh_started_daemon_goes_to_the_gui_session_only_when_there_is_one() {
        // Over ssh (not in the login session), the person's own home:
        assert_eq!(placement(false, true, true), Placement::LoginJob);
        assert_eq!(placement(false, true, false), Placement::NoGuiLogin);
        // In the login session already, or a test's home: here, as before.
        assert_eq!(placement(true, true, true), Placement::InPlace);
        assert_eq!(placement(true, true, false), Placement::InPlace);
        assert_eq!(placement(false, false, true), Placement::InPlace);
        assert_eq!(placement(false, false, false), Placement::InPlace);
    }

    #[test]
    fn no_gui_login_is_said_by_name_with_its_consequence_and_fix() {
        let line = no_gui_login_warning();
        assert!(line.contains(NO_GUI_LOGIN), "{line}");
        assert!(line.contains("keychain"), "{line}");
        assert!(line.contains("log in at the screen"), "{line}");
    }
}
