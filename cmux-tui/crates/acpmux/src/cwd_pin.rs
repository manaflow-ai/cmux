//! The folder a harness must exec in, by identity (device and inode): a sub-session's folder as
//! its start checked it (`hub/subsession_guard.rs` `CheckedFolder`). The harness process checks
//! it itself, after it changed into its folder by path and right before it execs, so a folder
//! renamed or a link swapped at any point after the start's check fails the spawn instead of
//! running the harness there. A start carries it to every spawn it makes: a direct child
//! (`agent/command.rs`, through a task-local [`CwdPin::scope`]), an agent host (`SpawnSpec`), and
//! the fresh host that replaces one that did not answer. Unix only; Windows spawns as before.

use serde::{Deserialize, Serialize};
use std::future::Future;
use std::path::Path;

/// A folder's device and inode, as `std::os::unix::fs::MetadataExt` reads them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CwdPin {
    pub dev: u64,
    pub ino: u64,
}

tokio::task_local! {
    static PIN: CwdPin;
}

impl CwdPin {
    /// The pin of the folder `dir` leads to now; None when it cannot be read, or off unix.
    pub fn of(dir: &Path) -> Option<Self> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            std::fs::metadata(dir).ok().map(|m| Self { dev: m.dev(), ino: m.ino() })
        }
        #[cfg(not(unix))]
        {
            let _ = dir;
            None
        }
    }

    /// Runs `f` with every harness command it builds pinned to `pin` (none: as before).
    pub async fn scope<F: Future>(pin: Option<Self>, f: F) -> F::Output {
        match pin {
            Some(pin) => PIN.scope(pin, f).await,
            None => f.await,
        }
    }

    /// The pin of the [`CwdPin::scope`] this task runs in, if any.
    pub fn current() -> Option<Self> {
        PIN.try_with(|pin| *pin).ok()
    }

    /// Makes `cmd` fail its spawn (`ESTALE`) unless the folder it changed into is `pin`'s. The
    /// check runs in the child after its `chdir` and before its `exec`.
    #[cfg(unix)]
    pub fn pin(pin: Option<Self>, cmd: &mut tokio::process::Command) {
        let Some(Self { dev, ino }) = pin else { return };
        // SAFETY: the hook runs in the child between fork and exec. It calls only stat(2) on a
        // static C string and compares integers: no allocation, no lock, async-signal-safe.
        unsafe {
            cmd.pre_exec(move || {
                let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
                if libc::stat(c".".as_ptr(), st.as_mut_ptr()) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                let st = st.assume_init();
                // As `MetadataExt` widens them: `dev_t` is i32 on macOS.
                #[allow(clippy::unnecessary_cast)]
                let here = (st.st_dev as u64, st.st_ino as u64);
                if here == (dev, ino) {
                    Ok(())
                } else {
                    Err(std::io::Error::from_raw_os_error(libc::ESTALE))
                }
            });
        }
    }

    /// A command for `program`, pinned to `pin` ([`CwdPin::pin`]).
    #[cfg(unix)]
    pub fn command(program: &str, pin: Option<Self>) -> tokio::process::Command {
        let mut cmd = tokio::process::Command::new(program);
        Self::pin(pin, &mut cmd);
        cmd
    }
}
