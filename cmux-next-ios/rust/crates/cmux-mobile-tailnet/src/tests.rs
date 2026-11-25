use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use cmux_tailnet_join::Secret;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::Mode;
use crate::connect::{PhoneNode, RelayDial, Stream, connect};
use crate::key::{
    Advice, KeyKind, KeyStore, KeychainItem, PhoneTailnet, key_advice, keychain_item, tailnet_account,
};
use crate::route::{NodeState, PeerPath, RelayReason, Route, RouteTracker, route_for};

fn peer(online: bool, direct: bool) -> PeerPath {
    PeerPath { addr: "100.64.0.2".into(), online, direct }
}

#[test]
fn mode_reads_the_setting_and_unknown_is_off() {
    assert_eq!(Mode::default(), Mode::Off);
    for (text, mode) in [
        ("off", Mode::Off),
        ("direct-only", Mode::DirectOnly),
        ("on", Mode::On),
        ("relayed-too", Mode::Off),
        ("", Mode::Off),
    ] {
        assert_eq!(Mode::from_setting(text), mode, "{text}");
    }
    for mode in [Mode::Off, Mode::DirectOnly, Mode::On] {
        assert_eq!(Mode::from_setting(mode.as_setting()), mode);
        let json = serde_json::to_string(&mode).unwrap();
        assert_eq!(json, format!("\"{}\"", mode.as_setting()));
    }
    assert!(!Mode::Off.runs_node());
}

#[test]
fn route_is_the_tailnet_only_when_running_and_direct() {
    let direct = peer(true, true);
    for mode in [Mode::DirectOnly, Mode::On] {
        assert_eq!(
            route_for(mode, NodeState::Running, Some(&direct)),
            Route::Tailnet { addr: "100.64.0.2".into() }
        );
    }
    let cases = [
        (Mode::Off, NodeState::Running, Some(direct.clone()), RelayReason::SettingOff),
        (Mode::On, NodeState::Stopped, Some(direct.clone()), RelayReason::NodeStopped),
        (Mode::On, NodeState::Starting, Some(direct.clone()), RelayReason::NodeStarting),
        (Mode::On, NodeState::NeedsLogin, Some(direct), RelayReason::NeedsLogin),
        (Mode::On, NodeState::Running, None, RelayReason::PeerNotOnTailnet),
        (Mode::On, NodeState::Running, Some(peer(false, true)), RelayReason::PeerOffline),
        // DERP or a peer relay: excluded in both modes until measured, like the Mac.
        (Mode::On, NodeState::Running, Some(peer(true, false)), RelayReason::PeerNotDirect),
        (Mode::DirectOnly, NodeState::Running, Some(peer(true, false)), RelayReason::PeerNotDirect),
    ];
    for (mode, state, peer, why) in cases {
        assert_eq!(route_for(mode, state, peer.as_ref()), Route::Relay { why });
    }
}

#[test]
fn tracker_reports_every_change_and_nothing_else() {
    let mut tracker = RouteTracker::default();
    let tailnet = Route::Tailnet { addr: "100.64.0.2".into() };
    let relay = Route::Relay { why: RelayReason::SettingOff };
    let first = tracker.observe(tailnet.clone()).unwrap();
    assert_eq!(first.from, None);
    assert_eq!(first.to_string(), "link: direct over the tailnet (100.64.0.2)");
    assert!(tracker.observe(tailnet.clone()).is_none());
    let moved = tracker.observe(relay.clone()).unwrap();
    assert_eq!(moved.from, Some(tailnet));
    assert_eq!(
        moved.to_string(),
        "link moved from direct over the tailnet (100.64.0.2) to the relay (the Tailscale carrier is off)"
    );
    assert_eq!(tracker.current(), Some(&relay));
}

#[test]
fn route_wire_form_is_versionless_and_tolerant() {
    // A newer peer may add fields; this side still reads the route.
    let route: Route = serde_json::from_str(r#"{"route":"tailnet","addr":"100.64.0.2","rttMs":4}"#).unwrap();
    assert_eq!(route, Route::Tailnet { addr: "100.64.0.2".into() });
    let relay = Route::Relay { why: RelayReason::DialFailed("timeout".into()) };
    let text = serde_json::to_string(&relay).unwrap();
    assert_eq!(serde_json::from_str::<Route>(&text).unwrap(), relay);
}

#[test]
fn keychain_item_is_this_device_only_and_one_per_tailnet() {
    let item = keychain_item(Some("https://HS.example.com:8443/"));
    assert_eq!(item.service, "dev.cmux.tailnet");
    assert_eq!(item.account, "hs.example.com:8443");
    assert_eq!(item.accessible, "kSecAttrAccessibleWhenUnlockedThisDeviceOnly");
    assert!(!item.synchronizable);
    assert_eq!(tailnet_account(None), "tailscale");
    assert_ne!(
        keychain_item(Some("https://a.example")).account,
        keychain_item(Some("https://b.example")).account
    );
}

#[derive(Default)]
struct MemoryStore(HashMap<String, String>);

impl KeyStore for MemoryStore {
    fn save(&mut self, item: &KeychainItem, key: &Secret) -> Result<(), String> {
        self.0.insert(item.account.clone(), key.expose().to_owned());
        Ok(())
    }
    fn load(&self, item: &KeychainItem) -> Result<Option<Secret>, String> {
        Ok(self.0.get(&item.account).map(|k| Secret::new(k.clone())))
    }
    fn delete(&mut self, item: &KeychainItem) -> Result<(), String> {
        self.0.remove(&item.account);
        Ok(())
    }
}

fn headscale(allow_http: bool) -> PhoneTailnet {
    PhoneTailnet {
        control_url: Some(if allow_http { "http://hs.lan:8080" } else { "https://hs.example" }.into()),
        hostname: Some("iphone".into()),
        ephemeral: true,
        allow_http,
    }
}

#[test]
fn a_key_is_checked_before_it_is_stored_and_forget_deletes_it() {
    let mut store = MemoryStore::default();
    let tailnet = headscale(false);
    let checked = tailnet.save_key(&mut store, Secret::new("hskey-abc123")).unwrap();
    assert!(checked.request().ephemeral);
    assert_eq!(
        store.load(&tailnet.item()).unwrap().map(|k| k.expose().to_owned()),
        Some("hskey-abc123".into())
    );
    tailnet.forget(&mut store).unwrap();
    assert!(store.load(&tailnet.item()).unwrap().is_none());

    // Plain http only when chosen for this server; a refused key is never stored.
    let mut plain = headscale(true);
    plain.allow_http = false;
    let err = plain.save_key(&mut store, Secret::new("hskey-abc123")).unwrap_err();
    assert!(err.contains("https"), "{err}");
    assert!(store.0.is_empty());
    headscale(true).save_key(&mut store, Secret::new("hskey-abc123")).unwrap();

    // A Tailscale key must look like one.
    let tailscale = PhoneTailnet { control_url: None, hostname: None, ephemeral: true, allow_http: false };
    assert!(tailscale.save_key(&mut store, Secret::new("nope")).is_err());
}

#[test]
fn keys_never_reach_debug_or_json() {
    let checked = headscale(false).request(Secret::new("hskey-very-secret")).unwrap();
    let options = cmux_tailnet_join::embedded_options(&checked);
    assert!(!format!("{checked:?}").contains("very-secret"));
    assert!(!format!("{options:?}").contains("very-secret"));
    assert!(!serde_json::to_string(checked.request()).unwrap().contains("very-secret"));
}

#[test]
fn key_sheet_suggests_ephemeral_single_use_and_warns_on_reusable() {
    let safe = key_advice(KeyKind { reusable: false, ephemeral: true }, &headscale(false));
    assert_eq!(safe.len(), 1);
    assert!(matches!(&safe[0], Advice::Suggest(t) if t.contains("ephemeral, single-use")));
    let risky = key_advice(KeyKind { reusable: true, ephemeral: false }, &headscale(true));
    let warns: Vec<_> =
        risky.iter().filter_map(|a| if let Advice::Warn(t) = a { Some(t.as_str()) } else { None }).collect();
    assert_eq!(warns.len(), 3);
    assert!(warns[0].contains("reusable"));
    assert!(warns[1].contains("not ephemeral"));
    assert!(warns[2].contains("Plain http"));
}

#[test]
fn phone_tailnet_settings_tolerate_unknown_and_missing_fields() {
    let old: PhoneTailnet =
        serde_json::from_str(r#"{"controlUrl":"https://hs.example","hostname":null,"ephemeral":true}"#)
            .unwrap();
    assert!(!old.allow_http);
    let new: PhoneTailnet = serde_json::from_str(
        r#"{"controlUrl":null,"hostname":"p","ephemeral":false,"allowHttp":false,"later":1}"#,
    )
    .unwrap();
    assert_eq!(new.hostname.as_deref(), Some("p"));
}

/// A fake node: its state, its view of the peer, and what its dial does.
struct FakeNode {
    state: NodeState,
    peer: Option<PeerPath>,
    dial: Dial,
    dialed: Mutex<Vec<String>>,
}

#[derive(Clone, Copy)]
enum Dial {
    Ok,
    Fail,
    Hang,
}

impl PhoneNode for FakeNode {
    fn state(&self) -> NodeState {
        self.state
    }
    fn peer(&self, _host: &str) -> Option<PeerPath> {
        self.peer.clone()
    }
    async fn dial(&self, addr: &str, port: u16) -> Result<Stream, String> {
        self.dialed.lock().unwrap().push(format!("{addr}:{port}"));
        match self.dial {
            Dial::Ok => Ok(echo_stream(b"tailnet")),
            Dial::Fail => Err("connection refused".into()),
            Dial::Hang => std::future::pending().await,
        }
    }
}

struct FakeRelay;

impl RelayDial for FakeRelay {
    async fn dial(&self) -> Result<Stream, String> {
        Ok(echo_stream(b"relay"))
    }
}

/// A stream whose far side writes `tag` and closes.
fn echo_stream(tag: &'static [u8]) -> Stream {
    let (near, mut far) = tokio::io::duplex(64);
    tokio::spawn(async move {
        let _ = far.write_all(tag).await;
    });
    Box::new(near)
}

async fn read_tag(mut stream: Stream) -> String {
    let mut out = Vec::new();
    stream.read_to_end(&mut out).await.unwrap();
    String::from_utf8(out).unwrap()
}

fn node(state: NodeState, peer: Option<PeerPath>, dial: Dial) -> FakeNode {
    FakeNode { state, peer, dial, dialed: Mutex::new(Vec::new()) }
}

#[tokio::test]
async fn connect_goes_direct_then_falls_back_visibly() {
    let mut tracker = RouteTracker::default();
    let timeout = Duration::from_millis(200);

    let up = node(NodeState::Running, Some(peer(true, true)), Dial::Ok);
    let link = connect(Mode::On, Some(&up), "mac", 7000, &FakeRelay, &mut tracker, timeout).await.unwrap();
    assert_eq!(link.route, Route::Tailnet { addr: "100.64.0.2".into() });
    assert!(link.change.is_some());
    assert_eq!(read_tag(link.stream).await, "tailnet");
    assert_eq!(*up.dialed.lock().unwrap(), vec!["100.64.0.2:7000".to_owned()]);

    // The person turns the carrier off: the relay, and the change is reported.
    let link = connect(Mode::Off, Some(&up), "mac", 7000, &FakeRelay, &mut tracker, timeout).await.unwrap();
    assert_eq!(link.route, Route::Relay { why: RelayReason::SettingOff });
    assert!(link.change.unwrap().to_string().starts_with("link moved from direct over the tailnet"));
    assert_eq!(read_tag(link.stream).await, "relay");
    assert_eq!(up.dialed.lock().unwrap().len(), 1, "off never dials the node");

    // Same route again: no change event.
    let link = connect(Mode::Off, Some(&up), "mac", 7000, &FakeRelay, &mut tracker, timeout).await.unwrap();
    assert!(link.change.is_none());
}

#[tokio::test]
async fn connect_falls_back_when_the_tailnet_dial_fails_or_hangs() {
    let timeout = Duration::from_millis(100);
    for (dial, expect) in [(Dial::Fail, "connection refused"), (Dial::Hang, "no answer in 100 ms")] {
        let mut tracker = RouteTracker::default();
        let n = node(NodeState::Running, Some(peer(true, true)), dial);
        let link = connect(Mode::DirectOnly, Some(&n), "mac", 7000, &FakeRelay, &mut tracker, timeout)
            .await
            .unwrap();
        assert_eq!(link.route, Route::Relay { why: RelayReason::DialFailed(expect.into()) });
        assert_eq!(read_tag(link.stream).await, "relay");
    }
}

#[tokio::test]
async fn connect_without_a_node_uses_the_relay() {
    let mut tracker = RouteTracker::default();
    let link = connect::<FakeNode, _>(
        Mode::On,
        None,
        "mac",
        7000,
        &FakeRelay,
        &mut tracker,
        Duration::from_millis(100),
    )
    .await
    .unwrap();
    assert_eq!(link.route, Route::Relay { why: RelayReason::NodeStopped });
}
