//! `sudo acpmux machine consent grant --control`: this Mac's admin turns a consent surface on or
//! off with no app and no screen (Leo, 2026-11-15, on an agent that could not turn Control on for
//! a fleet Mac: "but why? why cant you do that? you should be able to do that.").
//!
//! The proof is sudo's: the admin password (or a sudoers rule the machine's admin wrote). Root can
//! already do anything on the Mac, so this widens nothing a non-admin could reach; a same-user
//! shell with no admin rights is still refused by the daemon's person check
//! (`server/pairing.rs` `machine_consent`). The write lands in the account sudo ran from
//! (`SUDO_UID`), as that account: the process drops to its uid and gid for good first, so the
//! consent file stays owned by the account and the authority resolves that account's home.
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

/// Sets `surface` as this Mac's admin when the process runs under sudo, and `None` otherwise (the
/// caller then asks the daemon, which only the app's person proof may change).
#[cfg(unix)]
pub(crate) fn set_if_admin(surface: &str, granted: bool) -> Result<Option<Consent>> {
    let Some((uid, gid)) = sudo_account()? else { return Ok(None) };
    // ACPMUX_HOME outranks the override below, so the join (for `signedInMachines`) would be
    // read from another home than the consent is written to: refuse it.
    anyhow::ensure!(
        std::env::var_os("ACPMUX_HOME").is_none(),
        "unset ACPMUX_HOME: as this Mac's admin, consent is set in the account's own acpmux home"
    );
    let home = super::machine_consent::home_of_uid(uid)?;
    // The account's own acpmux home: its join (for `signedInMachines`) and legacy consent live there.
    crate::config::set_home_override(crate::config::default_home_in(&home));
    drop_to(uid, gid)?;
    let consent = super::cloud_join::set_consent_for_person(surface, granted)?;
    tracing::info!(surface, granted, uid, "machine consent set by this Mac's admin (sudo)");
    Ok(Some(consent))
}

/// Becomes the account for good: its group alone, then its gid, then its uid (real, effective and
/// saved), so the private-state checks, which compare owners with the real uid, see the account,
/// and nothing after this can act as root again.
#[cfg(unix)]
fn drop_to(uid: libc::uid_t, gid: libc::gid_t) -> Result<()> {
    // SAFETY: plain syscalls on values we own; groups before gid before uid, since each later
    // step gives up the right to the earlier ones.
    unsafe {
        anyhow::ensure!(libc::setgroups(1, &gid) == 0, "could not switch to the account's groups");
        anyhow::ensure!(libc::setgid(gid) == 0, "could not switch to the account's group");
        anyhow::ensure!(libc::setuid(uid) == 0, "could not switch to the account");
        anyhow::ensure!(
            libc::getuid() == uid && libc::geteuid() == uid && libc::getgid() == gid,
            "still running as root after switching to the account"
        );
        anyhow::ensure!(libc::setuid(0) != 0, "could switch back to root after the switch");
    }
    Ok(())
}

#[cfg(not(unix))]
pub(crate) fn set_if_admin(_surface: &str, _granted: bool) -> Result<Option<Consent>> {
    Ok(None)
}

#[cfg(test)]
#[path = "consent_admin_tests.rs"]
mod tests;
