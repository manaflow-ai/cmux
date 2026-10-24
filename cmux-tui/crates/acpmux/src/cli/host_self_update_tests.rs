//! `host self-update` on a fake host ([`FakePeer`]) with a fake file server:
//! the channel file, the download and its sha256, the lock (shared with
//! `host update`, `host setup` and `host enroll --fix`) and the opt-out, a
//! rollback that is not tried again, a daemon home a drop-in moved, and the
//! timer units' install.

use super::super::host_self_update::{
    Channel, Fetch, LocalRemote, Paths, Plan, Prepared, ROLLED_BACK, Step, apply, channel_url,
    prepare,
};
use super::*;
use crate::cli::hosts::host_auto_update::{
    NO_AUTO_UPDATE, UPDATE_SERVICE, UPDATE_TIMER, install_script,
};
use crate::cli::hosts::{Remote, lock_to_install, lock_updates};
use futures::future::BoxFuture;
use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::sync::Mutex;

const KEY: &str = "0123456789abcdef0123456789abcdef01234567";
const COMMIT: &str = "89abcdef0123456789abcdef0123456789abcdef";
const CHANNEL: &str = "feat-cmux-next";

/// A file server: its bodies by URL, and every URL asked for.
#[derive(Default)]
struct Files {
    bodies: HashMap<String, Vec<u8>>,
    asked: Mutex<Vec<String>>,
}

impl Fetch for Files {
    fn get<'a>(&'a self, url: &'a str, max: usize) -> BoxFuture<'a, Result<Vec<u8>, String>> {
        self.asked.lock().unwrap().push(url.to_owned());
        let body = match self.bodies.get(url) {
            Some(body) if body.len() <= max => Ok(body.clone()),
            Some(_) => Err(format!("the body is above the {max} byte limit")),
            None => Err("the server answered 404".to_owned()),
        };
        Box::pin(async move { body })
    }
}

impl Files {
    fn asked(&self) -> Vec<String> {
        self.asked.lock().unwrap().clone()
    }
}

fn channel_json(binaries: &[(&str, &str)]) -> Vec<u8> {
    let binaries: serde_json::Map<String, Value> =
        binaries.iter().map(|(name, sha)| ((*name).to_owned(), json!(sha))).collect();
    json!({"key": KEY, "commit": COMMIT, "binaries": binaries}).to_string().into_bytes()
}

fn sha_of(text: &str) -> String {
    crate::sha256::sha256_hex(text.as_bytes())
}

fn binary_url() -> String {
    format!("https://files.cmux.com/cmux-tui/tree/{KEY}/cmux-tui-acpmux-{TARGET}")
}

/// A server whose channel offers `binary` (a fake acpmux) for the host's target.
fn serving(binary: &str) -> Files {
    let mut files = Files::default();
    let name = format!("cmux-tui-acpmux-{TARGET}");
    let sha = sha_of(binary);
    let channel = channel_json(&[(name.as_str(), sha.as_str())]);
    files.bodies.insert(channel_url(CHANNEL).unwrap(), channel);
    files.bodies.insert(binary_url(), binary.as_bytes().to_vec());
    files
}

/// The self-update's paths in the fake host's home.
fn paths(peer: &FakePeer) -> Paths {
    Paths {
        home: peer.home.join(".acpmux"),
        installed: peer.home.join(".local/bin/acpmux"),
        off: peer.home.join(".acpmux").join(NO_AUTO_UPDATE),
        cloud_vm: peer.home.join("etc/cmux/vm-kind"),
        target: TARGET,
    }
}

/// `f` until it gives a value, for up to 2 s: a lock this process just
/// dropped is free only once no other test thread's spawn still holds a copy
/// of its descriptor (a spawn copies every one until the child closes its
/// close-on-exec ones).
fn once_free<T>(mut f: impl FnMut() -> Option<T>) -> Option<T> {
    for _ in 0..100 {
        if let Some(value) = f() {
            return Some(value);
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    None
}

/// [`prepare`] once the lock this test dropped is free ([`once_free`]).
async fn prepared(peer: &FakePeer, files: &Files) -> Prepared {
    for _ in 0..100 {
        match prepare(&paths(peer), files, CHANNEL).await.unwrap() {
            Prepared::Locked => std::thread::sleep(std::time::Duration::from_millis(20)),
            other => return other,
        }
    }
    Prepared::Locked
}

async fn ready(peer: &FakePeer, files: &Files) -> Plan {
    match prepared(peer, files).await {
        Prepared::Ready(plan) => plan,
        Prepared::Off => panic!("automatic updates are off"),
        Prepared::Locked => panic!("the lock is held"),
        Prepared::RolledBackBefore(_) => panic!("the build was rolled back before"),
    }
}

async fn refused(peer: &FakePeer, files: &Files) -> String {
    match prepare(&paths(peer), files, CHANNEL).await {
        Err(e) => format!("{e:#}"),
        Ok(_) => panic!("the self-update went ahead"),
    }
}

#[test]
fn the_channel_file_names_a_tree_and_each_targets_sha256() {
    let name = format!("cmux-tui-acpmux-{TARGET}");
    let sha = "a".repeat(64);
    let channel = Channel::parse(&channel_json(&[(name.as_str(), sha.as_str())])).unwrap();
    assert_eq!((channel.key.as_str(), channel.commit.as_str()), (KEY, COMMIT));
    assert_eq!(channel.sha256_for(TARGET).unwrap(), sha);
    let why = channel.sha256_for("riscv64gc-unknown-linux-musl").unwrap_err().to_string();
    assert!(why.contains("no acpmux build for riscv64gc-unknown-linux-musl"), "{why}");
    // A sha256 that is not one is refused, not compared.
    let channel = Channel::parse(&channel_json(&[(name.as_str(), "ABC")])).unwrap();
    assert!(channel.sha256_for(TARGET).is_err());
    // Keys CI adds later are ignored.
    let extra = json!({"key": KEY, "commit": COMMIT, "binaries": {}, "run": "1"}).to_string();
    assert!(Channel::parse(extra.as_bytes()).is_ok());
    for broken in [
        "not json".to_owned(),
        "[]".to_owned(),
        json!({"key": KEY, "commit": COMMIT}).to_string(),
        json!({"key": "../latest", "commit": COMMIT, "binaries": {}}).to_string(),
        json!({"key": KEY, "commit": "abc1234", "binaries": {}}).to_string(),
        json!({"key": KEY.to_uppercase(), "commit": COMMIT, "binaries": {}}).to_string(),
    ] {
        assert!(Channel::parse(broken.as_bytes()).is_err(), "{broken}");
    }
    assert_eq!(
        channel_url(CHANNEL).unwrap(),
        "https://files.cmux.com/cmux-tui/channels/feat-cmux-next.json"
    );
    for bad in ["", "../latest", "Feat", "a/b", "x?y"] {
        assert!(channel_url(bad).is_err(), "{bad}");
    }
}

#[tokio::test]
async fn a_host_that_has_the_channels_binary_is_left_alone() {
    let peer = FakePeer::new("self-current");
    let installed = fake_acpmux(OLD, Some(OLD));
    let files = serving(&installed);
    let plan = ready(&peer, &files).await;
    assert!(matches!(&plan.step, Step::Current(Some(build)) if build == OLD));
    let up = apply(&peer, &plan, TARGET);
    assert_eq!(up.outcome, Outcome::Current, "{up:?}");
    assert_eq!(up.build.as_deref(), Some(OLD));
    assert_eq!(files.asked(), [channel_url(CHANNEL).unwrap()], "nothing is downloaded");
    peer.assert_untouched(&installed, OLD);
}

#[tokio::test]
async fn a_newer_build_is_downloaded_checked_and_installed() {
    let peer = FakePeer::new("self-update");
    let new = fake_acpmux(NEW, Some(NEW));
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    let dir = peer.home.join(".acpmux/update").join(sha_of(&new));
    assert!(matches!(&plan.step, Step::Install(d) if *d == dir));
    assert_eq!(peer.read(&format!(".acpmux/update/{}/acpmux-{TARGET}", sha_of(&new))), new);
    let up = apply(&peer, &plan, TARGET);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(up.build.as_deref(), Some(NEW));
    assert_eq!(peer.read(".local/bin/acpmux"), new);
    assert_eq!(peer.read(".local/bin/acpmux.prev"), fake_acpmux(OLD, Some(OLD)));
    assert!(peer.exists("agents"), "the restart keeps the agents");
    let calls = peer.take_calls();
    assert!(calls.contains(&"systemctl --user restart acpmux.service".to_owned()), "{calls:?}");
    // The update installs the timer beside acpmux.service.
    assert_eq!(peer.read(&format!("{UNITS}/acpmux-update.timer")), UPDATE_TIMER);
    assert!(calls.contains(&"systemctl --user enable --now acpmux-update.timer".to_owned()));
    drop(plan);

    // The next run finds the channel's binary installed: no download.
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    assert!(matches!(&plan.step, Step::Current(Some(build)) if build == NEW));
    assert_eq!(files.asked().len(), 1);
}

#[tokio::test]
async fn a_download_that_does_not_match_the_channel_is_never_installed() {
    let peer = FakePeer::new("self-bad-sha");
    let new = fake_acpmux(NEW, Some(NEW));
    let mut files = serving(&new);
    files.bodies.insert(binary_url(), b"#!/bin/sh\necho tampered\n".to_vec());
    let why = refused(&peer, &files).await;
    assert!(why.contains("sha256") && why.contains("not installed"), "{why}");
    assert!(!peer.exists(&format!(".acpmux/update/{}", sha_of(&new))), "nothing is kept");
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
}

#[tokio::test]
async fn a_channel_without_this_hosts_target_is_refused() {
    let peer = FakePeer::new("self-no-target");
    let mut files = Files::default();
    let sha = "b".repeat(64);
    let other = channel_json(&[("cmux-tui-acpmux-riscv64gc-unknown-linux-musl", sha.as_str())]);
    files.bodies.insert(channel_url(CHANNEL).unwrap(), other);
    let why = refused(&peer, &files).await;
    assert!(why.contains(&format!("no acpmux build for {TARGET}")), "{why}");
    assert_eq!(files.asked().len(), 1, "nothing is downloaded");
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
}

#[tokio::test]
async fn a_build_whose_daemon_does_not_come_back_is_rolled_back_and_not_tried_again() {
    let peer = FakePeer::new("self-rollback");
    let bad = fake_acpmux(NEW, Some("fedcba987 2026-10-21"));
    let files = serving(&bad);
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::RolledBack, Some("buildMismatch")),
        "{up:?}"
    );
    assert!(up.outcome.failed());
    assert_eq!(up.build.as_deref(), Some(OLD), "the previous build answers again");
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
    assert_eq!(peer.daemon(), OLD);
    assert!(peer.exists("agents"));
    assert!(peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&bad))));
    drop(plan);
    let _ = peer.take_calls();

    // The next run leaves that build alone: no download, no restart.
    let files = serving(&bad);
    let again = prepared(&peer, &files).await;
    assert!(matches!(&again, Prepared::RolledBackBefore(commit) if commit == COMMIT));
    assert!(peer.take_calls().is_empty(), "the daemon is not restarted again");
    assert_eq!(files.asked().len(), 1);

    // A newer build is tried, and the rejected download goes; its
    // rejection stays.
    let newer = "b2c3d4e5f 2026-10-22";
    let files = serving(&fake_acpmux(newer, Some(newer)));
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(newer)), "{up:?}");
    assert!(!peer.exists(&format!(".acpmux/update/{}/acpmux-{TARGET}", sha_of(&bad))));
    assert!(peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&bad))));
    drop(plan);
    let _ = peer.take_calls();

    // Review of #24232: pruning took the rejection with the download, so a
    // channel that moved back to the bad build installed it again.
    let files = serving(&bad);
    let again = prepared(&peer, &files).await;
    assert!(matches!(&again, Prepared::RolledBackBefore(commit) if commit == COMMIT));
    assert!(peer.take_calls().is_empty(), "the healthy daemon is not restarted");
    assert_eq!(files.asked().len(), 1, "the bad build is not downloaded again");
    assert_eq!(peer.daemon(), newer);
}

#[tokio::test]
async fn one_self_update_runs_at_a_time_and_the_opt_out_stops_them() {
    let peer = FakePeer::new("self-lock");
    let files = serving(&fake_acpmux(OLD, Some(OLD)));
    let held = ready(&peer, &files).await;
    let second = prepare(&paths(&peer), &files, CHANNEL).await.unwrap();
    assert!(matches!(second, Prepared::Locked));
    drop(held);
    drop(ready(&peer, &files).await);

    peer.write(&format!(".acpmux/{NO_AUTO_UPDATE}"), "");
    let asked = files.asked().len();
    assert!(matches!(prepare(&paths(&peer), &files, CHANNEL).await.unwrap(), Prepared::Off));
    assert_eq!(files.asked().len(), asked, "nothing is read");
}

#[tokio::test]
async fn a_cloud_vm_is_refused_before_anything_is_read() {
    let peer = FakePeer::new("self-cloud-vm");
    peer.write("etc/cmux/vm-kind", "cloud\n");
    let files = serving(&fake_acpmux(NEW, Some(NEW)));
    let why = refused(&peer, &files).await;
    assert!(why.contains("--to-bundled"), "{why}");
    assert!(files.asked().is_empty());
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
}

#[tokio::test]
async fn a_host_update_and_a_self_update_of_one_host_never_run_at_once() {
    // The review's race: a self-update and a `host update` both probe the
    // old daemon and install, and the second one's backup is the first one's
    // new binary, so a rollback restores that. One lock on the host now
    // keeps each out while the other runs.
    let peer = FakePeer::new("self-host-lock");
    let old = fake_acpmux(OLD, Some(OLD));
    peer.offer(NEW, Some(NEW));
    let opts = UpdateOptions {
        binary_dir: Some(peer.home.join("binaries")),
        if_idle: false,
        caller: None,
    };

    // The timer holds it: an update from another machine changes nothing.
    let files = serving(&fake_acpmux(NEW, Some(NEW)));
    let held = ready(&peer, &files).await;
    let up = update_locked(&peer, &opts);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Failed, Some("updateRunning")));
    assert!(up.outcome.failed());
    // `host setup` and `host enroll --fix` take it before they push, link
    // or restart, so they do neither.
    let Err(why) = lock_to_install(&peer) else { panic!("the lock was taken twice") };
    assert!(format!("{why:#}").contains("another update of fake is running"), "{why:#}");
    peer.assert_only_read(&old, OLD);
    assert!(!peer.exists(".local/bin/acpmux.prev"));
    drop(held);

    // An update from another machine holds it: the timer leaves the host
    // alone, and so does a second update.
    let lock = once_free(|| lock_updates(&peer).unwrap()).expect("the lock is free");
    assert!(matches!(prepare(&paths(&peer), &files, CHANNEL).await.unwrap(), Prepared::Locked));
    assert!(lock_updates(&peer).unwrap().is_none());
    assert_eq!(update_locked(&peer, &opts).reason.as_deref(), Some("updateRunning"));
    drop(lock);

    // Each takes it once the other ended.
    let up = update_locked(&peer, &opts);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux.prev"), old, "the backup is the known-good binary");
    drop(ready(&peer, &files).await);
}

#[tokio::test]
async fn a_daemon_whose_socket_a_drop_in_moved_is_checked_where_it_listens() {
    // A migration carries ACPMUX_HOME and ACPMUX_SOCKET to acpmux.service in
    // a drop-in (host_migrate.rs); acpmux-update.service has neither, so its
    // checks asked the default socket, took the healthy new daemon for a
    // dead one and rolled it back, at every run. Every update script now
    // reads them from acpmux.service.
    let peer = FakePeer::new("self-moved-socket");
    let socket = peer.home.join(".acpmux-supervised/hb/acpmux.sock").display().to_string();
    peer.write(
        &format!("{UNITS}/acpmux.service.d/10-migrated.conf"),
        &format!("[Service]\nEnvironment=ACPMUX_SOCKET={socket}\n"),
    );
    let old = listening_at(&socket, &fake_acpmux(OLD, Some(OLD)));
    peer.exe(".local/bin/acpmux", &old);
    let new = listening_at(&socket, &fake_acpmux(NEW, Some(NEW)));
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), new);
    assert!(!peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&new))));

    // The same holds for a check of the previous build, after a rollback.
    drop(plan);
    let newer = "b2c3d4e5f 2026-10-22";
    let bad = listening_at(&socket, &fake_acpmux(newer, Some("fedcba987 2026-10-21")));
    let files = serving(&bad);
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET);
    assert_eq!(
        (up.outcome, up.reason.as_deref(), up.build.as_deref()),
        (Outcome::RolledBack, Some("buildMismatch"), Some(NEW)),
        "{up:?}"
    );
    assert_eq!(peer.daemon(), NEW);
}

#[tokio::test]
async fn a_self_update_whose_lease_another_update_took_changes_nothing_and_marks_nothing() {
    // The lease went to another update (this test's process stands in for
    // its holder): no step runs, and the build is not marked rolled back.
    let peer = FakePeer::new("self-lease-taken");
    let new = fake_acpmux(NEW, Some(NEW));
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    let theirs = format!("{} {}\n", "f".repeat(32), std::process::id());
    peer.write(".acpmux/update.owner", &theirs);
    let up = apply(&peer, &plan, TARGET);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Failed, Some("lockLost")), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
    assert!(!peer.exists(".local/bin/acpmux.prev"));
    assert!(!peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&new))));
    drop(plan);
    assert_eq!(peer.read(".acpmux/update.owner"), theirs, "the other update's lease stays");
}

/// A user manager as the fake `systemctl` answers `show`: its unit search
/// path is `$HOME/unit-paths` (default: `~/.config/systemd/user` and
/// `$HOME/etc-user`), the first directory with the unit is where it loads
/// from, a link to /dev/null there masks it, and with `$HOME/no-manager` it
/// does not answer. Every other call is logged to `$HOME/calls`.
const FAKE_MANAGER: &str = r#"if [ "$2" = show ]; then
  [ -f "$HOME/no-manager" ] && exit 1
  paths=$(cat "$HOME/unit-paths" 2>/dev/null) || paths="$HOME/.config/systemd/user $HOME/etc-user"
  s=not-found; f=
  for p in $paths; do
    if [ -L "$p/$3" ] && [ "$(readlink "$p/$3")" = /dev/null ]; then s=masked; break; fi
    if [ -e "$p/$3" ]; then s=loaded; f=$p/$3; break; fi
  done
  case "$5" in LoadState) echo $s;; FragmentPath) echo "$f";; esac
  exit 0
fi
echo "systemctl $*" >> "$HOME/calls""#;

/// [`install_script`] in `home` with [`FAKE_MANAGER`] as `systemctl`: the
/// calls and stderr.
fn install_units(home: &Path) -> (Vec<String>, String) {
    use std::os::unix::fs::PermissionsExt;
    let bin = home.join("fakebin");
    std::fs::create_dir_all(&bin).unwrap();
    let systemctl = bin.join("systemctl");
    std::fs::write(&systemctl, format!("#!/bin/sh\n{FAKE_MANAGER}\n")).unwrap();
    std::fs::set_permissions(&systemctl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = Command::new("sh")
        .args(["-c", &install_script()])
        .env("HOME", home)
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    let calls = std::fs::read_to_string(home.join("calls")).unwrap_or_default();
    let _ = std::fs::remove_file(home.join("calls"));
    (calls.lines().map(str::to_owned).collect(), String::from_utf8_lossy(&out.stderr).into_owned())
}

#[test]
fn the_timer_units_install_once_and_a_unit_someone_else_wrote_is_left_alone() {
    let home = std::env::temp_dir().join(format!("acpmux-auto-update-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let units = home.join(".config/systemd/user");
    let read = |name: &str| std::fs::read_to_string(units.join(name)).unwrap_or_default();
    let enable = "systemctl --user enable --now acpmux-update.timer";

    let (calls, _) = install_units(&home);
    assert_eq!(read("acpmux-update.service"), UPDATE_SERVICE);
    assert_eq!(read("acpmux-update.timer"), UPDATE_TIMER);
    assert_eq!(calls, ["systemctl --user daemon-reload", enable]);
    assert!(UPDATE_SERVICE.contains("ExecStart=%h/.local/bin/acpmux host self-update --json"));
    assert!(UPDATE_SERVICE.contains("Type=oneshot") && UPDATE_SERVICE.contains("KillMode=process"));
    for line in
        ["OnActiveSec=5min", "OnUnitActiveSec=15min", "RandomizedDelaySec=2min", "Persistent=true"]
    {
        assert!(UPDATE_TIMER.contains(line), "{line}");
    }
    assert!(!UPDATE_TIMER.contains("OnBootSec"), "a late start would fire at once");

    // Again: nothing to write, so no reload; the timer stays on.
    let (calls, _) = install_units(&home);
    assert_eq!(calls, [enable]);

    // A timer someone else wrote is kept, its service is not written, and
    // nothing is started.
    let theirs = "[Timer]\nOnCalendar=daily\n";
    std::fs::write(units.join("acpmux-update.timer"), theirs).unwrap();
    std::fs::remove_file(units.join("acpmux-update.service")).unwrap();
    let (calls, err) = install_units(&home);
    assert!(calls.is_empty(), "{calls:?}");
    assert!(err.contains("acpmux-update.timer is a unit acpmux did not write"), "{err}");
    assert_eq!(read("acpmux-update.timer"), theirs);
    assert!(!units.join("acpmux-update.service").exists());

    // Review of #24232: a unit the running manager loads from another
    // directory (/etc/systemd/user here; a runtime or $XDG_DATA_HOME
    // directory the same way, whatever that manager reads) would be shadowed
    // by the one written here, so neither is written.
    std::fs::remove_dir_all(&units).unwrap();
    let etc = home.join("etc-user");
    std::fs::create_dir_all(&etc).unwrap();
    std::fs::write(etc.join("acpmux-update.service"), "[Service]\nExecStart=/bin/true\n").unwrap();
    let (calls, err) = install_units(&home);
    assert!(calls.is_empty(), "{calls:?}");
    assert!(err.contains("etc-user/acpmux-update.service is a unit"), "{err}");
    assert!(!units.exists());
    std::fs::remove_dir_all(&etc).unwrap();

    // Re-review: the manager's own search path counts, not the shell's (a
    // manager started with another XDG_DATA_HOME), and a mask counts too.
    let custom = home.join("srv/units/systemd/user");
    std::fs::create_dir_all(&custom).unwrap();
    std::os::unix::fs::symlink("/dev/null", custom.join("acpmux-update.timer")).unwrap();
    let searched = format!("{} {}\n", units.display(), custom.display());
    std::fs::write(home.join("unit-paths"), searched).unwrap();
    let (calls, err) = install_units(&home);
    assert!(calls.is_empty(), "{calls:?}");
    assert!(err.contains("acpmux-update.timer (masked) is a unit"), "{err}");
    assert!(!units.exists());
    std::fs::remove_dir_all(home.join("srv")).unwrap();
    std::fs::remove_file(home.join("unit-paths")).unwrap();

    // A manager that cannot say: nothing is written (fail closed).
    std::fs::write(home.join("no-manager"), "").unwrap();
    let (calls, err) = install_units(&home);
    assert!(calls.is_empty(), "{calls:?}");
    assert!(err.contains("no answer from the user manager"), "{err}");
    assert!(!units.exists());
    std::fs::remove_file(home.join("no-manager")).unwrap();

    // The opt-out stops the timer and writes nothing.
    std::fs::create_dir_all(home.join(".acpmux")).unwrap();
    std::fs::write(home.join(".acpmux").join(NO_AUTO_UPDATE), "").unwrap();
    let (calls, _) = install_units(&home);
    assert_eq!(calls, ["systemctl --user disable --now acpmux-update.timer"]);
    assert!(!units.exists());
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn this_machine_runs_scripts_under_sh_and_pushes_by_copying() {
    let out = LocalRemote
        .exec("read x; echo \"got $x\"; echo oops >&2; exit 3", Some(b"hi\n".as_slice()))
        .unwrap();
    assert!(!out.ok);
    assert_eq!((out.stdout.as_str(), out.stderr.as_str()), ("got hi\n", "oops\n"));
    assert!(LocalRemote.exec("true", None).unwrap().ok);

    let dir = std::env::temp_dir().join(format!("acpmux-local-push-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("from"), "bytes").unwrap();
    LocalRemote.push(&dir.join("from"), &dir.join("to").to_string_lossy()).unwrap();
    assert_eq!(std::fs::read_to_string(dir.join("to")).unwrap(), "bytes");
    let _ = std::fs::remove_dir_all(&dir);
}
