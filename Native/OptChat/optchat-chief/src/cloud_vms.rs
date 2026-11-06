//! The cloud VMs cloud subagents run on (plans/cmux-next/cloud-subagents-DESIGN.md,
//! B4): the Chief host resumes a peer's VM before it starts or tells a
//! subagent there, and pauses it when no cloud subagent lives on it.

use std::path::PathBuf;

/// Starts and pauses the VM behind an acpmux peer.
pub trait CloudVms: Send + Sync {
    /// Whether the pool tool is set up (it can make VMs). False: cloud is
    /// not the default placement (cloud-subagents-DESIGN.md, v2).
    fn available(&self) -> bool {
        true
    }
    /// Makes sure peer `peer`'s VM runs (a no-op when it does); it blocks
    /// until the VM is up.
    fn resume(&self, peer: &str) -> Result<(), String>;
    /// Pauses peer `peer`'s VM: it keeps its memory (the acpmux sessions
    /// live on) and bills storage only.
    fn pause(&self, peer: &str) -> Result<(), String>;
    /// Writes subagent `agent`'s agent key file (agent_keys.rs) on peer
    /// `peer`'s VM, mode 0600 for the VM user. `file` holds a secret: it
    /// travels on stdin, never in an argument or a log.
    fn put_agent_key(&self, peer: &str, agent: &str, file: &str) -> Result<(), String> {
        let _ = (peer, agent, file);
        Err("this pool tool cannot place agent keys".into())
    }
    /// Makes subagent VM `peer` (`chief-sub-<id>`) at `size` (`small`,
    /// `medium`, `large`) from the shared base image when it does not exist
    /// yet, else resumes it; it blocks until the VM is up and is an acpmux
    /// peer. One VM per subagent (cloud-subagents-DESIGN.md).
    fn provision(&self, peer: &str, size: &str) -> Result<(), String> {
        let _ = size;
        self.resume(peer)
    }
    /// Deletes subagent VM `peer` and forgets the peer. Refused (Err) while
    /// a worktree there holds unpushed commits or edits.
    fn destroy(&self, peer: &str) -> Result<(), String> {
        Err(format!("this pool tool cannot delete {peer}"))
    }
    /// Removes subagent `agent`'s agent key file from peer `peer`'s VM.
    fn drop_agent_key(&self, peer: &str, agent: &str) -> Result<(), String> {
        let _ = (peer, agent);
        Ok(())
    }
}

/// The VM command the pool tool names: `~/.config/cloud-subagents/vm-cmd`
/// holds the path of `~/.local/bin/cloud-subagents-deploy`, which runs
/// cmuxterm-hq main's `tools/cloud-subagents/deploy.sh` from the installed hq
/// tools (never a task worktree's copy); `deploy.sh up` and
/// `deploy.sh install-vm-cmd` write both. No file: VMs are left as they are.
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
        self.run_with(&[verb, peer], None)
    }

    /// Runs the pool tool with `args`, `input` on stdin; no tool named: Ok.
    fn run_with(&self, args: &[&str], input: Option<&str>) -> Result<(), String> {
        use std::io::Write;
        let Ok(cmd) = std::fs::read_to_string(&self.file) else {
            return Ok(());
        };
        let cmd = cmd.trim();
        if cmd.is_empty() {
            return Ok(());
        }
        let shown = format!("{cmd} {}", args.join(" "));
        let mut child = std::process::Command::new(cmd)
            .args(args)
            .stdin(if input.is_some() {
                std::process::Stdio::piped()
            } else {
                std::process::Stdio::null()
            })
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("{shown}: {e}"))?;
        if let (Some(text), Some(mut stdin)) = (input, child.stdin.take()) {
            stdin
                .write_all(text.as_bytes())
                .map_err(|e| format!("{shown}: stdin: {e}"))?;
        }
        let out = child
            .wait_with_output()
            .map_err(|e| format!("{shown}: {e}"))?;
        let (verb, peer) = (
            args.first().copied().unwrap_or_default(),
            args.get(1).copied().unwrap_or_default(),
        );
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
    fn available(&self) -> bool {
        std::fs::read_to_string(&self.file).is_ok_and(|c| !c.trim().is_empty())
    }

    fn resume(&self, peer: &str) -> Result<(), String> {
        self.run("resume", peer)
    }

    fn pause(&self, peer: &str) -> Result<(), String> {
        self.run("pause", peer)
    }

    fn put_agent_key(&self, peer: &str, agent: &str, file: &str) -> Result<(), String> {
        if std::fs::read_to_string(&self.file)
            .map(|c| c.trim().is_empty())
            .unwrap_or(true)
        {
            return Err("no pool tool (~/.config/cloud-subagents/vm-cmd)".into());
        }
        self.run_with(&["agent-key", peer, agent], Some(file))
    }

    fn drop_agent_key(&self, peer: &str, agent: &str) -> Result<(), String> {
        self.run_with(&["agent-key-rm", peer, agent], None)
    }

    fn provision(&self, peer: &str, size: &str) -> Result<(), String> {
        if !self.has_tool() {
            return Err("no pool tool (~/.config/cloud-subagents/vm-cmd)".into());
        }
        self.run_with(&["resume", peer, "--size", size], None)
    }

    fn destroy(&self, peer: &str) -> Result<(), String> {
        if !self.has_tool() {
            return Err("no pool tool (~/.config/cloud-subagents/vm-cmd)".into());
        }
        self.run_with(&["destroy", peer], None)
    }
}

impl CommandVms {
    /// Whether the file names a pool tool that exists.
    fn has_tool(&self) -> bool {
        std::fs::read_to_string(&self.file)
            .map(|c| !c.trim().is_empty() && std::path::Path::new(c.trim()).exists())
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn the_agent_key_travels_on_stdin_to_the_pool_tool() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("cloud-vms-key-{}", std::process::id()));
        std::fs::create_dir_all(home.join(".config/cloud-subagents")).unwrap();
        let tool = home.join("tool.sh");
        let seen = home.join("seen");
        std::fs::write(
            &tool,
            format!(
                "#!/bin/sh\nprintf '%s ' \"$@\" > {s}\ncat >> {s}\n",
                s = seen.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(
            home.join(".config/cloud-subagents/vm-cmd"),
            format!("{}\n", tool.display()),
        )
        .unwrap();
        let vms = CommandVms::in_home(&home);
        vms.put_agent_key("chief-subagents-1", "a7", "{\"key\":\"secret\"}")
            .unwrap();
        assert_eq!(
            std::fs::read_to_string(&seen).unwrap(),
            "agent-key chief-subagents-1 a7 {\"key\":\"secret\"}"
        );
        vms.drop_agent_key("chief-subagents-1", "a7").unwrap();
        assert_eq!(
            std::fs::read_to_string(&seen).unwrap(),
            "agent-key-rm chief-subagents-1 a7 "
        );
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn without_a_pool_tool_no_key_is_placed() {
        let home = std::env::temp_dir().join(format!("cloud-vms-none-{}", std::process::id()));
        assert!(
            CommandVms::in_home(&home)
                .put_agent_key("p", "a1", "{}")
                .is_err()
        );
    }
}
