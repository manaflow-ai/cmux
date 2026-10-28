//! The `peer`, `peer-back` and `identity` steps of `host enroll` and `host
//! doctor` (plans/cmux-next/add-machine-DESIGN.md): this daemon lists the
//! machine as an ssh peer and reaches it; the machine lists this one back
//! and can ssh here with a key; the peer answers under its name. With `fix`
//! false nothing changes, here or there. Every outside effect goes through
//! [`Io`], so the tests need no host.

use crate::cli::host_steps::{Step, StepResult, StepState};
use crate::cli::hosts::{checked_host, ssh_argv};
use crate::client::Client;
use crate::tailnet::{self, Tailnet};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::net::IpAddr;
use std::process::{Command, Stdio};

/// The machine a step checks, and this machine as that one sees it.
pub struct PeerTarget<'a> {
    /// The peer name here (`host ls`).
    pub name: &'a str,
    /// The machine's ssh destination, `[user@]host`.
    pub host: &'a str,
    /// The machine's daemon port: the peer url names it when it is not
    /// the default (`hosts::ssh_peer_url`).
    pub port: u16,
    /// This machine's peer name on that machine.
    pub local_name: &'a str,
    /// How that machine reaches this one over ssh (`[user@]host`); `None`
    /// works it out ([`local_dest`]).
    pub local_dest: Option<&'a str>,
}

/// One finished `ssh`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Ran {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
}

/// What the steps do outside this process: the local daemon's RPCs, `ssh`,
/// the local tailnet status and the local user. [`Live`] does it; tests
/// pass a fake.
pub(crate) trait Io {
    async fn rpc(&self, method: &str, params: Value) -> Result<Value>;
    /// `ssh ARGV`, with stdin closed.
    fn ssh(&self, argv: &[String]) -> Ran;
    fn tailscale(&self) -> Result<tailnet::Status>;
    /// The local `$USER`.
    fn user(&self) -> Option<String>;
}

/// The real [`Io`]; `peer-back` has no daemon connection.
pub(crate) struct Live<'a>(pub Option<&'a Client>);

impl Io for Live<'_> {
    async fn rpc(&self, method: &str, params: Value) -> Result<Value> {
        match self.0 {
            Some(client) => client.request(method, params).await,
            None => Err(anyhow!("no connection to the local daemon")),
        }
    }

    fn ssh(&self, argv: &[String]) -> Ran {
        match Command::new("ssh").args(argv).stdin(Stdio::null()).output() {
            Ok(out) => Ran {
                ok: out.status.success(),
                stdout: String::from_utf8_lossy(&out.stdout).trim().to_owned(),
                stderr: String::from_utf8_lossy(&out.stderr).trim().to_owned(),
            },
            Err(e) => Ran { stderr: format!("cannot run ssh: {e}"), ..Ran::default() },
        }
    }

    fn tailscale(&self) -> Result<tailnet::Status> {
        Tailnet::locate()?.status()
    }

    fn user(&self) -> Option<String> {
        std::env::var("USER").ok().filter(|u| !u.is_empty())
    }
}

/// `peer`: this daemon lists `t.name` at `ssh://t.host` and it connects.
pub async fn peer(client: &Client, t: &PeerTarget<'_>, fix: bool) -> StepResult {
    peer_with(&Live(Some(client)), t, fix).await
}

/// `peer-back`: the machine lists this one as an ssh peer that resolves
/// here, and can ssh here with a key.
pub async fn peer_back(t: &PeerTarget<'_>, fix: bool) -> StepResult {
    peer_back_with(&Live(None), t, fix).await
}

/// `identity`: the peer answers under its name. acpmux's peer handshake
/// carries no machine id (`initialize` reports version, build, origin and
/// the daemon run), and the sidebar name and icon belong to the app, so a
/// connected peer named NAME passes. `fix` has nothing to write yet.
pub async fn identity(client: &Client, t: &PeerTarget<'_>, fix: bool) -> StepResult {
    let _ = fix;
    identity_with(&Live(Some(client)), t).await
}

fn result(step: Step, state: StepState, detail: impl Into<String>) -> StepResult {
    StepResult::new(step, state, detail)
}

fn list(reply: &Value) -> Vec<Value> {
    reply.get("peers").and_then(Value::as_array).cloned().unwrap_or_default()
}

fn named<'v>(peers: &'v [Value], name: &str) -> Option<&'v Value> {
    peers.iter().find(|p| text(p, "name") == name)
}

fn text<'v>(p: &'v Value, key: &str) -> &'v str {
    p.get(key).and_then(Value::as_str).unwrap_or("")
}

fn connected(p: &Value) -> bool {
    p.get("connected").and_then(Value::as_bool).unwrap_or(false)
}

/// ` (the peer's last error)`, or nothing.
fn last_error(p: &Value) -> String {
    p.get("error").and_then(Value::as_str).map(|e| format!(" ({e})")).unwrap_or_default()
}

/// Two ssh peer URLs that name the same destination and port.
fn same_ssh_url(a: &str, b: &str) -> bool {
    match (crate::peer::ssh_target(a), crate::peer::ssh_target(b)) {
        (Ok(a), Ok(b)) => a.destination.eq_ignore_ascii_case(&b.destination) && a.port == b.port,
        _ => false,
    }
}

/// A peer name passed to a remote CLI: letters, digits, `.`, `_` and `-`,
/// not starting with `-`.
pub(crate) fn checked_name(name: &str) -> Result<&str, &'static str> {
    if name.is_empty() || name.len() > 64 {
        return Err("the name is empty or longer than 64 characters");
    }
    if name.starts_with('-') {
        return Err("the name starts with -");
    }
    if !name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')) {
        return Err("the name has a character other than letters, digits, '.', '_' or '-'");
    }
    Ok(name)
}

pub(crate) async fn peer_with(io: &impl Io, t: &PeerTarget<'_>, fix: bool) -> StepResult {
    let fail = |detail: String| result(Step::Peer, StepState::Fail, detail);
    if let Err(e) = checked_host(t.host) {
        return fail(e.to_string()).with_fix("Give the host as [user@]name, without a port.");
    }
    let (name, url) = (t.name, crate::cli::hosts::ssh_peer_url(t.host, t.port));
    let peers = match io.rpc("_acpmux/peers", json!({})).await {
        Ok(reply) => list(&reply),
        Err(e) => {
            return fail(format!("the local acpmux daemon did not answer: {e}"))
                .with_fix("Start it (`acpmux daemon start`), then check again.");
        }
    };
    let settle = |reply: Result<Value>| match reply {
        Err(e) => fail(format!("the local daemon refused {name} at {url}: {e}")),
        Ok(reply) => match named(&list(&reply), name) {
            Some(p) if connected(p) => {
                result(Step::Peer, StepState::Fixed, format!("{name} at {url}, connected"))
            }
            Some(p) => fail(format!("{name} at {url} does not connect{}", last_error(p)))
                .with_fix(format!("Check that the daemon on {} runs (the daemon step).", t.host)),
            None => fail(format!("the local daemon did not keep {name}")),
        },
    };
    match named(&peers, name) {
        Some(p) if !same_ssh_url(text(p, "url"), &url) => {
            fail(format!("{name} is already the peer at {}", text(p, "url"))).with_fix(format!(
                "Pick another name for this machine, or remove that peer first (`acpmux host rm {name}`)."
            ))
        }
        Some(p) if connected(p) => {
            result(Step::Peer, StepState::Ok, format!("{name} at {url}, connected"))
        }
        Some(p) if !fix => fail(format!("{name} at {url} is not connected{}", last_error(p)))
            .with_fix("Check again with --fix to reconnect it."),
        Some(_) => settle(
            io.rpc("_acpmux/peer_reconnect", json!({"name": name, "wait": true})).await,
        ),
        None if !fix => fail(format!("no peer named {name}"))
            .with_fix(format!("Check again with --fix to add {name} at {url}.")),
        None => settle(
            io.rpc("_acpmux/peer_add", json!({"name": name, "url": url, "wait": true})).await,
        ),
    }
}

pub(crate) async fn identity_with(io: &impl Io, t: &PeerTarget<'_>) -> StepResult {
    let fail = |detail: String| result(Step::Identity, StepState::Fail, detail);
    let peers = match io.rpc("_acpmux/peers", json!({})).await {
        Ok(reply) => list(&reply),
        Err(e) => return fail(format!("the local acpmux daemon did not answer: {e}")),
    };
    match named(&peers, t.name) {
        None => fail(format!("no peer named {}", t.name)).with_fix("The peer step adds it."),
        Some(p) if !connected(p) => fail(format!("{} is not connected{}", t.name, last_error(p)))
            .with_fix("Fix the peer step first."),
        Some(_) => {
            result(Step::Identity, StepState::Ok, format!("name {} (app sets icon)", t.name))
        }
    }
}

/// The remote's acpmux CLI as `"$@"`: the binary `host setup` installs and
/// its launchd agent runs, else the one cmux-tui carries (`cmux-tui acp`).
/// The machine's acpmux CLI: a standalone one, else the cmux app's (macOS,
/// `cmux*.app/Contents/Resources/bin/acpmux`), else cmux-tui's `acp`.
const REMOTE_CLI: &str = "a=; for f in /Applications/cmux*.app/Contents/Resources/bin/acpmux; do if [ -x \"$f\" ]; then a=$f; break; fi; done; if [ -x ~/.local/bin/acpmux ]; then set -- ~/.local/bin/acpmux; elif [ -n \"$a\" ]; then set -- \"$a\"; elif [ -x ~/.local/bin/cmux-tui ]; then set -- ~/.local/bin/cmux-tui acp; elif [ -x ~/.cmux/bin/cmux-tui ]; then set -- ~/.cmux/bin/cmux-tui acp; elif command -v cmux-tui >/dev/null 2>&1; then set -- cmux-tui acp; else echo 'no acpmux or cmux-tui on this machine' >&2; exit 127; fi; ";

/// A remote script running `"$@" --json TAIL`. `tail` is acpmux's own text
/// with only checked names in it.
pub(crate) fn remote_cli(tail: &str) -> String {
    format!("{REMOTE_CLI}\"$@\" --json {tail}")
}

/// `daemon status` lists the peers without starting a daemon (`host ls`
/// would start one).
const REMOTE_STATUS: &str = "daemon status";

/// `host add LOCAL ssh://DEST` on the remote; both are checked first.
pub(crate) fn remote_add_script(local: &str, dest: &str) -> Result<String> {
    let local = checked_name(local).map_err(|why| anyhow!("refusing that name: {why}"))?;
    let dest = checked_host(dest)?;
    Ok(remote_cli(&format!("host add '{local}' 'ssh://{dest}'")))
}

const BACK_OK: &str = "acpmux-ssh-back-ok";
const BACK_FAILED: &str = "acpmux-ssh-back-failed";

/// `ssh HOST 'ssh -o BatchMode=yes -o ConnectTimeout=8 -- DEST true'`: can
/// the remote ssh here with a key. DEST is checked like a peer host, so it
/// is a plain name and safe in single quotes; the marker line tells the
/// remote's ssh failing from ours.
pub(crate) fn probe_argv(host: &str, dest: &str) -> Result<Vec<String>> {
    let dest = checked_host(dest)?;
    ssh_argv(
        host,
        &format!(
            "if ssh -o BatchMode=yes -o ConnectTimeout=8 -- '{dest}' true </dev/null; then echo {BACK_OK}; else echo {BACK_FAILED}; fi"
        ),
    )
}

/// A running tailnet's status, else `None`.
fn running_tailnet(io: &impl Io) -> Option<tailnet::Status> {
    io.tailscale().ok().filter(|s| s.backend_state == "Running")
}

/// How the remote reaches this machine: `$USER@` this machine's MagicDNS
/// name (or tailnet IPv4) when the tailnet runs, else `None`. The address
/// the remote sees in `$SSH_CONNECTION` is never used: behind a NAT, VPN or
/// jump host it names some other machine.
pub(crate) fn local_dest(io: &impl Io, ts: Option<&tailnet::Status>) -> Option<String> {
    let user = io.user().filter(|u| checked_name(u).is_ok());
    let s = ts?;
    let name = Some(s.this.dns_name.clone()).filter(|n| !n.is_empty());
    let h = name.or_else(|| s.this.dial_ip().filter(IpAddr::is_ipv4).map(|ip| ip.to_string()))?;
    let dest = match &user {
        Some(u) => format!("{u}@{h}"),
        None => h,
    };
    checked_host(&dest).is_ok().then_some(dest)
}

/// The host part of an `ssh://` URL, lowercased, without user or brackets.
fn ssh_url_host(url: &str) -> Option<String> {
    let t = crate::peer::ssh_target(url).ok()?;
    let host = t.destination.rsplit('@').next().unwrap_or(&t.destination);
    Some(host.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase())
}

/// The names and addresses this machine answers to: `dest`'s host, its
/// peer name `local` (a peer URL may name it by its short host name) and,
/// on a tailnet, its MagicDNS name, short name, host name and IPs.
fn here_names(dest: &str, local: &str, ts: Option<&tailnet::Status>) -> Vec<String> {
    let mut names: Vec<String> = ssh_url_host(&format!("ssh://{dest}")).into_iter().collect();
    names.push(local.to_owned());
    if let Some(s) = ts {
        names.extend([s.this.dns_name.clone(), s.this.short_name(), s.this.host_name.clone()]);
        names.extend(s.this.ips.iter().map(IpAddr::to_string));
    }
    names.into_iter().filter(|n| !n.is_empty()).map(|n| n.to_ascii_lowercase()).collect()
}

/// Whether a peer URL's host is one of `here`. A bare name (no dots) also
/// matches the first label of one (`ssh://cosmic-gray` for
/// `cosmic-gray.tail9.ts.net`); a dotted name must match whole, so
/// `ssh://cosmic.other.net` is not `cosmic`.
fn points_here(url: &str, here: &[String]) -> bool {
    let name = |s: &str| s.parse::<IpAddr>().is_err();
    ssh_url_host(url).is_some_and(|h| {
        here.contains(&h)
            || (!h.contains('.')
                && name(&h)
                && here.iter().any(|n| name(n) && n.split('.').next() == Some(h.as_str())))
    })
}

/// The peers in the remote's `daemon status`, or why there are none.
fn remote_peers(ran: &Ran) -> Result<Vec<Value>, String> {
    if !ran.ok {
        return Err(first_line(&ran.stderr, "ssh failed"));
    }
    let status: Value = serde_json::from_str(&ran.stdout)
        .map_err(|_| "its acpmux printed something that is not JSON".to_owned())?;
    if status.get("running").and_then(Value::as_bool) == Some(false) {
        return Err("its acpmux daemon is not running".into());
    }
    Ok(list(&status))
}

fn first_line(s: &str, fallback: &str) -> String {
    s.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or(fallback).to_owned()
}

/// Why the remote's ssh here failed, from its stderr, and what a person
/// can do about it. No key is ever copied for them.
pub(crate) fn why_no_ssh_back(stderr: &str, host: &str, dest: &str) -> (String, String) {
    let has = |needle: &str| stderr.contains(needle);
    if has("Permission denied") {
        (
            "key rejected".into(),
            format!(
                "Add {host}'s ssh public key to ~/.ssh/authorized_keys on this machine, then check again."
            ),
        )
    } else if has("Host key verification failed") || has("IDENTIFICATION HAS CHANGED") {
        (
            "this machine's host key is not trusted there".into(),
            format!(
                "On {host}, run `ssh {dest}` once and accept this machine's host key if it is the right one, then check again."
            ),
        )
    } else if has("Connection refused") {
        (
            "ssh is off on this machine".into(),
            "Turn on ssh here (Remote Login on macOS), then check again.".into(),
        )
    } else if has("Could not resolve") || has("timed out") || has("No route") || has("unreachable")
    {
        (
            "no route".into(),
            format!(
                "Allow ssh from {host} to this machine in your tailnet ACL or firewall, then check again."
            ),
        )
    } else {
        (
            first_line(stderr, "ssh failed"),
            format!("Check that {host} can run `ssh {dest}` without a password, then check again."),
        )
    }
}

pub(crate) async fn peer_back_with(io: &impl Io, t: &PeerTarget<'_>, fix: bool) -> StepResult {
    let at = |state, detail: String| result(Step::PeerBack, state, detail);
    let fail = |detail: String| at(StepState::Fail, detail);
    let host = match checked_host(t.host) {
        Ok(h) => h,
        Err(e) => return fail(e.to_string()),
    };
    let local = match checked_name(t.local_name) {
        Ok(n) => n,
        Err(why) => {
            return fail(format!("refusing this machine's name: {why}"))
                .with_fix("Name this machine with letters, digits, '.', '_' or '-'.");
        }
    };
    let ts = running_tailnet(io);
    let dest = match t.local_dest {
        Some(d) => match checked_host(d) {
            Ok(d) => d.to_owned(),
            Err(e) => return fail(format!("this machine's address: {e}")),
        },
        None => match local_dest(io, ts.as_ref()) {
            Some(d) => d,
            None => {
                return at(
                    StepState::Warn,
                    format!(
                        "this machine has no tailnet name, so how {host} reaches it is unknown"
                    ),
                )
                .with_fix("Sign this machine in to Tailscale, then check again.");
            }
        },
    };
    let peers = match ssh_argv(host, &remote_cli(REMOTE_STATUS)).map(|argv| io.ssh(&argv)) {
        Ok(ran) => remote_peers(&ran),
        Err(e) => Err(e.to_string()),
    };
    let peers = match peers {
        Ok(p) => p,
        Err(why) => {
            return fail(format!("cannot read {host}'s peers: {why}"))
                .with_fix("Check the daemon step first.");
        }
    };
    let here = here_names(&dest, local, ts.as_ref());
    let by_name = named(&peers, local);
    if let Some(p) = by_name
        && !points_here(text(p, "url"), &here)
    {
        return fail(format!("{host} already has a peer named {local} at {}", text(p, "url")))
            .with_fix(format!(
                "Pick another name for this machine, or remove that peer on {host} (`acpmux host rm {local}` there)."
            ));
    }
    // Listed under another name still counts: a second peer would be a duplicate.
    let listed = by_name.or_else(|| peers.iter().find(|p| points_here(text(p, "url"), &here)));
    let probe = match probe_argv(host, &dest) {
        Ok(argv) => io.ssh(&argv),
        Err(e) => return fail(format!("this machine's address: {e}")),
    };
    if !probe.stdout.contains(BACK_OK) {
        if !probe.stdout.contains(BACK_FAILED) {
            return fail(format!(
                "ssh to {host} failed: {}",
                first_line(&probe.stderr, "no reply")
            ));
        }
        let (why, fix_text) = why_no_ssh_back(&probe.stderr, host, &dest);
        return at(StepState::Warn, format!("{host} cannot ssh to this machine at {dest}: {why}"))
            .with_fix(fix_text);
    }
    let not_connected_fix = "Check that this machine's acpmux daemon runs with its WebSocket listener set, then check again.";
    match listed {
        Some(p) if connected(p) => at(
            StepState::Ok,
            format!(
                "{host} lists this machine as {} at {}, connected",
                text(p, "name"),
                text(p, "url")
            ),
        ),
        Some(p) => at(
            StepState::Warn,
            format!(
                "{host} lists this machine as {} at {} but is not connected{}",
                text(p, "name"),
                text(p, "url"),
                last_error(p)
            ),
        )
        .with_fix(not_connected_fix),
        None if !fix => fail(format!("{host} does not list this machine"))
            .with_fix(format!("Check again with --fix to add {local} at ssh://{dest} on {host}.")),
        None => {
            let ran = match remote_add_script(local, &dest).and_then(|s| ssh_argv(host, &s)) {
                Ok(argv) => io.ssh(&argv),
                Err(e) => return fail(e.to_string()),
            };
            let reply = if ran.ok { serde_json::from_str::<Value>(&ran.stdout).ok() } else { None };
            let Some(reply) = reply else {
                return fail(format!(
                    "adding this machine on {host} failed: {}",
                    first_line(&ran.stderr, "no reply")
                ));
            };
            match named(&list(&reply), local) {
                Some(p) if connected(p) => at(
                    StepState::Fixed,
                    format!("{host} lists this machine as {local} at ssh://{dest}, connected"),
                ),
                Some(p) => at(
                    StepState::Warn,
                    format!(
                        "{host} added this machine as {local} at ssh://{dest} but is not connected{}",
                        last_error(p)
                    ),
                )
                .with_fix(not_connected_fix),
                None => fail(format!("{host}'s daemon did not keep {local}")),
            }
        }
    }
}

#[cfg(test)]
#[path = "host_peering_tests.rs"]
mod tests;
