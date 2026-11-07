//! The `approvals` step and `host approvals` file changes (cli/host_approvals.rs)
//! against a fake [`Io`]: the local daemon's own key, and the remote's
//! `host approvals` as a script that answers like it.

use super::*;
use crate::cli::host_peering::Ran;
use std::cell::RefCell;

/// A 65-byte uncompressed P-256 point (the generator), as hex.
const KEY: &str = "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";

struct Fake {
    /// This machine's app key (`thisMac`); None: no app gave one.
    own: Option<Value>,
    /// The remote's enrolled Macs; None: its acpmux has no `host approvals`.
    remote: RefCell<Option<Vec<Value>>>,
    /// This Mac's paired phones (`thisMacPhones`) and the device id they are under.
    phones: RefCell<Vec<Value>>,
    device: &'static str,
    /// The remote's `host approvals` listing answers this text instead (a broken listing).
    listing: RefCell<Option<&'static str>>,
    /// The app has not sent its device id: no `thisMacPhonePrefix`.
    no_device: std::cell::Cell<bool>,
    /// The local daemon predates phone enrollment: no `thisMacPhones` or prefix at all.
    old_daemon: std::cell::Cell<bool>,
    scripts: RefCell<Vec<String>>,
}

impl Fake {
    fn new(own: bool, remote: Option<Vec<Value>>) -> Self {
        let own = own.then(|| {
            json!({"id": "mac-1", "name": "Leo's Mac", "publicKey": KEY,
                   "fingerprint": crate::hub::approvers::fingerprint(&unhex(KEY))})
        });
        Self {
            own,
            remote: RefCell::new(remote),
            phones: RefCell::new(Vec::new()),
            device: "mac-device-1",
            listing: RefCell::new(None),
            no_device: std::cell::Cell::new(false),
            old_daemon: std::cell::Cell::new(false),
            scripts: RefCell::new(Vec::new()),
        }
    }

    /// Pairs a phone with `key` on this Mac (as `ApproverSet::peer_entries` lists it).
    fn pair(&self, phone: &str, key: &str) {
        let id = crate::hub::approvers::peer_phone_id(self.device, phone).unwrap();
        let mut phones = self.phones.borrow_mut();
        phones.retain(|p| p["id"] != id.as_str());
        phones.push(json!({"id": id, "name": phone, "publicKey": key,
                           "fingerprint": crate::hub::approvers::fingerprint(&unhex(key))}));
    }

    fn unpair(&self, phone: &str) {
        let id = crate::hub::approvers::peer_phone_id(self.device, phone).unwrap();
        self.phones.borrow_mut().retain(|p| p["id"] != id.as_str());
    }

    fn remote_ids(&self) -> Vec<String> {
        let remote = self.remote.borrow();
        remote.iter().flatten().map(|m| m["id"].as_str().unwrap().to_owned()).collect()
    }
}

/// The value after `flag` in a `host approvals add` script, its shell quotes taken off.
fn arg(script: &str, flag: &str) -> String {
    let rest = &script[script.find(flag).unwrap() + flag.len() + 1..];
    if let Some(quoted) = rest.strip_prefix('\'') {
        let mut out = String::new();
        let mut rest = quoted;
        loop {
            let end = rest.find('\'').unwrap();
            out.push_str(&rest[..end]);
            rest = &rest[end + 1..];
            match rest.strip_prefix("\\''") {
                Some(more) => {
                    out.push('\'');
                    rest = more;
                }
                None => break,
            }
        }
        out
    } else {
        rest.split(' ').next().unwrap().to_owned()
    }
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

impl Io for Fake {
    async fn rpc(&self, method: &str, _params: Value) -> Result<Value> {
        assert_eq!(method, "_acpmux/mac_approvers");
        if self.old_daemon.get() {
            return Ok(json!({"macs": [], "thisMac": self.own}));
        }
        Ok(json!({
            "macs": [], "thisMac": self.own, "thisMacPhones": *self.phones.borrow(),
            "thisMacPhonePrefix": (!self.no_device.get())
                .then(|| crate::hub::approvers::peer_phone_prefix(self.device)),
        }))
    }

    fn ssh(&self, argv: &[String]) -> Ran {
        let command = argv.last().map(String::as_str).unwrap_or("");
        let script = crate::cli::hosts::script_of(command).unwrap_or_else(|| command.to_owned());
        self.scripts.borrow_mut().push(script.clone());
        let mut remote = self.remote.borrow_mut();
        let Some(macs) = remote.as_mut() else {
            return Ran {
                ok: false,
                stdout: String::new(),
                stderr: "error: unrecognized subcommand 'approvals'".into(),
            };
        };
        if script.ends_with("host approvals") {
            if let Some(text) = *self.listing.borrow() {
                return Ran { ok: true, stdout: text.into(), stderr: String::new() };
            }
            return Ran {
                ok: true,
                stdout: json!({"macs": macs}).to_string(),
                stderr: String::new(),
            };
        }
        if let Some(at) = script.find("host approvals rm ") {
            let id = arg(&script[at..], "rm");
            assert!(macs.iter().any(|m| m["id"] == id.as_str()), "removed {id}, not there");
            macs.retain(|m| m["id"] != id.as_str());
            return Ran { ok: true, stdout: "{}".into(), stderr: String::new() };
        }
        assert!(script.contains("host approvals add --id "), "{script}");
        let (id, key, name) = (arg(&script, "--id"), arg(&script, "--key"), arg(&script, "--name"));
        if id == "mac-1" {
            // The name reaches the remote shell quoted.
            assert!(script.contains("--name 'Leo'\\''s Mac'"), "{script}");
        }
        let fingerprint = crate::hub::approvers::fingerprint(&unhex(&key));
        macs.retain(|m| m["id"] != id.as_str());
        // The peer's file holds at most MAX_APPROVERS (`host approvals add`'s `change`).
        if macs.len() >= crate::hub::approvers::MAX_APPROVERS {
            return Ran {
                ok: false,
                stdout: String::new(),
                stderr: "error: at most 16 Macs".into(),
            };
        }
        macs.push(json!({"id": id, "name": name, "fingerprint": fingerprint}));
        Ran { ok: true, stdout: "{}".into(), stderr: String::new() }
    }

    fn tailscale(&self) -> Result<crate::tailnet::Status> {
        Err(anyhow!("no tailnet"))
    }

    fn user(&self) -> Option<String> {
        None
    }
}

fn target() -> PeerTarget<'static> {
    PeerTarget { name: "hb", host: "huge-blue", port: 47811, local_name: "mac", local_dest: None }
}

fn block<T>(f: impl std::future::Future<Output = T>) -> T {
    tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(f)
}

fn run(fake: &Fake, fix: bool) -> StepResult {
    block(approvals_with(fake, &target(), fix))
}

#[test]
fn enroll_adds_this_macs_app_key_once_and_doctor_finds_it() {
    let fake = Fake::new(true, Some(Vec::new()));
    // Doctor without --fix: a warning that says how, and nothing written.
    let r = run(&fake, false);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.fix.as_deref().unwrap_or("").contains("acpmux machine doctor hb --fix"), "{r:?}");
    assert_eq!(fake.scripts.borrow().len(), 1);
    // Enroll: added there.
    let r = run(&fake, true);
    assert_eq!(r.state, StepState::Fixed, "{r:?}");
    assert!(r.detail.contains("this Mac (Leo's Mac) may now allow huge-blue's prompts"), "{r:?}");
    // Again: already there, nothing added.
    let before = fake.scripts.borrow().len();
    assert_eq!(run(&fake, true).state, StepState::Ok);
    assert_eq!(fake.scripts.borrow().len(), before + 1);
    // Unenroll: removed there; doctor then finds it missing.
    assert_eq!(block(unenroll_with(&fake, &target())).state, StepState::Fixed);
    assert_eq!(fake.remote.borrow().as_ref().unwrap().len(), 0);
    assert_eq!(run(&fake, false).state, StepState::Warn);
}

#[test]
fn no_app_key_skips_and_an_old_remote_warns_with_the_update() {
    let r = run(&Fake::new(false, Some(Vec::new())), true);
    assert_eq!(r.state, StepState::Skip, "{r:?}");
    assert!(r.fix.as_deref().unwrap_or("").contains("open cmux"), "{r:?}");
    let r = run(&Fake::new(true, None), true);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.detail.contains("too old"), "{r:?}");
    assert_eq!(r.data.as_ref().unwrap()["try"], "acpmux machine update hb");
}

#[test]
fn a_change_rewrites_the_file_whole_and_keeps_each_mac_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(mac_approvers::FILE);
    let entry = |id: &str| {
        crate::hub::approvers::parse_approvers(&[json!({"id": id, "publicKey": KEY, "name": id})])
            .unwrap()
    };
    change(&path, |m| {
        m.extend(entry("mac-1"));
        Ok(())
    })
    .unwrap();
    change(&path, |m| {
        m.retain(|x| x.id != "mac-1");
        m.extend(entry("mac-1"));
        m.extend(entry("mac-2"));
        Ok(())
    })
    .unwrap();
    let ids: Vec<String> = mac_approvers::read(&path).unwrap().into_iter().map(|m| m.id).collect();
    assert_eq!(ids, ["mac-1", "mac-2"]);
    change(&path, |m| {
        m.retain(|x| x.id != "mac-1");
        Ok(())
    })
    .unwrap();
    let ids: Vec<String> = mac_approvers::read(&path).unwrap().into_iter().map(|m| m.id).collect();
    assert_eq!(ids, ["mac-2"]);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

/// `rm` (and `add`) hold the file's lock until the daemon's reload returns, so
/// another change cannot land between the write and the reload and put back a
/// key `rm` took out.
#[test]
fn a_change_holds_its_lock_until_the_reload_returns() {
    use std::time::Duration;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(mac_approvers::FILE);
    let held = change(&path, |_| Ok(())).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let other = path.clone();
    std::thread::spawn(move || {
        let added = change(&other, |m| {
            m.extend(
                crate::hub::approvers::parse_approvers(&[json!({"id": "mac-2", "publicKey": KEY})])
                    .unwrap(),
            );
            Ok(())
        });
        let _ = tx.send(added.map(drop).map_err(|e| e.to_string()));
    });
    // Another change waits while the first one's reload has not returned.
    assert!(
        rx.recv_timeout(Duration::from_millis(300)).is_err(),
        "another change landed before the reload"
    );
    drop(held);
    assert_eq!(rx.recv_timeout(Duration::from_secs(10)), Ok(Ok(())));
    let ids: Vec<String> = mac_approvers::read(&path).unwrap().into_iter().map(|m| m.id).collect();
    assert_eq!(ids, ["mac-2"]);
}

struct FakeDaemon(bool);

impl Reload for FakeDaemon {
    async fn reload(&self) -> Result<Value> {
        if self.0 { Ok(json!({"macs": []})) } else { Err(anyhow!("method not found")) }
    }
}

/// A running daemon that does not reload fails the command (and so a remote
/// `enroll`/`unenroll`), instead of reporting success with `reloaded: false`.
#[test]
fn a_daemon_that_does_not_reload_fails_the_change() {
    assert!(block(reload_with(&FakeDaemon(true))).unwrap());
    let e = block(reload_with(&FakeDaemon(false))).unwrap_err().to_string();
    assert!(e.contains("did not reload") && e.contains("method not found"), "{e}");
}

/// A daemon that holds its lock but whose socket does not answer (or does not
/// finish `initialize`) still runs with the old file: the change fails. No
/// daemon at all: nothing to reload, it reads the file when it starts.
///
/// The lock nobody holds is checked before the test takes it, not after it
/// drops it: a child another test spawns in parallel holds a copy of this
/// process's open files between its fork and its exec, the lock's included,
/// so a dropped `flock` can stay held for that moment and read as a daemon.
#[test]
fn a_running_daemon_whose_socket_does_not_answer_fails_the_change() {
    let dir = tempfile::tempdir().unwrap();
    let lock = dir.path().join("daemon.lock");
    let refused = anyhow!("connection refused");
    let none: Result<&FakeDaemon, &anyhow::Error> = Err(&refused);
    assert!(!block(reload_on(none, &lock)).unwrap(), "no lock file: no daemon");
    let held = std::fs::File::create(&lock).unwrap();
    assert!(!block(reload_on(none, &lock)).unwrap(), "a lock nobody holds: no daemon");
    held.lock().unwrap();
    let e = block(reload_on(none, &lock)).unwrap_err().to_string();
    assert!(e.contains("did not answer") && e.contains("connection refused"), "{e}");
    assert!(block(reload_on(Ok(&FakeDaemon(true)), &lock)).unwrap());
    drop(held);
}

/// Another phone key: a different 65-byte point (only its shape is checked here).
const PHONE_KEY: &str = "04aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const NEW_PHONE_KEY: &str = "04bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

#[test]
fn enroll_brings_this_macs_paired_phones_and_keeps_them_current() {
    let fake = Fake::new(true, Some(Vec::new()));
    fake.pair("iphone-1", PHONE_KEY);
    let phone = crate::hub::approvers::peer_phone_id(fake.device, "iphone-1").unwrap();
    assert!(phone.starts_with("phone:") && phone.ends_with(":iphone-1"), "{phone}");
    let r = run(&fake, true);
    assert_eq!(r.state, StepState::Fixed, "{r:?}");
    assert!(r.detail.contains("and its paired phones"), "{r:?}");
    assert_eq!(fake.remote_ids(), ["mac-1", phone.as_str()]);
    assert_eq!(run(&fake, true).state, StepState::Ok);
    // A phone paired again with a new key: doctor warns, --fix replaces the key.
    fake.pair("iphone-1", NEW_PHONE_KEY);
    let r = run(&fake, false);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.detail.contains("paired phones"), "{r:?}");
    assert_eq!(run(&fake, true).state, StepState::Fixed);
    let fingerprint = crate::hub::approvers::fingerprint(&unhex(NEW_PHONE_KEY));
    assert!(
        fake.remote.borrow().iter().flatten().any(|m| m["fingerprint"] == fingerprint.as_str())
    );
    // Unpaired here: removed there.
    fake.unpair("iphone-1");
    assert_eq!(run(&fake, true).state, StepState::Fixed);
    assert_eq!(fake.remote_ids(), ["mac-1"]);
}

#[test]
fn enroll_leaves_another_macs_phones_and_unenroll_takes_only_this_macs() {
    let fake = Fake::new(true, Some(Vec::new()));
    let other = crate::hub::approvers::peer_phone_id("mac-device-2", "iphone-9").unwrap();
    fake.remote.borrow_mut().as_mut().unwrap().push(json!({"id": other, "name": "x",
        "fingerprint": crate::hub::approvers::fingerprint(&unhex(PHONE_KEY))}));
    fake.pair("iphone-1", PHONE_KEY);
    assert_eq!(run(&fake, true).state, StepState::Fixed);
    assert_eq!(fake.remote_ids().len(), 3);
    assert_eq!(block(unenroll_with(&fake, &target())).state, StepState::Fixed);
    assert_eq!(fake.remote_ids(), [other.as_str()]);
}

#[test]
fn unenroll_changes_nothing_when_the_peers_list_cannot_be_read() {
    let fake = Fake::new(true, Some(Vec::new()));
    fake.pair("iphone-1", PHONE_KEY);
    assert_eq!(run(&fake, true).state, StepState::Fixed);
    for broken in ["not json", "{}", r#"{"macs":"x"}"#] {
        *fake.listing.borrow_mut() = Some(broken);
        let before = fake.scripts.borrow().len();
        let r = block(unenroll_with(&fake, &target()));
        assert_eq!(r.state, StepState::Warn, "{broken}: {r:?}");
        assert!(r.detail.contains("nothing was unenrolled"), "{r:?}");
        // Only the listing ran: no rm, the Mac and its phone are still there.
        assert_eq!(fake.scripts.borrow().len(), before + 1);
        assert_eq!(fake.remote_ids().len(), 2);
    }
    *fake.listing.borrow_mut() = None;
    assert_eq!(block(unenroll_with(&fake, &target())).state, StepState::Fixed);
    assert!(fake.remote_ids().is_empty());
}

#[test]
fn unenroll_refuses_while_phones_are_there_and_the_app_gave_no_device_id() {
    let fake = Fake::new(true, Some(Vec::new()));
    fake.pair("iphone-1", PHONE_KEY);
    assert_eq!(run(&fake, true).state, StepState::Fixed);
    fake.no_device.set(true);
    let r = block(unenroll_with(&fake, &target()));
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert_eq!(fake.remote_ids().len(), 2);
    // With no phone there, the Mac's own key goes as before.
    fake.no_device.set(false);
    fake.unpair("iphone-1");
    assert_eq!(run(&fake, true).state, StepState::Fixed);
    fake.no_device.set(true);
    assert_eq!(block(unenroll_with(&fake, &target())).state, StepState::Fixed);
    assert!(fake.remote_ids().is_empty());
}

#[test]
fn fix_makes_room_on_a_full_peer_by_removing_unpaired_phones_first() {
    let fake = Fake::new(true, Some(Vec::new()));
    fake.pair("iphone-old", PHONE_KEY);
    assert_eq!(run(&fake, true).state, StepState::Fixed);
    // The peer is full: this Mac, its old phone and 14 other Macs.
    for n in 0..crate::hub::approvers::MAX_APPROVERS - 2 {
        fake.remote
            .borrow_mut()
            .as_mut()
            .unwrap()
            .push(json!({"id": format!("other-{n}"), "fingerprint": "x"}));
    }
    // The old phone unpaired, a new one paired: --fix converges in one run.
    fake.unpair("iphone-old");
    fake.pair("iphone-new", NEW_PHONE_KEY);
    let r = run(&fake, true);
    assert_eq!(r.state, StepState::Fixed, "{r:?}");
    let new = crate::hub::approvers::peer_phone_id(fake.device, "iphone-new").unwrap();
    let old = crate::hub::approvers::peer_phone_id(fake.device, "iphone-old").unwrap();
    let ids = fake.remote_ids();
    assert!(ids.contains(&new) && !ids.contains(&old), "{ids:?}");
    // The Mac's own key gone there too: the stale phone still goes before the Mac's key is added.
    fake.remote.borrow_mut().as_mut().unwrap().retain(|m| m["id"] != "mac-1");
    fake.remote.borrow_mut().as_mut().unwrap().push(json!({"id": "other-x", "fingerprint": "x"}));
    fake.unpair("iphone-new");
    assert_eq!(run(&fake, true).state, StepState::Fixed);
    assert!(fake.remote_ids().contains(&"mac-1".to_owned()));
}

#[test]
fn an_older_local_daemon_warns_that_its_phones_were_not_enrolled() {
    let fake = Fake::new(true, Some(Vec::new()));
    fake.old_daemon.set(true);
    // Enrolling the Mac still works, but says the phones were left out.
    let r = run(&fake, true);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.detail.contains("too old to enroll its paired phones"), "{r:?}");
    assert_eq!(fake.remote_ids(), ["mac-1"]);
    // Doctor again: the Mac is there, the phones are still unknown, never "Ok".
    let r = run(&fake, false);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.fix.as_deref().unwrap_or("").contains("Update acpmux"), "{r:?}");
}
