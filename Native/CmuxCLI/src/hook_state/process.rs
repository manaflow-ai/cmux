//! Process identity queries used by the persisted hook state.
//!
//! Codex uses `sysctl(KERN_PROC_PID)` so identities remain readable for
//! privileged ancestors such as `login`. Claude deliberately retains the
//! Swift CLI's `proc_pidinfo` and signal-zero behavior.

use super::CodexProcessGeneration;

fn validated_pid(pid: i64) -> Option<libc::pid_t> {
    libc::pid_t::try_from(pid).ok().filter(|pid| *pid > 0)
}

/// Read a live process's birth timestamp and parent from the same kernel
/// snapshot. A zombie is no longer a live owner, even before its parent reaps it.
pub fn process_snapshot(pid: i64) -> Option<(CodexProcessGeneration, i64)> {
    let pid = validated_pid(pid)?;
    platform::process_snapshot(pid).map(|(seconds, microseconds, parent)| {
        (
            CodexProcessGeneration {
                pid: i64::from(pid),
                start_seconds: seconds,
                start_microseconds: microseconds,
            },
            parent,
        )
    })
}

pub fn process_generation(pid: i64) -> Option<CodexProcessGeneration> {
    process_snapshot(pid).map(|(generation, _)| generation)
}

pub fn process_parent(pid: i64) -> Option<i64> {
    process_snapshot(pid).map(|(_, parent)| parent)
}

/// Match `ClaudeHookStateStore.processStartIdentity` in the Swift CLI.
/// `proc_pidinfo` can decline to describe a process owned by a different UID.
pub fn claude_process_start_identity(pid: i64) -> Option<(i64, i64)> {
    platform::claude_process_start_identity(validated_pid(pid)?)
}

/// Match Claude's liveness check: a process that exists but cannot be signaled
/// still exists. This intentionally does not use Codex's zombie rejection.
pub fn process_exists(pid: Option<i64>) -> bool {
    let Some(pid) = pid.and_then(validated_pid) else {
        return false;
    };
    // SAFETY: A positive representable PID and signal zero only query process
    // existence. No process receives a signal.
    (unsafe { libc::kill(pid, 0) == 0 })
        || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(target_os = "macos")]
mod platform {
    use std::mem::{MaybeUninit, size_of};

    unsafe extern "C" {
        fn cmux_cli_process_snapshot(
            pid: libc::pid_t,
            start_seconds: *mut i64,
            start_microseconds: *mut i64,
            parent_pid: *mut i64,
        ) -> libc::c_int;
    }

    pub fn process_snapshot(pid: libc::pid_t) -> Option<(i64, i64, i64)> {
        let mut seconds = 0;
        let mut microseconds = 0;
        let mut parent = 0;
        // SAFETY: The C shim accepts a checked positive PID and writes only to
        // these three initialized i64 values. It uses the SDK's kinfo_proc
        // definition, which libc intentionally does not expose on Darwin.
        let found =
            unsafe { cmux_cli_process_snapshot(pid, &mut seconds, &mut microseconds, &mut parent) };
        (found == 1).then_some((seconds, microseconds, parent))
    }

    pub fn claude_process_start_identity(pid: libc::pid_t) -> Option<(i64, i64)> {
        let mut info = MaybeUninit::<libc::proc_bsdinfo>::zeroed();
        let expected_size = size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: The allocation is exactly proc_bsdinfo's size, the supplied
        // flavor writes that structure, and it is read only after a full write.
        let size = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                info.as_mut_ptr().cast(),
                expected_size,
            )
        };
        if size != expected_size {
            return None;
        }
        // SAFETY: proc_pidinfo returned the full initialized structure above.
        let info = unsafe { info.assume_init() };
        Some((
            info.pbi_start_tvsec.try_into().ok()?,
            info.pbi_start_tvusec.try_into().ok()?,
        ))
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    // These identities are Darwin timestamps persisted by the original Swift
    // CLI. Do not fabricate comparable generations from another OS's clocks.
    pub fn process_snapshot(_pid: libc::pid_t) -> Option<(i64, i64, i64)> {
        None
    }

    pub fn claude_process_start_identity(_pid: libc::pid_t) -> Option<(i64, i64)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_process_ids_without_truncating() {
        for pid in [i64::MIN, -1, 0, i64::from(i32::MAX) + 1, i64::MAX] {
            assert!(process_generation(pid).is_none());
            assert!(process_parent(pid).is_none());
            assert!(claude_process_start_identity(pid).is_none());
            assert!(!process_exists(Some(pid)));
        }
        assert!(!process_exists(None));
        assert!(process_exists(Some(i64::from(std::process::id()))));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn identity_and_parent_match_the_current_process() {
        let pid = i64::from(std::process::id());
        let (generation, parent) = process_snapshot(pid).unwrap();
        assert_eq!(generation.pid, pid);
        // SAFETY: getppid has no inputs and only reads this process's parent.
        assert_eq!(parent, i64::from(unsafe { libc::getppid() }));
        assert_eq!(
            claude_process_start_identity(pid),
            Some((generation.start_seconds, generation.start_microseconds))
        );
        assert!(generation.start_seconds > 0);
        assert!((0..1_000_000).contains(&generation.start_microseconds));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn zombie_is_not_a_codex_process_owner() {
        let mut child = std::process::Command::new("/usr/bin/true").spawn().unwrap();
        let pid = child.id();
        let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: This waits for our own child, writes into a correctly sized
        // siginfo_t, and WNOWAIT leaves the process as a zombie for the checks.
        let wait_result = unsafe {
            libc::waitid(
                libc::P_PID,
                pid,
                info.as_mut_ptr(),
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        let exists = process_exists(Some(i64::from(pid)));
        let generation = process_generation(i64::from(pid));
        let parent = process_parent(i64::from(pid));
        let reaped = child.wait();
        assert_eq!(wait_result, 0);
        assert!(exists, "signal zero still sees an unreaped child");
        assert!(generation.is_none(), "zombies cannot retain ownership");
        assert!(parent.is_none(), "zombie snapshots are rejected entirely");
        assert!(reaped.unwrap().success());
        assert!(!process_exists(Some(i64::from(pid))));
    }
}
