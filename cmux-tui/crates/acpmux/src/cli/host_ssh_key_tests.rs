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
    let home = home_with(&[("id_rsa.pub", "ssh-rsa AAAAB3Nza rsa@mac\n"), ("id_ed25519.pub", ED)]);
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
    assert_eq!(std::fs::read_to_string(half.path().join(".ssh/id_ed25519")).unwrap(), "private");
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
