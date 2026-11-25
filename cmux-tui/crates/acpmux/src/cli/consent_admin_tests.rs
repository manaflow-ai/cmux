use crate::cli::command::{Cli, Command, PeerCmd};
use crate::cli::command_host::ConsentCmd;
use clap::Parser;

fn grant(args: &[&str]) -> Result<ConsentCmd, clap::Error> {
    let mut argv = vec!["acpmux", "machine", "consent", "grant"];
    argv.extend_from_slice(args);
    match Cli::try_parse_from(argv)?.command.unwrap() {
        Command::Host(PeerCmd::Consent { cmd }) => Ok(cmd),
        _ => panic!("not a consent command"),
    }
}

#[test]
fn consent_cli_takes_exactly_one_surface_including_signed_in_machines() {
    assert!(matches!(
        grant(&["--signed-in-machines"]).unwrap(),
        ConsentCmd::Grant { signed_in_machines: true, screen: false, control: false }
    ));
    assert!(matches!(
        grant(&["--control"]).unwrap(),
        ConsentCmd::Grant { control: true, screen: false, signed_in_machines: false }
    ));
    assert!(grant(&[]).is_err());
    assert!(grant(&["--control", "--screen"]).is_err());
}

/// Not under sudo, nothing is written here: the caller asks the daemon, which a plain shell
/// cannot satisfy.
#[cfg(unix)]
#[test]
fn a_plain_shell_is_not_the_admin() {
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } == 0 && std::env::var_os("SUDO_UID").is_some() {
        return; // a test runner under sudo is the admin; nothing to check here
    }
    assert!(super::set_if_admin("control", true).unwrap().is_none());
}
