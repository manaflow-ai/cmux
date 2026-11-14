//! `acpmux host approvals`: the Macs whose cmux app may allow this
//! machine's prompts in a chat the Mac reaches through its own daemon
//! (peer-route approvals, `hub/mac_approvers.rs`), and the `approvals` step
//! of `host enroll` and `host doctor`, which enrolls this machine's app key on
//! the machine it adds.
//!
//! The Macs live in `ACPMUX_HOME/mac-approvers.json`; a change is one locked
//! read-modify-write (`mac-approvers.lock`) and one rename, then the running
//! daemon reloads it (`_acpmux/mac_approvers {reload: true}`), which returns
//! only after an answer being committed. The lock is held until that reload
//! returns, so no other change lands between the write and the reload: once
//! `rm` returns, the Mac's signatures count nothing. A running daemon that
//! does not reload fails the command. Only this command writes the file; no
//! RPC does.

use crate::cli::host_peering::{Io, PeerTarget, remote_cli};
use crate::cli::host_steps::{Step, StepResult, StepState};
use crate::cli::hosts::ssh_argv;
use crate::cli::output::print_json;
use crate::harness_health::channel::quote as shell_quote;
use crate::hub::approvers::Approver;
use crate::hub::mac_approvers;
use anyhow::{Context, Result, anyhow};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// `ACPMUX_HOME/mac-approvers.json`.
pub(crate) fn file() -> PathBuf {
    crate::config::home().join(mac_approvers::FILE)
}

/// `host approvals [add|rm]`.
pub(crate) async fn run(
    cmd: Option<crate::cli::command_host::ApprovalsCmd>,
    json_out: bool,
) -> Result<()> {
    use crate::cli::command_host::ApprovalsCmd;
    let path = file();
    let v = match cmd {
        None => {
            let mut v = json!({"macs": listed(&mac_approvers::read(&path)?), "file": path});
            // This machine's own app key, when its daemon runs and the app gave one.
            if let Ok(client) = crate::daemon::connect(false).await
                && let Ok(view) = client.request("_acpmux/mac_approvers", json!({})).await
            {
                v.set("thisMac", view["thisMac"].clone());
            }
            v
        }
        Some(ApprovalsCmd::Add { id, key, name }) => {
            let entry = json!({"id": id, "publicKey": key, "name": name.unwrap_or_default()});
            let added = crate::hub::approvers::parse_approvers(std::slice::from_ref(&entry))
                .map_err(|e| anyhow!("{}", e.message))?;
            let lock = change(&path, |macs| {
                macs.retain(|m| m.id != id);
                macs.extend(added);
                Ok(())
            })?;
            let reloaded = reload().await;
            drop(lock);
            json!({"added": id, "reloaded": reloaded?})
        }
        Some(ApprovalsCmd::Enroll { peer }) => return on_peer(&peer, true, json_out).await,
        Some(ApprovalsCmd::Unenroll { peer }) => return on_peer(&peer, false, json_out).await,
        Some(ApprovalsCmd::Rm { id }) => {
            let mut known = false;
            let lock = change(&path, |macs| {
                known = macs.iter().any(|m| m.id == id);
                macs.retain(|m| m.id != id);
                Ok(())
            })?;
            let reloaded = reload().await;
            drop(lock);
            json!({"removed": id, "enrolled": known, "reloaded": reloaded?})
        }
    };
    if json_out {
        print_json(&v);
    } else if let Some(macs) = v.get("macs").and_then(Value::as_array) {
        if macs.is_empty() {
            println!(
                "no Mac may allow this machine's prompts (`acpmux machine enroll` from the Mac adds one)"
            );
        }
        for m in macs {
            println!("{:<24} {:<18} {}", text(m, "id"), text(m, "fingerprint"), text(m, "name"));
        }
        if let Some(own) = v.get("thisMac").filter(|m| m.is_object()) {
            println!("this machine's app key: {} ({})", text(own, "id"), text(own, "fingerprint"));
        }
    } else if let Some(id) = v.get("added").and_then(Value::as_str) {
        println!("{id}: may allow this machine's prompts from its cmux app");
    } else if v["enrolled"] == true {
        println!("{}: removed; its Allows count no more", text(&v, "removed"));
    } else {
        println!("{}: was not enrolled", text(&v, "removed"));
    }
    Ok(())
}

/// `host approvals enroll|unenroll PEER`: this machine's app key added on (or
/// removed from) the machine of peer (or ssh host) `peer`.
async fn on_peer(peer: &str, enroll: bool, json_out: bool) -> Result<()> {
    let client = crate::daemon::connect(true).await?;
    let peers = client.request("_acpmux/peers", json!({})).await?;
    let list = peers.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
    let (name, host, port) = crate::cli::host_enroll::pick_target(&list, peer);
    let local_name = crate::cli::hosts::short_name(&crate::hand::pair::hostname());
    let t = PeerTarget {
        name: &name,
        host: &host,
        port: port.unwrap_or(crate::peer::SSH_PEER_PORT),
        local_name: &local_name,
        local_dest: None,
    };
    let io = crate::cli::host_peering::Live(Some(&*client));
    let r = if enroll { approvals_with(&io, &t, true).await } else { unenroll_with(&io, &t).await };
    if json_out {
        println!("{}", crate::cli::host_enroll::step_line(&r));
    } else {
        println!("{}", r.detail);
        if let Some(fix) = &r.fix {
            println!("{fix}");
        }
    }
    anyhow::ensure!(matches!(r.state, StepState::Ok | StepState::Fixed), "{}", r.detail);
    Ok(())
}

/// `host approvals unenroll`: `host approvals rm` of this machine's app key and its paired
/// phones there (ids under its `thisMacPhonePrefix`), over ssh.
pub(crate) async fn unenroll_with(io: &impl Io, t: &PeerTarget<'_>) -> StepResult {
    let host = t.host;
    let view = match io.rpc("_acpmux/mac_approvers", json!({})).await {
        Ok(view) => view,
        Err(e) => {
            return step(StepState::Warn, format!("the local acpmux daemon did not answer: {e}"));
        }
    };
    let own = view.get("thisMac").filter(|m| m.is_object());
    let Some(id) = own.map(|o| text(o, "id")).filter(|id| crate::hub::approvers::valid_id(id))
    else {
        return step(StepState::Skip, "no cmux app on this machine gave an approver key");
    };
    let ssh = |tail: &str| ssh_argv(host, &remote_cli(tail)).map(|argv| io.ssh(&argv));
    // This Mac's phones there go with it: every id under its prefix. Nothing changes until the
    // list is read, so an unenroll never leaves a phone of this Mac allowing there unsaid.
    let listed = match ssh("host approvals") {
        Ok(r) if r.ok => serde_json::from_str::<Value>(&r.stdout)
            .ok()
            .filter(|v| v.get("macs").is_some_and(Value::is_array)),
        _ => None,
    };
    let Some(listed) = listed else {
        return step(
            StepState::Warn,
            format!("could not read {host}'s enrolled Macs: nothing was unenrolled"),
        );
    };
    let there: Vec<&str> = macs(&listed)
        .map(|m| text(m, "id"))
        .filter(|m| crate::hub::approvers::valid_id(m))
        .collect();
    let prefix = text(&view, "thisMacPhonePrefix");
    if prefix.is_empty() && there.iter().any(|m| m.starts_with(crate::hub::approvers::PEER_PHONE)) {
        // Without the app's device id this Mac cannot tell its phones from another Mac's.
        return step(
            StepState::Warn,
            format!("{host} has paired phones enrolled, and this Mac's app has not said which are its own: nothing was unenrolled"),
        )
        .with_fix("Open cmux on this Mac, then run `acpmux host approvals unenroll` again.");
    }
    let mut ids: Vec<&str> =
        there.iter().copied().filter(|m| !prefix.is_empty() && m.starts_with(prefix)).collect();
    if there.contains(&id) {
        ids.push(id);
    }
    for id in ids {
        match ssh(&format!("host approvals rm {}", shell_quote(id))) {
            Ok(r) if r.ok => {}
            Ok(r) => {
                return step(
                    StepState::Warn,
                    format!(
                        "could not unenroll this Mac on {host}: {}",
                        r.stderr.lines().last().unwrap_or("").trim()
                    ),
                );
            }
            Err(e) => return step(StepState::Warn, e.to_string()),
        }
    }
    step(StepState::Fixed, format!("this Mac's app no longer allows {host}'s prompts"))
}

fn text<'v>(v: &'v Value, key: &str) -> &'v str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

/// The entries of a `host approvals` listing (`{"macs": [...]}`); none when it has no list.
fn macs(listed: &Value) -> impl Iterator<Item = &Value> {
    listed.get("macs").and_then(Value::as_array).into_iter().flatten()
}

fn listed(macs: &[Approver]) -> Vec<Value> {
    macs.iter()
        .map(|m| {
            json!({"id": m.id, "name": m.name,
                   "fingerprint": crate::hub::approvers::fingerprint(&m.public_key)})
        })
        .collect()
}

/// One locked read-modify-write of the Macs in `path`. Returns the lock, held
/// until the caller drops it (after the daemon's reload).
fn change(
    path: &Path,
    edit: impl FnOnce(&mut Vec<Approver>) -> Result<()>,
) -> Result<std::fs::File> {
    let dir = path.parent().ok_or_else(|| anyhow!("{} has no folder", path.display()))?;
    crate::config::private_state_dir(dir)?;
    let lock = path.with_extension("lock");
    let lock = crate::config::private_state_rw(&lock)?;
    lock.lock().with_context(|| format!("lock {}", path.display()))?;
    let mut macs = mac_approvers::read(path)?;
    edit(&mut macs)?;
    anyhow::ensure!(
        macs.len() <= crate::hub::approvers::MAX_APPROVERS,
        "at most {} Macs",
        crate::hub::approvers::MAX_APPROVERS
    );
    let list: Vec<Value> = macs
        .iter()
        .map(|m| {
            json!({"id": m.id, "publicKey": crate::hub::approvers::hex(&m.public_key),
                   "name": m.name})
        })
        .collect();
    let mut text = serde_json::to_string_pretty(&json!({"macs": list}))?;
    text.push('\n');
    crate::config::write_atomic(path, text.as_bytes())?;
    Ok(lock)
}

/// Has the running daemon read the file again: false when none runs (it
/// reads the file when it starts), an error when one runs and did not.
async fn reload() -> Result<bool> {
    let connected = crate::daemon::connect(false).await;
    reload_on(connected.as_deref(), &crate::config::home().join("daemon.lock")).await
}

/// `reload` on a daemon connection, or on the error connecting gave: no
/// daemon, unless one holds its `lock` (it runs, but its socket did not answer
/// or did not finish `initialize`), which fails the change.
async fn reload_on(client: Result<&impl Reload, &anyhow::Error>, lock: &Path) -> Result<bool> {
    match client {
        Ok(client) => reload_with(client).await,
        Err(e) if daemon_runs(lock) => Err(anyhow!(
            "{} changed, but the running acpmux daemon did not answer ({e}); \
             restart it (`acpmux daemon stop`, then `acpmux daemon`)",
            mac_approvers::FILE
        )),
        Err(_) => Ok(false),
    }
}

/// Whether a daemon holds `lock` (its `daemon.lock`, `daemon/lock.rs`).
fn daemon_runs(lock: &Path) -> bool {
    let Ok(file) = std::fs::File::open(lock) else { return false };
    matches!(file.try_lock_shared(), Err(std::fs::TryLockError::WouldBlock))
}

async fn reload_with(client: &impl Reload) -> Result<bool> {
    client.reload().await.map_err(|e| {
        anyhow!(
            "{} changed, but the running acpmux daemon did not reload it ({e}); \
             restart it (`acpmux daemon stop`, then `acpmux daemon`)",
            mac_approvers::FILE
        )
    })?;
    Ok(true)
}

/// The daemon's reload of the file, faked in the tests.
trait Reload {
    async fn reload(&self) -> Result<Value>;
}

impl Reload for crate::client::Client {
    async fn reload(&self) -> Result<Value> {
        self.request("_acpmux/mac_approvers", json!({"reload": true})).await
    }
}

fn step(state: StepState, detail: impl Into<String>) -> StepResult {
    StepResult::new(Step::Approvals, state, detail)
}

/// `approvals`: the machine lists this machine's app key, so the app here
/// may allow its prompts in a chat reached through this daemon. With `fix`,
/// it is added there (`host approvals add` over ssh). Never a failure: a
/// machine works without it, its prompts then answered on that machine only.
pub(crate) async fn approvals_with(io: &impl Io, t: &PeerTarget<'_>, fix: bool) -> StepResult {
    let (host, name) = (t.host, t.name);
    let view = match io.rpc("_acpmux/mac_approvers", json!({})).await {
        Ok(view) => view,
        Err(e) => {
            return step(StepState::Warn, format!("the local acpmux daemon did not answer: {e}"));
        }
    };
    let own = view.get("thisMac").filter(|m| m.is_object()).cloned();
    let Some(own) = own else {
        return step(StepState::Skip, "no cmux app on this machine gave an approver key").with_fix(
            format!(
                "To allow {host}'s prompts from the cmux app here, open cmux, then run `acpmux machine enroll {host}` again."
            ),
        );
    };
    let (id, key, label) = (text(&own, "id"), text(&own, "publicKey"), text(&own, "name"));
    // Checked before they reach a remote shell.
    let entry = json!({"id": id, "publicKey": key, "name": label});
    if crate::hub::approvers::parse_approvers(std::slice::from_ref(&entry)).is_err() {
        return step(StepState::Warn, "this machine's app key is malformed");
    }
    let mac = if label.is_empty() { "this Mac".to_owned() } else { format!("this Mac ({label})") };
    let ssh = |tail: &str| ssh_argv(host, &remote_cli(tail)).map(|argv| io.ssh(&argv));
    let listed = match ssh("host approvals") {
        Err(e) => return step(StepState::Warn, e.to_string()),
        Ok(r) if !r.ok => {
            let last = r.stderr.lines().last().unwrap_or("").trim().to_owned();
            if last.contains("unrecognized subcommand") || last.contains("unexpected argument") {
                return step(
                    StepState::Warn,
                    format!("the acpmux on {host} is too old for approvals from {mac}"),
                )
                .with_fix(format!(
                    "Run `acpmux machine update {name}`, then `acpmux machine enroll {host}` again."
                ))
                .with_try(format!("acpmux machine update {name}"));
            }
            return step(StepState::Warn, format!("could not read {host}'s enrolled Macs: {last}"));
        }
        Ok(r) => serde_json::from_str::<Value>(&r.stdout).unwrap_or(Value::Null),
    };
    let fingerprint = text(&own, "fingerprint");
    let enrolled = listed["macs"].as_array().into_iter().flatten().any(|m| {
        text(m, "id") == id && (fingerprint.is_empty() || text(m, "fingerprint") == fingerprint)
    });
    let phones = PhonePlan::of(&view, &listed);
    // A daemon from before phone enrollment lists no phones at all (not an empty list): its
    // phones are unknown, never up to date.
    let old_daemon = !view.get("thisMacPhones").is_some_and(Value::is_array);
    let too_old =
        |state: StepState| {
            step(
            StepState::Warn,
            format!(
                "{} on {host}, but this Mac's acpmux is too old to enroll its paired phones there",
                if state == StepState::Fixed { "enrolled this Mac" } else { "this Mac is enrolled" }
            ),
        )
        .with_fix(format!(
            "Update acpmux on this Mac, then run `acpmux machine doctor {name} --fix` again."
        ))
        };
    if enrolled && phones.is_empty() {
        if old_daemon {
            return too_old(StepState::Ok);
        }
        return step(StepState::Ok, format!("{mac} may allow {host}'s prompts from the app"));
    }
    if !fix {
        let detail = if enrolled {
            format!(
                "{mac}'s paired phones on {host} are out of date: a phone cannot allow {host}'s prompts"
            )
        } else {
            format!("{mac} is not enrolled on {host}: its app cannot allow {host}'s prompts")
        };
        return step(StepState::Warn, detail)
            .with_fix(format!("Run `acpmux machine doctor {name} --fix` to enroll it."));
    }
    let add = |entry: (&str, &str, &str)| {
        let (id, key, label) = entry;
        let script = format!(
            "host approvals add --id {} --key {} --name {}",
            shell_quote(id),
            shell_quote(key),
            shell_quote(label)
        );
        match ssh(&script) {
            Ok(r) if r.ok => Ok(()),
            Ok(r) => Err(r.stderr.lines().last().unwrap_or("").trim().to_owned()),
            Err(e) => Err(e.to_string()),
        }
    };
    // The paired phones follow the Mac's own key: none this Mac no longer pairs (a phone unpaired
    // here stops counting there too), then each one current. Removals go first, so a peer whose
    // list is full still makes room for the Mac and a newly paired phone.
    let mut failed = Vec::new();
    for id in &phones.remove {
        match ssh(&format!("host approvals rm {}", shell_quote(id))) {
            Ok(r) if r.ok => {}
            Ok(r) => failed.push(r.stderr.lines().last().unwrap_or("").trim().to_owned()),
            Err(e) => failed.push(e.to_string()),
        }
    }
    if !enrolled && let Err(why) = add((id, key, label)) {
        return step(StepState::Warn, format!("could not enroll {mac} on {host}: {why}"));
    }
    for phone in &phones.add {
        let entry = (text(phone, "id"), text(phone, "publicKey"), text(phone, "name"));
        if let Err(why) = add(entry) {
            failed.push(why);
        }
    }
    if let Some(why) = failed.first() {
        return step(StepState::Warn, format!("could not enroll {mac}'s phones on {host}: {why}"));
    }
    if old_daemon {
        return too_old(StepState::Fixed);
    }
    let what = if phones.paired == 0 { mac } else { format!("{mac} and its paired phones") };
    step(StepState::Fixed, format!("{what} may now allow {host}'s prompts from the app"))
}

/// What a peer's enrolled list needs for this Mac's paired phones
/// (`_acpmux/mac_approvers` `thisMacPhones`, ids under `thisMacPhonePrefix`).
#[derive(Debug, Default)]
struct PhonePlan {
    /// Phones missing there or there with another key.
    add: Vec<Value>,
    /// Ids under this Mac's prefix there that it no longer pairs.
    remove: Vec<String>,
    /// How many phones this Mac pairs.
    paired: usize,
}

impl PhonePlan {
    fn of(view: &Value, listed: &Value) -> Self {
        let phones: Vec<Value> = view
            .get("thisMacPhones")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|p| crate::hub::approvers::parse_approvers(std::slice::from_ref(*p)).is_ok())
            .cloned()
            .collect();
        let there: Vec<&Value> = macs(listed).collect();
        let add = phones
            .iter()
            .filter(|p| {
                !there.iter().any(|m| {
                    text(m, "id") == text(p, "id")
                        && text(m, "fingerprint") == text(p, "fingerprint")
                })
            })
            .cloned()
            .collect();
        let prefix = text(view, "thisMacPhonePrefix");
        let remove = if prefix.is_empty() {
            Vec::new()
        } else {
            there
                .iter()
                .map(|m| text(m, "id"))
                .filter(|id| id.starts_with(prefix) && !phones.iter().any(|p| text(p, "id") == *id))
                .map(str::to_owned)
                .collect()
        };
        Self { add, remove, paired: phones.len() }
    }

    fn is_empty(&self) -> bool {
        self.add.is_empty() && self.remove.is_empty()
    }
}

#[cfg(test)]
#[path = "host_approvals_tests.rs"]
mod tests;
