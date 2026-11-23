//! `host update` rollbacks and moves off hand-written units, on fake
//! peers. Split out of `host_update_tests.rs` to keep that file under
//! 100 KB; the fakes ([`FakePeer`]) live there.

use super::*;

#[test]
#[cfg(unix)]
fn a_daemon_that_does_not_answer_with_the_pushed_build_is_rolled_back() {
    for (tag, runs, reason) in [
        ("mismatch", Some("fedcba987 2026-10-21"), "buildMismatch"),
        ("no-answer", None, "noAnswer"),
    ] {
        let peer = FakePeer::new(tag);
        peer.offer(NEW, runs);
        let up = peer.update(true);
        assert_eq!(
            (up.outcome, up.reason.as_deref()),
            (Outcome::RolledBack, Some(reason)),
            "{up:?}"
        );
        assert!(up.outcome.failed());
        assert_eq!(up.build.as_deref(), Some(OLD), "the previous build answers again");
        assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
        assert_eq!(peer.daemon(), OLD);
        let restarts = peer
            .take_calls()
            .iter()
            .filter(|c| *c == "systemctl --user restart acpmux.service")
            .count();
        assert_eq!(restarts, 2, "{tag}");
        assert!(peer.exists("agents"));
    }
}

/// huge-blue, 2026-11-06: the restart ran, then ssh's link to the host
/// timed out ("Connection to UNKNOWN port 65535 timed out", ssh's words for
/// a ProxyJump peer) and the update rolled back a daemon that served the new
/// build. A dropped link says nothing about the daemon: asked again on a new
/// connection, it is updated; a host still gone is unreachable, never rolled
/// back blind.
#[test]
#[cfg(unix)]
fn a_link_that_drops_under_the_restart_is_no_rollback() {
    let peer = FakePeer::new("link-drop");
    peer.offer(NEW, Some(NEW));
    peer.link_drops_on_restart.set(Some(false));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.daemon(), NEW);
    assert_eq!(up.build.as_deref(), Some(NEW));
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(NEW, Some(NEW)), "nothing put back");

    let peer = FakePeer::new("link-gone");
    peer.offer(NEW, Some(NEW));
    peer.link_drops_on_restart.set(Some(true));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("unreachable")),
        "{up:?}"
    );
    let restarts = peer
        .take_calls()
        .iter()
        .filter(|c| *c == "systemctl --user restart acpmux.service")
        .count();
    assert_eq!(restarts, 1, "no rollback restart over a link that is gone");
}

#[test]
fn ssh_keepalive_timeouts_are_a_lost_host() {
    assert!(lost_the_host_text("Connection to UNKNOWN port 65535 timed out\r\n"));
    assert!(lost_the_host_text("Connection to 100.64.0.7 port 22 timed out"));
    assert!(!lost_the_host_text("restart timed out waiting for acpmux.service"));
}

#[test]
#[cfg(unix)]
fn without_systemd_the_detached_daemon_is_updated_checked_and_rolled_back() {
    // A cloud VM (root, no user manager): a daemon started detached.
    let peer = FakePeer::new("detached");
    peer.write("no-systemd", "");
    let _ = std::fs::remove_file(peer.home.join("active-acpmux.service"));
    peer.under("session-4.scope");
    peer.write(
            "sessions.json",
            r#"{"sessions": [{"name": "lane", "status": "idle", "turn": null, "pendingPermissions": 2}]}"#,
        );
    peer.offer(NEW, Some(NEW));
    assert_eq!(peer.update(true).outcome, Outcome::Busy);
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
    peer.write("sessions.json", r#"{"sessions": []}"#);
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.daemon(), NEW);
    let calls = peer.take_calls();
    assert!(
        calls.contains(&"acpmux daemon shutdown --keep-agents --restart".to_owned()),
        "{calls:?}"
    );
    assert!(calls.contains(&"acpmux --json daemon start".to_owned()), "{calls:?}");
    // A newer binary whose daemon never answers: back to NEW, detached.
    peer.offer("b2c3d4e5f 2026-10-22", None);
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::RolledBack, Some("noAnswer")),
        "{up:?}"
    );
    assert_eq!(peer.daemon(), NEW);
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(NEW, Some(NEW)));
    assert!(peer.exists("agents"));
}

#[test]
#[cfg(unix)]
fn a_daemon_under_a_hand_written_unit_moves_to_acpmux_service_with_its_agents() {
    let peer = FakePeer::new("migrate");
    peer.under_foreign_unit(true);
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(up.migrated_from.as_deref(), Some(FOREIGN));
    assert_eq!(up.to_json("hb", "hb")["migratedFrom"], FOREIGN);
    assert_eq!(up.build.as_deref(), Some(NEW));
    // The old unit is renamed, so nothing starts it by name again.
    assert!(!peer.exists(&format!("{UNITS}/{FOREIGN}")));
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}.migrated")));
    assert_eq!(peer.read(&format!("{UNITS}/acpmux.service")), SYSTEMD_UNIT);
    assert_eq!(peer.read(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf")), BACKSTOP);
    let home = peer.home.join(".acpmux-supervised/hb");
    assert_eq!(
        peer.read(&format!("{UNITS}/acpmux.service.d/10-migrated.conf")),
        format!(
            "[Service]\nEnvironment=ACPMUX_HOME={h}\nEnvironment=ACPMUX_SOCKET={h}/acpmux.sock\n",
            h = home.display()
        )
    );
    let started_with = peer.read("started-with");
    assert!(started_with.contains("MemoryMax=6G") && started_with.contains("ACPMUX_HOME="));
    assert_eq!(
        peer.read(&format!("run/systemd/user/{FOREIGN}.d/zzz-acpmux-migrate.conf")),
        "[Service]\nKillMode=process\nRestart=no\n"
    );
    let calls = peer.take_calls();
    let at =
        |c: &str| calls.iter().position(|x| x == c).unwrap_or_else(|| panic!("no {c}: {calls:?}"));
    let stop = at(&format!("systemctl --user disable --now {FOREIGN}"));
    assert!(at("systemctl --user daemon-reload") < stop, "the drop-in applies before the stop");
    assert!(calls.contains(&format!("agents kept by {FOREIGN}")), "{calls:?}");
    assert!(stop < at("systemctl --user enable --now acpmux.service"));
    assert!(
        !calls
            .iter()
            .any(|c| c.contains("--end-agents") || c.contains(" stop ") || c.contains(" kill ")),
        "{calls:?}"
    );
    assert!(peer.exists("agents"));
    assert!(!peer.read("started").contains(STALE));

    // Again, with nothing new: current, and no second migration.
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Current, "{up:?}");
    peer.assert_only_read(&fake_acpmux(NEW, Some(NEW)), NEW);
    // A newer build restarts acpmux.service like any set-up host.
    let newer = "b2c3d4e5f 2026-10-22";
    peer.offer(newer, Some(newer));
    let up = peer.update(true);
    assert_eq!((up.outcome, up.migrated_from), (Outcome::Updated, None));
    assert!(peer.take_calls().contains(&"systemctl --user restart acpmux.service".to_owned()));
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}.migrated")));
}

#[cfg(unix)]
impl FakePeer {
    /// The daemon of [`FakePeer::under_foreign_unit`] is down and its unit
    /// stopped and disabled, with no `Restart=`: a Linux host whose daemon the
    /// OOM killer ended (2026-11-06).
    /// `carried` as in [`FakePeer::under_foreign_unit`].
    fn stopped_foreign_unit(&self, carried: bool) {
        self.under_foreign_unit(carried);
        self.write(
            &format!("{UNITS}/{FOREIGN}"),
            "[Service]\nEnvironment=ACPMUX_HOME=%h/.acpmux-supervised/hb\nExecStart=%h/.local/share/acpmux-supervised/acpmux daemon run --listen 127.0.0.1:47822 --log info\n",
        );
        for gone in
            ["daemon", &format!("active-{FOREIGN}"), "proc/4242/environ", "proc/4242/cmdline"]
        {
            let _ = std::fs::remove_file(self.home.join(gone));
        }
    }

    /// The unit and drop-ins a move from [`FOREIGN`] leaves, read from its file.
    fn assert_moved_from_stopped_unit(&self) {
        assert!(!self.exists(&format!("{UNITS}/{FOREIGN}")));
        assert!(self.exists(&format!("{UNITS}/{FOREIGN}.migrated")));
        assert_eq!(self.read(&format!("{UNITS}/acpmux.service")), SYSTEMD_UNIT);
        assert_eq!(self.read(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf")), BACKSTOP);
        // The unit's own home, `%h` read as the home: its state is where it was.
        assert_eq!(
            self.read(&format!("{UNITS}/acpmux.service.d/10-migrated.conf")),
            format!(
                "[Service]\nEnvironment=ACPMUX_HOME={}\n",
                self.home.join(".acpmux-supervised/hb").display()
            )
        );
        assert!(self.take_calls().contains(&"systemctl --user enable --now acpmux.service".into()));
    }
}

/// A daemon its hand-written unit no longer runs (the OOM killer ended it;
/// the unit is disabled, with no `Restart=`) is moved to `acpmux.service`
/// by an update, not given a detached start that nothing restarts.
#[test]
#[cfg(unix)]
fn an_update_moves_a_stopped_hand_written_unit_to_acpmux_service() {
    let peer = FakePeer::new("migrate-stopped");
    peer.stopped_foreign_unit(false);
    peer.offer(NEW, Some(NEW));
    let up = peer.update(false);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(up.migrated_from.as_deref(), Some(FOREIGN));
    assert_eq!(up.build.as_deref(), Some(NEW));
    assert_eq!(peer.daemon(), NEW);
    peer.assert_moved_from_stopped_unit();
    assert!(!peer.read("started").contains(STALE));
}

/// Setup (`machine enroll --fix`, `machine setup`) moves a stopped
/// hand-written unit too, and still refuses one whose daemon runs.
#[test]
#[cfg(unix)]
fn setup_moves_a_stopped_hand_written_unit_and_refuses_a_running_one() {
    let peer = FakePeer::new("setup-stopped");
    peer.stopped_foreign_unit(false);
    peer.exe(".local/bin/acpmux", &fake_acpmux(NEW, Some(NEW)));
    let out = peer.exec(&linux_restart(true, true), None).unwrap();
    assert!(out.ok, "{out:?}");
    assert!(out.stdout.lines().any(|l| l == SYSTEMD_STARTED), "{out:?}");
    assert_eq!(peer.daemon(), NEW);
    peer.assert_moved_from_stopped_unit();

    let peer = FakePeer::new("setup-running");
    peer.under_foreign_unit(false);
    let out = peer.exec(&linux_restart(true, true), None).unwrap();
    assert!(!out.ok && out.stderr.contains(&format!("runs under the systemd unit {FOREIGN}")));
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));
    assert!(!peer.exists(&format!("{UNITS}/acpmux.service")));
}

/// A stopped unit of another home, two such units, or one that quotes its
/// settings are never moved by guess.
#[test]
#[cfg(unix)]
fn a_stopped_unit_is_moved_only_when_it_is_this_homes_one() {
    // Another home: `~/.acpmux` is its own folder, not a link to the unit's.
    let peer = FakePeer::new("stopped-other-home");
    peer.stopped_foreign_unit(true);
    peer.offer(NEW, Some(NEW));
    let up = peer.update(false);
    assert_eq!(up.migrated_from, None, "{up:?}");
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));
    // Two hand-written units: which one is the daemon's is not known.
    let peer = FakePeer::new("stopped-two");
    peer.stopped_foreign_unit(false);
    peer.write(
        &format!("{UNITS}/acpmux-agent-other.service"),
        &peer.read(&format!("{UNITS}/{FOREIGN}")),
    );
    peer.offer(NEW, Some(NEW));
    let up = peer.update(false);
    assert_eq!(up.migrated_from, None, "{up:?}");
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));
    // A drop-in that runs something else in its place: not the daemon's unit.
    let peer = FakePeer::new("stopped-overridden");
    peer.stopped_foreign_unit(false);
    peer.write(
        &format!("{UNITS}/{FOREIGN}.d/other.conf"),
        "[Service]\nExecStart=\nExecStart=/usr/bin/true\n",
    );
    peer.offer(NEW, Some(NEW));
    let up = peer.update(false);
    assert_eq!(up.migrated_from, None, "{up:?}");
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));
    // A quoted value: refused before anything changes, the binary put back.
    let peer = FakePeer::new("stopped-quoted");
    peer.stopped_foreign_unit(false);
    peer.write(&format!("{UNITS}/{FOREIGN}.d/home.conf"), "[Service]\nEnvironment=\"NOTE=a b\"\n");
    peer.offer(NEW, Some(NEW));
    let up = peer.update(false);
    assert_eq!(up.outcome, Outcome::Failed, "{up:?}");
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));
    assert!(!peer.exists(&format!("{UNITS}/acpmux.service")));
    // Settings are systemd's effective ones: a home set by a name prefix's
    // drop-in, or behind an `env` wrapper, is another home's unit, and a
    // unit systemd says is running is not a stopped one.
    for (tag, path, text) in [
        (
            "stopped-prefix-home",
            "acpmux-agent-.service.d/home.conf",
            "[Service]\nEnvironment=ACPMUX_HOME=%h/other\n",
        ),
        (
            "stopped-env-wrapper",
            "acpmux-agent-hb.service.d/run.conf",
            "[Service]\nExecStart=\nExecStart=/usr/bin/env ACPMUX_HOME=%h/other %h/.local/bin/acpmux daemon run\n",
        ),
        ("stopped-active", "", ""),
    ] {
        let peer = FakePeer::new(tag);
        peer.stopped_foreign_unit(false);
        if path.is_empty() {
            peer.write(&format!("active-{FOREIGN}"), "");
        } else {
            peer.write(&format!("{UNITS}/{path}"), text);
        }
        peer.offer(NEW, Some(NEW));
        let up = peer.update(false);
        assert_eq!(up.migrated_from, None, "{tag}: {up:?}");
        assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")), "{tag}");
        assert!(!peer.exists(&format!("{UNITS}/{FOREIGN}.migrated")), "{tag}");
    }
    // This home's unit, but with settings the move would leave behind: an
    // `EnvironmentFile=`, or a name prefix's drop-in. Refused before anything changes.
    for (tag, path, text) in [
        (
            "stopped-env-file",
            "acpmux-agent-hb.service.d/env.conf",
            "[Service]\nEnvironmentFile=%h/env\n",
        ),
        ("stopped-prefix-setting", "acpmux-.service.d/mem.conf", "[Service]\nMemoryMax=1G\n"),
    ] {
        let peer = FakePeer::new(tag);
        peer.stopped_foreign_unit(false);
        peer.write(&format!("{UNITS}/{path}"), text);
        peer.offer(NEW, Some(NEW));
        let up = peer.update(false);
        assert_eq!(up.outcome, Outcome::Failed, "{tag}: {up:?}");
        assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")), "{tag}");
        assert!(!peer.exists(&format!("{UNITS}/acpmux.service")), "{tag}");
    }
}

/// A setup whose move from a stopped hand-written unit fails to start
/// `acpmux.service` puts that unit back, as an update does: never left
/// disabled and renamed with nothing to run the daemon.
#[test]
#[cfg(unix)]
fn a_failed_setup_move_restores_the_stopped_hand_written_unit() {
    let peer = FakePeer::new("setup-stopped-fails");
    peer.stopped_foreign_unit(false);
    peer.exe(".local/bin/acpmux", &fake_acpmux(NEW, Some(NEW)));
    peer.write("fails-acpmux.service", "");
    let err = setup_restart(&peer, true).unwrap_err().to_string();
    assert!(err.contains(&format!("moved back to {FOREIGN}")), "{err}");
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));
    assert!(!peer.exists(&format!("{UNITS}/{FOREIGN}.migrated")));
    assert!(!peer.exists(&format!("run/systemd/user/{FOREIGN}.d/zzz-acpmux-migrate.conf")));
    assert!(peer.take_calls().contains(&format!("systemctl --user enable --now {FOREIGN}")));
}

#[test]
#[cfg(unix)]
fn a_moved_daemon_is_reached_through_the_settings_its_move_carried() {
    // One rule for the daemon's home and socket: the move to acpmux.service
    // carries them into its drop-in (#24079), and every update script reads
    // them back from the unit (SERVICE_ENV), so the next update, from a
    // shell or the timer that has neither, checks the daemon where it
    // listens instead of rolling a healthy one back.
    let peer = FakePeer::new("carried-socket");
    peer.under_foreign_unit(false);
    peer.offer(NEW, Some(NEW));
    assert_eq!(peer.update(true).outcome, Outcome::Updated);
    let socket = peer.home.join(".acpmux-supervised/hb/acpmux.sock").display().to_string();
    let carried = peer.read(&format!("{UNITS}/acpmux.service.d/10-migrated.conf"));
    assert!(carried.contains(&format!("Environment=ACPMUX_SOCKET={socket}\n")), "{carried}");
    let newer = "b2c3d4e5f 2026-10-22";
    let binary = listening_at(&socket, &fake_acpmux(newer, Some(newer)));
    peer.exe(&format!("binaries/acpmux-{TARGET}"), &binary);
    let up = peer.update(true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(newer)), "{up:?}");
    assert_eq!(up.migrated_from, None);
}

#[test]
#[cfg(unix)]
fn huge_blues_stale_binary_never_runs() {
    // The hand-written unit already runs the build to push: current, and
    // acpmux.service is not started on the stale binary at its path.
    let peer = FakePeer::new("stale-current");
    peer.under_foreign_unit(false);
    peer.offer(OLD, Some(OLD));
    assert_eq!(peer.update(true).outcome, Outcome::Current);
    peer.assert_untouched(&fake_acpmux(STALE, Some(STALE)), OLD);
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));

    // A new build: pushed over the stale one before acpmux.service starts.
    let peer = FakePeer::new("stale-update");
    peer.under_foreign_unit(false);
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.daemon(), NEW);
    assert_eq!(peer.read("started").trim(), NEW, "only the pushed build started");
    // `~/.acpmux` links to the unit's home, but the daemon never opens its
    // home through a link: the home is carried (huge-blue, 2026-10-22).
    let home = peer.home.join(".acpmux-supervised/hb");
    assert_eq!(
        peer.read(&format!("{UNITS}/acpmux.service.d/10-migrated.conf")),
        format!(
            "[Service]\nEnvironment=ACPMUX_HOME={h}\nEnvironment=ACPMUX_SOCKET={h}/acpmux.sock\n",
            h = home.display()
        )
    );
    assert!(peer.read("started-with").contains("MemoryHigh=5G"));

    // The unit names the link itself, with a trailing `/`: the old daemon
    // opens it, acpmux.service without it would not, so it is carried.
    let peer = FakePeer::new("stale-slash");
    peer.under_foreign_unit(false);
    let linked = format!("{}/.acpmux/", peer.home.display());
    peer.write("proc/4242/environ", &format!("PATH=/usr/bin\0ACPMUX_HOME={linked}\0"));
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(
        peer.read(&format!("{UNITS}/acpmux.service.d/10-migrated.conf")),
        format!("[Service]\nEnvironment=ACPMUX_HOME={linked}\n")
    );

    // A drop-in of the unit's own with the carried settings' name would
    // replace them: refused before anything changes.
    let peer = FakePeer::new("stale-clash");
    peer.under_foreign_unit(false);
    peer.write(&format!("{UNITS}/{FOREIGN}.d/10-migrated.conf"), "[Service]\nNice=5\n");
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("unitSettings")),
        "{up:?}"
    );
    peer.assert_untouched(&fake_acpmux(STALE, Some(STALE)), OLD);
}

#[test]
#[cfg(unix)]
fn a_failed_move_restores_the_hand_written_unit_and_never_runs_the_old_binary_under_acpmux_service()
{
    for (tag, runs, fails, reason) in [
        ("migrate-no-answer", None, false, "noAnswer"),
        ("migrate-no-start", Some(NEW), true, "restartFailed"),
    ] {
        let peer = FakePeer::new(tag);
        peer.under_foreign_unit(false);
        peer.offer(NEW, runs);
        if fails {
            peer.write("fails-acpmux.service", "");
        }
        let up = peer.update(true);
        assert_eq!(
            (up.outcome, up.reason.as_deref()),
            (Outcome::RolledBack, Some(reason)),
            "{tag}: {up:?}"
        );
        assert_eq!(up.migrated_from, None);
        assert_eq!(up.build.as_deref(), Some(OLD), "{tag}: the old unit's daemon answers");
        assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")), "{tag}");
        assert!(!peer.exists(&format!("{UNITS}/{FOREIGN}.migrated")), "{tag}");
        assert!(
            !peer.exists(&format!("run/systemd/user/{FOREIGN}.d/zzz-acpmux-migrate.conf")),
            "{tag}"
        );
        assert!(peer.exists(&format!("active-{FOREIGN}")) && !peer.exists("active-acpmux.service"));
        assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(STALE, Some(STALE)), "{tag}");
        assert!(!peer.read("started").contains(STALE), "{tag}");
        let calls = peer.take_calls();
        let starts =
            calls.iter().filter(|c| *c == "systemctl --user enable --now acpmux.service").count();
        assert_eq!(starts, 1, "{tag}: acpmux.service is not started again: {calls:?}");
        assert!(calls.contains(&format!("systemctl --user enable --now {FOREIGN}")), "{calls:?}");
        assert!(peer.exists("agents"), "{tag}");
    }
}

#[test]
#[cfg(unix)]
fn an_acpmux_service_someone_else_wrote_is_refused_and_a_matching_one_adopted() {
    for (tag, unit, drop_in) in [
        ("conflict-unit", "[Service]\nExecStart=/opt/acpmux daemon run\n", BACKSTOP),
        ("conflict-drop-in", SYSTEMD_UNIT, "[Service]\nMemoryMax=1G\n"),
    ] {
        let peer = FakePeer::new(tag);
        peer.under_foreign_unit(false);
        peer.write(&format!("{UNITS}/acpmux.service"), unit);
        peer.write(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf"), drop_in);
        peer.offer(NEW, Some(NEW));
        let up = peer.update(true);
        assert_eq!(
            (up.outcome, up.reason.as_deref()),
            (Outcome::Failed, Some("unitConflict")),
            "{tag}: {up:?}"
        );
        assert!(up.error.as_deref().unwrap_or("").contains("differs"), "{up:?}");
        assert_eq!(peer.read(&format!("{UNITS}/acpmux.service")), unit);
        assert_eq!(peer.read(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf")), drop_in);
        assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));
        peer.assert_untouched(&fake_acpmux(STALE, Some(STALE)), OLD);
    }

    use std::os::unix::fs::MetadataExt;
    let peer = FakePeer::new("adopt");
    peer.under_foreign_unit(false);
    peer.write(&format!("{UNITS}/acpmux.service"), SYSTEMD_UNIT);
    peer.write(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf"), BACKSTOP);
    let unit = peer.home.join(format!("{UNITS}/acpmux.service"));
    let before = std::fs::metadata(&unit).unwrap();
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.migrated_from.as_deref()),
        (Outcome::Updated, Some(FOREIGN)),
        "{up:?}"
    );
    let after = std::fs::metadata(&unit).unwrap();
    assert_eq!(
        (before.ino(), before.mtime(), before.mtime_nsec()),
        (after.ino(), after.mtime(), after.mtime_nsec())
    );

    // One an earlier acpmux wrote (a move rolled back leaves it) is not a
    // conflict: the move replaces it with this build's text.
    let peer = FakePeer::new("adopt-old");
    peer.under_foreign_unit(false);
    peer.write(&format!("{UNITS}/acpmux.service"), OLD_SYSTEMD_UNITS[0]);
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.migrated_from.as_deref()),
        (Outcome::Updated, Some(FOREIGN)),
        "{up:?}"
    );
    assert_eq!(peer.read(&format!("{UNITS}/acpmux.service")), SYSTEMD_UNIT);

    // A full disk while the new text is copied in: the old unit stays whole
    // (written beside it and renamed, never cut), and the daemon goes back.
    // A full disk while the new text is copied in, or while the old text is
    // kept aside: the old unit stays whole (written beside it and renamed,
    // never cut), nothing is left beside it, and the daemon goes back. (The
    // update's own refresh of the unit fails first on the same full disk,
    // at its copy of the old text.)
    for (tag, full) in [
        ("adopt-old-full", "*.service.acpmux-old|*.service.acpmux-new"),
        ("adopt-old-full-backup", "*.service.acpmux-old|*.acpmux-old.new"),
    ] {
        let peer = FakePeer::new(tag);
        peer.under_foreign_unit(false);
        peer.write(&format!("{UNITS}/acpmux.service"), OLD_SYSTEMD_UNITS[0]);
        peer.exe(
            "fakebin/cp",
            &format!("#!/bin/sh\nfor a; do last=$a; done\ncase \"$last\" in {full}) printf x > \"$last\"; echo 'No space left on device' >&2; exit 1;; esac\nexec /bin/cp \"$@\"\n"),
        );
        peer.offer(NEW, Some(NEW));
        let up = peer.update(true);
        assert_ne!(up.outcome, Outcome::Updated, "{tag}: {up:?}");
        assert_eq!(peer.read(&format!("{UNITS}/acpmux.service")), OLD_SYSTEMD_UNITS[0], "{tag}");
        let mut left: Vec<String> = std::fs::read_dir(peer.home.join(UNITS))
            .unwrap()
            .filter_map(|e| e.ok()?.file_name().into_string().ok())
            .filter(|n| n.contains("acpmux.service") && n != "acpmux.service")
            .collect();
        left.retain(|n| n != "acpmux.service.d");
        assert!(left.is_empty(), "{tag}: left {left:?}");
        assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")), "{tag}: {up:?}");
    }

    // The disk fills at a drop-in, after acpmux.service was put in place:
    // everything this move wrote goes, so the host is as it was.
    let peer = FakePeer::new("move-full-drop-in");
    peer.under_foreign_unit(false);
    peer.exe(
        "fakebin/cp",
        "#!/bin/sh\nfor a; do last=$a; done\ncase \"$last\" in *.conf.acpmux-new) printf x > \"$last\"; echo 'No space left on device' >&2; exit 1;; esac\nexec /bin/cp \"$@\"\n",
    );
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_ne!(up.outcome, Outcome::Updated, "{up:?}");
    assert!(!peer.exists(&format!("{UNITS}/acpmux.service")), "{up:?}");
    let left: Vec<String> = std::fs::read_dir(peer.home.join(format!("{UNITS}/acpmux.service.d")))
        .map(|d| d.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect())
        .unwrap_or_default();
    assert!(left.is_empty(), "the move left {left:?}");
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")), "{up:?}");
    assert!(!peer.exists(&format!("run/systemd/user/{FOREIGN}.d/zzz-acpmux-migrate.conf")));
}

#[test]
#[cfg(unix)]
fn a_listen_address_acpmux_service_would_lose_is_refused() {
    let peer = FakePeer::new("listen");
    peer.under_foreign_unit(false);
    peer.write(
        ".acpmux-supervised/hb/config.json",
        "{\n  \"websocket\": {\n    \"listen\": \"127.0.0.1:47811\"\n  }\n}\n",
    );
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("listenConflict")),
        "{up:?}"
    );
    assert!(up.error.as_deref().unwrap_or("").contains("127.0.0.1:47822"), "{up:?}");
    peer.assert_untouched(&fake_acpmux(STALE, Some(STALE)), OLD);
}

/// The target of a `Darwin arm64` peer.
#[cfg(unix)]
const MAC_TARGET: &str = "aarch64-apple-darwin";

/// launchd as macOS 27 runs the job `host setup` loads: `$HOME/loaded`
/// while it is loaded, its daemon pid 4242. `kickstart -k` after the binary
/// at the plist's path became a new ad-hoc signed build kills the restarted
/// daemon at once (`OS_REASON_CODESIGNING`). `bootout` returns before the old
/// daemon has exited (`$HOME/exiting`, until the next `ps` sees it gone), and
/// a `bootstrap` before then starts a daemon that finds `daemon.lock` held.
/// `$HOME/no-gui`: no one is logged in at the screen, so there is no GUI
/// domain (`print gui/<uid>` fails) and a bootstrap into it fails with 125.
/// `$HOME/refuses-bootstrap`: the domain is there but takes no job (the probe
/// neither); `$HOME/refuses-daemon-bootstrap`: it takes the probe, not the
/// daemon's job. The probe's temporary plist is logged as `PROBE`.
#[cfg(unix)]
const FAKE_LAUNCHCTL: &str = r#"#!/bin/sh
case "$3" in */probe.plist) echo "launchctl $1 $2 PROBE" >> "$HOME/calls";; *) echo "launchctl $*" >> "$HOME/calls";; esac
case "$1" in
print) case "$2" in
  */*/*) test -f "$HOME/loaded" || exit 113
    if [ "$(cat "$HOME/daemon-pid" 2>/dev/null || echo 4242)" = 4242 ]; then printf 'gui/501/com.acpmux.daemon = {\n\tstate = running\n\tpid = 4242\n\tlast exit code = (never exited)\n}\n'
    else printf 'gui/501/com.acpmux.daemon = {\n\tstate = waiting\n\tlast exit code = 1\n}\n'; fi;;
  *) test ! -f "$HOME/no-gui" || { echo 'Could not print domain: 125: Domain does not support specified action' >&2; exit 125; };;
  esac;;
bootout) case "$2" in */com.acpmux.probe) exit 0;; esac
  test ! -f "$HOME/no-gui" || { echo 'Boot-out failed: 125: Domain does not support specified action' >&2; exit 125; }
  test -f "$HOME/loaded" || { echo 'Boot-out failed: 3: No such process' >&2; exit 3; }; rm -f "$HOME/loaded"
  if [ "$(cat "$HOME/daemon-pid" 2>/dev/null || echo 4242)" = 4242 ]; then rm -f "$HOME/daemon"; touch "$HOME/exiting"; fi;;
print-disabled) test ! -f "$HOME/print-disabled-fails" || { echo 'Could not print disabled services: 5: Input/output error' >&2; exit 5; }
  test ! -f "$HOME/disabled-daemon" || printf 'disabled services = {\n\t"com.apple.Siri.agent" => enabled\n\t"com.acpmux.daemon" => disabled\n}\n';;
bootstrap)
  test ! -f "$HOME/no-gui" || { echo 'Bootstrap failed: 125: Domain does not support specified action' >&2; exit 125; }
  test ! -f "$HOME/refuses-bootstrap" || { echo 'Bootstrap failed: 5: Input/output error' >&2; exit 5; }
  case "$3" in */probe.plist) exit 0;; esac
  test ! -f "$HOME/disabled-daemon" || { echo 'Bootstrap failed: 5: Input/output error' >&2; exit 5; }
  test ! -f "$HOME/refuses-daemon-bootstrap" || { echo 'Bootstrap failed: 5: Input/output error' >&2; exit 5; }
  test ! -f "$HOME/loaded" || { echo 'Bootstrap failed: 5: Input/output error' >&2; exit 5; }
  touch "$HOME/loaded"
  if [ -f "$HOME/exiting" ]; then echo 'daemon.lock held' >> "$HOME/calls"; else ~/.local/bin/acpmux __start; fi;;
kickstart) rm -f "$HOME/daemon"; echo 'OS_REASON_CODESIGNING' >> "$HOME/calls";;
esac
"#;

/// `plutil -lint`: a plist that is there and does not say BROKEN parses.
#[cfg(unix)]
const FAKE_PLUTIL: &str = "#!/bin/sh\n[ -f \"$2\" ] && ! grep -q BROKEN \"$2\" && { echo \"$2: OK\"; exit 0; }\necho \"$2: Unexpected character B at line 1\"; exit 1\n";

/// `ps -p`: the old daemon is still there once after a `bootout`.
#[cfg(unix)]
const FAKE_PS: &str = "#!/bin/sh\necho \"ps $*\" >> \"$HOME/calls\"\n[ -f \"$HOME/exiting\" ] || exit 1\nrm -f \"$HOME/exiting\"\n";

#[cfg(unix)]
impl FakePeer {
    /// A macOS host: the daemon runs build OLD under the launchd job, with
    /// no systemd and no `/proc`.
    fn under_launchd(&self) {
        self.write("uname", "Darwin arm64\n");
        self.write("no-systemd", "");
        let unit = format!("{UNITS}/acpmux.service");
        for rel in [unit.as_str(), "active-acpmux.service", "proc/4242/cgroup"] {
            let _ = std::fs::remove_file(self.home.join(rel));
        }
        self.exe("fakebin/launchctl", FAKE_LAUNCHCTL);
        self.exe("fakebin/ps", FAKE_PS);
        self.exe("fakebin/plutil", FAKE_PLUTIL);
        self.write("Library/LaunchAgents/com.acpmux.daemon.plist", "<plist/>\n");
        self.write("launchd-host", "");
        self.write("loaded", "");
    }

    /// What launchd and `ps` got since the last call.
    fn take_launchd_calls(&self) -> Vec<String> {
        let keep = |c: &String| {
            c.starts_with("launchctl ")
                || c.starts_with("ps ")
                || c == "daemon.lock held"
                || c == "OS_REASON_CODESIGNING"
        };
        self.take_calls().into_iter().filter(keep).collect()
    }
}

#[test]
#[cfg(unix)]
fn a_macos_daemon_restarts_by_bootout_then_bootstrap_once_the_old_one_exited() {
    let uid = Command::new("id").arg("-u").output().unwrap();
    let uid = String::from_utf8_lossy(&uid.stdout).trim().to_owned();
    let job = format!("gui/{uid}/com.acpmux.daemon");
    let peer = FakePeer::new("launchd");
    peer.under_launchd();
    let plist = format!("{}/Library/LaunchAgents/com.acpmux.daemon.plist", peer.home.display());
    let bootstrap = format!("launchctl bootstrap gui/{uid} {plist}");
    let probe = [
        format!("launchctl print gui/{uid}"),
        format!("launchctl bootout gui/{uid}/com.acpmux.probe"),
        format!("launchctl bootstrap gui/{uid} PROBE"),
        format!("launchctl bootout gui/{uid}/com.acpmux.probe"),
        format!("launchctl print-disabled gui/{uid}"),
    ];
    let restart = [
        probe[0].clone(),
        probe[1].clone(),
        probe[2].clone(),
        probe[3].clone(),
        probe[4].clone(),
        format!("launchctl print {job}"),
        format!("launchctl bootout {job}"),
        "ps -p 4242".to_owned(),
        "ps -p 4242".to_owned(),
        bootstrap.clone(),
    ];
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(NEW, Some(NEW)));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(up.target, Some(MAC_TARGET));
    assert_eq!(up.build.as_deref(), Some(NEW));
    assert_eq!(peer.daemon(), NEW);
    assert_eq!(peer.take_launchd_calls(), restart);
    assert!(peer.exists("agents"));

    // A build whose daemon never answers: the rollback restarts the same way.
    let never = "b2c3d4e5f 2026-10-22";
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(never, None));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::RolledBack, Some("noAnswer")),
        "{up:?}"
    );
    assert_eq!(peer.daemon(), NEW);
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(NEW, Some(NEW)));
    assert_eq!(peer.take_launchd_calls(), [restart.clone(), restart].concat());

    // A job that is not loaded: bootout fails harmlessly and bootstrap still runs.
    let _ = std::fs::remove_file(peer.home.join("loaded"));
    let _ = std::fs::remove_file(peer.home.join("daemon"));
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(OLD, Some(OLD)));
    let up = update_peer(
        &peer,
        &UpdateOptions {
            binary_dir: Some(peer.home.join("binaries")),
            if_idle: false,
            keep_newer: false,
            allow_downgrade: false,
            caller: None,
            now: true,
        },
    );
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.daemon(), OLD);
    assert_eq!(
        peer.take_launchd_calls(),
        [
            probe.to_vec(),
            vec![format!("launchctl print {job}"), format!("launchctl bootout {job}"), bootstrap]
        ]
        .concat()
    );
}

/// A host that answers to nothing: a held peer must never reach it.
struct Unreachable;

impl Remote for Unreachable {
    fn host(&self) -> &str {
        "cmux@mini-a.tail0.ts.net"
    }

    fn exec(&self, script: &str, _: Option<&[u8]>) -> Result<RemoteOut> {
        panic!("a held peer was reached: {script}")
    }

    fn push(&self, _: &Path, remote: &str) -> Result<()> {
        panic!("a held peer got {remote}")
    }

    fn spawn(&self, script: &str) -> Result<std::process::Child> {
        panic!("a held peer was reached: {script}")
    }

    fn reachable(&self) -> Result<()> {
        panic!("a held peer was reached")
    }
}

/// A host that does not answer: down, or behind a hop that stalls.
struct Down;

impl Remote for Down {
    fn host(&self) -> &str {
        "leo@big-box"
    }

    fn exec(&self, script: &str, _: Option<&[u8]>) -> Result<RemoteOut> {
        panic!("a host that does not answer was asked to run {script}")
    }

    fn push(&self, _: &Path, remote: &str) -> Result<()> {
        panic!("a host that does not answer got {remote}")
    }

    fn spawn(&self, script: &str) -> Result<std::process::Child> {
        panic!("a host that does not answer was asked to lock: {script}")
    }

    fn reachable(&self) -> Result<()> {
        Err(anyhow!("leo@big-box is unreachable over ssh: no answer within 20 s"))
    }
}

/// Leo, 2026-10-29: "Couldn't update <host>: acpmux ran past its 900.0 seconds deadline and was
/// stopped; it exited". A host that does not answer fails at once as `unreachable`, before its lock
/// or probe: nothing waits on its ssh, and the app retries it quietly once it is back.
#[test]
fn a_host_that_does_not_answer_is_unreachable_before_anything_runs() {
    let opts = UpdateOptions {
        binary_dir: None,
        if_idle: false,
        keep_newer: true,
        allow_downgrade: false,
        caller: None,
        now: true,
    };
    let up = update_locked(&Down, &opts);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("unreachable")),
        "{up:?}"
    );
    let row = up.to_json("big-box", "leo@big-box");
    assert_eq!(
        row["error"].as_str(),
        Some("leo@big-box is unreachable over ssh: no answer within 20 s"),
        "{row}"
    );
}

/// Leo, 2026-10-26: a machine reserved for someone else ("cmux16 is reserved for lawrencecchen
/// until 10-28") must never have its daemon restarted by the update queue. Held by its host's first
/// label, it is left alone with no ssh at all, and that is no failure (exit 0); a holds file that
/// cannot be read leaves it alone too.
#[test]
fn a_held_peer_is_left_alone_without_reaching_it() {
    let dir = std::env::temp_dir().join(format!("acpmux-held-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("update-holds.json");
    let holds = r#"{"holds": {"mini-a": {"reason": "reserved for a teammate", "until": "2026-10-28T23:59:59Z"}}}"#;
    std::fs::write(&path, holds).unwrap();
    let opts = UpdateOptions {
        binary_dir: None,
        if_idle: false,
        keep_newer: true,
        allow_downgrade: false,
        caller: None,
        now: true,
    };
    let now = 1_793_000_000_000; // 2026-10-26
    let up = update_unless_held("peer-a", &Unreachable, &path, now, &opts);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Held, Some("held")), "{up:?}");
    assert!(!up.outcome.failed(), "held is no failure: the command exits 0");
    let row = up.to_json("peer-a", "cmux@mini-a.tail0.ts.net");
    assert_eq!((row["outcome"].as_str(), row["ok"].as_bool()), (Some("held"), Some(true)));
    assert!(row["error"].as_str().unwrap().contains("reserved for a teammate"), "{row}");
    assert!(up.line().starts_with("held, left alone: mini-a is held"), "{}", up.line());

    std::fs::write(&path, "{not json").unwrap();
    let up = update_unless_held("peer-a", &Unreachable, &path, now, &opts);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Failed, Some("holdsUnreadable")));
    let _ = std::fs::remove_dir_all(&dir);
}

/// This uid, as the scripts' `id -u` prints it.
#[cfg(unix)]
fn uid() -> String {
    let uid = Command::new("id").arg("-u").output().unwrap();
    String::from_utf8_lossy(&uid.stdout).trim().to_owned()
}

/// Leo, 2026-10-26: "Couldn't update cmux16: Bootstrap failed: 125: Domain
/// does not support specified action; the rollback failed too: Bootstrap
/// failed: 125: ...". A Mac no one is logged in to at the screen has no GUI
/// domain: its daemon restarts in place, as acpmux's own start over ssh
/// places it then (#24474), and launchd is not asked to stop or start
/// anything; a build that does not answer is rolled back in place too.
#[test]
#[cfg(unix)]
fn a_mac_with_no_gui_login_restarts_its_daemon_in_place_and_rolls_back_there() {
    let peer = FakePeer::new("nogui");
    peer.under_launchd();
    peer.write("no-gui", "");
    let _ = std::fs::remove_file(peer.home.join("loaded"));
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(NEW, Some(NEW)));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(up.build.as_deref(), Some(NEW));
    assert_eq!(peer.daemon(), NEW);
    assert!(peer.exists("agents"), "the agents are kept");
    assert_eq!(up.in_place.as_deref(), Some("noGuiLogin"));
    assert_eq!(up.to_json("m", "m")["inPlace"], "noGuiLogin");
    assert_eq!(peer.take_launchd_calls(), [format!("launchctl print gui/{}", uid())]);

    let never = "b2c3d4e5f 2026-10-22";
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(never, None));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::RolledBack, Some("noAnswer")),
        "{up:?}"
    );
    assert_eq!((peer.daemon(), up.build.as_deref()), (NEW.to_owned(), Some(NEW)));
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(NEW, Some(NEW)));
}

/// Review of #25602: launchd that takes no job (the probe's bootstrap fails)
/// is asked before anything stops, so neither the restart nor its rollback
/// boots out the daemon that runs: it is left running on its build, and the
/// binary is put back. That holds even when a start in place would fail too.
#[test]
#[cfg(unix)]
fn launchd_that_takes_no_job_leaves_the_running_daemon_alone() {
    let peer = FakePeer::new("refused");
    peer.under_launchd();
    peer.write("refuses-bootstrap", "");
    // A start in place would fail too: this binary's daemon never answers.
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(NEW, None));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("launchdRefused")),
        "{up:?}"
    );
    assert!(up.error.as_deref().unwrap_or("").contains("left running"), "{up:?}");
    assert_eq!(peer.daemon(), OLD, "the old daemon still runs");
    assert!(peer.exists("loaded"), "its job was never booted out");
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
    let calls = peer.take_launchd_calls();
    assert!(!calls.iter().any(|c| c.contains("bootout gui/") && c.ends_with("com.acpmux.daemon")));
}

/// A rollback whose launchd stops taking jobs between the restart and the
/// rollback stops nothing more: whatever runs keeps running, and the row
/// says the rollback stopped nothing, never just "the rollback failed too".
#[test]
#[cfg(unix)]
fn a_rollback_launchd_refuses_stops_nothing_and_says_so() {
    let peer = FakePeer::new("refused-rollback");
    peer.under_launchd();
    // The new build's daemon starts but reports another build, and its start
    // turns launchd's refusal on, so the rollback finds launchd taking no job.
    let other = "c3d4e5f6a 2026-10-22";
    let pushed = fake_acpmux(NEW, Some(other))
        .replace("echo '", "touch \"$HOME/refuses-bootstrap\"; echo '");
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &pushed);
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("buildMismatch")),
        "{up:?}"
    );
    let error = up.error.as_deref().unwrap_or("");
    assert!(error.contains("the rollback stopped nothing"), "{error}");
    assert!(!error.contains("the rollback failed too"), "{error}");
    assert_eq!(peer.daemon(), other, "the running daemon was not stopped");
}

/// The probe passes but the daemon's own bootstrap fails after the bootout
/// (in the restart and in its rollback): the daemon starts in place, so the
/// host is never left without one.
#[test]
#[cfg(unix)]
fn a_bootstrap_that_fails_after_the_bootout_starts_the_daemon_in_place() {
    let peer = FakePeer::new("daemon-refused");
    peer.under_launchd();
    peer.write("refuses-daemon-bootstrap", "");
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(NEW, Some(NEW)));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!((peer.daemon(), up.in_place.as_deref()), (NEW.to_owned(), Some("bootstrapFailed")));

    peer.write("loaded", "");
    let never = "b2c3d4e5f 2026-10-22";
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(never, None));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::RolledBack, Some("noAnswer")),
        "{up:?}"
    );
    assert_eq!(peer.daemon(), NEW, "a daemon runs after the rollback");
}

/// Review of #25602 at a72d1894: launchd can take jobs (the probe passes)
/// while it refuses the daemon's own, as when its label was disabled there
/// after the restart. The rollback from a daemon that runs but is not the
/// pushed build then asks first, refuses, and stops nothing: that daemon is
/// left running even though the previous build's start in place would fail
/// too, and the row says so instead of "the rollback failed too".
#[test]
#[cfg(unix)]
fn a_rollback_to_a_daemon_launchd_has_disabled_leaves_the_running_daemon() {
    let peer = FakePeer::new("disabled-rollback");
    peer.under_launchd();
    // The previous build's start in place would fail: its daemon never answers.
    peer.exe(".local/bin/acpmux", &fake_acpmux(OLD, None));
    // The new build's daemon starts but reports another build, and its start
    // disables the daemon's label in launchd.
    let other = "c3d4e5f6a 2026-10-22";
    let pushed =
        fake_acpmux(NEW, Some(other)).replace("echo '", "touch \"$HOME/disabled-daemon\"; echo '");
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &pushed);
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("buildMismatch")),
        "{up:?}"
    );
    let error = up.error.as_deref().unwrap_or("");
    assert!(error.contains("the rollback stopped nothing"), "{error}");
    assert!(error.contains("com.acpmux.daemon disabled"), "{error}");
    assert!(!error.contains("the rollback failed too"), "{error}");
    assert_eq!((peer.daemon(), up.build.as_deref()), (other.to_owned(), Some(other)));
    assert!(peer.exists("loaded"), "the running daemon's job was not booted out");
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, None), "the binary went back");
    let calls = peer.take_calls();
    let bootouts =
        calls.iter().filter(|c| c.ends_with("/com.acpmux.daemon") && c.contains("bootout"));
    assert_eq!(bootouts.count(), 1, "only the update's own restart booted the job out: {calls:?}");
    assert!(!calls.iter().any(|c| c.contains("daemon start")), "{calls:?}");
}

/// Review of #25602 at a72d1894: the restart follows where the daemon runs.
/// An update with no one logged in starts it in place; once someone logs in,
/// the next update finds it outside launchd's job, shuts it down keeping its
/// agents, and only then bootstraps the job, so the job's daemon gets
/// `daemon.lock` (the fake enforces it) instead of exiting while the old one
/// keeps running.
#[test]
#[cfg(unix)]
fn an_update_after_someone_logs_in_hands_the_in_place_daemon_to_launchd() {
    let peer = FakePeer::new("login-later");
    peer.under_launchd();
    peer.write("no-gui", "");
    let _ = std::fs::remove_file(peer.home.join("loaded"));
    peer.write("daemon-pid", "5151");
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(NEW, Some(NEW)));
    let up = peer.update(true);
    assert_eq!((up.outcome, up.in_place.as_deref()), (Outcome::Updated, Some("noGuiLogin")));
    assert_eq!((peer.daemon(), peer.read("daemon-pid").trim()), (NEW.to_owned(), "5151"));
    peer.take_calls();

    // Someone logs in at the screen.
    let _ = std::fs::remove_file(peer.home.join("no-gui"));
    let newer = "d4e5f6a7b 2026-10-23";
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(newer, Some(newer)));
    let up = peer.update(true);
    assert_eq!((up.outcome, up.in_place.as_deref()), (Outcome::Updated, None), "{up:?}");
    assert_eq!(up.build.as_deref(), Some(newer));
    assert_eq!((peer.daemon(), peer.read("daemon-pid").trim()), (newer.to_owned(), "4242"));
    assert!(peer.exists("loaded"), "the daemon runs as launchd's job");
    assert!(peer.exists("agents"), "the agents are kept");
    let calls = peer.take_calls();
    assert!(!calls.iter().any(|c| c == "daemon.lock held"), "{calls:?}");
    let shutdown = calls.iter().position(|c| c.contains("daemon shutdown --keep-agents"));
    let bootstrap = calls.iter().position(|c| c.contains("bootstrap") && c.ends_with(".plist"));
    assert!(shutdown.is_some() && shutdown < bootstrap, "{calls:?}");

    // The next update restarts launchd's job as usual.
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(NEW, Some(NEW)));
    let up = peer.update_with(true, false);
    assert_eq!((up.outcome, up.in_place.as_deref()), (Outcome::Updated, None), "{up:?}");
    assert_eq!((peer.daemon(), peer.read("daemon-pid").trim()), (NEW.to_owned(), "4242"));
    assert!(!peer.take_calls().iter().any(|c| c.contains("daemon shutdown")));
}

/// Review of #25602 at d486002d: a `launchctl print-disabled` that fails
/// says nothing about the daemon's job, so the restart refuses before the
/// bootout instead of going on as if the job were enabled.
#[test]
#[cfg(unix)]
fn a_launchd_that_cannot_say_whether_the_job_is_disabled_stops_nothing() {
    let peer = FakePeer::new("print-disabled-fails");
    peer.under_launchd();
    peer.write("print-disabled-fails", "");
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(NEW, Some(NEW)));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("launchdRefused")),
        "{up:?}"
    );
    assert!(up.error.as_deref().unwrap_or("").contains("did not say whether"), "{up:?}");
    assert_eq!(peer.daemon(), OLD, "the old daemon still runs");
    assert!(peer.exists("loaded"), "its job was never booted out");
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
}

/// A plist launchd cannot read is found before anything stops.
#[test]
#[cfg(unix)]
fn a_daemon_plist_launchd_cannot_read_stops_nothing() {
    let peer = FakePeer::new("bad-plist");
    peer.under_launchd();
    peer.write("Library/LaunchAgents/com.acpmux.daemon.plist", "BROKEN");
    peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(NEW, Some(NEW)));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("launchdRefused")),
        "{up:?}"
    );
    assert!(up.error.as_deref().unwrap_or("").contains("acpmux machine setup writes it again"));
    assert_eq!(peer.daemon(), OLD, "the old daemon still runs");
    assert!(peer.exists("loaded"));
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
}

/// cosmic-gray (2026-10-31): the cmux NIGHTLY app installs acpmux as a
/// link into its bundle and runs the daemon as its own LaunchAgent, with no
/// `com.acpmux.daemon.plist`. The update refused only at the restart, after
/// it had replaced the app's link with a hard link to the old binary. Now it
/// refuses before it pushes anything, and the link is as it was.
#[test]
#[cfg(unix)]
fn a_mac_whose_acpmux_the_cmux_app_runs_is_left_as_it_was() {
    let bin = "Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";
    for (shape, app_link, app_job) in
        [("app", true, true), ("app-link", true, false), ("app-job", false, true)]
    {
        let peer = FakePeer::new(shape);
        peer.under_launchd();
        let link = peer.home.join(".local/bin/acpmux");
        let target = peer.home.join(bin);
        if app_link {
            peer.exe(bin, &fake_acpmux(OLD, Some(OLD)));
            std::fs::remove_file(&link).unwrap();
            std::os::unix::fs::symlink(&target, &link).unwrap();
        }
        if app_job {
            std::fs::remove_file(peer.home.join("Library/LaunchAgents/com.acpmux.daemon.plist"))
                .unwrap();
            peer.write("Library/LaunchAgents/com.cmux.acpmux.daemon.3f9c2a.plist", "<plist/>\n");
        }
        peer.exe(&format!("binaries/acpmux-{MAC_TARGET}"), &fake_acpmux(NEW, Some(NEW)));
        let up = peer.update_with(true, true);
        assert_eq!(
            (up.outcome, up.reason.as_deref()),
            (Outcome::Failed, Some("appManaged")),
            "{shape}: {up:?}"
        );
        assert!(up.error.as_deref().unwrap_or("").contains("cmux app"), "{shape}: {up:?}");
        if app_link {
            let meta = std::fs::symlink_metadata(&link).unwrap();
            assert!(meta.file_type().is_symlink(), "{shape}: the app's link is still a link");
            assert_eq!(std::fs::read_link(&link).unwrap(), target, "{shape}");
            assert_eq!(peer.read(bin), fake_acpmux(OLD, Some(OLD)), "{shape}: the app's binary");
        }
        assert!(peer.exists("loaded"), "{shape}: launchd was not touched");
        peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
    }
}
