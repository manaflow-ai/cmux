//! The peer, peer-back and identity steps (cli/host_peering.rs) against a
//! fake local daemon and a fake remote: what each reports, and that a check
//! without `fix` changes nothing.

use super::*;
use std::cell::RefCell;

const TAILNET: &str = r#"{
  "BackendState": "Running",
  "Self": {"HostName": "cosmic", "DNSName": "cosmic-gray.tail9.ts.net.", "OS": "macOS",
           "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"], "Online": true},
  "Peer": {}
}"#;

/// The local daemon's peers and a scripted remote, recording every call.
struct Fake {
    peers: RefCell<Vec<Value>>,
    /// Whether a peer the local daemon adds or reconnects connects.
    local_connects: bool,
    tailnet: Option<&'static str>,
    user: Option<&'static str>,
    /// The remote's peers (`daemon status`); `None`: no daemon runs there.
    remote_peers: RefCell<Option<Vec<Value>>>,
    /// The remote's ssh here: `Ok` or its stderr.
    back: Result<(), &'static str>,
    /// Whether a peer the remote adds connects.
    remote_connects: bool,
    rpcs: RefCell<Vec<String>>,
    scripts: RefCell<Vec<Vec<String>>>,
}

impl Default for Fake {
    fn default() -> Self {
        Self {
            peers: RefCell::new(Vec::new()),
            local_connects: true,
            tailnet: Some(TAILNET),
            user: Some("leo"),
            remote_peers: RefCell::new(Some(Vec::new())),
            back: Ok(()),
            remote_connects: true,
            rpcs: RefCell::new(Vec::new()),
            scripts: RefCell::new(Vec::new()),
        }
    }
}

fn ran(ok: bool, stdout: impl Into<String>, stderr: &str) -> Ran {
    Ran { ok, stdout: stdout.into(), stderr: stderr.into() }
}

impl Io for Fake {
    async fn rpc(&self, method: &str, params: Value) -> Result<Value> {
        self.rpcs.borrow_mut().push(method.to_owned());
        let name = params.get("name").and_then(Value::as_str).unwrap_or("").to_owned();
        let mut peers = self.peers.borrow_mut();
        match method {
            "_acpmux/peers" => {}
            "_acpmux/peer_add" => {
                peers.retain(|p| p["name"] != name);
                peers.push(json!({"name": name, "url": params["url"], "connected": self.local_connects, "error": (!self.local_connects).then_some("ssh: no route")}));
            }
            "_acpmux/peer_reconnect" => {
                for p in peers.iter_mut().filter(|p| p["name"] == name) {
                    p["connected"] = json!(self.local_connects);
                }
            }
            other => return Err(anyhow!("unexpected rpc {other}")),
        }
        Ok(json!({"peers": *peers}))
    }

    fn ssh(&self, argv: &[String]) -> Ran {
        self.scripts.borrow_mut().push(argv.to_vec());
        let command = argv.last().map(String::as_str).unwrap_or("");
        let unwrapped = crate::cli::hosts::script_of(command);
        let script = unwrapped.as_deref().unwrap_or(command);
        if script.contains(BACK_OK) {
            match self.back {
                Ok(()) => ran(true, BACK_OK, ""),
                Err(stderr) => ran(true, BACK_FAILED, stderr),
            }
        } else if script.ends_with("--json daemon status") {
            match &*self.remote_peers.borrow() {
                Some(peers) => ran(true, json!({"running": true, "peers": peers}).to_string(), ""),
                None => ran(true, json!({"running": false, "error": "no daemon"}).to_string(), ""),
            }
        } else if script.contains("--json host add") {
            let mut remote = self.remote_peers.borrow_mut();
            let peers = remote.get_or_insert_with(Vec::new);
            // `host add 'NAME' 'URL'`
            let quoted: Vec<&str> =
                script.rsplit("host add ").next().unwrap_or("").split('\'').collect();
            peers.push(
                json!({"name": quoted[1], "url": quoted[3], "connected": self.remote_connects}),
            );
            ran(true, json!({"peers": peers}).to_string(), "")
        } else {
            ran(false, "", "unexpected script")
        }
    }

    fn tailscale(&self) -> Result<tailnet::Status> {
        match self.tailnet {
            Some(raw) => tailnet::parse_status(raw.as_bytes()),
            None => Err(anyhow!("Tailscale is not installed")),
        }
    }

    fn user(&self) -> Option<String> {
        self.user.map(str::to_owned)
    }
}

impl Fake {
    fn mutated_here(&self) -> bool {
        self.rpcs.borrow().iter().any(|m| m != "_acpmux/peers")
    }

    fn mutated_there(&self) -> bool {
        self.scripts.borrow().iter().any(|argv| {
            argv.last()
                .and_then(|s| crate::cli::hosts::script_of(s))
                .is_some_and(|s| s.contains("host add"))
        })
    }
}

fn target<'a>(dest: Option<&'a str>) -> PeerTarget<'a> {
    PeerTarget {
        name: "hb",
        host: "huge-blue",
        port: crate::peer::SSH_PEER_PORT,
        local_name: "cosmic",
        local_dest: dest,
    }
}

#[test]
fn names_and_destinations_refuse_option_like_values() {
    for bad in ["-oProxyCommand=x", "a b", "a;b", "", "host:22", "u@-x", "a'b"] {
        assert!(checked_host(bad).is_err(), "{bad}");
        assert!(probe_argv("huge-blue", bad).is_err(), "{bad}");
    }
    assert!(probe_argv("-F/tmp/x", "leo@cosmic").is_err());
    for bad in ["-x", "", "a b", "a'b", "a/b", "n".repeat(65).as_str()] {
        assert!(checked_name(bad).is_err(), "{bad}");
        assert!(remote_add_script(bad, "leo@cosmic").is_err(), "{bad}");
    }
    assert!(remote_add_script("cosmic", "-oProxyCommand=x").is_err());
    assert_eq!(checked_name("cosmic-gray.1_a"), Ok("cosmic-gray.1_a"));
}

#[test]
fn the_probe_is_a_fixed_script_with_the_destination_quoted() {
    let argv = probe_argv("huge-blue", "leo@cosmic-gray.tail9.ts.net").unwrap();
    assert_eq!(&argv[..5], ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--"]);
    assert_eq!(argv[5], "huge-blue");
    assert_eq!(
        crate::cli::hosts::script_of(&argv[6]).unwrap(),
        format!(
            "if ssh -o BatchMode=yes -o ConnectTimeout=8 -- 'leo@cosmic-gray.tail9.ts.net' true </dev/null; then echo {BACK_OK}; else echo {BACK_FAILED}; fi"
        )
    );
    assert_eq!(argv.len(), 7);
    let add = remote_add_script("cosmic", "leo@100.64.0.1").unwrap();
    assert!(add.starts_with(REMOTE_CLI));
    assert!(add.ends_with("\"$@\" --json host add 'cosmic' 'ssh://leo@100.64.0.1'"));
}

#[test]
fn the_local_destination_comes_only_from_the_tailnet() {
    let fake = Fake::default();
    let ts = running_tailnet(&fake);
    assert_eq!(local_dest(&fake, ts.as_ref()).as_deref(), Some("leo@cosmic-gray.tail9.ts.net"));
    assert!(fake.scripts.borrow().is_empty(), "the tailnet answers without ssh");

    // A tailnet that is not running is not used, and nothing else is guessed.
    let stopped = TAILNET.replace("\"Running\"", "\"Stopped\"");
    let stopped: &'static str = Box::leak(stopped.into_boxed_str());
    let fake = Fake { tailnet: Some(stopped), ..Fake::default() };
    let ts = running_tailnet(&fake);
    assert!(ts.is_none());
    assert_eq!(local_dest(&fake, None), None);
    assert!(fake.scripts.borrow().is_empty(), "no $SSH_CONNECTION guess");

    // No user: the bare name; a user name that is not plain is left out.
    let fake = Fake { user: None, ..Fake::default() };
    let ts = running_tailnet(&fake);
    assert_eq!(local_dest(&fake, ts.as_ref()).as_deref(), Some("cosmic-gray.tail9.ts.net"));
    let fake = Fake { user: Some("-oX"), ..Fake::default() };
    let ts = running_tailnet(&fake);
    assert_eq!(local_dest(&fake, ts.as_ref()).as_deref(), Some("cosmic-gray.tail9.ts.net"));
}

#[tokio::test]
async fn peer_back_without_a_tailnet_warns_instead_of_guessing() {
    let fake = Fake { tailnet: None, ..Fake::default() };
    let r = peer_back_with(&fake, &target(None), true).await;
    assert_eq!(r.state, StepState::Warn, "{}", r.detail);
    assert!(r.detail.contains("no tailnet name"), "{}", r.detail);
    assert!(fake.scripts.borrow().is_empty(), "nothing runs on the host");
}

#[tokio::test]
async fn peer_back_matches_an_existing_peer_by_its_url_host() {
    // Listed under another name at this machine's short host name.
    for url in ["ssh://leo@cosmic", "ssh://cosmic-gray", "ssh://COSMIC-GRAY.tail9.ts.net:47812"] {
        let fake = Fake::default();
        *fake.remote_peers.borrow_mut() =
            Some(vec![json!({"name": "cg", "url": url, "connected": true})]);
        let r = peer_back_with(&fake, &target(None), true).await;
        assert_eq!(r.state, StepState::Ok, "{url}: {}", r.detail);
        assert!(!fake.mutated_there(), "{url}: no second peer for the same machine");
    }
    // A dotted name elsewhere is another machine, even with this one's
    // short name as its first label.
    for url in ["ssh://cosmic.other.net", "ssh://cosmic-gray.local"] {
        let fake = Fake::default();
        *fake.remote_peers.borrow_mut() =
            Some(vec![json!({"name": "cg", "url": url, "connected": true})]);
        let r = peer_back_with(&fake, &target(None), true).await;
        assert_eq!(r.state, StepState::Fixed, "{url}: {}", r.detail);
        assert!(fake.mutated_there(), "{url}: this machine is added");
    }
}

#[tokio::test]
async fn peer_adds_only_with_fix_and_then_connects() {
    let fake = Fake::default();
    let r = peer_with(&fake, &target(None), false).await;
    assert_eq!(r.state, StepState::Fail);
    assert!(r.fix.as_deref().unwrap_or("").contains("--fix"));
    assert!(!fake.mutated_here());

    let r = peer_with(&fake, &target(None), true).await;
    assert_eq!(
        (r.state, r.detail.as_str()),
        (StepState::Fixed, "hb at ssh://huge-blue, connected")
    );
    let r = peer_with(&fake, &target(None), false).await;
    assert_eq!(r.state, StepState::Ok);
}

#[tokio::test]
async fn peer_reports_a_peer_that_does_not_connect() {
    let fake = Fake { local_connects: false, ..Fake::default() };
    let r = peer_with(&fake, &target(None), true).await;
    assert_eq!(r.state, StepState::Fail);
    assert!(r.detail.contains("does not connect (ssh: no route)"), "{}", r.detail);
    // An offline peer: reconnected only with fix.
    let fake = Fake::default();
    fake.peers
        .borrow_mut()
        .push(json!({"name": "hb", "url": "ssh://huge-blue", "connected": false}));
    assert_eq!(peer_with(&fake, &target(None), false).await.state, StepState::Fail);
    assert!(!fake.mutated_here());
    assert_eq!(peer_with(&fake, &target(None), true).await.state, StepState::Fixed);
}

#[tokio::test]
async fn peer_never_overwrites_a_name_taken_by_another_url() {
    let fake = Fake::default();
    fake.peers
        .borrow_mut()
        .push(json!({"name": "hb", "url": "ssh://other-box", "connected": true}));
    for fix in [false, true] {
        let r = peer_with(&fake, &target(None), fix).await;
        assert_eq!(r.state, StepState::Fail);
        assert!(r.detail.contains("already the peer at ssh://other-box"), "{}", r.detail);
        assert!(r.fix.as_deref().unwrap_or("").contains("host rm hb"));
    }
    assert!(!fake.mutated_here());
    // The same destination spelled with the default port is the same peer.
    let fake = Fake::default();
    fake.peers
        .borrow_mut()
        .push(json!({"name": "hb", "url": "ssh://huge-blue:47811", "connected": true}));
    assert_eq!(peer_with(&fake, &target(None), false).await.state, StepState::Ok);
}

#[tokio::test]
async fn peer_back_adds_this_machine_only_with_fix() {
    let fake = Fake::default();
    let r = peer_back_with(&fake, &target(None), false).await;
    assert_eq!(r.state, StepState::Fail, "{}", r.detail);
    assert_eq!(r.detail, "huge-blue does not list this machine");
    assert!(!fake.mutated_there() && !fake.mutated_here());

    let r = peer_back_with(&fake, &target(None), true).await;
    assert_eq!(r.state, StepState::Fixed, "{}", r.detail);
    assert_eq!(
        r.detail,
        "huge-blue lists this machine as cosmic at ssh://leo@cosmic-gray.tail9.ts.net, connected"
    );
    // Now listed: a check passes and adds nothing more.
    fake.scripts.borrow_mut().clear();
    let r = peer_back_with(&fake, &target(None), true).await;
    assert_eq!(r.state, StepState::Ok, "{}", r.detail);
    assert!(!fake.mutated_there());
}

#[tokio::test]
async fn peer_back_accepts_any_address_of_this_machine() {
    let fake = Fake::default();
    *fake.remote_peers.borrow_mut() =
        Some(vec![json!({"name": "cg", "url": "ssh://leo@100.64.0.1", "connected": true})]);
    let r = peer_back_with(&fake, &target(None), true).await;
    assert_eq!(r.state, StepState::Ok, "{}", r.detail);
    assert!(r.detail.contains("as cg at ssh://leo@100.64.0.1"));
    assert!(!fake.mutated_there(), "no second peer for the same machine");
}

#[tokio::test]
async fn peer_back_never_overwrites_a_name_taken_there() {
    let fake = Fake::default();
    *fake.remote_peers.borrow_mut() =
        Some(vec![json!({"name": "cosmic", "url": "ssh://somewhere-else", "connected": true})]);
    for fix in [false, true] {
        let r = peer_back_with(&fake, &target(None), fix).await;
        assert_eq!(r.state, StepState::Fail);
        assert!(r.detail.contains("already has a peer named cosmic at ssh://somewhere-else"));
        assert!(r.fix.as_deref().unwrap_or("").contains("host rm cosmic"));
    }
    assert!(!fake.mutated_there());
}

#[tokio::test]
async fn peer_back_warns_when_the_remote_cannot_ssh_here() {
    let cases = [
        ("leo@cosmic: Permission denied (publickey).", "key rejected", "authorized_keys"),
        // OpenSSH wrappers and remote shells can lowercase diagnostics; the
        // classifier should retain the same actionable setup guidance.
        ("leo@cosmic: permission denied (publickey).", "key rejected", "authorized_keys"),
        ("ssh: connect to host cosmic port 22: Operation timed out", "no route", "tailnet ACL"),
        (
            "ssh: Could not resolve hostname cosmic: nodename nor servname",
            "no route",
            "tailnet ACL",
        ),
        ("Host key verification failed.", "host key is not trusted", "accept"),
        ("REMOTE HOST IDENTIFICATION HAS CHANGED!", "host key is not trusted", "accept"),
        ("ssh: connect to host cosmic port 22: Connection refused", "ssh is off", "Remote Login"),
        ("ssh: connect to host cosmic port 22: connection refused", "ssh is off", "Remote Login"),
    ];
    for (stderr, why, fix) in cases {
        let fake = Fake { back: Err(stderr), ..Fake::default() };
        let r = peer_back_with(&fake, &target(Some("leo@cosmic")), true).await;
        assert_eq!(r.state, StepState::Warn, "{stderr}");
        assert!(r.detail.contains(why), "{stderr}: {}", r.detail);
        assert!(r.fix.as_deref().unwrap_or("").contains(fix), "{stderr}: {:?}", r.fix);
        assert!(!fake.mutated_there(), "nothing is added when it cannot ssh back");
    }
}

#[tokio::test]
async fn peer_back_needs_the_remote_daemon_and_a_plain_name() {
    let fake = Fake::default();
    *fake.remote_peers.borrow_mut() = None;
    let r = peer_back_with(&fake, &target(None), true).await;
    assert_eq!(r.state, StepState::Fail);
    assert!(r.detail.contains("daemon is not running"), "{}", r.detail);
    let bad = PeerTarget { local_name: "-x", ..target(None) };
    assert_eq!(peer_back_with(&fake, &bad, true).await.state, StepState::Fail);
    let bad = target(Some("-oProxyCommand=x"));
    assert_eq!(peer_back_with(&fake, &bad, true).await.state, StepState::Fail);
    assert!(!fake.mutated_there());
}

#[tokio::test]
async fn identity_passes_a_connected_peer_by_name() {
    let fake = Fake::default();
    assert_eq!(identity_with(&fake, &target(None)).await.state, StepState::Fail);
    fake.peers
        .borrow_mut()
        .push(json!({"name": "hb", "url": "ssh://huge-blue", "connected": true}));
    let r = identity_with(&fake, &target(None)).await;
    assert_eq!((r.state, r.detail.as_str()), (StepState::Ok, "name hb (app sets icon)"));
    assert!(!fake.mutated_here());
}

#[tokio::test]
async fn a_peer_on_another_port_passes_peer_and_identity_and_fix_adds_it_with_its_port() {
    // A peer `host setup --port 47900` made: doctor finds it by name.
    let fake = Fake::default();
    fake.peers
        .borrow_mut()
        .push(json!({"name": "hb", "url": "ssh://huge-blue:47900", "connected": true}));
    let t = PeerTarget { port: 47900, ..target(None) };
    let r = peer_with(&fake, &t, true).await;
    assert_eq!(
        (r.state, r.detail.as_str()),
        (StepState::Ok, "hb at ssh://huge-blue:47900, connected")
    );
    assert_eq!(identity_with(&fake, &t).await.state, StepState::Ok);
    assert!(!fake.mutated_here());
    // The default port's target sees that peer as another url.
    assert_eq!(peer_with(&fake, &target(None), true).await.state, StepState::Fail);

    // Missing: --fix adds it at its port, and it then passes.
    let fake = Fake::default();
    let r = peer_with(&fake, &t, true).await;
    assert_eq!(
        (r.state, r.detail.as_str()),
        (StepState::Fixed, "hb at ssh://huge-blue:47900, connected")
    );
    assert_eq!(fake.peers.borrow()[0]["url"], "ssh://huge-blue:47900");
    assert_eq!(peer_with(&fake, &t, false).await.state, StepState::Ok);
    assert_eq!(identity_with(&fake, &t).await.state, StepState::Ok);
}
