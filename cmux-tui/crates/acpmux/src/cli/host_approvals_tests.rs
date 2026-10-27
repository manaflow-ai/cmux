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
    scripts: RefCell<Vec<String>>,
}

impl Fake {
    fn new(own: bool, remote: Option<Vec<Value>>) -> Self {
        let own = own.then(|| {
            json!({"id": "mac-1", "name": "Leo's Mac", "publicKey": KEY,
                   "fingerprint": crate::hub::approvers::fingerprint(&unhex(KEY))})
        });
        Self { own, remote: RefCell::new(remote), scripts: RefCell::new(Vec::new()) }
    }
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

impl Io for Fake {
    async fn rpc(&self, method: &str, _params: Value) -> Result<Value> {
        assert_eq!(method, "_acpmux/mac_approvers");
        Ok(json!({"macs": [], "thisMac": self.own}))
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
            return Ran {
                ok: true,
                stdout: json!({"macs": macs}).to_string(),
                stderr: String::new(),
            };
        }
        if script.contains("host approvals rm") {
            assert!(script.ends_with("host approvals rm mac-1"), "{script}");
            macs.retain(|m| m["id"] != "mac-1");
            return Ran { ok: true, stdout: "{}".into(), stderr: String::new() };
        }
        assert!(script.contains("host approvals add --id mac-1 --key 04"), "{script}");
        // The name reaches the remote shell quoted.
        assert!(script.contains("--name 'Leo'\\''s Mac'"), "{script}");
        let fingerprint = crate::hub::approvers::fingerprint(&unhex(KEY));
        macs.push(json!({"id": "mac-1", "name": "Leo's Mac", "fingerprint": fingerprint}));
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
    assert!(r.fix.as_deref().unwrap_or("").contains("acpmux host doctor hb --fix"), "{r:?}");
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
    assert_eq!(r.data.as_ref().unwrap()["try"], "acpmux host update hb");
}

#[test]
fn a_change_rewrites_the_file_whole_and_keeps_each_mac_once() {
    let dir = std::env::temp_dir().join(format!("hap-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let path = dir.join(mac_approvers::FILE);
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
    let _ = std::fs::remove_dir_all(&dir);
}
