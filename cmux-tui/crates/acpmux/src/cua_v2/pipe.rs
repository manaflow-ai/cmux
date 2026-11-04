//! The Windows transport of the bridge: the cmux Remote host's Computer Use
//! worker pipe (`\\.\pipe\cmux-remote-<leaf>-cu`, owner-only DACL, remote
//! clients rejected by the server).
//!
//! - Every open uses identification-only QoS, so the server can identify
//!   this client (the worker's admission reads its pid and token) but never
//!   act as it.
//! - The worker keeps one listening instance; while each instance is taken,
//!   an open fails with `ERROR_PIPE_BUSY`. The bridge then waits on
//!   `WaitNamedPipeW` (the OS signal that an instance is free) for at most
//!   [`BUSY_WAIT`] in all, never a sleep loop.
//! - The secret is sent only after `GetNamedPipeServerProcessId` names a
//!   server process whose token user is this user (the peer uid check on
//!   Unix).

use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use tokio::net::windows::named_pipe::{ClientOptions, NamedPipeClient};
use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::Storage::FileSystem::SECURITY_IDENTIFICATION;
use windows_sys::Win32::System::Pipes::{GetNamedPipeServerProcessId, WaitNamedPipeW};

/// `ERROR_PIPE_BUSY`: every instance of the pipe is connected.
const ERROR_PIPE_BUSY: i32 = 231;
/// The longest the bridge waits for a busy pipe's next instance.
pub(super) const BUSY_WAIT: Duration = Duration::from_secs(5);

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain([0]).collect()
}

fn require_local_pipe(name: &Path) -> Result<()> {
    if super::is_local_pipe_name(&name.to_string_lossy()) {
        Ok(())
    } else {
        bail!("{} is not a local named pipe", name.display())
    }
}

fn open(name: &Path) -> std::io::Result<NamedPipeClient> {
    ClientOptions::new().security_qos_flags(SECURITY_IDENTIFICATION).open(name)
}

/// Opens the worker's pipe, waiting at most [`BUSY_WAIT`] while it is busy.
pub(super) async fn connect(name: &Path) -> Result<NamedPipeClient> {
    require_local_pipe(name)?;
    let deadline = Instant::now() + BUSY_WAIT;
    loop {
        match open(name) {
            Ok(client) => return Ok(client),
            Err(error) if error.raw_os_error() == Some(ERROR_PIPE_BUSY) => {
                let left = deadline.saturating_duration_since(Instant::now());
                let millis = u32::try_from(left.as_millis()).unwrap_or(u32::MAX);
                if millis == 0 {
                    bail!("{} stayed busy for {BUSY_WAIT:?}", name.display());
                }
                let wide = wide(name);
                // WaitNamedPipeW blocks until an instance is free or the time is up.
                let free = tokio::task::spawn_blocking(move || {
                    // SAFETY: a NUL-terminated name that lives for the call.
                    if unsafe { WaitNamedPipeW(wide.as_ptr(), millis) } != 0 {
                        Ok(())
                    } else {
                        Err(std::io::Error::last_os_error())
                    }
                })
                .await
                .unwrap_or_else(|join| Err(std::io::Error::other(join)));
                if let Err(error) = free {
                    bail!("{} stayed busy for {BUSY_WAIT:?} ({error})", name.display());
                }
                // Free now; another client may still win it, so open again.
            }
            Err(error) => {
                return Err(error).with_context(|| format!("cannot connect to {}", name.display()));
            }
        }
    }
}

/// The pipe's server process must run as this user before the secret goes out.
pub(super) fn require_same_user_server(client: &NamedPipeClient, name: &Path) -> Result<()> {
    let mut pid = 0_u32;
    // SAFETY: a connected client handle and a u32 out pointer.
    let ok =
        unsafe { GetNamedPipeServerProcessId(client.as_raw_handle() as HANDLE, &mut pid) } != 0;
    if !ok {
        bail!(
            "cannot read the server process of {} ({}); the secret was not sent",
            name.display(),
            std::io::Error::last_os_error()
        );
    }
    let me = cmux::local_socket::win::current_identity()
        .context("cannot read this process's user")?
        .user_sid;
    let server = cmux::local_socket::win::process_identity(pid)
        .map_err(|e| {
            anyhow!(
                "cannot read the user of {}'s server (pid {pid}): {e}; the secret was not sent",
                name.display()
            )
        })?
        .user_sid;
    if !server.eq_ignore_ascii_case(&me) {
        bail!(
            "{} is served by {server}, not this user ({me}); the secret was not sent",
            name.display()
        );
    }
    Ok(())
}

/// Whether the pipe has a server: an open that succeeds (closed at once; the
/// worker drops a client that sends no secret) or one refused as busy.
pub(super) fn probe(name: &Path) -> Result<(), String> {
    use std::os::windows::fs::OpenOptionsExt;
    if !super::is_local_pipe_name(&name.to_string_lossy()) {
        return Err(format!("{} is not a local named pipe", name.display()));
    }
    match std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .security_qos_flags(SECURITY_IDENTIFICATION)
        .open(name)
    {
        Ok(_) => Ok(()),
        Err(error) if error.raw_os_error() == Some(ERROR_PIPE_BUSY) => Ok(()),
        Err(error) => Err(error.to_string()),
    }
}
