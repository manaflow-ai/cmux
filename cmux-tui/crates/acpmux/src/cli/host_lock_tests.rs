//! The host's update lock (`host_lock.rs`) on a fake host ([`FakePeer`]):
//! one update of a host at a time (by flock(1) or perl, never by neither),
//! an update whose lease went changes nothing more, and every update
//! script reaches the daemon through the
//! home and socket `acpmux.service` sets ([`SERVICE_ENV`]), quoted or not.

use super::*;
use crate::cli::hosts::{LockLost, lock_to_install, lock_updates, run};
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
        keep_newer: false,
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
        keep_newer: false,
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

#[test]
fn of_updates_that_start_at_once_one_takes_the_lock() {
    let peer = FakePeer::new("lock-race");
    let (home, start) = (&peer.home, std::sync::Barrier::new(8));
    let locks: Vec<_> = std::thread::scope(|s| {
        let tries: Vec<_> = (0..8)
            .map(|_| {
                s.spawn(|| {
                    // Each its own connection to the one host; never
                    // dropped, which would delete the home.
                    let peer = std::mem::ManuallyDrop::new(FakePeer {
                        home: home.clone(),
                        after_copy: Default::default(),
                        lease_ends_after_copy: Default::default(),
                    });
                    start.wait();
                    lock_updates(&*peer).unwrap()
                })
            })
            .collect();
        tries.into_iter().filter_map(|t| t.join().unwrap()).collect()
    });
    assert_eq!(locks.len(), 1, "one update holds the lock");
    drop(locks);
    assert!(lock_updates(&peer).unwrap().is_some(), "and gave it back");
}

#[test]
fn a_late_copy_of_an_update_whose_lease_went_never_lands_on_the_next_ones() {
    // Review of #24304: copies ran unfenced to one staging path, so an
    // update whose lease went could overwrite the binary the next update
    // staged, between that update's check and its rename.
    let peer = FakePeer::new("late-copy");
    let staged = "~/.local/bin/.acpmux-new/acpmux";
    std::fs::create_dir_all(peer.home.join(".local/bin/.acpmux-new")).unwrap();
    peer.write("binaries/late", "the late update's binary");
    peer.write("binaries/next", "the next update's binary");
    let late = lock_updates(&peer).unwrap().expect("the lock is free");
    peer.end_lease();
    let next = lock_updates(&peer).unwrap().expect("a lease whose process ended is free");
    next.fence(&peer).push(&peer.home.join("binaries/next"), staged).unwrap();
    let Err(e) = late.fence(&peer).push(&peer.home.join("binaries/late"), staged) else {
        panic!("the late copy landed")
    };
    assert!(e.is::<LockLost>(), "{e:#}");
    assert_eq!(peer.read(".local/bin/.acpmux-new/acpmux"), "the next update's binary");
}

#[test]
fn an_upload_lands_on_a_host_whose_login_shell_is_zsh() {
    // Review of #24304: the cleanup of other leases' copies was a glob,
    // and zsh fails a glob that matches nothing, so every upload failed.
    if !std::path::Path::new("/bin/zsh").exists() {
        return;
    }
    let peer = FakePeer::new("zsh-push");
    peer.write("shell", "/bin/zsh");
    std::fs::create_dir_all(peer.home.join(".local/bin/.acpmux-new")).unwrap();
    peer.write("binaries/new", "the new binary");
    let lock = lock_updates(&peer).unwrap().expect("the lock is free");
    lock.fence(&peer)
        .push(&peer.home.join("binaries/new"), "~/.local/bin/.acpmux-new/acpmux")
        .unwrap();
    assert_eq!(peer.read(".local/bin/.acpmux-new/acpmux"), "the new binary");
}

#[test]
fn a_stale_lease_whose_pid_now_names_another_process_is_free() {
    // Review of #24304: a lease a crash left named a pid that another
    // process of the user had by then, so every update refused. The lease
    // is the flock its process held, which ended with it.
    let peer = FakePeer::new("stale-lease");
    peer.write(".acpmux/update.owner", &format!("{} {}\n", "0".repeat(32), std::process::id()));
    assert!(lock_updates(&peer).unwrap().is_some(), "the stale lease kept the lock");
}

#[test]
fn without_flock_perl_locks_and_without_either_nothing_runs() {
    // A host's tools without flock(1), as macOS has them.
    let peer = FakePeer::new("perl-lock");
    let bin = peer.home.join("lockbin");
    std::fs::create_dir_all(&bin).unwrap();
    for tool in ["/bin/sh", "/bin/mkdir", "/bin/cat", "/bin/mv", "/bin/rm", "/usr/bin/perl"] {
        std::os::unix::fs::symlink(tool, bin.join(tool.rsplit('/').next().unwrap())).unwrap();
    }
    peer.write("path", &bin.display().to_string());
    let lock = lock_updates(&peer).unwrap().expect("perl takes the lock");
    assert!(lock_updates(&peer).unwrap().is_none(), "and holds it");
    assert_eq!(run(&lock.fence(&peer), "echo ran").unwrap(), "ran");

    // Review of #24304: with neither, the lock locked nothing and every
    // step ran. Now no step runs and no lock is taken.
    std::fs::remove_file(bin.join("perl")).unwrap();
    let Err(e) = run(&lock.fence(&peer), "echo ran > ran") else { panic!("a step ran unlocked") };
    assert!(format!("{e:#}").contains("neither flock nor perl"), "{e:#}");
    assert!(!peer.exists("ran"));
    drop(lock);
    let Err(e) = lock_to_install(&peer) else { panic!("the lock was taken with neither") };
    assert!(format!("{e:#}").contains("neither flock nor perl"), "{e:#}");
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
