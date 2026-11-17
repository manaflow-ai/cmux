//! Real SSH policy checks. Run with `cargo test -p acpmux --lib first_contact_real_ssh -- --nocapture`.
//! The server runs in inetd mode over the client's private pipe, with no listening port.

use super::*;
use crate::cli::host_candidates;
use crate::cli::host_enroll::SshFailure;
use crate::harness_health::channel::quote as shell_quote;
use std::path::PathBuf;
use std::time::Duration;

fn executable(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .chain([PathBuf::from("/usr/sbin"), PathBuf::from("/usr/bin")])
        .map(|dir| dir.join(name))
        .find(|path| path.is_file())
}

struct Fixture {
    _dir: tempfile::TempDir,
    ssh: PathBuf,
    client: PathBuf,
    server: PathBuf,
    known: PathBuf,
    first_key: PathBuf,
    second_key: PathBuf,
}

impl Fixture {
    fn new() -> Option<Self> {
        let Some((ssh, sshd, keygen)) = executable("ssh")
            .zip(executable("sshd"))
            .zip(executable("ssh-keygen"))
            .map(|((ssh, sshd), keygen)| (ssh, sshd, keygen))
        else {
            eprintln!("SKIP first_contact_real_ssh: ssh, sshd and ssh-keygen are required");
            return None;
        };
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let client_key = root.join("client_key");
        let first_key = root.join("host_key");
        let second_key = root.join("other_host_key");
        for key in [&client_key, &first_key, &second_key] {
            let mut cmd = Command::new(&keygen);
            cmd.args(["-q", "-t", "ed25519", "-N", "", "-f"]).arg(key);
            bounded_ok(&mut cmd, Duration::from_secs(10)).expect("generate fixture key");
        }
        let user = Command::new("id").arg("-un").output().unwrap();
        assert!(user.status.success());
        let user = String::from_utf8(user.stdout).unwrap();
        let user = user.trim();
        let known = root.join("known_hosts");
        std::fs::write(&known, "").unwrap();
        let server = root.join("sshd_config");
        let client = root.join("ssh_config");
        std::fs::write(
            &client,
            format!(
                "Host *\n HostName 127.0.0.1\n HostKeyAlias first-contact-test\n User {user}\n\
                 IdentityFile {}\n IdentitiesOnly yes\n IdentityAgent none\n\
                 UserKnownHostsFile {}\n GlobalKnownHostsFile /dev/null\n\
                 StrictHostKeyChecking yes\n UpdateHostKeys no\n VerifyHostKeyDNS no\n LogLevel QUIET\n\
                 CheckHostIP no\n HostKeyAlgorithms ssh-ed25519\n\
                 ProxyCommand {} -i -e -f {}\n",
                client_key.display(),
                known.display(),
                shell_quote(&sshd.to_string_lossy()),
                shell_quote(&server.to_string_lossy()),
            ),
        )
        .unwrap();
        let fixture = Self { _dir: dir, ssh, client, server, known, first_key, second_key };
        fixture.serve(&fixture.first_key);
        Some(fixture)
    }

    fn serve(&self, key: &Path) {
        let authorized = self._dir.path().join("client_key.pub");
        std::fs::write(
            &self.server,
            format!(
                "HostKey {}\n AuthorizedKeysFile {}\n StrictModes no\n\
                 PasswordAuthentication no\n KbdInteractiveAuthentication no\n UsePAM no\n\
                 PermitRootLogin yes\n LogLevel ERROR\n",
                key.display(),
                authorized.display(),
            ),
        )
        .unwrap();
    }

    fn run(&self, argv: &[String]) -> std::result::Result<(), String> {
        // bounded_ok keeps only the last stderr line. Preserve the complete SSH
        // warning for classification while retaining its timeout/group cleanup.
        let stderr = self._dir.path().join("ssh.stderr");
        let mut command = Command::new("sh");
        command
            .args(["-c", "exec \"$@\" 2>\"$SSH_POLICY_STDERR\"", "ssh-policy-test"])
            .arg(&self.ssh)
            .arg("-F")
            .arg(&self.client)
            .args(argv)
            .env("SSH_POLICY_STDERR", &stderr)
            .env("LC_ALL", "C");
        bounded_ok(&mut command, Duration::from_secs(15)).map_err(|why| {
            format!("{why}\n{}", std::fs::read_to_string(stderr).unwrap_or_default())
        })
    }

    fn contact(&self, accept: bool) -> std::result::Result<(), String> {
        self.run(&first_contact_argv("first-contact-test", accept).unwrap())
    }

    fn stored(&self) -> Vec<u8> {
        std::fs::read(&self.known).unwrap()
    }
}

fn passed_host_key_check(result: std::result::Result<(), String>) {
    // Some fleet accounts are locked for direct SSH login. Authentication rejection
    // still proves the host-key check completed; no account changes are needed.
    if let Err(stderr) = result {
        assert_eq!(SshFailure::of(&stderr), SshFailure::KeyRejected, "{stderr}");
    }
}

#[test]
fn first_contact_quiet_probe_keeps_diagnostics() {
    let Some(f) = Fixture::new() else { return };
    let empty = f.stored();
    let probe = host_candidates::probe_argv("first-contact-test").unwrap();
    let unknown = f.run(&probe).expect_err("strict probe must reject an unknown key");
    assert_eq!(SshFailure::of(&unknown), SshFailure::HostKeyUnknown, "{unknown}");
    assert_eq!(f.stored(), empty);
}

/// OpenSSH's default `StrictHostKeyChecking ask` under BatchMode names nothing but "Host key
/// verification failed." for an unknown key; the strict re-check names it and records nothing.
#[test]
fn first_contact_default_policy_unknown_key_needs_the_strict_recheck() {
    let Some(f) = Fixture::new() else { return };
    let empty = f.stored();
    let config = std::fs::read_to_string(&f.client).unwrap();
    std::fs::write(
        &f.client,
        config.replace("StrictHostKeyChecking yes", "StrictHostKeyChecking ask"),
    )
    .unwrap();
    let bare = f.contact(false).expect_err("BatchMode cannot ask about an unknown key");
    assert_eq!(SshFailure::of(&bare), SshFailure::HostKeyUntrusted, "{bare}");
    let strict = f
        .run(&strict_host_key_check_argv("first-contact-test").unwrap())
        .expect_err("strict re-check must reject an unknown key");
    assert_eq!(SshFailure::of(&strict), SshFailure::HostKeyUnknown, "{strict}");
    assert_eq!(f.stored(), empty);
    passed_host_key_check(f.contact(true));
    assert!(!f.stored().is_empty());
}

#[test]
fn first_contact_real_ssh_records_only_unknown_keys() {
    let Some(f) = Fixture::new() else { return };
    let empty = f.stored();
    let unknown = f.contact(false).expect_err("strict first contact must reject unknown key");
    assert_eq!(SshFailure::of(&unknown), SshFailure::HostKeyUnknown, "{unknown}");
    assert_eq!(f.stored(), empty);

    // Exercise the actual background probe argv, including a permissive user config.
    let mut config = std::fs::read_to_string(&f.client).unwrap();
    config = config.replace("StrictHostKeyChecking yes", "StrictHostKeyChecking accept-new");
    std::fs::write(&f.client, &config).unwrap();
    let probe = host_candidates::probe_argv("first-contact-test").unwrap();
    let unknown = f.run(&probe).expect_err("background probe cannot record a key");
    assert_eq!(SshFailure::of(&unknown), SshFailure::HostKeyUnknown, "{unknown}");
    assert_eq!(f.stored(), empty);

    passed_host_key_check(f.contact(true));
    let recorded = f.stored();
    assert!(!recorded.is_empty());
    config = config.replace("StrictHostKeyChecking accept-new", "StrictHostKeyChecking yes");
    std::fs::write(&f.client, config).unwrap();
    passed_host_key_check(f.contact(false));
    passed_host_key_check(f.run(&probe));
    assert_eq!(f.stored(), recorded);

    f.serve(&f.second_key);
    for accept in [false, true] {
        let changed = f.contact(accept).expect_err("changed key must be rejected");
        assert_eq!(SshFailure::of(&changed), SshFailure::HostKeyChanged, "{changed}");
        assert_eq!(f.stored(), recorded);
    }
    assert!(f.run(&probe).is_err());
    assert_eq!(f.stored(), recorded);

    f.serve(&f.first_key);
    let public = std::fs::read_to_string(f.first_key.with_extension("pub")).unwrap();
    std::fs::write(&f.known, format!("@revoked first-contact-test {public}")).unwrap();
    let revoked_record = f.stored();
    for accept in [false, true] {
        let revoked = f.contact(accept).expect_err("revoked key must be rejected");
        assert!(revoked.contains("REVOKED HOST KEY"), "{revoked}");
        assert!(SshFailure::of(&revoked).label().contains("revoked"));
        assert_eq!(f.stored(), revoked_record);
    }
    assert!(f.run(&probe).is_err());
    assert_eq!(f.stored(), revoked_record);

    // RevokedHostKeys emits a different diagnostic from known_hosts' @revoked
    // marker. Both must keep candidates rejected and give revocation advice.
    std::fs::write(&f.known, &recorded).unwrap();
    let revoked_keys = f._dir.path().join("revoked_keys");
    std::fs::write(&revoked_keys, public).unwrap();
    let config = std::fs::read_to_string(&f.client).unwrap();
    std::fs::write(&f.client, format!("{config}\n RevokedHostKeys {}\n", revoked_keys.display()))
        .unwrap();
    for accept in [false, true] {
        let revoked = f.contact(accept).expect_err("revocation-file key must be rejected");
        assert!(revoked.contains("revoked by file"), "{revoked}");
        assert_eq!(SshFailure::of(&revoked), SshFailure::HostKeyRevoked, "{revoked}");
        assert_eq!(f.stored(), recorded);
    }
    let revoked = f.run(&probe).expect_err("probe must reject revocation-file key");
    assert_eq!(SshFailure::of(&revoked), SshFailure::HostKeyRevoked, "{revoked}");
    assert_eq!(f.stored(), recorded);

    for file in [f._dir.path().join("missing_revocations"), revoked_keys] {
        if file.exists() {
            std::fs::write(&file, "not a valid revocation file\n").unwrap();
        }
        std::fs::write(&f.client, format!("{config}\n RevokedHostKeys {}\n", file.display()))
            .unwrap();
        for accept in [false, true] {
            let failed = f.contact(accept).expect_err("invalid revocation file must fail closed");
            assert_eq!(SshFailure::of(&failed), SshFailure::HostKeyConfigInvalid, "{failed}");
            assert_eq!(f.stored(), recorded);
        }
        let failed = f.run(&probe).expect_err("probe must reject invalid revocation file");
        assert_eq!(SshFailure::of(&failed), SshFailure::HostKeyConfigInvalid, "{failed}");
        assert_eq!(f.stored(), recorded);
    }
    eprintln!(
        "PASS first_contact_real_ssh: quiet-config/unknown/probe/accept/reconnect/changed/revoked/revocation-file/invalid-revocations; stored keys preserved"
    );
}
