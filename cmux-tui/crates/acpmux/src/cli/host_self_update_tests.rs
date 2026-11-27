//! `host self-update` on a fake host ([`FakePeer`]) with a fake file server:
//! the channel file, the download and its sha256, the lock (shared with
//! `host update`, `host setup` and `host enroll --fix`) and the opt-out, a
//! rollback that is not tried again, a daemon home a drop-in moved, and the
//! timer units' install.

use super::super::host_self_update::{
    Channel, Controller, Fetch, LocalRemote, Paths, Plan, Prepared, ROLLED_BACK, Source, Step,
    apply, channel_url, prepare, refresh_tui, tui::TuiOutcome, unpack,
};
use super::*;
use crate::cli::hosts::host_auto_update::{
    AUTO_UPDATE_OFF, NO_AUTO_UPDATE, UPDATE_SERVICE, UPDATE_TIMER, install_script,
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
        unit: peer.home.join(format!("{UNITS}/acpmux.service")),
        target: TARGET,
        rd: None,
        tui: Some(peer.home.join(".local/bin/cmux-tui")),
        allow_downgrade: false,
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
    prepared_with(&paths(peer), files).await
}

/// [`prepared`] with these paths (`--allow-downgrade`, say): a run right after
/// one that dropped its plan waits out the same descriptor copies.
async fn prepared_with(paths: &Paths, files: &Files) -> Prepared {
    for _ in 0..100 {
        match prepare(paths, files, None, CHANNEL).await.unwrap() {
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
        Prepared::RolledBackBefore(..) => panic!("the build was rolled back before"),
    }
}

async fn refused(peer: &FakePeer, files: &Files) -> String {
    match prepare(&paths(peer), files, None, CHANNEL).await {
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
    let up = apply(&peer, &plan, TARGET, true);
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
    let up = apply(&peer, &plan, TARGET, true);
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

/// Review of #24232: an update stopped after the install but before the
/// restart left the channel's binary installed under a daemon still on the
/// old build, and every later run called the host current. The run checks
/// the daemon that answers, so it restarts that one.
#[tokio::test]
async fn an_install_that_never_restarted_is_finished_by_the_next_run() {
    let peer = FakePeer::new("self-unrestarted");
    let new = fake_acpmux(NEW, Some(NEW));
    let old = peer.read(".local/bin/acpmux");
    peer.exe(".local/bin/acpmux.prev", &old);
    peer.exe(".local/bin/acpmux", &new);
    assert_eq!(peer.daemon(), OLD);
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    assert!(matches!(&plan.step, Step::Current(Some(build)) if build == NEW));
    assert_eq!(files.asked().len(), 1, "nothing is downloaded");
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    assert_eq!(peer.daemon(), NEW);
    assert_eq!(peer.read(".local/bin/acpmux"), new);
    assert!(peer.exists("agents"), "the restart keeps the agents");
    // Re-review: pushing the installed binary again kept it as the backup
    // too, so a failed restart had only the new build to go back to.
    assert_eq!(peer.read(".local/bin/acpmux.prev"), old, "the backup is still the old build");
}

/// Re-review of #24232: after an update stopped before its restart, the next
/// build's install backed up the binary that never ran, so a rollback put
/// back a build no daemon had run instead of the one that last ran.
#[tokio::test]
async fn an_install_that_never_restarted_keeps_the_last_build_that_ran_as_the_backup() {
    let peer = FakePeer::new("self-unrestarted-newer");
    let old = peer.read(".local/bin/acpmux");
    peer.exe(".local/bin/acpmux.prev", &old);
    peer.exe(".local/bin/acpmux", &fake_acpmux(NEW, Some(NEW)));
    let newer = "b2c3d4e5f 2026-10-22";
    let files = serving(&fake_acpmux(newer, Some(newer)));
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(newer)), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux.prev"), old, "the backup is the build that last ran");
}

/// Re-review of #24232: with no daemon answering (an update that stopped
/// the old one and died), pushing the installed binary again took the
/// backup of the build that last ran.
#[tokio::test]
async fn a_retry_with_no_daemon_keeps_the_backup() {
    let peer = FakePeer::new("self-unrestarted-down");
    let old = peer.read(".local/bin/acpmux");
    peer.exe(".local/bin/acpmux.prev", &old);
    let new = fake_acpmux(NEW, Some(NEW));
    peer.exe(".local/bin/acpmux", &new);
    let _ = std::fs::remove_file(peer.home.join("daemon"));
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux.prev"), old, "the backup is the build that last ran");

    // Re-review: the same with the channel moved on to a newer build.
    peer.exe(".local/bin/acpmux", &new);
    let _ = std::fs::remove_file(peer.home.join("daemon"));
    drop(plan);
    let newer = "b2c3d4e5f 2026-10-22";
    let files = serving(&fake_acpmux(newer, Some(newer)));
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(newer)), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux.prev"), old, "the backup is the build that last ran");
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

/// `new` packed as `zstd --patch-from=old` packs it: `old` the raw-content
/// dictionary (no dictionary: `zstd --long`).
fn packed(new: &str, old: &str) -> Vec<u8> {
    zstd::bulk::Compressor::with_dictionary(19, old.as_bytes())
        .unwrap()
        .compress(new.as_bytes())
        .unwrap()
}

/// A fresh host updates to `new` from `files`; `raw`: whether the binary
/// itself was fetched.
async fn installs(name: &str, files: &Files, new: &str, raw: bool) {
    let peer = FakePeer::new(&format!("self-small-{name}"));
    let plan = ready(&peer, files).await;
    assert_eq!(
        peer.read(&format!(".acpmux/update/{}/acpmux-{TARGET}", sha_of(new))),
        new,
        "{name}"
    );
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(up.outcome, Outcome::Updated, "{name}: {up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), new, "{name}");
    assert_eq!(files.asked().contains(&binary_url()), raw, "{name}: {:?}", files.asked());
}

/// RFD 0166: a patch against the installed build is fetched first and the
/// binary itself never is; with none, the `.zst`; a patch that rebuilds
/// another binary, or that does not decode, falls back to the next, the raw
/// binary last, all under the channel's sha256.
#[tokio::test]
async fn a_patch_or_zst_beside_the_binary_is_fetched_first() {
    let old = fake_acpmux(OLD, Some(OLD));
    let new = fake_acpmux(NEW, Some(NEW));
    let patch_url = format!("{}.from-{}.zst", binary_url(), sha_of(&old));
    let zst_url = format!("{}.zst", binary_url());
    let mut files = serving(&new);
    files.bodies.insert(patch_url.clone(), packed(&new, &old));
    files.bodies.insert(zst_url.clone(), packed(&new, ""));
    installs("patch", &files, &new, false).await;
    assert!(!files.asked().contains(&zst_url), "the patch was enough");

    let mut files = serving(&new);
    files.bodies.insert(zst_url.clone(), packed(&new, ""));
    installs("zst", &files, &new, false).await;
    assert!(files.asked().contains(&patch_url), "the patch was asked first");

    let mut files = serving(&new);
    files.bodies.insert(patch_url.clone(), packed(&fake_acpmux(NEW, None), &old));
    files.bodies.insert(zst_url.clone(), b"not zstd".to_vec());
    installs("bad", &files, &new, true).await;
}

/// The patch decoder reads what the `zstd` CLI's `--patch-from --long=31`
/// writes (the publish side's tool), not only what the crate's encoder does.
#[test]
fn a_zstd_cli_patch_decodes() {
    if Command::new("zstd").arg("--version").output().is_err() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let old: Vec<u8> =
        (0..400_000u32).flat_map(|i| (i.wrapping_mul(2654435761) >> 7).to_le_bytes()).collect();
    let mut new = old.clone();
    new[123_456..123_470].copy_from_slice(b"a changed part");
    new.extend_from_slice(b"and a new tail");
    std::fs::write(dir.path().join("old"), &old).unwrap();
    std::fs::write(dir.path().join("new"), &new).unwrap();
    let ok = Command::new("zstd")
        .current_dir(dir.path())
        .args(["-q", "-19", "--long=31", "--patch-from=old", "new", "-o", "patch"])
        .status()
        .unwrap()
        .success();
    assert!(ok);
    let patch = std::fs::read(dir.path().join("patch")).unwrap();
    assert!(patch.len() < new.len() / 20, "{} bytes", patch.len());
    assert_eq!(unpack(&patch, &old).unwrap(), new);
    assert!(unpack(&patch, &[]).is_err() || unpack(&patch, &[]).unwrap() != new);
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

fn tui_url() -> String {
    format!("https://files.cmux.com/cmux-tui/tree/{KEY}/cmux-tui-{TARGET}")
}

/// `files` also serves the tree's cmux-tui (`cli`) and its `.sha256` as CI writes it.
fn with_tui(mut files: Files, cli: &str) -> Files {
    files.bodies.insert(tui_url(), cli.as_bytes().to_vec());
    let sum = format!("{}  cmux-tui-{TARGET}\n", sha_of(cli));
    files.bodies.insert(format!("{}.sha256", tui_url()), sum.into_bytes());
    files
}

/// A Linux host, 2026-11-24: the self-update replaced acpmux only, and the October cmux-tui beside
/// it had no `chief` verb, so the Chief failed every wake for days. The cmux-tui beside acpmux
/// now follows the same tree, checked against the tree's sha256 and renamed into place.
#[tokio::test]
async fn the_cmux_tui_beside_acpmux_follows_acpmuxs_update() {
    let peer = FakePeer::new("self-tui");
    peer.exe(".local/bin/cmux-tui", "october cli");
    let new = fake_acpmux(NEW, Some(NEW));
    let files = with_tui(serving(&new), "november cli");
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    let tui = refresh_tui(&paths(&peer), &files, &plan, &up).await;
    assert_eq!(tui, TuiOutcome::Installed(sha_of("november cli")));
    assert_eq!(peer.read(".local/bin/cmux-tui"), "november cli");
    assert!(!peer.exists(".local/bin/.cmux-tui.new"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(peer.home.join(".local/bin/cmux-tui")).unwrap().permissions();
        assert_eq!(mode.mode() & 0o777, 0o755);
    }
    assert_eq!(tui.json()["outcome"], "installed");
    drop(plan);

    // The next run (acpmux current) finds it current: only the sha256 is read.
    let files = with_tui(serving(&new), "november cli");
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(up.outcome, Outcome::Current, "{up:?}");
    assert_eq!(refresh_tui(&paths(&peer), &files, &plan, &up).await, TuiOutcome::Current);
    assert!(!files.asked().contains(&tui_url()), "{:?}", files.asked());
}

/// The case that host hit: acpmux is already the channel's, cmux-tui is stale. A channel file
/// that lists cmux-tui's sha256 is used over the tree's `.sha256`.
#[tokio::test]
async fn a_stale_cmux_tui_beside_a_current_acpmux_is_refreshed() {
    let peer = FakePeer::new("self-tui-current");
    peer.exe(".local/bin/cmux-tui", "october cli");
    let installed = fake_acpmux(OLD, Some(OLD));
    let mut files = serving(&installed);
    let acpmux = format!("cmux-tui-acpmux-{TARGET}");
    let cli = format!("cmux-tui-{TARGET}");
    let (acpmux_sha, cli_sha) = (sha_of(&installed), sha_of("november cli"));
    let channel =
        channel_json(&[(acpmux.as_str(), acpmux_sha.as_str()), (cli.as_str(), cli_sha.as_str())]);
    files.bodies.insert(channel_url(CHANNEL).unwrap(), channel);
    files.bodies.insert(tui_url(), b"november cli".to_vec());
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(up.outcome, Outcome::Current, "{up:?}");
    let tui = refresh_tui(&paths(&peer), &files, &plan, &up).await;
    assert_eq!(tui, TuiOutcome::Installed(cli_sha));
    assert_eq!(peer.read(".local/bin/cmux-tui"), "november cli");
    assert!(!files.asked().iter().any(|u| u.ends_with(".sha256")), "{:?}", files.asked());
    peer.assert_untouched(&installed, OLD);
}

/// A cmux-tui download that fails or does not match changes nothing and never fails acpmux's
/// update: the row stays `updated`, the cmux-tui step says why.
#[tokio::test]
async fn a_cmux_tui_that_cannot_be_fetched_or_does_not_match_keeps_the_old_one() {
    let peer = FakePeer::new("self-tui-bad");
    peer.exe(".local/bin/cmux-tui", "october cli");
    let new = fake_acpmux(NEW, Some(NEW));
    let mut files = with_tui(serving(&new), "november cli");
    files.bodies.insert(tui_url(), b"tampered cli".to_vec());
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    let tui = refresh_tui(&paths(&peer), &files, &plan, &up).await;
    assert!(matches!(&tui, TuiOutcome::Failed(why) if why.contains("has sha256")), "{tui:?}");
    assert_eq!(tui.json()["outcome"], "failed");
    assert!(tui.line().unwrap().starts_with("cmux-tui: not updated"));
    assert_eq!(peer.read(".local/bin/cmux-tui"), "october cli");
    assert!(!peer.exists(".local/bin/.cmux-tui.new"));
    assert_eq!(peer.read(".local/bin/acpmux"), new, "acpmux's update stands");

    // No cmux-tui in the tree (404): the same.
    let mut files = serving(&new);
    files.bodies.remove(&tui_url());
    let tui = refresh_tui(&paths(&peer), &files, &plan, &up).await;
    assert!(matches!(&tui, TuiOutcome::Failed(why) if why.contains("404")), "{tui:?}");
    assert_eq!(peer.read(".local/bin/cmux-tui"), "october cli");
}

/// None is installed where none was (nothing launches it there), a symlink is a dev build and is
/// kept, and an acpmux step that did not leave the channel's build running leaves cmux-tui alone.
#[tokio::test]
async fn a_cmux_tui_is_only_replaced_where_one_was_and_acpmux_moved_to_the_channel() {
    let peer = FakePeer::new("self-tui-absent");
    let new = fake_acpmux(NEW, Some(NEW));
    let files = with_tui(serving(&new), "november cli");
    let plan = ready(&peer, &files).await;
    let mut up = apply(&peer, &plan, TARGET, true);
    assert_eq!(refresh_tui(&paths(&peer), &files, &plan, &up).await, TuiOutcome::Absent);
    assert!(!peer.exists(".local/bin/cmux-tui"));
    assert!(!files.asked().iter().any(|u| u.contains("/cmux-tui-x")), "{:?}", files.asked());

    #[cfg(unix)]
    {
        peer.exe("dev/cmux-tui", "dev cli");
        std::os::unix::fs::symlink(
            peer.home.join("dev/cmux-tui"),
            peer.home.join(".local/bin/cmux-tui"),
        )
        .unwrap();
        assert_eq!(refresh_tui(&paths(&peer), &files, &plan, &up).await, TuiOutcome::Symlink);
        assert_eq!(peer.read(".local/bin/cmux-tui"), "dev cli");
        std::fs::remove_file(peer.home.join(".local/bin/cmux-tui")).unwrap();
    }

    peer.exe(".local/bin/cmux-tui", "october cli");
    for (outcome, reason) in [
        (Outcome::RolledBack, None),
        (Outcome::Failed, None),
        (Outcome::Busy, Some("restartWindow")),
        (Outcome::Current, Some("newerInstalled")),
    ] {
        up.outcome = outcome;
        up.reason = reason.map(str::to_owned);
        let tui = refresh_tui(&paths(&peer), &files, &plan, &up).await;
        assert!(matches!(&tui, TuiOutcome::Skipped(_)), "{outcome:?}: {tui:?}");
        assert_eq!(peer.read(".local/bin/cmux-tui"), "october cli");
    }
}

const CONTROLLER: &str = "http://100.64.0.1:18765";
const MARKER_COMMIT: &str = "fedcba9876543210fedcba9876543210fedcba98";

fn marker_url() -> String {
    format!("{CONTROLLER}/v1/channels/{CHANNEL}")
}

fn artifact_url(sha: &str) -> String {
    format!("{CONTROLLER}/v1/artifacts/sha256:{sha}/url")
}

fn presigned(sha: &str) -> String {
    format!("https://r2.example/artifacts/{sha}?X-Amz-Signature=x")
}

/// The build controller's marker (schema ci-channel/v1) naming `sha` for
/// `target`, in `mode`.
fn marker_json(mode: &str, target: &str, sha: &str) -> Vec<u8> {
    json!({
        "schema": "ci-channel/v1",
        "channel": CHANNEL,
        "commit": MARKER_COMMIT,
        "binaries": {"acpmux": {target: format!("sha256:{sha}")}},
        "step_id": 7,
        "step_key": "acpmux-musl",
        "worker": "w1",
        "run_s": 312,
        "at": "2026-11-23T14:00:00Z",
        "mode": mode,
        "key_id": null,
        "sig": null,
        "unsigned": true,
    })
    .to_string()
    .into_bytes()
}

/// `files` with the controller's marker for `binary` in `mode`, its artifact
/// lookup and the presigned download.
fn with_marker(mut files: Files, mode: &str, binary: &str) -> Files {
    let sha = sha_of(binary);
    files.bodies.insert(marker_url(), marker_json(mode, TARGET, &sha));
    let answer = json!({"url": presigned(&sha), "sha256": format!("sha256:{sha}")});
    files.bodies.insert(artifact_url(&sha), answer.to_string().into_bytes());
    files.bodies.insert(presigned(&sha), binary.as_bytes().to_vec());
    files
}

/// [`prepare`] asking the controller first, once the lock is free.
async fn from_controller(peer: &FakePeer, files: &Files) -> anyhow::Result<Prepared> {
    let ctl = Controller { url: CONTROLLER.to_owned(), fetch: files };
    for _ in 0..100 {
        match prepare(&paths(peer), files, Some(&ctl), CHANNEL).await? {
            Prepared::Locked => std::thread::sleep(std::time::Duration::from_millis(20)),
            other => return Ok(other),
        }
    }
    Ok(Prepared::Locked)
}

async fn ready_from_controller(peer: &FakePeer, files: &Files) -> Plan {
    match from_controller(peer, files).await.unwrap() {
        Prepared::Ready(plan) => plan,
        _ => panic!("the self-update did not go ahead"),
    }
}

#[tokio::test]
async fn a_marker_that_is_on_decides_acpmuxs_build_over_the_r2_channel() {
    let peer = FakePeer::new("self-marker-on");
    let r2s = fake_acpmux(STALE, Some(STALE));
    let new = fake_acpmux(NEW, Some(NEW));
    let files = with_marker(serving(&r2s), "on", &new);
    let plan = ready_from_controller(&peer, &files).await;
    assert_eq!(plan.picked.source, Source::Controller);
    assert_eq!(plan.picked.source.name(), "controller");
    assert_eq!(plan.picked.marker_skipped, None);
    assert_eq!(
        (plan.commit.as_str(), plan.sha256.as_str()),
        (MARKER_COMMIT, sha_of(&new).as_str())
    );
    let asked = files.asked();
    assert_eq!(asked[0], channel_url(CHANNEL).unwrap(), "the R2 channel is still read first");
    assert!(asked.contains(&artifact_url(&sha_of(&new))), "{asked:?}");
    assert!(asked.contains(&presigned(&sha_of(&new))), "{asked:?}");
    assert!(!asked.contains(&binary_url()), "the R2 binary is not downloaded: {asked:?}");
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), new);
    drop(plan);

    // The next run finds the marker's build installed: nothing is downloaded.
    let files = with_marker(serving(&r2s), "on", &new);
    let plan = ready_from_controller(&peer, &files).await;
    assert!(matches!(&plan.step, Step::Current(Some(build)) if build == NEW));
    assert!(!files.asked().iter().any(|u| u.contains("/v1/artifacts/")));
}

#[tokio::test]
async fn an_r2_that_cannot_be_read_does_not_stop_the_controllers_marker() {
    let peer = FakePeer::new("self-marker-r2-down");
    let new = fake_acpmux(NEW, Some(NEW));
    // No R2 channel file: R2 answers 404, the controller serves the marker.
    let files = with_marker(Files::default(), "on", &new);
    let plan = ready_from_controller(&peer, &files).await;
    assert_eq!(plan.picked.source, Source::Controller);
    assert_eq!(plan.sha256, sha_of(&new));
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    drop(plan);

    // With the marker off too, the update fails and names both reasons.
    let files = with_marker(Files::default(), "off", &new);
    let err = match from_controller(&peer, &files).await {
        Err(e) => format!("{e:#}"),
        Ok(_) => panic!("an update with neither source went ahead"),
    };
    assert!(err.contains("channel") && err.contains("controller's marker"), "{err}");
}

#[tokio::test]
async fn a_marker_that_is_not_on_or_cannot_be_used_leaves_the_r2_channel_deciding() {
    let new = fake_acpmux(NEW, Some(NEW));
    let theirs = fake_acpmux(STALE, Some(STALE));
    let reported = with_marker(serving(&new), "report", &theirs);
    let mut absent = serving(&new);
    absent.bodies.remove(&marker_url());
    let mut unreadable = serving(&new);
    unreadable.bodies.insert(marker_url(), b"<html>bad gateway</html>".to_vec());
    let mut no_target = serving(&new);
    let sha = sha_of(&theirs);
    let other = marker_json("on", "riscv64gc-unknown-linux-musl", &sha);
    no_target.bodies.insert(marker_url(), other);
    let mut no_artifact = with_marker(serving(&new), "on", &theirs);
    no_artifact.bodies.remove(&artifact_url(&sha));
    let no_build = format!("no acpmux build for {TARGET}");
    let cases = [
        ("report", reported, "\"report\""),
        ("absent", absent, "404"),
        ("unreadable", unreadable, "not a marker"),
        ("no-target", no_target, no_build.as_str()),
        ("no-artifact", no_artifact, "asking the controller for the binary"),
    ];
    for (name, files, why) in cases {
        let peer = FakePeer::new(&format!("self-marker-{name}"));
        let plan = ready_from_controller(&peer, &files).await;
        assert_eq!(plan.picked.source, Source::R2, "{name}");
        let skipped = plan.picked.marker_skipped.clone().unwrap_or_default();
        assert!(skipped.contains(why), "{name}: {skipped}");
        assert_eq!((plan.commit.as_str(), plan.sha256.as_str()), (COMMIT, sha_of(&new).as_str()));
        let up = apply(&peer, &plan, TARGET, true);
        assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{name}");
        assert!(!files.asked().contains(&presigned(&sha)), "{name}: the marker's is not fetched");
    }

    // No controller configured: R2, saying so.
    let peer = FakePeer::new("self-marker-none");
    let plan = ready(&peer, &serving(&new)).await;
    assert_eq!(plan.picked.source, Source::R2);
    let skipped = plan.picked.marker_skipped.clone().unwrap_or_default();
    assert!(skipped.contains("no build controller"), "{skipped}");
}

#[tokio::test]
async fn a_marker_download_that_does_not_match_is_never_installed() {
    let peer = FakePeer::new("self-marker-bad-sha");
    let new = fake_acpmux(NEW, Some(NEW));
    let mut files = with_marker(serving(&fake_acpmux(STALE, Some(STALE))), "on", &new);
    files.bodies.insert(presigned(&sha_of(&new)), b"#!/bin/sh\necho tampered\n".to_vec());
    let why = match from_controller(&peer, &files).await {
        Err(e) => format!("{e:#}"),
        Ok(_) => panic!("the self-update went ahead"),
    };
    assert!(why.contains("sha256") && why.contains("not installed"), "{why}");
    assert!(why.contains("controller's marker"), "{why}");
    assert!(!peer.exists(&format!(".acpmux/update/{}", sha_of(&new))), "nothing is kept");
    assert!(!files.asked().contains(&binary_url()), "a mismatch does not fall back to R2");
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
}

/// The controller's build of a commit has another sha256 than R2's build of
/// it (another profile). Once the marker installed it, a run the controller
/// is down (R2 decides) keeps it instead of swapping in R2's build of the same
/// commit, whether the channel's commit or the one R2's binary carries says
/// so; a build of unknown commit, or `--allow-downgrade`, takes R2's.
#[tokio::test]
#[cfg(unix)]
async fn an_r2_fallback_keeps_the_controllers_build_of_the_same_commit() {
    // The channel's commit (COMMIT) is in the build id; then one that only
    // R2's binary carries (an older commit of the same tree).
    for (name, build) in [("channel", "89abcdef0 2026-10-22"), ("tree", "13579bdf1 2026-10-19")] {
        let peer = FakePeer::new(&format!("self-same-commit-{name}"));
        let r2s = fake_acpmux(build, Some(build));
        let controllers = format!("{r2s}# the controller's profile\n");
        peer.exe(".local/bin/acpmux", &controllers);
        peer.write("daemon", build);
        let files = serving(&r2s);
        let plan = ready(&peer, &files).await;
        assert_eq!(plan.picked.source, Source::R2, "{name}");
        let why = plan.picked.kept_installed.clone().unwrap_or_default();
        assert!(why.contains("so it is kept"), "{name}: {why}");
        assert!(matches!(&plan.step, Step::Current(Some(b)) if b == build), "{name}");
        assert_eq!(plan.sha256, sha_of(&controllers), "{name}");
        let downloaded = files.asked().contains(&binary_url());
        assert_eq!(downloaded, name == "tree", "{name}: R2's binary is read only to compare");
        let up = apply(&peer, &plan, TARGET, true);
        assert_eq!(up.outcome, Outcome::Current, "{name}: {up:?}");
        assert_eq!(peer.read(".local/bin/acpmux"), controllers, "{name}");
        let calls = peer.take_calls();
        assert!(!calls.iter().any(|c| c.contains("restart acpmux.service")), "{name}: {calls:?}");
        drop(plan);
        // The next run keeps it too, with nothing downloaded again.
        let files = serving(&r2s);
        let plan = ready(&peer, &files).await;
        assert!(plan.picked.kept_installed.is_some(), "{name}");
        assert!(files.asked().len() <= 2, "{name}: {:?}", files.asked());
    }

    // An installed build whose commit is unknown takes R2's.
    let peer = FakePeer::new("self-same-commit-unknown");
    let build = "89abcdef0 2026-10-22";
    peer.exe(".local/bin/acpmux", "#!/bin/sh\necho no build id here\n");
    let r2s = fake_acpmux(build, Some(build));
    let plan = ready(&peer, &serving(&r2s)).await;
    assert_eq!(plan.picked.kept_installed, None);
    assert!(matches!(&plan.step, Step::Install(_)));
    drop(plan);

    // `--allow-downgrade` takes R2's build of the same commit.
    let peer = FakePeer::new("self-same-commit-downgrade");
    let controllers = format!("{r2s}# the controller's profile\n");
    peer.exe(".local/bin/acpmux", &controllers);
    peer.write("daemon", build);
    let mut back = paths(&peer);
    back.allow_downgrade = true;
    let Prepared::Ready(plan) = prepare(&back, &serving(&r2s), None, CHANNEL).await.unwrap() else {
        panic!("the self-update did not go ahead");
    };
    assert_eq!(plan.picked.kept_installed, None);
    assert!(matches!(&plan.step, Step::Install(_)));
}

/// Lane hosts, 2026-11-23: several held b45cad3d8 (a lane branch's build, newer
/// than the channel's head 7d439038 and containing the fix the channel lacked)
/// while the timer kept trying to put the older channel build back, each try a
/// daemon restart that some hosts did not survive (`rolledBack`) and others did
/// (a downgrade). Newer wins: the timer leaves a build of a newer commit alone
/// and restarts nothing; `--allow-downgrade` still pulls it back.
#[tokio::test]
#[cfg(unix)]
async fn a_host_on_a_newer_commit_than_the_channels_keeps_it_unless_told_to_go_back() {
    let peer = FakePeer::new("self-newer-wins");
    let installed = stamped_acpmux(OLD, Some(OLD), 1_794_748_257);
    peer.exe(".local/bin/acpmux", &installed);
    let channels = stamped_acpmux(NEW, Some(NEW), 1_794_744_982);
    let files = serving(&channels);
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Current, Some("newerInstalled")),
        "{up:?}"
    );
    assert!(!up.outcome.failed(), "the timer's unit does not fail for it");
    assert_eq!(peer.read(".local/bin/acpmux"), installed);
    assert!(!peer.exists(".local/bin/acpmux.prev"));
    assert_eq!(peer.daemon(), OLD);
    let calls = peer.take_calls();
    assert!(!calls.iter().any(|c| c.contains("restart acpmux.service")), "{calls:?}");
    assert!(!peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&channels))));
    drop(plan);

    // The next run finds the same: still nothing installed or restarted.
    let plan = ready(&peer, &serving(&channels)).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(up.reason.as_deref(), Some("newerInstalled"), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), installed);
    drop(plan);

    // `--allow-downgrade`: a bad channel build is pulled back on purpose.
    let mut back = paths(&peer);
    back.allow_downgrade = true;
    let Prepared::Ready(plan) = prepared_with(&back, &serving(&channels)).await else {
        panic!("the self-update did not go ahead");
    };
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), channels);
    assert_eq!(peer.read(".local/bin/acpmux.prev"), installed);
}

#[tokio::test]
async fn a_build_whose_daemon_does_not_come_back_is_rolled_back_and_not_tried_again() {
    let peer = FakePeer::new("self-rollback");
    let bad = fake_acpmux(NEW, Some("fedcba987 2026-10-21"));
    let files = serving(&bad);
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
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
    assert!(!up.error.as_deref().unwrap_or("").contains("marking"), "{up:?}");
    drop(plan);
    let _ = peer.take_calls();

    // The next run leaves that build alone: no download, no restart.
    let files = serving(&bad);
    let again = prepared(&peer, &files).await;
    assert!(matches!(&again, Prepared::RolledBackBefore(commit, _, _) if commit == COMMIT));
    assert!(peer.take_calls().is_empty(), "the daemon is not restarted again");
    assert_eq!(files.asked().len(), 1);

    // A newer build is tried, and the rejected download goes; its
    // rejection stays.
    let newer = "b2c3d4e5f 2026-10-22";
    let files = serving(&fake_acpmux(newer, Some(newer)));
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(newer)), "{up:?}");
    assert!(!peer.exists(&format!(".acpmux/update/{}/acpmux-{TARGET}", sha_of(&bad))));
    assert!(peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&bad))));
    drop(plan);
    let _ = peer.take_calls();

    // Review of #24232: pruning took the rejection with the download, so a
    // channel that moved back to the bad build installed it again.
    let files = serving(&bad);
    let again = prepared(&peer, &files).await;
    assert!(matches!(&again, Prepared::RolledBackBefore(commit, _, _) if commit == COMMIT));
    assert!(peer.take_calls().is_empty(), "the healthy daemon is not restarted");
    assert_eq!(files.asked().len(), 1, "the bad build is not downloaded again");
    assert_eq!(peer.daemon(), newer);
}

/// Review of #24232: a rollback whose mark could not be written was reported
/// as a plain rollback, so the next run retried the bad build unannounced.
#[tokio::test]
async fn a_rollback_that_cannot_be_marked_says_the_build_will_be_tried_again() {
    let peer = FakePeer::new("self-rollback-unmarked");
    let bad = fake_acpmux(NEW, Some("fedcba987 2026-10-21"));
    let files = serving(&bad);
    let plan = ready(&peer, &files).await;
    // The mark's path is taken by a folder, so writing it fails.
    let mark = format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&bad));
    std::fs::create_dir_all(peer.home.join(&mark)).unwrap();
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(up.outcome, Outcome::RolledBack, "{up:?}");
    let why = up.error.as_deref().unwrap_or("");
    assert!(why.contains("marking the build rolled back failed"), "{why}");
    assert!(why.contains("the next run tries it again"), "{why}");
    assert_eq!(peer.daemon(), OLD, "the previous build answers again");
    drop(plan);
    // Re-review: the folder in the mark's place counted as a mark, so the
    // next run did not try the build again as the row said.
    let again = prepared(&peer, &serving(&bad)).await;
    assert!(matches!(&again, Prepared::Ready(_)), "the next run tries it again");
}

/// A fleet Linux host, 2026-11-23 10:53Z: the old daemon saw its binary
/// replaced and handed over itself (`systemctl --user restart --no-block
/// acpmux.service`), so the update found the unit not active, shut the
/// daemon down, and then read the unit's new daemon, on the new build, as
/// the old one that "did not shut down". The good build was rolled back and
/// marked, and every later run skipped it. The unit's own daemon is the
/// takeover done: the update succeeds.
#[tokio::test]
async fn a_daemon_the_unit_already_restarted_on_the_new_build_is_not_read_as_the_old_one() {
    let peer = FakePeer::new("self-unit-takes-over");
    let new = fake_acpmux(NEW, Some(NEW));
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    // The unit is mid-restart (deactivating, not active) when the update's
    // restart reads it, and its new daemon (pid 5252) comes up as the old
    // one stops.
    std::fs::remove_file(peer.home.join("active-acpmux.service")).unwrap();
    peer.write("unit-takes-over", "");
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    assert_eq!(peer.daemon(), NEW);
    assert!(peer.exists("agents"), "the agents are kept");
    assert!(!peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&new))));
}

/// A daemon that really does not stop is still refused (exit 4), and the
/// update rolls back; but a restart that failed before the build was
/// checked says nothing against the build, so it is not marked: the next
/// run tries it again instead of waiting for a newer one for good.
#[tokio::test]
async fn a_restart_that_failed_before_the_build_was_checked_is_tried_again() {
    let peer = FakePeer::new("self-restart-failed");
    // The new build's shutdown leaves the old daemon (pid 4242, not the
    // unit's) running.
    let new = fake_acpmux(NEW, Some(NEW))
        .replace(r#""daemon shutdown"*) rm -f "$HOME/daemon";"#, r#""daemon shutdown"*) :;"#);
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    std::fs::remove_file(peer.home.join("active-acpmux.service")).unwrap();
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::RolledBack, Some("restartFailed")),
        "{up:?}"
    );
    assert!(up.error.as_deref().unwrap_or("").contains("did not shut down"), "{up:?}");
    assert!(!peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&new))));
    drop(plan);
    let again = prepared(&peer, &serving(&new)).await;
    assert!(matches!(&again, Prepared::Ready(_)), "the next run tries the build again");
}

#[tokio::test]
async fn one_self_update_runs_at_a_time_and_the_opt_out_stops_them() {
    let peer = FakePeer::new("self-lock");
    let files = serving(&fake_acpmux(OLD, Some(OLD)));
    let held = ready(&peer, &files).await;
    let second = prepare(&paths(&peer), &files, None, CHANNEL).await.unwrap();
    assert!(matches!(second, Prepared::Locked));
    drop(held);
    drop(ready(&peer, &files).await);

    peer.write(&format!(".acpmux/{NO_AUTO_UPDATE}"), "");
    let asked = files.asked().len();
    assert!(matches!(prepare(&paths(&peer), &files, None, CHANNEL).await.unwrap(), Prepared::Off));
    assert_eq!(files.asked().len(), asked, "nothing is read");
}

#[tokio::test]
async fn a_cloud_vm_is_refused_before_anything_is_read() {
    // cmux Cloud's own shape: no acpmux.service, or one someone else wrote.
    for theirs in [None, Some("# theirs\n")] {
        let peer = FakePeer::new("self-cloud-vm");
        peer.write("etc/cmux/vm-kind", "cloud\n");
        let unit = peer.home.join(format!("{UNITS}/acpmux.service"));
        match theirs {
            None => std::fs::remove_file(&unit).unwrap(),
            Some(edit) => std::fs::write(&unit, format!("{SYSTEMD_UNIT}{edit}")).unwrap(),
        }
        let files = serving(&fake_acpmux(NEW, Some(NEW)));
        let why = refused(&peer, &files).await;
        assert!(why.contains("--to-bundled"), "{why}");
        assert!(files.asked().is_empty());
        peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
    }
}

/// A cmux Cloud VM set up as a fleet lane host (2026-10-30) runs
/// acpmux's own `acpmux.service`; its timer refused every run and the host
/// stayed on its first build. That daemon is nobody else's, so it updates.
#[tokio::test]
async fn a_cloud_vm_running_acpmux_service_updates_itself() {
    let peer = FakePeer::new("self-cloud-vm-own-unit");
    peer.write("etc/cmux/vm-kind", "team\n");
    let new = fake_acpmux(NEW, Some(NEW));
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), new);
    assert_eq!(peer.daemon(), NEW);
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
        keep_newer: false,
        allow_downgrade: false,
        caller: None,
        now: true,
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
    assert!(matches!(
        prepare(&paths(&peer), &files, None, CHANNEL).await.unwrap(),
        Prepared::Locked
    ));
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
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), new);
    assert!(!peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&new))));

    // The same holds for a check of the previous build, after a rollback.
    drop(plan);
    let newer = "b2c3d4e5f 2026-10-22";
    let bad = listening_at(&socket, &fake_acpmux(newer, Some("fedcba987 2026-10-21")));
    let files = serving(&bad);
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, true);
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
    let up = apply(&peer, &plan, TARGET, true);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Failed, Some("lockLost")), "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
    assert!(!peer.exists(".local/bin/acpmux.prev"));
    assert!(!peer.exists(&format!(".acpmux/update/{}/{ROLLED_BACK}", sha_of(&new))));
    drop(plan);
    assert_eq!(peer.read(".acpmux/update.owner"), theirs, "the other update's lease stays");
}

/// Seconds since 1970 on this machine, the fake host's clock.
fn clock() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

/// The fake host's restart stamp says an update restarted its daemon
/// `ago` seconds ago (negative: in the future, a clock that went back).
fn restarted_ago(peer: &FakePeer, ago: i64) {
    let at = clock() as i64 - ago;
    peer.write(".acpmux/update.restarted", &format!("{at}\n"));
}

/// [`update_locked`], as `host update` from another machine runs it, pushing
/// `build`, with `--now` when `now`.
fn host_update(peer: &FakePeer, build: &str, now: bool) -> PeerUpdate {
    peer.offer(build, Some(build));
    let opts = UpdateOptions {
        binary_dir: Some(peer.home.join("binaries")),
        if_idle: false,
        keep_newer: false,
        allow_downgrade: false,
        caller: None,
        now,
    };
    once_free(|| {
        let up = update_locked(peer, &opts);
        (up.reason.as_deref() != Some("updateRunning")).then_some(up)
    })
    .expect("the lock is free")
}

/// A 2 vCPU fleet host, 2026-11-15: its acpmux-update.timer restarted the
/// daemon for each new build, and a `host update` from another machine 1-3
/// minutes later restarted it again: 13 restarts in 160 minutes, each waking
/// every harness at once. Whichever comes first restarts it; the other, within
/// the hour, changes nothing, both ways round.
#[tokio::test]
async fn a_self_update_and_a_host_update_restart_a_daemon_once_an_hour() {
    let peer = FakePeer::new("self-window");
    // With the idle restart off, the guarantee is as it was: one an hour.
    peer.write(".acpmux/update.idle-restart", "0\n");
    let new = fake_acpmux(NEW, Some(NEW));
    let files = serving(&new);
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, false);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    drop(plan);
    let stamped: u64 = peer.read(".acpmux/update.restarted").trim().parse().unwrap_or(0);

    // Five minutes later another machine's `host update` pushes a newer
    // build: the daemon is left alone and nothing is installed.
    restarted_ago(&peer, 5 * 60);
    peer.take_calls();
    let newer = "b2c3d4e5f 2026-10-22";
    let up = host_update(&peer, newer, false);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Busy, Some("restartWindow")),
        "{up:?}"
    );
    assert!(!up.outcome.failed(), "the app retries a busy host quietly");
    assert_eq!(up.build.as_deref(), Some(NEW));
    let line = up.line();
    assert!(line.contains("last update restart 5 min ago; next after "), "{line}");
    peer.assert_only_read(&new, NEW);
    assert!((clock() - 60..=clock()).contains(&stamped), "the self-update stamped its restart");

    // An hour after, the host update restarts it; then the timer, five
    // minutes later with an even newer build, leaves it alone.
    restarted_ago(&peer, 61 * 60);
    let up = host_update(&peer, newer, false);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(newer)), "{up:?}");
    restarted_ago(&peer, 5 * 60);
    peer.take_calls();
    let installed = peer.read(".local/bin/acpmux");
    let newest = "c3d4e5f6a 2026-10-23";
    let files = serving(&fake_acpmux(newest, Some(newest)));
    let plan = ready(&peer, &files).await;
    let up = apply(&peer, &plan, TARGET, false);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Busy, Some("restartWindow")),
        "{up:?}"
    );
    peer.assert_only_read(&installed, newer);
    drop(plan);

    // The idle restart on (the default): the bound moves to one an hour
    // amortized, at most two in any rolling hour. After a restart, one idle
    // early restart may happen; a third update in the same window is held.
    std::fs::remove_file(peer.home.join(".acpmux/update.idle-restart")).unwrap();
    peer.write("sessions.json", IDLE);
    restarted_ago(&peer, 5 * 60);
    let up = windowed_apply(&peer, newest).await;
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(newest)), "{up:?}");
    let third = "d4e5f6a7b 2026-10-24";
    let installed = peer.read(".local/bin/acpmux");
    peer.take_calls();
    let up = windowed_apply(&peer, third).await;
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Busy, Some("restartWindow")),
        "{up:?}"
    );
    peer.assert_only_read(&installed, newest);
}

/// A self-update of a peer the window holds, pushing `build`, idle or not as
/// the fake host's `sessions.json` says.
async fn windowed_apply(peer: &FakePeer, build: &str) -> PeerUpdate {
    let files = serving(&fake_acpmux(build, Some(build)));
    let plan = ready(peer, &files).await;
    apply(peer, &plan, TARGET, false)
}

const IDLE: &str = r#"{"sessions": []}"#;
const MID_TURN: &str =
    r#"{"sessions": [{"name": "w", "status": "running", "turn": {"startedAt": 1}}]}"#;

/// While the window holds and no session is mid-turn, the update goes in at
/// once, one restart; and a second channel move inside the same window waits
/// (at most one idle restart per window), so restarts per host per hour stay
/// at the window's bound plus this one.
#[tokio::test]
#[cfg(unix)]
async fn a_window_that_holds_an_idle_daemon_restarts_it_once() {
    let peer = FakePeer::new("idle-early");
    peer.write("sessions.json", IDLE);
    restarted_ago(&peer, 5 * 60);
    let up = windowed_apply(&peer, NEW).await;
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
    let early: u64 = peer.read(".acpmux/update.idle-restarted").trim().parse().unwrap();
    assert!((clock() - 60..=clock()).contains(&early), "the early restart is timed");

    // A newer build ten minutes on, idle: the early restart made one
    // stamp, but the guard counts from the early restart itself, so no
    // cascade; coalesced into the window's forced restart.
    restarted_ago(&peer, 10 * 60);
    peer.write(".acpmux/update.idle-restarted", &format!("{}\n", clock() - 10 * 60));
    let newer = "b2c3d4e5f 2026-10-22";
    let installed = peer.read(".local/bin/acpmux");
    let up = windowed_apply(&peer, newer).await;
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Busy, Some("restartWindow")),
        "{up:?}"
    );
    assert_eq!(peer.read(".local/bin/acpmux"), installed, "nothing installed");

    // The window's forced restart still comes, as today, newest build.
    restarted_ago(&peer, 61 * 60);
    let up = windowed_apply(&peer, newer).await;
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(newer)), "{up:?}");
}

/// A session mid-turn keeps the window as it is: nothing installed, busy;
/// the first run after the window forces the restart as before.
#[tokio::test]
#[cfg(unix)]
async fn a_window_that_holds_a_busy_daemon_changes_nothing_until_it_ends() {
    let peer = FakePeer::new("idle-early-busy");
    peer.write("sessions.json", MID_TURN);
    restarted_ago(&peer, 5 * 60);
    let installed = peer.read(".local/bin/acpmux");
    let up = windowed_apply(&peer, NEW).await;
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Busy, Some("restartWindow")),
        "{up:?}"
    );
    assert_eq!(peer.read(".local/bin/acpmux"), installed, "nothing installed");
    assert!(peer.read(".acpmux/update.idle-restarted").is_empty(), "no early restart was made");

    // Idle a run later: it restarts then.
    peer.write("sessions.json", IDLE);
    let up = windowed_apply(&peer, NEW).await;
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");

    // Busy for the whole window: the forced restart after it, as today.
    let peer = FakePeer::new("idle-early-forced");
    peer.write("sessions.json", MID_TURN);
    restarted_ago(&peer, 61 * 60);
    let up = windowed_apply(&peer, NEW).await;
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
}

/// `0` in `~/.acpmux/update.idle-restart` is today's behaviour.
#[tokio::test]
#[cfg(unix)]
async fn the_idle_restart_switch_turns_it_off() {
    let peer = FakePeer::new("idle-early-off");
    peer.write("sessions.json", IDLE);
    peer.write(".acpmux/update.idle-restart", "0\n");
    restarted_ago(&peer, 5 * 60);
    let installed = peer.read(".local/bin/acpmux");
    let up = windowed_apply(&peer, NEW).await;
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Busy, Some("restartWindow")),
        "{up:?}"
    );
    assert_eq!(peer.read(".local/bin/acpmux"), installed, "nothing installed");
}

/// A person's `--now` (no window) restarts it within the hour.
#[test]
#[cfg(unix)]
fn now_restarts_a_daemon_an_update_restarted_minutes_ago() {
    let peer = FakePeer::new("window-now");
    restarted_ago(&peer, 5 * 60);
    let up = host_update(&peer, NEW, true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
}

/// A daemon that does not run is started on the new build whatever the
/// window: nothing runs on it to wake, and a host left down is worse.
#[test]
#[cfg(unix)]
fn a_daemon_that_does_not_run_is_updated_within_the_window() {
    let peer = FakePeer::new("window-down");
    restarted_ago(&peer, 5 * 60);
    let _ = std::fs::remove_file(peer.home.join("daemon"));
    let up = host_update(&peer, NEW, false);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
}

/// A stamp from the future (the host's clock went back) does not hold the
/// host off updates for good.
#[test]
#[cfg(unix)]
fn a_restart_stamp_from_the_future_is_ignored() {
    let peer = FakePeer::new("window-future");
    restarted_ago(&peer, -(2 * 60 * 60));
    let up = host_update(&peer, NEW, false);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(NEW)), "{up:?}");
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
    let bin = home.join("fakebin");
    std::fs::create_dir_all(&bin).unwrap();
    let systemctl = bin.join("systemctl");
    crate::test_exec::write_executable(&systemctl, format!("#!/bin/sh\n{FAKE_MANAGER}\n"));
    // With `cat-cut` in the home, a write from stdin fails (a full /tmp).
    let cat = bin.join("cat");
    let fail =
        "if [ -e \"$HOME/cat-cut\" ] && [ $# -eq 0 ]; then head -c 20 > /dev/null; exit 1; fi";
    crate::test_exec::write_executable(&cat, format!("#!/bin/sh\n{fail}\nexec /bin/cat \"$@\"\n"));
    // With `cp-cut` in the home, a copy stops halfway (a full disk, a kill).
    let cp = bin.join("cp");
    let cut = "if [ -e \"$HOME/cp-cut\" ]; then head -c 20 \"$1\" > \"$2\"; exit 1; fi";
    crate::test_exec::write_executable(&cp, format!("#!/bin/sh\n{cut}\nexec /bin/cp \"$@\"\n"));
    let out = Command::new("sh")
        .args(["-c", &install_script()])
        .env("HOME", home)
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    let calls = std::fs::read_to_string(home.join("calls")).unwrap_or_default();
    let _ = std::fs::remove_file(home.join("calls"));
    (calls.lines().map(str::to_owned).collect(), String::from_utf8_lossy(&out.stdout).into_owned())
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

    // Re-review: a copy cut off halfway was left under the unit's name, and
    // every later run took it for someone else's unit.
    std::fs::remove_dir_all(&units).unwrap();
    std::fs::write(home.join("cp-cut"), "").unwrap();
    let (calls, _) = install_units(&home);
    assert!(calls.is_empty(), "{calls:?}");
    std::fs::remove_file(home.join("cp-cut")).unwrap();
    let (calls, err) = install_units(&home);
    assert_eq!(calls, ["systemctl --user daemon-reload", enable], "{err}");
    assert_eq!(read("acpmux-update.timer"), UPDATE_TIMER);

    // Re-review: a unit that could not be staged was installed empty.
    std::fs::remove_dir_all(&units).unwrap();
    std::fs::write(home.join("cat-cut"), "").unwrap();
    let (calls, _) = install_units(&home);
    assert!(calls.is_empty(), "{calls:?}");
    assert!(!units.exists(), "nothing is installed");
    std::fs::remove_file(home.join("cat-cut")).unwrap();
    let (calls, err) = install_units(&home);
    assert_eq!(calls, ["systemctl --user daemon-reload", enable], "{err}");

    // A timer someone else wrote is kept, its service is not written, and
    // nothing is started.
    let theirs = "[Timer]\nOnCalendar=daily\n";
    std::fs::write(units.join("acpmux-update.timer"), theirs).unwrap();
    std::fs::remove_file(units.join("acpmux-update.service")).unwrap();
    let (calls, err) = install_units(&home);
    assert!(calls.is_empty(), "{calls:?}");
    assert!(err.contains("acpmux-update.timer is a unit acpmux did not write"), "{err}");
    assert!(err.starts_with(AUTO_UPDATE_OFF), "the row's marker, on stdout: {err}");
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
    let (calls, off) = install_units(&home);
    assert_eq!(calls, ["systemctl --user disable --now acpmux-update.timer"]);
    assert!(!units.exists());
    assert!(off.is_empty(), "an opt-out is no reason to report: {off}");
    // Review: nor is one whose units could not be staged.
    std::fs::write(home.join("cat-cut"), "").unwrap();
    let (_, off) = install_units(&home);
    assert!(off.is_empty(), "{off}");
    std::fs::remove_file(home.join("cat-cut")).unwrap();

    // Review of #24232: the opt-out stops only acpmux's timer, never one
    // someone else wrote.
    std::fs::create_dir_all(&units).unwrap();
    std::fs::write(units.join("acpmux-update.timer"), theirs).unwrap();
    let (calls, _) = install_units(&home);
    assert!(calls.is_empty(), "{calls:?}");
    assert_eq!(read("acpmux-update.timer"), theirs);

    // Re-review: acpmux's timer is stopped even when the service beside it
    // is someone else's.
    std::fs::write(units.join("acpmux-update.timer"), UPDATE_TIMER).unwrap();
    std::fs::write(units.join("acpmux-update.service"), "[Service]\nExecStart=/bin/true\n")
        .unwrap();
    let (calls, _) = install_units(&home);
    assert_eq!(calls, ["systemctl --user disable --now acpmux-update.timer"]);
    let _ = std::fs::remove_dir_all(&home);
}

/// A host that does not update itself says why in `host update`'s row, not
/// only on a stderr nobody reads.
#[test]
fn an_update_row_says_when_the_host_does_not_update_itself() {
    let peer = FakePeer::new("update-auto-off");
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!((up.outcome, up.auto_update_off.as_deref()), (Outcome::Updated, None), "{up:?}");
    assert!(up.to_json("p", "fake").get("autoUpdateOff").is_none());

    let peer = FakePeer::new("update-auto-off-theirs");
    peer.write(&format!("{UNITS}/acpmux-update.timer"), "[Timer]\nOnCalendar=daily\n");
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    let why = up.auto_update_off.clone().unwrap_or_default();
    assert!(why.contains("acpmux-update.timer is a unit acpmux did not write"), "{up:?}");
    assert!(!why.starts_with(AUTO_UPDATE_OFF), "{why}");
    assert_eq!(up.to_json("p", "fake")["autoUpdateOff"], why.as_str());
    assert!(up.line().ends_with(&format!("; auto-update off: {why}")), "{}", up.line());
    assert!(!up.status.unwrap_or_default().contains(AUTO_UPDATE_OFF));
}

/// A [`FakePeer`] that takes a script's stdin, as `host setup` writes the
/// daemon config (`host update` feeds none, which the peer itself checks).
struct SetupPeer(FakePeer);

impl Remote for SetupPeer {
    fn host(&self) -> &str {
        self.0.host()
    }

    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        use std::io::Write as _;
        use std::process::Stdio;
        let Some(input) = stdin else { return self.0.exec(script, None) };
        let mut sh = self.0.sh(script);
        sh.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = sh.spawn()?;
        child.stdin.take().ok_or_else(|| anyhow::anyhow!("no stdin"))?.write_all(input)?;
        let out = child.wait_with_output()?;
        Ok(RemoteOut {
            ok: out.status.success(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })
    }

    fn spawn(&self, script: &str) -> Result<std::process::Child> {
        self.0.spawn(script)
    }

    fn push(&self, local: &Path, remote: &str) -> Result<()> {
        self.0.push(local, remote)
    }
}

/// The same for `host setup` (and `host enroll --fix`): the install answers
/// the reason beside the daemon's status.
#[test]
fn a_setup_says_when_the_host_does_not_update_itself() {
    let peer = SetupPeer(FakePeer::new("setup-auto-off"));
    let (_, off) = crate::cli::hosts::install_daemon(&peer, 47811, true).unwrap();
    assert_eq!(off, None);

    let peer = SetupPeer(FakePeer::new("setup-auto-off-theirs"));
    peer.0.write(&format!("{UNITS}/acpmux-update.service"), "[Service]\nExecStart=/bin/true\n");
    let (status, off) = crate::cli::hosts::install_daemon(&peer, 47811, true).unwrap();
    let why = off.unwrap_or_default();
    assert!(why.contains("acpmux-update.service is a unit acpmux did not write"), "{why}");
    assert!(!status.contains(AUTO_UPDATE_OFF), "{status}");
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
