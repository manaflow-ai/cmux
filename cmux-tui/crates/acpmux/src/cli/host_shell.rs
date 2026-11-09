//! `acpmux machine shell MACHINE [--cwd DIR]`: a login shell on a machine this one added, over
//! `ssh -t`, in this terminal. A machine added without a cmux daemon (`acpmux machine enroll`) has
//! no terminal of its own, so the app's chat header Terminal runs this in a terminal tab for a chat
//! on that machine: the shell is on the machine the agent works on, in the chat's folder there.
//!
//! Only a machine `_acpmux/peers` lists as an ssh peer: the name never becomes an ssh host by itself.

use crate::cli::hosts;
use anyhow::{Result, anyhow, bail};
use serde_json::Value;
use std::process::Command;

/// `MACHINE`'s ssh host among `peers` (`_acpmux/peers`'s list), by name or by host.
pub(crate) fn ssh_host(peers: &[Value], machine: &str) -> Result<String> {
    peers
        .iter()
        .filter_map(|p| {
            let name = p.get("name").and_then(Value::as_str)?;
            let target = crate::peer::ssh_target(p.get("url").and_then(Value::as_str)?).ok()?;
            (name == machine || target.destination == machine).then_some(target.destination)
        })
        .next()
        .ok_or_else(|| anyhow!("no added ssh machine is named `{machine}` (acpmux machine ls)"))
}

/// `ssh -t … HOST 'cd DIR; exec $SHELL -l'`: the machine's login shell, in `cwd` when that
/// folder is there (else its home folder, as a plain ssh login).
pub(crate) fn shell_argv(host: &str, cwd: Option<&str>) -> Result<Vec<String>> {
    let enter = match cwd.filter(|dir| !dir.is_empty()) {
        Some(dir) => format!("cd -- '{}' 2>/dev/null; ", dir.replace('\'', "'\\''")),
        None => String::new(),
    };
    let mut argv = vec!["-t".to_owned()];
    argv.extend(hosts::ssh_argv(host, &format!(r#"{enter}exec "${{SHELL:-/bin/sh}}" -l"#))?);
    Ok(argv)
}

/// Runs the shell in this terminal until it ends.
pub(crate) fn run(peers: &[Value], machine: &str, cwd: Option<&str>) -> Result<()> {
    let host = ssh_host(peers, machine)?;
    let status = Command::new("ssh").args(shell_argv(&host, cwd)?).status()?;
    // 255 is ssh's own failure (no route, key refused); the shell's own exit status is the person's.
    if status.code() == Some(255) {
        bail!("ssh to {machine} ({host}) failed: `acpmux machine doctor {machine}` checks it");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_a_listed_ssh_machine_is_reached() {
        let peers = vec![
            json!({"name": "box", "url": "ssh://leo@box.tail"}),
            json!({"name": "cloud", "url": "https://cloud.example"}),
        ];
        assert_eq!(ssh_host(&peers, "box").unwrap(), "leo@box.tail");
        assert_eq!(ssh_host(&peers, "leo@box.tail").unwrap(), "leo@box.tail");
        assert!(ssh_host(&peers, "cloud").is_err());
        assert!(ssh_host(&peers, "elsewhere").is_err());
    }

    #[test]
    fn the_shell_starts_in_the_folder_with_any_name_quoted() {
        let argv = shell_argv("leo@box", Some("/home/leo/it's here")).unwrap();
        assert_eq!(argv[0], "-t");
        let script = hosts::script_of(argv.last().unwrap()).unwrap();
        assert_eq!(
            script,
            r#"cd -- '/home/leo/it'\''s here' 2>/dev/null; exec "${SHELL:-/bin/sh}" -l"#
        );
        // The script runs as written under sh: the folder is entered, the quote kept in its name.
        let dir = tempfile::tempdir().unwrap();
        let odd = dir.path().join("it's here");
        std::fs::create_dir(&odd).unwrap();
        let real = shell_argv("leo@box", Some(&odd.to_string_lossy())).unwrap();
        let probe = hosts::script_of(real.last().unwrap())
            .unwrap()
            .replace(r#"exec "${SHELL:-/bin/sh}" -l"#, "pwd -P");
        let out = Command::new("/bin/sh").arg("-c").arg(&probe).output().unwrap();
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).trim(),
            odd.canonicalize().unwrap().to_string_lossy()
        );
        let home = shell_argv("leo@box", None).unwrap();
        assert_eq!(
            hosts::script_of(home.last().unwrap()).unwrap(),
            r#"exec "${SHELL:-/bin/sh}" -l"#
        );
        assert!(shell_argv("-oProxyCommand=x", None).is_err());
    }
}
