//! The host's update lock (`host_lock.rs`) on a fake host ([`FakePeer`]):
//! one update of a host at a time, an update whose lease went changes
//! nothing more, and every update script reaches the daemon through the
//! home and socket `acpmux.service` sets ([`SERVICE_ENV`]), quoted or not.

use super::*;
use crate::cli::hosts::{lock_to_install, lock_updates};
use std::process::Command;

#[test]
fn two_updates_of_one_host_never_run_at_once() {
    // The review's race: two updates both probe the old daemon and install,
    // and the second one's backup is the first one's new binary, so a
    // rollback restores that. One lock on the host keeps each out while the
    // other runs.
    let peer = FakePeer::new("host-lock");
    let old = fake_acpmux(OLD, Some(OLD));
    peer.offer(NEW, Some(NEW));
    let opts = UpdateOptions {
        binary_dir: Some(peer.home.join("binaries")),
        if_idle: false,
        caller: None,
    };

    // An update from another machine holds it: a second one changes nothing.
    let lock = lock_updates(&peer).unwrap().expect("the lock is free");
    assert!(lock_updates(&peer).unwrap().is_none());
    let up = update_locked(&peer, &opts);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Failed, Some("updateRunning")));
    // `host setup` and `host enroll --fix` take it before they push, link
    // or restart, so they do neither.
    let Err(why) = lock_to_install(&peer) else { panic!("the lock was taken twice") };
    assert!(format!("{why:#}").contains("another update of fake is running"), "{why:#}");
    peer.assert_only_read(&old, OLD);
    assert!(!peer.exists(".local/bin/acpmux.prev"));
    drop(lock);

    // The next one takes it once the other ended.
    let up = update_locked(&peer, &opts);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux.prev"), old, "the backup is the known-good binary");
    assert!(!peer.exists(".acpmux/update.owner"), "the lease was given back");
}

#[test]
fn an_update_whose_lock_connection_drops_changes_nothing_more() {
    // Re-review of #24232: once the connection that kept the lock ended,
    // its flock was free while the update went on over other connections,
    // so another update could replace the binary and acpmux.prev under it.
    // Every step now checks, on the host, that the lease is still its
    // update's.
    let peer = FakePeer::new("lease-ends");
    let old = fake_acpmux(OLD, Some(OLD));
    peer.offer(NEW, Some(NEW));
    peer.lease_ends_after_copy.set(true);
    let opts = UpdateOptions {
        binary_dir: Some(peer.home.join("binaries")),
        if_idle: false,
        caller: None,
    };
    let up = update_locked(&peer, &opts);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Failed, Some("lockLost")), "{up:?}");
    assert!(up.error.as_deref().unwrap_or_default().contains("lost its update lock"), "{up:?}");
    // The pushed binary was never installed: the old one and its daemon run.
    assert_eq!(peer.read(".local/bin/acpmux"), old);
    assert!(!peer.exists(".local/bin/acpmux.prev"));
    assert_eq!(peer.daemon(), OLD);
    assert!(!peer.take_calls().iter().any(|c| c.contains("restart")));
    // The lease is free for the next update at once.
    let next = lock_updates(&peer).unwrap();
    assert!(next.is_some(), "a lease whose process ended is free");
}

/// [`SERVICE_ENV`] with a fake `systemctl` whose `show` prints `printed`:
/// the `ACPMUX_HOME` and `ACPMUX_SOCKET` a script then sees.
fn service_env(printed: &str) -> (String, String) {
    let dir = std::env::temp_dir().join(format!("acpmux-service-env-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("printed"), printed).unwrap();
    let systemctl = dir.join("systemctl");
    std::fs::write(&systemctl, "#!/bin/sh\ncat \"$(dirname \"$0\")/printed\"\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&systemctl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let script = format!(
        "{SERVICE_ENV}printf '%s\\n%s' \"${{ACPMUX_HOME-unset}}\" \"${{ACPMUX_SOCKET-unset}}\""
    );
    let out = Command::new("sh")
        .args(["-c", &script])
        .env("PATH", format!("{}:/usr/bin:/bin", dir.display()))
        .env("ACPMUX_HOME", "/inherited")
        .env_remove("ACPMUX_SOCKET")
        .output()
        .unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    let text = String::from_utf8(out.stdout).unwrap();
    let (home, socket) = text.split_once('\n').unwrap();
    (home.to_owned(), socket.to_owned())
}

#[test]
fn the_daemons_settings_are_read_as_systemd_quotes_them() {
    // Re-review of #24232: a value with a space, which `systemctl show`
    // quotes, was dropped or cut at the space with a quote left in it.
    let pair = |h: &str, s: &str| (h.to_owned(), s.to_owned());
    for (printed, want) in [
        (
            r#"PATH=/usr/bin "ACPMUX_HOME=/srv/agent data" "ACPMUX_SOCKET=/srv/agent data/a\"b \$x.sock""#,
            pair("/srv/agent data", r#"/srv/agent data/a"b $x.sock"#),
        ),
        (r#"ACPMUX_SOCKET="/srv/x y.sock" FOO=bar"#, pair("unset", "/srv/x y.sock")),
        ("'ACPMUX_HOME=/single q' ACPMUX_SOCKET=/s\\ t", pair("/single q", "/s t")),
        ("ACPMUX_HOME=/plain", pair("/plain", "unset")),
        // A unit that sets neither leaves the inherited pair.
        ("PATH=/usr/bin FOO=*", pair("/inherited", "unset")),
        ("", pair("/inherited", "unset")),
    ] {
        assert_eq!(service_env(printed), want, "{printed}");
    }
}

#[test]
fn a_daemon_whose_quoted_socket_has_a_space_is_checked_where_it_listens() {
    let peer = FakePeer::new("quoted-socket");
    let socket = peer.home.join("agent data/a\"b.sock").display().to_string();
    let quoted = socket.replace('\\', "\\\\").replace('"', "\\\"");
    peer.write("unit-environment", &format!("PATH=/usr/bin \"ACPMUX_SOCKET={quoted}\"\n"));
    peer.exe(".local/bin/acpmux", &listening_at(&socket, &fake_acpmux(OLD, Some(OLD))));
    let new = listening_at(&socket, &fake_acpmux(NEW, Some(NEW)));
    peer.exe(&format!("binaries/acpmux-{TARGET}"), &new);
    let up = peer.update(false);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), new);
}
