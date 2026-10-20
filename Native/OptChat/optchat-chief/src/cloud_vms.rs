//! The cloud VMs cloud subagents run on (plans/cmux-next/cloud-subagents-DESIGN.md,
//! B4): the Chief host resumes a peer's VM before it starts or tells a
//! subagent there, and pauses it when no cloud subagent lives on it.

use std::path::PathBuf;

/// Starts and pauses the VM behind an acpmux peer.
pub trait CloudVms: Send + Sync {
    /// Makes sure peer `peer`'s VM runs (a no-op when it does); it blocks
    /// until the VM is up.
    fn resume(&self, peer: &str) -> Result<(), String>;
    /// Pauses peer `peer`'s VM: it keeps its memory (the acpmux sessions
    /// live on) and bills storage only.
    fn pause(&self, peer: &str) -> Result<(), String>;
}

/// The VM command the pool tool names: `~/.config/cloud-subagents/vm-cmd`
/// holds the path of cmuxterm-hq `tools/cloud-subagents/deploy.sh`, which
/// `deploy.sh up` writes. No file: VMs are left as they are.
pub struct CommandVms {
    /// The file that names the command.
    pub file: PathBuf,
}

impl CommandVms {
    /// The command at `~/.config/cloud-subagents/vm-cmd` under `home`.
    pub fn in_home(home: &std::path::Path) -> CommandVms {
        CommandVms {
            file: home.join(".config/cloud-subagents/vm-cmd"),
        }
    }

    fn run(&self, verb: &str, peer: &str) -> Result<(), String> {
        let Ok(cmd) = std::fs::read_to_string(&self.file) else {
            return Ok(());
        };
        let cmd = cmd.trim();
        if cmd.is_empty() {
            return Ok(());
        }
        let out = std::process::Command::new(cmd)
            .args([verb, peer])
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| format!("{cmd} {verb} {peer}: {e}"))?;
        if out.status.success() {
            Ok(())
        } else {
            Err(format!(
                "{cmd} {verb} {peer}: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ))
        }
    }
}

impl CloudVms for CommandVms {
    fn resume(&self, peer: &str) -> Result<(), String> {
        self.run("resume", peer)
    }

    fn pause(&self, peer: &str) -> Result<(), String> {
        self.run("pause", peer)
    }
}
