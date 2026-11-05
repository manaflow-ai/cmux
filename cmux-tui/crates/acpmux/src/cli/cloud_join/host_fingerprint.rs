//! Which box a machine credential was joined on. A home copied to another box (a VM image, a
//! restored disk, an rsync of `~/.acpmux`) carries `machine-credential.json` and `node.wg.key`,
//! and two boxes answering with one credential and one WireGuard key fight over one identity
//! (tailscale/tailscale#506: cloned `tailscaled.state` makes duplicate node keys fight; the fix
//! Tailscale gives is to re-authenticate the copy).
//!
//! The fingerprint is a domain-separated SHA-256 of the operating system's machine identity,
//! from the sources cmux-tui's host stamp reads (`cmux-tui-core`
//! `workspace_registry/host_identity.rs`): the cmux Cloud instance id, else `/etc/machine-id`
//! (or dbus's copy) on Linux, the host UUID on macOS. The raw id never rests in acpmux state.
//! A box with no OS identity (a container without a machine id) has no fingerprint, and then
//! nothing is compared.

/// The current box's fingerprint, or None when the OS names no machine.
pub(crate) fn current() -> Option<String> {
    os_machine_identity().map(|raw| of(&raw))
}

#[cfg(test)]
thread_local! {
    /// `Some(fp)` stands in for [`machine_only`] on this thread (`Some(None)`: none).
    pub(crate) static TEST_MACHINE_ONLY: std::cell::RefCell<Option<Option<String>>> =
        const { std::cell::RefCell::new(None) };
}

/// The fingerprint of the OS machine id alone, without the cmux Cloud instance id. cmux-host
/// writes `/etc/cmux/daemon-instance-id` when it binds an instance (`cmux-host`
/// `linux/identity.rs`), so a `host join` that ran before that bind recorded this one; the
/// same box then reads the instance id at its next start.
fn machine_only() -> Option<String> {
    #[cfg(test)]
    if let Some(fp) = TEST_MACHINE_ONLY.with(|cell| cell.borrow().clone()) {
        return fp;
    }
    machine_id().map(|raw| of(&raw))
}

/// Whether a record joined with fingerprint `joined` is this box, whose fingerprint is `here`:
/// the same fingerprint, or (an instance id bound since the join) the fingerprint of this
/// box's own machine id. A copy carries another box's machine id and matches neither.
pub(crate) fn same_box(joined: &str, here: &str) -> bool {
    joined == here || machine_only().is_some_and(|machine| machine == joined)
}

fn of(raw: &str) -> String {
    let mut bytes = b"acpmux machine credential host v1\0".to_vec();
    bytes.extend_from_slice(raw.as_bytes());
    crate::sha256::sha256_hex(&bytes)
}

/// On a cmux Cloud machine, the instance id cmux-host binds before it starts the daemon
/// (`/etc/machine-id` is rekeyed later on a fork). Elsewhere the systemd machine id.
#[cfg(target_os = "linux")]
fn os_machine_identity() -> Option<String> {
    if let Ok(value) = std::fs::read_to_string("/etc/cmux/daemon-instance-id") {
        let value = value.trim();
        if !value.is_empty() && value.len() <= 256 && !value.contains(char::is_whitespace) {
            return Some(format!("cmux-instance:{value}"));
        }
    }
    machine_id()
}

#[cfg(target_os = "linux")]
fn machine_id() -> Option<String> {
    ["/etc/machine-id", "/var/lib/dbus/machine-id"].iter().find_map(|path| {
        let value = std::fs::read_to_string(path).ok()?;
        let value = value.trim();
        // systemd's first-boot placeholder and an all-zero id name no machine.
        let valid = value.len() == 32
            && value.bytes().all(|byte| byte.is_ascii_hexdigit())
            && value.bytes().any(|byte| byte != b'0');
        valid.then(|| value.to_ascii_lowercase())
    })
}

#[cfg(target_os = "macos")]
fn os_machine_identity() -> Option<String> {
    let mut uuid = [0u8; 16];
    let timeout = libc::timespec { tv_sec: 5, tv_nsec: 0 };
    // SAFETY: gethostuuid writes exactly 16 bytes into `uuid`.
    let status = unsafe { libc::gethostuuid(uuid.as_mut_ptr(), &timeout) };
    (status == 0 && uuid.iter().any(|byte| *byte != 0))
        .then(|| uuid.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn os_machine_identity() -> Option<String> {
    None
}

/// Off Linux there is no separate instance id: the machine id is the whole identity.
#[cfg(not(target_os = "linux"))]
fn machine_id() -> Option<String> {
    os_machine_identity()
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_fingerprint_is_stable_hashed_and_differs_per_machine() {
        let first = super::of("0123456789abcdef0123456789abcdef");
        assert_eq!(first, super::of("0123456789abcdef0123456789abcdef"));
        assert_ne!(first, super::of("fedcba9876543210fedcba9876543210"));
        assert_eq!(first.len(), 64);
        assert!(!first.contains("0123456789abcdef0123456789abcdef"));
    }
}
