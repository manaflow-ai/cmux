//! The exec of a restart in place (`daemon/handoff.rs`): this process's image is replaced, so
//! nothing is started and there is no child to own.

use std::ffi::OsStr;
use std::os::fd::RawFd;
use std::path::Path;

/// Exec `program` as `arg0` with `args`, `fds` inherited: close-on-exec is cleared on exactly
/// those. Returns only when the exec failed: its error, with `fds` close-on-exec again and this
/// thread's signal state as before (std resets SIGPIPE and the signal mask for the program it
/// runs).
pub(super) fn exec_with(
    program: &Path,
    arg0: &OsStr,
    args: &[String],
    fds: &[RawFd],
) -> std::io::Error {
    use std::os::unix::process::CommandExt;
    // SAFETY: all-zero sigaction and sigset_t are valid values; the calls only fill them.
    let mut pipe: libc::sigaction = unsafe { std::mem::zeroed() };
    // SAFETY: as above.
    let mut mask: libc::sigset_t = unsafe { std::mem::zeroed() };
    // SAFETY: a null new action or set only reads the current one.
    unsafe {
        libc::sigaction(libc::SIGPIPE, std::ptr::null(), &mut pipe);
        libc::pthread_sigmask(libc::SIG_SETMASK, std::ptr::null(), &mut mask);
    }
    for fd in fds {
        super::set_cloexec(*fd, false);
    }
    let error = std::process::Command::new(program).arg0(arg0).args(args).exec();
    for fd in fds {
        super::set_cloexec(*fd, true);
    }
    // SAFETY: the action and the mask read above, put back.
    unsafe {
        libc::sigaction(libc::SIGPIPE, &pipe, std::ptr::null_mut());
        libc::pthread_sigmask(libc::SIG_SETMASK, &mask, std::ptr::null_mut());
    }
    error
}
