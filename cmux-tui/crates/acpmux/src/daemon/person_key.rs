//! The person key a keyed daemon start hands the daemon: reading it from an inherited
//! descriptor, the not-dumpable guard around it, and `daemon start --person-key-fd`.
use super::*;

/// Read the person key (one line, at most 128 bytes) from an inherited
/// descriptor and close it. The key is never logged.
#[cfg(unix)]
pub(super) fn read_person_key(fd: i32) -> Option<String> {
    use std::io::Read;
    use std::os::fd::FromRawFd;
    if fd <= 2 {
        tracing::warn!("--person-key-fd {fd}: not a stdio descriptor");
        return None;
    }
    // Close the descriptor at exec too, so that no agent inherits it even
    // if a spawn starts before the read below returns.
    // SAFETY: fcntl on a descriptor number only sets its flags.
    unsafe {
        libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
    }
    if let Err(e) = not_dumpable() {
        // An agent this daemon starts (same uid) could read the key from
        // its memory: no key, so no allow, rather than a readable key.
        tracing::warn!(
            "--person-key-fd {fd}: refused, the daemon cannot be made not dumpable: {e}"
        );
        // SAFETY: the launcher passed this descriptor for us to close.
        drop(unsafe { std::fs::File::from_raw_fd(fd) });
        return None;
    }
    // SAFETY: the launcher passed this descriptor for us to read and close;
    // `File` owns and closes it here.
    let f = unsafe { std::fs::File::from_raw_fd(fd) };
    // A socket (`daemon start --person-key-fd`): say that this process is
    // not dumpable now; the launcher writes the key only after that, so a
    // same-uid reader of /proc/<pid>/fd before this point finds no key.
    if is_socket(&f) {
        use std::io::Write;
        if let Err(e) = (&f).write_all(KEY_READY) {
            tracing::warn!("--person-key-fd {fd}: {e}");
            return None;
        }
    }
    let mut buf = zeroize::Zeroizing::new(Vec::with_capacity(80));
    if let Err(e) = f.take(128).read_to_end(&mut buf) {
        tracing::warn!("--person-key-fd {fd}: {e}");
        return None;
    }
    let key = std::str::from_utf8(&buf).ok()?.trim().to_owned();
    if crate::hub::person::valid_key(&key) {
        Some(key)
    } else {
        tracing::warn!("--person-key-fd {fd}: not a person key");
        None
    }
}

/// What a daemon writes on a socket key descriptor once it is not dumpable.
pub(super) const KEY_READY: &[u8] = b"nodump\n";

/// Whether `f` is a socket.
#[cfg(unix)]
fn is_socket(f: &std::fs::File) -> bool {
    use std::os::unix::fs::FileTypeExt;
    f.metadata().is_ok_and(|m| m.file_type().is_socket())
}

/// `acpmux daemon start --person-key-fd <fd>` (cx-0q7o slice 2a, D2): the
/// app's own ssh exec (or the VM provisioning exec) passes this launch's
/// person key on `fd` (stdin: 0). This process makes itself not dumpable,
/// reads one line, starts the daemon with a socket pair as its key
/// descriptor, and writes the key only after the daemon said it is not
/// dumpable. A daemon that already runs holds another key or none: this
/// refuses then (a keyed restart stops it first with `daemon shutdown
/// --keep-agents`). Returns the daemon's readiness line.
#[cfg(unix)]
pub async fn start_keyed(fd: i32) -> Result<String> {
    not_dumpable().context("make the launcher not dumpable before it reads the person key")?;
    exe_path::check_start()?;
    let path = socket_path();
    if Client::connect(&path).await.is_ok() {
        return Err(anyhow!(
            "a daemon already runs at {}: it holds another person key or none; stop it with `acpmux daemon shutdown --keep-agents`, then start it again with the key",
            path.display()
        ));
    }
    let key = read_key_line(fd)?;
    // Another daemon is stopping or starting: start again until this key's daemon has the lock,
    // never leaving the caller to start an unkeyed one.
    loop {
        let ready = start_daemon_with(Some(key.clone())).await?;
        if !lock_held(&ready) {
            // A keyed daemon that exited before it was ready fails this start: the caller must
            // not go on to start an unkeyed daemon in its place.
            anyhow::ensure!(
                !ready.trim().is_empty(),
                "the keyed daemon exited before it was ready; see {}",
                home().join("daemon.log").display()
            );
            return Ok(ready);
        }
        tokio::time::sleep(HANDOVER_RETRY).await;
        if Client::connect(&path).await.is_ok() {
            return Err(anyhow!(
                "a daemon started at {} meanwhile: it holds another person key or none; stop it with `acpmux daemon shutdown --keep-agents`, then start it again with the key",
                path.display()
            ));
        }
    }
}

/// One person key line (64 lowercase hex characters and a newline) from `fd`, which stays open
/// (stdin), read straight into one fixed buffer that is zeroed on drop: no reader buffer keeps
/// another copy. The caller made itself not dumpable first.
#[cfg(unix)]
pub(crate) fn read_key_line(fd: i32) -> Result<zeroize::Zeroizing<String>> {
    use std::io::Read;
    use std::os::fd::FromRawFd;
    // SAFETY: the caller passed this descriptor for this process to read;
    // ManuallyDrop: stdin stays open for the process.
    let input = std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(fd) });
    let mut line = zeroize::Zeroizing::new([0u8; 129]);
    let mut filled = 0;
    while filled < line.len() && !line.get(..filled).unwrap_or_default().contains(&b'\n') {
        let Some(rest) = line.get_mut(filled..) else { break };
        match (&*input).read(rest) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e).context("read the person key"),
        }
    }
    let read = line.get(..filled).unwrap_or_default();
    let end = read.iter().position(|b| *b == b'\n').unwrap_or(filled);
    let key = zeroize::Zeroizing::new(
        std::str::from_utf8(read.get(..end).unwrap_or_default())
            .unwrap_or_default()
            .trim()
            .to_owned(),
    );
    if !crate::hub::person::valid_key(&key) {
        return Err(anyhow!(
            "--person-key-fd {fd}: not a person key (64 lowercase hex characters)"
        ));
    }
    Ok(key)
}

/// Makes this process not dumpable before it holds a person key (cx-0q7o):
/// on Linux, a same-uid process (an agent the daemon starts) can then not
/// ptrace it or read its memory through /proc, and the kernel owns its
/// /proc files. Also logs yama's ptrace_scope, the host's other ptrace rule.
#[cfg(target_os = "linux")]
pub(crate) fn not_dumpable() -> std::io::Result<()> {
    // SAFETY: PR_SET_DUMPABLE takes an integer and changes only this
    // process's dumpable flag.
    if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: PR_GET_DUMPABLE reads this process's flag.
    if unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(std::io::Error::other("PR_GET_DUMPABLE is not 0 after PR_SET_DUMPABLE 0"));
    }
    match std::fs::read_to_string("/proc/sys/kernel/yama/ptrace_scope") {
        Ok(scope) => tracing::info!("person key: not dumpable; yama ptrace_scope {}", scope.trim()),
        Err(_) => tracing::info!("person key: not dumpable; yama is not active"),
    }
    Ok(())
}

/// macOS and other Unix: no dumpable flag. A DEV daemon is unsigned and
/// takes the key at spawn; a Release daemon is hardened-runtime signed,
/// which refuses a debugger without the get-task-allow entitlement, and
/// ignores the key descriptor (it enrolls the signed app instead).
#[cfg(all(unix, not(target_os = "linux")))]
pub(crate) fn not_dumpable() -> std::io::Result<()> {
    Ok(())
}

/// Windows: an inherited handle (`daemon/windows.rs`).
#[cfg(windows)]
pub(super) fn read_person_key(fd: i32) -> Option<String> {
    windows::read_person_key(fd)
}
