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
    assert_eq!(list.iter().map(|c| c.ssh_ok).collect::<Vec<_>>(), [Some(false), Some(true), None]);
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
