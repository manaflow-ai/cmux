//! `acpmux host candidates`: the tailnet's machines that Add Machine can
//! offer (plans/cmux-next/add-machine-DESIGN.md), each marked when a peer
//! here already points at it. `--probe` also tries key-only ssh to each
//! online machine of the user's own (same login, not tagged, not shared
//! in), a few at a time and at most [`MAX_PROBES`].

use crate::cli::host_peering::{Io, Live, Ran};
use crate::cli::hosts::checked_host;
use crate::cli::output::print_json;
use crate::client::Client;
use crate::tailnet::{Node, Status};
use anyhow::Result;
use serde::Serialize;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicUsize, Ordering};

/// How many ssh probes run at once.
const PROBES_AT_ONCE: usize = 8;
/// The most machines one `--probe` tries; the rest stay unprobed.
pub(crate) const MAX_PROBES: usize = 32;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Candidate {
    /// The MagicDNS short name, else the host name: the peer name enroll
    /// suggests.
    pub name: String,
    /// The MagicDNS name, the host enroll dials; empty without MagicDNS.
    pub dns_name: String,
    /// The tailnet address, IPv4 first.
    pub ip: Option<String>,
    pub os: String,
    pub online: bool,
    /// The user's own machine: the same tailnet login as this one, not
    /// tagged and not shared in. Only these are probed.
    pub mine: bool,
    /// A peer here already points at this machine (`peer` names it).
    pub already_peer: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peer: Option<String>,
    /// That peer's URL (`ssh://[user@]host[:port]`): how this machine dials it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peer_url: Option<String>,
    /// With `--probe`: key-only ssh worked. Not tried for an offline machine,
    /// one that is not [`Candidate::mine`], or one past [`MAX_PROBES`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ssh_ok: Option<bool>,
}

/// The host part of a peer URL (`ssh://[user@]host[:port]`, `ws://host:port/…`),
/// lowercased, without brackets.
pub(crate) fn url_host(url: &str) -> Option<String> {
    let (_, rest) = url.split_once("://")?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let hostport = authority.rsplit('@').next()?;
    let host = match hostport.strip_prefix('[') {
        Some(v6) => v6.split(']').next()?,
        None => hostport.split(':').next()?,
    };
    (!host.is_empty()).then(|| host.trim_end_matches('.').to_ascii_lowercase())
}

/// The name and URL of the peer whose URL points at `node`, by MagicDNS name,
/// short name, host name or tailnet IP.
fn peer_for(node: &Node, peers: &[Value]) -> Option<(String, String)> {
    let mut names = vec![node.dns_name.clone(), node.short_name(), node.host_name.clone()];
    names.extend(node.ips.iter().map(ToString::to_string));
    let names: Vec<String> =
        names.into_iter().filter(|n| !n.is_empty()).map(|n| n.to_ascii_lowercase()).collect();
    peers.iter().find_map(|p| {
        let url = p.get("url").and_then(Value::as_str)?;
        let target = crate::peer::ssh_target(url).ok()?;
        let host = url_host(url)?;
        names.contains(&host).then(|| {
            let canonical = if target.port == crate::peer::SSH_PEER_PORT {
                format!("ssh://{}", target.destination)
            } else {
                format!("ssh://{}:{}", target.destination, target.port)
            };
            (p.get("name").and_then(Value::as_str).unwrap_or("").to_owned(), canonical)
        })
    })
}

/// Whether `node` is the user's own: the login of this machine, untagged
/// and not shared in from another tailnet.
fn mine(node: &Node, this: &Node) -> bool {
    !node.tagged() && !node.shared && node.login.is_some() && node.login == this.login
}

/// A safe, deterministic recommendation for the Add Machine card. The
/// recommendation is advisory: enrollment still requires an explicit user
/// action. We only suggest the user's own online machines and never an
/// already-connected peer or a failed SSH probe.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Recommendation {
    pub name: String,
    pub host: String,
    pub reason: String,
    pub needs_probe: bool,
}

pub(crate) fn recommend(list: &[Candidate]) -> Option<Recommendation> {
    let mut choices: Vec<&Candidate> = list
        .iter()
        .filter(|c| c.mine && c.online && !c.already_peer && c.ssh_ok != Some(false))
        .collect();
    choices.sort_by(|a, b| {
        let rank = |c: &Candidate| match c.ssh_ok {
            Some(true) => 0,
            None => 1,
            Some(false) => 2,
        };
        rank(a).cmp(&rank(b)).then_with(|| a.name.cmp(&b.name))
    });
    let c = choices.first()?;
    let host = if c.dns_name.is_empty() { c.ip.clone()? } else { c.dns_name.clone() };
    let (reason, needs_probe) = match c.ssh_ok {
        Some(true) => ("online, owned, and key-only SSH succeeded".to_owned(), false),
        None => ("online and owned; run the key-only SSH check before enrolling".to_owned(), true),
        Some(false) => unreachable!("failed probes are filtered above"),
    };
    Some(Recommendation { name: c.name.clone(), host, reason, needs_probe })
}

pub(crate) fn candidates(status: &Status, peers: &[Value]) -> Vec<Candidate> {
    status
        .peers
        .iter()
        .map(|node| {
            let (peer, peer_url) = peer_for(node, peers).unzip();
            Candidate {
                name: node.short_name(),
                dns_name: node.dns_name.clone(),
                ip: node.dial_ip().map(|ip| ip.to_string()),
                os: node.os.clone(),
                online: node.online,
                mine: mine(node, &status.this),
                already_peer: peer.is_some(),
                peer,
                peer_url,
                ssh_ok: None,
            }
        })
        .collect()
}

/// `ssh -o BatchMode=yes -o ConnectTimeout=5 -- TARGET true`.
pub(crate) fn probe_argv(target: &str) -> Result<Vec<String>> {
    let target = checked_host(target)?;
    Ok(["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", target, "true"]
        .iter()
        .map(|s| s.to_string())
        .collect())
}

/// Try ssh to the user's own online candidates (at most [`MAX_PROBES`]),
/// [`PROBES_AT_ONCE`] at a time.
pub(crate) fn probe_all(list: &mut [Candidate], ssh: &(impl Fn(&[String]) -> Ran + Sync)) {
    let targets: Vec<(usize, Vec<String>)> = list
        .iter()
        .enumerate()
        .filter(|(_, c)| c.online && c.mine)
        .filter_map(|(i, c)| {
            let target = if c.dns_name.is_empty() { c.ip.clone()? } else { c.dns_name.clone() };
            Some((i, probe_argv(&target).ok()?))
        })
        .take(MAX_PROBES)
        .collect();
    let next = AtomicUsize::new(0);
    let results: Vec<(usize, bool)> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..PROBES_AT_ONCE.min(targets.len()))
            .map(|_| {
                scope.spawn(|| {
                    let mut done = Vec::new();
                    while let Some((i, argv)) = targets.get(next.fetch_add(1, Ordering::SeqCst)) {
                        done.push((*i, ssh(argv).ok));
                    }
                    done
                })
            })
            .collect();
        workers.into_iter().flat_map(|w| w.join().unwrap_or_default()).collect()
    });
    for &(i, _) in &targets {
        list[i].ssh_ok = Some(false);
    }
    for (i, ok) in results {
        list[i].ssh_ok = Some(ok);
    }
}

pub(crate) async fn list_with(
    io: &(impl Io + Sync),
    probe: bool,
) -> Result<(String, Vec<Candidate>)> {
    let status = io.tailscale()?;
    let reply = io.rpc("_acpmux/peers", json!({})).await?;
    let peers = reply.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut list = candidates(&status, &peers);
    if probe {
        probe_all(&mut list, &|argv| io.ssh(argv));
    }
    Ok((status.backend_state, list))
}

pub(crate) async fn run(client: &Client, probe: bool, json_out: bool) -> Result<()> {
    crate::cli::host_enroll::lead_process_group_if_asked();
    let (tailnet, list) = list_with(&Live(Some(client)), probe).await?;
    let recommendation = recommend(&list);
    if json_out {
        print_json(&json!({"tailnet": tailnet, "candidates": list, "recommended": recommendation}));
        return Ok(());
    }
    if let Some(r) = &recommendation {
        println!(
            "recommended {} ({}){}",
            r.name,
            r.host,
            if r.needs_probe { " — probe before adding" } else { "" }
        );
    }
    if list.is_empty() {
        println!("no other machines on the tailnet ({tailnet})");
    }
    for c in &list {
        println!(
            "{:<20} {:<40} {:<16} {:<8} {:<8} {}{}",
            c.name,
            c.dns_name,
            c.ip.as_deref().unwrap_or("-"),
            c.os,
            if c.online { "online" } else { "offline" },
            c.peer.as_deref().map(|p| format!("peer {p}")).unwrap_or_default(),
            match c.ssh_ok {
                Some(true) => "  ssh ok",
                Some(false) => "  no ssh",
                None => "",
            },
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tailnet::parse_status;

    const STATUS: &str = r#"{
      "BackendState": "Running",
      "User": {"1": {"ID": 1, "LoginName": "leo@example.com"}, "2": {"ID": 2, "LoginName": "sam@example.com"}},
      "Self": {"HostName": "cosmic", "DNSName": "cosmic-gray.tail9.ts.net.", "OS": "macOS",
               "TailscaleIPs": ["100.64.0.1"], "Online": true, "UserID": 1},
      "Peer": {
        "nodekey:a": {"HostName": "huge-blue", "DNSName": "huge-blue.tail9.ts.net.", "OS": "macOS",
                      "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"], "Online": true, "UserID": 1},
        "nodekey:b": {"HostName": "box", "DNSName": "", "OS": "linux",
                      "TailscaleIPs": ["fd7a:115c:a1e0::3", "100.64.0.3"], "Online": true, "UserID": 1},
        "nodekey:c": {"HostName": "phone", "DNSName": "phone.tail9.ts.net.", "OS": "iOS",
                      "TailscaleIPs": ["100.64.0.4"], "Online": false, "UserID": 1}
      }
    }"#;

    /// Online machines that are not the user's: a tagged server, a
    /// teammate's, one shared in from another tailnet.
    const OTHERS: &str = r#"{
      "BackendState": "Running",
      "User": {"1": {"ID": 1, "LoginName": "leo@example.com"}, "2": {"ID": 2, "LoginName": "sam@example.com"}},
      "Self": {"HostName": "cosmic", "DNSName": "cosmic-gray.tail9.ts.net.", "OS": "macOS",
               "TailscaleIPs": ["100.64.0.1"], "Online": true, "UserID": 1},
      "Peer": {
        "nodekey:t": {"HostName": "ci", "DNSName": "ci.tail9.ts.net.", "OS": "linux", "Tags": ["tag:ci"],
                      "TailscaleIPs": ["100.64.0.5"], "Online": true, "UserID": 1},
        "nodekey:u": {"HostName": "sams-mac", "DNSName": "sams-mac.tail9.ts.net.", "OS": "macOS",
                      "TailscaleIPs": ["100.64.0.6"], "Online": true, "UserID": 2},
        "nodekey:v": {"HostName": "shared", "DNSName": "shared.other.ts.net.", "OS": "linux",
                      "TailscaleIPs": ["100.64.0.7"], "Online": true, "UserID": 1, "ShareeNode": true}
      }
    }"#;

    fn status() -> Status {
        parse_status(STATUS.as_bytes()).unwrap()
    }

    #[test]
    fn tailscale_status_becomes_candidates() {
        let list = candidates(&status(), &[]);
        let names: Vec<&str> = list.iter().map(|c| c.name.as_str()).collect();
        // Sorted by MagicDNS name; a node without one is named by its host name.
        assert_eq!(names, ["box", "huge-blue", "phone"]);
        assert_eq!(list[0].ip.as_deref(), Some("100.64.0.3"), "IPv4 first");
        assert_eq!(list[1].dns_name, "huge-blue.tail9.ts.net");
        assert_eq!(list[1].os, "macOS");
        assert!(!list[2].online);
        assert!(list.iter().all(|c| !c.already_peer && c.ssh_ok.is_none()));
        let line = serde_json::to_value(&list[1]).unwrap();
        assert_eq!(line["already_peer"], false);
        assert!(line.get("ssh_ok").is_none());
    }

    #[test]
    fn already_peer_matches_any_name_or_address_in_a_peer_url() {
        let peers = [
            json!({"name": "hb", "url": "ssh://leo@HUGE-BLUE.tail9.ts.net"}),
            json!({"name": "b", "url": "ssh://100.64.0.3:47812"}),
            json!({"name": "sandbox", "url": "ws://10.0.0.9:47811"}),
        ];
        let list = candidates(&status(), &peers);
        assert_eq!(list[0].peer.as_deref(), Some("b"));
        assert_eq!(list[1].peer.as_deref(), Some("hb"));
        assert!(list[1].already_peer);
        assert_eq!(list[0].peer_url.as_deref(), Some("ssh://100.64.0.3:47812"));
        let line = serde_json::to_value(&list[0]).unwrap();
        assert_eq!(line["peer_url"], "ssh://100.64.0.3:47812");
        assert_eq!(list[2].peer, None);
        assert!(serde_json::to_value(&list[2]).unwrap().get("peer_url").is_none());
        // Only ssh peers can use the Add Machine peer path; websocket URLs stay out of the
        // already-peer marker and never carry arbitrary query text into candidate JSON.
        let list = candidates(
            &status(),
            &[
                json!({"name": "web", "url": "ws://huge-blue.tail9.ts.net:47811?token=secret"}),
                json!({"name": "bad", "url": "ssh://huge-blue.tail9.ts.net:47812?token=secret"}),
            ],
        );
        assert!(!list[1].already_peer && list[1].peer_url.is_none());
        // A short-name peer URL matches too.
        let list = candidates(&status(), &[json!({"name": "p", "url": "ssh://phone"})]);
        assert_eq!(list[2].peer.as_deref(), Some("p"));
    }

    #[test]
    fn recommendation_is_owned_online_and_deterministic() {
        let mut list = candidates(&status(), &[]);
        assert_eq!(recommend(&list).unwrap().name, "box");
        assert!(recommend(&list).unwrap().needs_probe);
        list[0].ssh_ok = Some(false);
        list[1].ssh_ok = Some(true);
        let picked = recommend(&list).unwrap();
        assert_eq!(picked.name, "cloud-box");
        assert_eq!(picked.host, "cloud-box.tail9.ts.net");
        assert!(!picked.needs_probe);
        list[1].already_peer = true;
        assert!(recommend(&list).is_none());
    }

    #[test]
    fn url_hosts() {
        assert_eq!(url_host("ssh://u@Host.ts.net.:22").as_deref(), Some("host.ts.net"));
        assert_eq!(url_host("wss://[fd7a::1]:47811/x").as_deref(), Some("fd7a::1"));
        assert_eq!(url_host("ssh://"), None);
        assert_eq!(url_host("nonsense"), None);
    }

    #[test]
    fn probe_runs_for_online_machines_only() {
        let mut list = candidates(&status(), &[]);
        let seen = std::sync::Mutex::new(Vec::new());
        probe_all(&mut list, &|argv: &[String]| {
            seen.lock().unwrap().push(argv.to_vec());
            Ran { ok: argv.iter().any(|a| a == "huge-blue.tail9.ts.net"), ..Ran::default() }
        });
        let mut seen = seen.into_inner().unwrap();
        seen.sort();
        assert_eq!(
            seen,
            [probe_argv("100.64.0.3").unwrap(), probe_argv("huge-blue.tail9.ts.net").unwrap()]
        );
        assert_eq!(
            list.iter().map(|c| c.ssh_ok).collect::<Vec<_>>(),
            [Some(false), Some(true), None]
        );
        assert_eq!(
            probe_argv("huge-blue").unwrap(),
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", "huge-blue", "true"]
        );
        assert!(probe_argv("-oProxyCommand=x").is_err());
    }

    #[test]
    fn only_the_users_own_machines_are_probed_and_at_most_max() {
        let others = parse_status(OTHERS.as_bytes()).unwrap();
        let mut list = candidates(&others, &[]);
        assert!(list.iter().all(|c| c.online && !c.mine), "{list:?}");
        probe_all(&mut list, &|argv: &[String]| panic!("probed {argv:?}"));
        assert!(list.iter().all(|c| c.ssh_ok.is_none()), "unprobed, still listed");

        // Many own machines: the first MAX_PROBES are tried, the rest stay unprobed.
        let one = candidates(&status(), &[]).remove(1);
        let mut many: Vec<Candidate> = (0..MAX_PROBES + 5)
            .map(|i| Candidate { dns_name: format!("m{i}.tail9.ts.net"), ..one.clone() })
            .collect();
        let tried = AtomicUsize::new(0);
        probe_all(&mut many, &|_: &[String]| {
            tried.fetch_add(1, Ordering::SeqCst);
            Ran { ok: true, ..Ran::default() }
        });
        assert_eq!(tried.load(Ordering::SeqCst), MAX_PROBES);
        assert!(many[..MAX_PROBES].iter().all(|c| c.ssh_ok == Some(true)));
        assert!(many[MAX_PROBES..].iter().all(|c| c.ssh_ok.is_none()));
    }
}
