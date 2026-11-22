//! This machine's ssh key for adding a machine without a terminal (HQ#7442 row 1).
//!
//! `acpmux machine key` answers the one public-key line a new machine must list in its
//! `~/.ssh/authorized_keys`, and the command that adds it there, so a caller can show both with
//! a Copy button instead of sending the person to `ssh-copy-id` in a terminal. `--create` makes
//! an ed25519 key when this machine has none: only when asked, and never over an existing key.
//! Enroll's `reach` step names the same line when the host rejects the key (`rejected_fix`).
//!
//! The key is the first of `~/.ssh/id_ed25519.pub`, `id_ecdsa.pub` and `id_rsa.pub`, else the
//! first key the running ssh agent holds (`ssh-add -L`): each is one ssh offers by default.

use crate::harness_health::channel::quote as shell_quote;
use anyhow::{Context as _, Result, anyhow, bail};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The key files ssh offers by default, in the order this module prefers them.
const KEY_FILES: [&str; 3] = ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"];

/// A public key this machine's ssh offers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LocalKey {
    /// `file` or `agent`.
    pub source: &'static str,
    /// The `.pub` file, for a file key.
    pub path: Option<PathBuf>,
    /// The `authorized_keys` line: `TYPE BASE64 [COMMENT]`.
    pub line: String,
}

impl LocalKey {
    pub(crate) fn to_json(&self) -> Value {
        json!({
            "source": self.source,
            "path": self.path,
            "publicKey": self.line,
            "authorizedKeysCommand": authorized_keys_command(&self.line),
        })
    }
}

/// Whether `line` is one public key: a key type ssh knows, then its base64.
fn key_line(line: &str) -> Option<String> {
    let line = line.trim();
    let mut words = line.split_whitespace();
    let kind = words.next()?;
    let body = words.next()?;
    let known = kind.starts_with("ssh-")
        || kind.starts_with("ecdsa-")
        || kind.starts_with("sk-ssh-")
        || kind.starts_with("sk-ecdsa-");
    let base64 = body.bytes().all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b));
    (known && base64 && !line.contains(['\n', '\r'])).then(|| line.to_owned())
}

/// The first key file under `home/.ssh`, else the first of `agent_list` (`ssh-add -L`'s output).
pub(crate) fn find(home: &Path, agent_list: Option<&str>) -> Option<LocalKey> {
    let from_file = KEY_FILES.iter().find_map(|name| {
        let path = home.join(".ssh").join(name);
        let line = key_line(std::fs::read_to_string(&path).ok()?.lines().next()?)?;
        Some(LocalKey { source: "file", path: Some(path), line })
    });
    from_file.or_else(|| {
        let line = agent_list?.lines().find_map(key_line)?;
        Some(LocalKey { source: "agent", path: None, line })
    })
}

/// `ssh-add -L`: the agent's keys, or None with no agent or no keys.
fn agent_list() -> Option<String> {
    let out = Command::new("ssh-add")
        .arg("-L")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// This machine's key, as ssh would offer it.
pub(crate) fn this_machine() -> Option<LocalKey> {
    find(&dirs::home_dir()?, agent_list().as_deref())
}

/// The command that adds `line` to `~/.ssh/authorized_keys` on the host, once, owner-only:
/// `~/.ssh` is set to 0700 and the file to 0600 even when they already existed looser (sshd's
/// StrictModes refuses group- or world-writable ones), and a file whose last line has no newline
/// gets one first, so the new key is a line of its own.
pub(crate) fn authorized_keys_command(line: &str) -> String {
    let key = shell_quote(line);
    let file = "~/.ssh/authorized_keys";
    format!(
        "umask 077; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch {file} && chmod 600 {file} && (grep -qxF {key} {file} || {{ [ -z \"$(tail -c 1 {file})\" ] || echo >> {file}; printf '%s\\n' {key} >> {file}; }})"
    )
}

/// Makes `home/.ssh/id_ed25519` (no passphrase, comment `cmux@HOSTNAME`) when this machine has
/// no key file yet; an existing key is never replaced.
pub(crate) fn create(home: &Path, hostname: &str) -> Result<LocalKey> {
    if let Some(existing) = find(home, None) {
        bail!(
            "this machine already has an ssh key ({}); nothing was made",
            existing.path.as_deref().unwrap_or(Path::new("?")).display()
        );
    }
    let dir = home.join(".ssh");
    // A private key of any of the names `find` reads, its .pub gone, is still this machine's key.
    if let Some(private) = KEY_FILES
        .iter()
        .filter_map(|name| name.strip_suffix(".pub"))
        .map(|name| dir.join(name))
        .find(|path| path.exists())
    {
        bail!("{} exists without its .pub; nothing was made", private.display());
    }
    let key = dir.join("id_ed25519");
    if !dir.is_dir() {
        std::fs::create_dir_all(&dir).with_context(|| format!("mkdir {}", dir.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
        }
    }
    let comment = format!("cmux@{}", crate::cli::hosts::short_name(hostname));
    let out = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-C", &comment, "-f"])
        .arg(&key)
        .stdin(Stdio::null())
        .output()
        .context("ssh-keygen (is OpenSSH installed?)")?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        bail!("ssh-keygen exited with {}: {}", out.status, err.trim());
    }
    find(home, None).ok_or_else(|| anyhow!("ssh-keygen finished but {} has no key", key.display()))
}

/// Enroll's `reach` fix when the host rejects the key: the line to add there and the command
/// that adds it (in `data`, for a Copy button), or, with no key here, how to make one.
pub(crate) fn rejected_fix(host: &str, key: Option<&LocalKey>) -> (String, Value) {
    let bare = host.rsplit('@').next().unwrap_or(host);
    match key {
        Some(key) => (
            format!(
                "Add this machine's public key to ~/.ssh/authorized_keys on {bare} (Copy Details has the line and the command that adds it, for its console or any login that works there; with a password login, `ssh-copy-id {host}`), then check again."
            ),
            json!({"sshKey": "present", "publicKey": key.line,
                "authorizedKeysCommand": authorized_keys_command(&key.line)}),
        ),
        None => (
            format!(
                "This machine has no ssh key yet: `acpmux machine key --create` makes one and prints the line to add to ~/.ssh/authorized_keys on {bare}; then check again."
            ),
            json!({"sshKey": "missing"}),
        ),
    }
}

/// `acpmux machine key [--create]`.
pub(crate) fn run(create_key: bool, json_out: bool) -> Result<()> {
    let home = dirs::home_dir().ok_or_else(|| anyhow!("no home folder"))?;
    let (key, created) = match this_machine() {
        Some(key) => (key, false),
        None if create_key => (create(&home, &crate::hand::pair::hostname())?, true),
        None => {
            bail!("this machine has no ssh key; `acpmux machine key --create` makes an ed25519 key")
        }
    };
    let mut value = key.to_json();
    if let Some(fields) = value.as_object_mut() {
        fields.insert("created".into(), json!(created));
    }
    if json_out {
        println!("{value}");
    } else {
        if created {
            println!("made {}", key.path.as_deref().unwrap_or(Path::new("")).display());
        }
        println!("{}", key.line);
        println!(
            "\nOn the new machine, add it to ~/.ssh/authorized_keys:\n  {}",
            authorized_keys_command(&key.line)
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ED: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEexample0123456789+/ leo@mac";

    fn home_with(files: &[(&str, &str)]) -> tempfile::TempDir {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join(".ssh")).unwrap();
        for (name, text) in files {
            std::fs::write(home.path().join(".ssh").join(name), text).unwrap();
        }
        home
    }

    #[test]
    fn a_key_file_comes_before_the_agent() {
        let home =
            home_with(&[("id_rsa.pub", "ssh-rsa AAAAB3Nza rsa@mac\n"), ("id_ed25519.pub", ED)]);
        let key = find(home.path(), Some("ssh-ed25519 AAAAagent agent@1p\n")).unwrap();
        assert_eq!((key.source, key.line.as_str()), ("file", ED));
        assert!(key.path.unwrap().ends_with(".ssh/id_ed25519.pub"));
    }

    #[test]
    fn the_agent_answers_when_there_is_no_file() {
        let home = home_with(&[("id_ed25519.pub", "not a key\n")]);
        let agent = "The agent has no identities.\nssh-ed25519 AAAAagent agent@1p\n";
        let key = find(home.path(), Some(agent)).unwrap();
        assert_eq!((key.source, key.line.as_str()), ("agent", "ssh-ed25519 AAAAagent agent@1p"));
        assert_eq!(find(home.path(), Some("The agent has no identities.")), None);
        assert_eq!(find(home.path(), None), None);
    }

    #[test]
    fn the_authorized_keys_command_adds_the_line_once_and_owner_only() {
        let home = tempfile::tempdir().unwrap();
        let line = "ssh-ed25519 AAAAx it's@mac";
        let cmd = authorized_keys_command(line);
        // An existing file, too open and with no newline after its last key.
        let ssh = home.path().join(".ssh");
        std::fs::create_dir_all(&ssh).unwrap();
        std::fs::write(ssh.join("authorized_keys"), "ssh-rsa AAAAold old@box").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o775)).unwrap();
            let keys = ssh.join("authorized_keys");
            std::fs::set_permissions(keys, std::fs::Permissions::from_mode(0o664)).unwrap();
        }
        for _ in 0..2 {
            let ok = Command::new("/bin/sh")
                .arg("-c")
                .arg(&cmd)
                .env("HOME", home.path())
                .status()
                .unwrap()
                .success();
            assert!(ok, "{cmd}");
        }
        let keys = home.path().join(".ssh/authorized_keys");
        assert_eq!(
            std::fs::read_to_string(&keys).unwrap(),
            format!("ssh-rsa AAAAold old@box\n{line}\n")
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&keys), 0o600);
            assert_eq!(mode(&home.path().join(".ssh")), 0o700);
        }
    }

    #[test]
    fn create_never_replaces_a_key() {
        let home = home_with(&[("id_ecdsa.pub", "ecdsa-sha2-nistp256 AAAAE2Vj x@y")]);
        let err = create(home.path(), "mac.local").unwrap_err().to_string();
        assert!(err.contains("already has an ssh key"), "{err}");
        let half = home_with(&[("id_ed25519", "private")]);
        let err = create(half.path(), "mac.local").unwrap_err().to_string();
        assert!(err.contains("without its .pub"), "{err}");
        assert_eq!(
            std::fs::read_to_string(half.path().join(".ssh/id_ed25519")).unwrap(),
            "private"
        );
        // Any of the key names counts, not only ed25519: an RSA key whose .pub is gone is still a key.
        let rsa = home_with(&[("id_rsa", "private")]);
        let err = create(rsa.path(), "mac.local").unwrap_err().to_string();
        assert!(err.contains("without its .pub"), "{err}");
        assert!(!rsa.path().join(".ssh/id_ed25519").exists());
    }

    #[test]
    fn create_makes_an_ed25519_key_when_there_is_none() {
        if Command::new("ssh-keygen").arg("-?").stderr(Stdio::null()).status().is_err() {
            return; // No OpenSSH on this runner.
        }
        let home = tempfile::tempdir().unwrap();
        let key = create(home.path(), "leos-mac.local").unwrap();
        assert!(key.line.starts_with("ssh-ed25519 "), "{}", key.line);
        assert!(key.line.ends_with(" cmux@leos-mac"), "{}", key.line);
        assert!(home.path().join(".ssh/id_ed25519").is_file());
    }

    #[test]
    fn a_rejected_key_names_the_line_or_how_to_make_one() {
        let key = LocalKey { source: "file", path: None, line: ED.into() };
        let (fix, data) = rejected_fix("leo@box", Some(&key));
        assert!(fix.contains("authorized_keys on box") && fix.contains("ssh-copy-id leo@box"));
        assert_eq!(data["publicKey"], ED);
        assert!(data["authorizedKeysCommand"].as_str().unwrap().contains("authorized_keys"));
        let (fix, data) = rejected_fix("leo@box", None);
        assert!(fix.contains("`acpmux machine key --create`"), "{fix}");
        assert_eq!(data["sshKey"], "missing");
    }
}
