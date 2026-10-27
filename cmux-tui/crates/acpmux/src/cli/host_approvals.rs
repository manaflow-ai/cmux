//! `acpmux host approvals`: the Macs whose cmux app may allow this
//! machine's prompts in a chat the Mac reaches through its own daemon
//! (peer-route approvals, `hub/mac_approvers.rs`), and the `approvals` step
//! of `host enroll` and `host doctor`, which enrolls this machine's app key on
//! the machine it adds.
//!
//! The Macs live in `ACPMUX_HOME/mac-approvers.json`; a change is one locked
//! read-modify-write (`mac-approvers.lock`) and one rename, then the running
//! daemon reloads it (`_acpmux/mac_approvers {reload: true}`), which returns
//! only after an answer being committed: once `rm` returns, the Mac's
//! signatures count nothing. Only this command writes the file; no RPC does.

use crate::cli::host_peering::{Io, PeerTarget, remote_cli};
use crate::cli::host_steps::{Step, StepResult, StepState};
use crate::cli::hosts::ssh_argv;
use crate::cli::output::print_json;
use crate::harness_health::channel::quote as shell_quote;
use crate::hub::approvers::Approver;
use crate::hub::mac_approvers;
use anyhow::{Context, Result, anyhow};
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
                v["thisMac"] = view["thisMac"].clone();
            }
            v
        }
        Some(ApprovalsCmd::Add { id, key, name }) => {
            let entry = json!({"id": id, "publicKey": key, "name": name.unwrap_or_default()});
            let added = crate::hub::approvers::parse_approvers(std::slice::from_ref(&entry))
                .map_err(|e| anyhow!("{}", e.message))?;
            change(&path, |macs| {
                macs.retain(|m| m.id != id);
                macs.extend(added);
                Ok(())
            })?;
            json!({"added": id, "reloaded": reload().await})
        }
        Some(ApprovalsCmd::Enroll { peer }) => return on_peer(&peer, true, json_out).await,
        Some(ApprovalsCmd::Unenroll { peer }) => return on_peer(&peer, false, json_out).await,
        Some(ApprovalsCmd::Rm { id }) => {
            let mut known = false;
            change(&path, |macs| {
                known = macs.iter().any(|m| m.id == id);
                macs.retain(|m| m.id != id);
                Ok(())
            })?;
            json!({"removed": id, "enrolled": known, "reloaded": reload().await})
        }
    };
    if json_out {
        print_json(&v);
    } else if let Some(macs) = v.get("macs").and_then(Value::as_array) {
        if macs.is_empty() {
            println!(
                "no Mac may allow this machine's prompts (`acpmux host enroll` from the Mac adds one)"
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

/// `host approvals unenroll`: `host approvals rm` of this machine's app key, over ssh.
pub(crate) async fn unenroll_with(io: &impl Io, t: &PeerTarget<'_>) -> StepResult {
    let host = t.host;
    let own = match io.rpc("_acpmux/mac_approvers", json!({})).await {
        Ok(view) => view.get("thisMac").filter(|m| m.is_object()).cloned(),
        Err(e) => {
            return step(StepState::Warn, format!("the local acpmux daemon did not answer: {e}"));
        }
    };
    let Some(id) =
        own.as_ref().map(|o| text(o, "id")).filter(|id| crate::hub::approvers::valid_id(id))
    else {
        return step(StepState::Skip, "no cmux app on this machine gave an approver key");
    };
    let rm = remote_cli(&format!("host approvals rm {}", shell_quote(id)));
    match ssh_argv(host, &rm).map(|argv| io.ssh(&argv)) {
        Ok(r) if r.ok => {
            step(StepState::Fixed, format!("this Mac's app no longer allows {host}'s prompts"))
        }
        Ok(r) => step(
            StepState::Warn,
            format!(
                "could not unenroll this Mac on {host}: {}",
                r.stderr.lines().last().unwrap_or("").trim()
            ),
        ),
        Err(e) => step(StepState::Warn, e.to_string()),
    }
}

fn text<'v>(v: &'v Value, key: &str) -> &'v str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

fn listed(macs: &[Approver]) -> Vec<Value> {
    macs.iter()
        .map(|m| {
            json!({"id": m.id, "name": m.name,
                   "fingerprint": crate::hub::approvers::fingerprint(&m.public_key)})
        })
        .collect()
}

/// One locked read-modify-write of the Macs in `path`.
fn change(path: &Path, edit: impl FnOnce(&mut Vec<Approver>) -> Result<()>) -> Result<()> {
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
    crate::config::write_atomic(path, text.as_bytes())
}

/// Has the running daemon read the file again; false when none runs (it
/// reads the file when it starts).
async fn reload() -> bool {
    match crate::daemon::connect(false).await {
        Ok(client) => {
            client.request("_acpmux/mac_approvers", json!({"reload": true})).await.is_ok()
        }
        Err(_) => false,
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
    let own = match io.rpc("_acpmux/mac_approvers", json!({})).await {
        Ok(view) => view.get("thisMac").filter(|m| m.is_object()).cloned(),
        Err(e) => {
            return step(StepState::Warn, format!("the local acpmux daemon did not answer: {e}"));
        }
    };
    let Some(own) = own else {
        return step(StepState::Skip, "no cmux app on this machine gave an approver key").with_fix(
            format!(
                "To allow {host}'s prompts from the cmux app here, open cmux, then run `acpmux host enroll {host}` again."
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
                    "Run `acpmux host update {name}`, then `acpmux host enroll {host}` again."
                ))
                .with_try(format!("acpmux host update {name}"));
            }
            return step(StepState::Warn, format!("could not read {host}'s enrolled Macs: {last}"));
        }
        Ok(r) => serde_json::from_str::<Value>(&r.stdout).unwrap_or(Value::Null),
    };
    let fingerprint = text(&own, "fingerprint");
    let enrolled = listed["macs"].as_array().into_iter().flatten().any(|m| {
        text(m, "id") == id && (fingerprint.is_empty() || text(m, "fingerprint") == fingerprint)
    });
    if enrolled {
        return step(StepState::Ok, format!("{mac} may allow {host}'s prompts from the app"));
    }
    if !fix {
        return step(
            StepState::Warn,
            format!("{mac} is not enrolled on {host}: its app cannot allow {host}'s prompts"),
        )
        .with_fix(format!("Run `acpmux host doctor {name} --fix` to enroll it."));
    }
    let add = format!(
        "host approvals add --id {} --key {} --name {}",
        shell_quote(id),
        shell_quote(key),
        shell_quote(label)
    );
    match ssh(&add) {
        Ok(r) if r.ok => {
            step(StepState::Fixed, format!("{mac} may now allow {host}'s prompts from the app"))
        }
        Ok(r) => step(
            StepState::Warn,
            format!(
                "could not enroll {mac} on {host}: {}",
                r.stderr.lines().last().unwrap_or("").trim()
            ),
        ),
        Err(e) => step(StepState::Warn, e.to_string()),
    }
}

#[cfg(test)]
#[path = "host_approvals_tests.rs"]
mod tests;
