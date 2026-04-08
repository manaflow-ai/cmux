use anyhow::Result;

use crate::policy::ResourceCaps;
use crate::registry::{AgentId, Registry, ResourceUsage};

/// Signal action for an agent that exceeds resource limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KillAction {
    /// Suspend the process (SIGSTOP).
    Stop,
    /// Terminate the process (SIGKILL).
    Kill,
}

/// Result of checking one agent against resource limits.
#[derive(Debug)]
pub struct GovernorVerdict {
    pub agent_id: AgentId,
    pub pid: u32,
    pub action: Option<KillAction>,
    pub reason: Option<String>,
}

/// Apply `setrlimit` caps to a child process by PID.
///
/// This sets soft limits so the OS warns/kills the process.
/// On macOS, `RLIMIT_RSS` is advisory — the governor's periodic sampler
/// enforces RSS via `task_info` + SIGKILL instead.
pub fn apply_resource_limits(pid: u32, caps: &ResourceCaps) -> Result<()> {
    if caps.cpu_time_secs > 0 {
        set_rlimit(pid, libc::RLIMIT_CPU, caps.cpu_time_secs)?;
    }
    if caps.address_space_bytes > 0 {
        set_rlimit(pid, libc::RLIMIT_AS, caps.address_space_bytes)?;
    }
    // RSS rlimit is advisory on macOS; we enforce via sampling.
    if caps.rss_bytes > 0 {
        set_rlimit(pid, libc::RLIMIT_RSS, caps.rss_bytes)?;
    }
    Ok(())
}

fn set_rlimit(pid: u32, resource: libc::c_int, limit: u64) -> Result<()> {
    // setrlimit only works on the calling process; for child processes we
    // apply limits before exec. This is a best-effort call for the current
    // process context (used when avmd itself is the parent).
    //
    // For external PIDs, the governor relies on periodic sampling + kill.
    if pid == std::process::id() {
        let rlim = libc::rlimit {
            rlim_cur: limit as libc::rlim_t,
            rlim_max: limit as libc::rlim_t,
        };
        let ret = unsafe { libc::setrlimit(resource, &raw const rlim) };
        if ret != 0 {
            anyhow::bail!(
                "setrlimit(resource={resource}, limit={limit}) failed: {}",
                std::io::Error::last_os_error()
            );
        }
    }
    Ok(())
}

/// Read resource usage for a process via macOS `proc_pid_rusage`.
///
/// Falls back to `/proc` on Linux (not implemented — macOS only for now).
pub fn sample_usage(pid: u32) -> Result<ResourceUsage> {
    #[cfg(target_os = "macos")]
    {
        sample_usage_macos(pid)
    }
    #[cfg(not(target_os = "macos"))]
    {
        anyhow::bail!("resource sampling not implemented for this platform (pid={pid})")
    }
}

#[cfg(target_os = "macos")]
fn sample_usage_macos(pid: u32) -> Result<ResourceUsage> {
    use std::mem::MaybeUninit;

    // Use proc_pid_rusage for accurate per-process stats.
    // RUSAGE_INFO_V0 gives us ri_resident_size and ri_user_time + ri_system_time.
    let mut info = MaybeUninit::<libc::rusage_info_v0>::uninit();

    #[allow(clippy::cast_possible_wrap)]
    let ret = unsafe {
        libc::proc_pid_rusage(
            pid as i32,
            libc::RUSAGE_INFO_V0,
            info.as_mut_ptr().cast::<libc::rusage_info_t>(),
        )
    };

    if ret != 0 {
        anyhow::bail!(
            "proc_pid_rusage({pid}) failed: {}",
            std::io::Error::last_os_error()
        );
    }

    let info = unsafe { info.assume_init() };

    let user_ns = info.ri_user_time;
    let sys_ns = info.ri_system_time;
    #[allow(clippy::cast_precision_loss)]
    let cpu_secs = (user_ns + sys_ns) as f64 / 1_000_000_000.0;

    Ok(ResourceUsage {
        cpu_secs,
        rss_bytes: info.ri_resident_size,
    })
}

/// Check a single agent against resource caps and return a verdict.
pub fn check_agent(
    registry: &Registry,
    agent_id: AgentId,
    caps: &ResourceCaps,
) -> Option<GovernorVerdict> {
    let entry = registry.get(agent_id)?;

    let usage = match sample_usage(entry.pid) {
        Ok(u) => u,
        Err(e) => {
            tracing::warn!(agent_id, pid = entry.pid, "failed to sample usage: {e}");
            return Some(GovernorVerdict {
                agent_id,
                pid: entry.pid,
                action: None,
                reason: Some(format!("sample failed: {e}")),
            });
        }
    };

    // Check RSS — kill if over 2x limit, stop if over 1x.
    if caps.rss_bytes > 0 && usage.rss_bytes > caps.rss_bytes * 2 {
        return Some(GovernorVerdict {
            agent_id,
            pid: entry.pid,
            action: Some(KillAction::Kill),
            reason: Some(format!(
                "RSS {} exceeds 2x limit {}",
                usage.rss_bytes, caps.rss_bytes
            )),
        });
    }
    if caps.rss_bytes > 0 && usage.rss_bytes > caps.rss_bytes {
        return Some(GovernorVerdict {
            agent_id,
            pid: entry.pid,
            action: Some(KillAction::Stop),
            reason: Some(format!(
                "RSS {} exceeds limit {}",
                usage.rss_bytes, caps.rss_bytes
            )),
        });
    }

    // Check CPU time — kill if over limit.
    #[allow(clippy::cast_precision_loss)]
    if caps.cpu_time_secs > 0 && usage.cpu_secs > caps.cpu_time_secs as f64 {
        return Some(GovernorVerdict {
            agent_id,
            pid: entry.pid,
            action: Some(KillAction::Kill),
            reason: Some(format!(
                "CPU time {:.1}s exceeds limit {}s",
                usage.cpu_secs, caps.cpu_time_secs
            )),
        });
    }

    None
}

/// Execute a kill action (SIGSTOP or SIGKILL) on a process.
pub fn execute_action(pid: u32, action: KillAction) -> Result<()> {
    let signal = match action {
        KillAction::Stop => libc::SIGSTOP,
        KillAction::Kill => libc::SIGKILL,
    };

    #[allow(clippy::cast_possible_wrap)]
    let ret = unsafe { libc::kill(pid as i32, signal) };
    if ret != 0 {
        anyhow::bail!(
            "kill(pid={pid}, sig={signal}) failed: {}",
            std::io::Error::last_os_error()
        );
    }

    tracing::warn!(pid, ?action, "governor action executed");
    Ok(())
}

/// Run one governance cycle: sample all agents, enforce limits, update registry.
pub fn sweep(registry: &mut Registry, caps: &ResourceCaps) -> Vec<GovernorVerdict> {
    let ids: Vec<AgentId> = registry.all().map(|a| a.id).collect();
    let mut verdicts = Vec::new();

    for id in ids {
        // Update stored usage.
        if let Some(entry) = registry.get(id) {
            let pid = entry.pid;
            if let Ok(usage) = sample_usage(pid) {
                if let Some(entry) = registry.get_mut(id) {
                    entry.last_usage = Some(usage);
                }
            }
        }

        if let Some(verdict) = check_agent(registry, id, caps) {
            if let Some(action) = verdict.action {
                if let Err(e) = execute_action(verdict.pid, action) {
                    tracing::error!(pid = verdict.pid, "failed to execute {action:?}: {e}");
                }
                // Deregister killed agents.
                if action == KillAction::Kill {
                    registry.deregister(id);
                }
            }
            verdicts.push(verdict);
        }
    }

    verdicts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sample_own_process() {
        let pid = std::process::id();
        let usage = sample_usage(pid).unwrap();
        // Our own process should have some CPU usage.
        assert!(usage.cpu_secs >= 0.0);
        assert!(usage.rss_bytes > 0);
    }

    #[test]
    fn check_agent_within_limits() {
        let mut reg = Registry::new();
        let id = reg.register("self".to_string(), std::process::id());

        let caps = ResourceCaps {
            cpu_time_secs: 999_999,
            rss_bytes: 100 * 1024 * 1024 * 1024, // 100 GiB
            address_space_bytes: 0,
        };

        let verdict = check_agent(&reg, id, &caps);
        // Our own process should be within generous limits.
        assert!(verdict.is_none());
    }

    #[test]
    fn check_agent_exceeds_rss() {
        let mut reg = Registry::new();
        let id = reg.register("self".to_string(), std::process::id());

        let caps = ResourceCaps {
            cpu_time_secs: 999_999,
            rss_bytes: 1, // 1 byte — guaranteed to exceed
            address_space_bytes: 0,
        };

        let verdict = check_agent(&reg, id, &caps).unwrap();
        // Should be Kill since our RSS is > 2 bytes (2x limit of 1).
        assert_eq!(verdict.action, Some(KillAction::Kill));
    }

    #[test]
    fn nonexistent_pid_returns_sample_error() {
        let result = sample_usage(99_999_999);
        assert!(result.is_err());
    }
}
