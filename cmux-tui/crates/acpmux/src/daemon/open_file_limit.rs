//! The daemon's open-file limit. launchd starts a user agent with a soft
//! RLIMIT_NOFILE of 256 (`launchctl limit maxfiles`), and the plist that starts
//! acpmux is written by hand on each Mac, so nothing raises it there. A daemon
//! with a few hundred sessions holds more than 256 descriptors (cmux16,
//! 2026-10-22: every agent start then failed with "Too many open files").
//! The hard limit is usually far above it, so the daemon raises its own soft
//! limit at start; the agents it starts inherit it.

/// The soft limit the daemon asks for, as far as the hard limit allows.
const WANTED: u64 = 65_536;

/// macOS's `OPEN_MAX`: older kernels refuse a soft limit above it.
#[cfg(target_os = "macos")]
const OPEN_MAX: u64 = 10_240;

/// Raises the soft RLIMIT_NOFILE to `min(hard, 65536)` (on macOS also at most
/// `kern.maxfilesperproc`) and logs the old and new values. Never lowers it.
pub(super) fn raise() {
    let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) } != 0 {
        tracing::warn!("open-file limit: getrlimit: {}", std::io::Error::last_os_error());
        return;
    }
    let (soft, hard) = (lim.rlim_cur, lim.rlim_max);
    let target = target(soft, hard, per_process_cap());
    if target <= soft {
        return;
    }
    match set_soft(target, lim.rlim_max) {
        Ok(()) => {
            tracing::info!("open-file limit raised from {soft} to {target} (hard {})", show(hard))
        }
        // Older macOS refuses a soft limit above OPEN_MAX.
        #[cfg(target_os = "macos")]
        Err(_) if target > OPEN_MAX && OPEN_MAX > soft => match set_soft(OPEN_MAX, lim.rlim_max) {
            Ok(()) => {
                tracing::info!(
                    "open-file limit raised from {soft} to {OPEN_MAX} (hard {})",
                    show(hard)
                );
            }
            Err(e) => tracing::warn!("open-file limit stays {soft}: setrlimit: {e}"),
        },
        Err(e) => tracing::warn!("open-file limit stays {soft}: setrlimit {target}: {e}"),
    }
}

fn set_soft(soft: u64, hard: libc::rlim_t) -> std::io::Result<()> {
    let lim = libc::rlimit { rlim_cur: soft as libc::rlim_t, rlim_max: hard };
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &lim) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// A limit as `ulimit -n` shows it: `RLIM_INFINITY` is "unlimited".
fn show(limit: u64) -> String {
    if limit == libc::RLIM_INFINITY { "unlimited".to_owned() } else { limit.to_string() }
}

/// The soft limit to set: `WANTED`, at most the hard limit and the kernel's
/// per-process cap, and never below the current soft limit.
fn target(soft: u64, hard: u64, cap: Option<u64>) -> u64 {
    WANTED.min(hard).min(cap.unwrap_or(u64::MAX)).max(soft)
}

/// `kern.maxfilesperproc`: macOS refuses a soft limit above it.
#[cfg(target_os = "macos")]
fn per_process_cap() -> Option<u64> {
    let mut value: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>();
    let rc = unsafe {
        libc::sysctlbyname(
            c"kern.maxfilesperproc".as_ptr(),
            (&raw mut value).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0 && value > 0).then_some(value as u64)
}

#[cfg(not(target_os = "macos"))]
fn per_process_cap() -> Option<u64> {
    None
}
