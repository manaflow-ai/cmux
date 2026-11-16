//! `sudo acpmux machine consent grant --control`: this Mac's admin turns a consent surface on or
//! off with no app and no screen (Leo, 2026-11-15, on an agent that could not turn Control on for
//! a fleet Mac: "but why? why cant you do that? you should be able to do that.").
//!
//! The proof is sudo's: the admin password (or a sudoers rule the machine's admin wrote). Root can
//! already do anything on the Mac, so this widens nothing a non-admin could reach; a same-user
//! shell with no admin rights is still refused by the daemon's person check
//! (`server/pairing.rs` `machine_consent`). The write lands in the account sudo ran from
//! (`SUDO_UID`), as that account: the process drops to its uid and gid first, so the consent
//! file stays owned by the account and the authority resolves that account's home.
use super::cloud_join::Consent;
use anyhow::{Result, anyhow};

/// The account `sudo` ran from, when this process runs as root under sudo.
#[cfg(unix)]
fn sudo_account() -> Result<Option<(libc::uid_t, libc::gid_t)>> {
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } != 0 {
        return Ok(None);
    }
    let Ok(uid) = std::env::var("SUDO_UID") else { return Ok(None) };
    let uid: libc::uid_t = uid.parse().map_err(|_| anyhow!("SUDO_UID is not a number"))?;
    let gid: libc::gid_t = std::env::var("SUDO_GID")
        .map_err(|_| anyhow!("SUDO_GID is missing"))?
        .parse()
        .map_err(|_| anyhow!("SUDO_GID is not a number"))?;
    anyhow::ensure!(uid != 0, "run it with sudo from the account whose consent it sets, not root");
    Ok(Some((uid, gid)))
}

#[cfg(unix)]
fn home_of(uid: libc::uid_t) -> Result<std::path::PathBuf> {
    use std::ffi::{CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 64 * 1024];
    // SAFETY: all output pointers refer to live buffers; the returned strings stay valid while
    // `buffer` lives, and are copied out before it drops.
    let code = unsafe {
        libc::getpwuid_r(
            uid,
            entry.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    anyhow::ensure!(code == 0 && !result.is_null(), "no account for uid {uid}");
    // SAFETY: getpwuid_r succeeded, so `entry` is initialized and pw_dir is a C string in `buffer`.
    let dir = unsafe { CStr::from_ptr(entry.assume_init().pw_dir) };
    Ok(std::path::PathBuf::from(OsStr::from_bytes(dir.to_bytes())))
}

/// Sets `surface` as this Mac's admin when the process runs under sudo, and `None` otherwise (the
/// caller then asks the daemon, which only the app's person proof may change).
#[cfg(unix)]
pub(crate) fn set_if_admin(surface: &str, granted: bool) -> Result<Option<Consent>> {
    let Some((uid, gid)) = sudo_account()? else { return Ok(None) };
    let home = home_of(uid)?;
    // The account's own acpmux home: its join (for `signedInMachines`) and legacy consent live there.
    crate::config::set_home_override(home.join(".acpmux"));
    // SAFETY: plain syscalls; group first, since dropping the uid first loses the right to.
    unsafe {
        anyhow::ensure!(libc::setegid(gid) == 0, "could not switch to the account's group");
        anyhow::ensure!(libc::seteuid(uid) == 0, "could not switch to the account");
    }
    let consent = super::cloud_join::set_consent_for_person(surface, granted)?;
    tracing::info!(surface, granted, uid, "machine consent set by this Mac's admin (sudo)");
    Ok(Some(consent))
}

#[cfg(not(unix))]
pub(crate) fn set_if_admin(_surface: &str, _granted: bool) -> Result<Option<Consent>> {
    Ok(None)
}

#[cfg(test)]
mod tests {
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
}
