//! The relay feed (src/relay_feed.rs) end to end: hostd reads its chats through `catch-up`,
//! seals them to the phone's push key on the fake Worker's relay cache, and after the Mac is gone
//! the phone's relay client opens each surface and gets the plaintext a `catch-up` reply carries
//! for it (`cmux-mobile-core` `catch_up::relay`): `workspaces` is the reply's `workspaces`,
//! `chat-list` its `chatList`, `chat/<sessionId>` one `chats` entry with that `sessionId`.
//! A `catch-up` reply then names the heads the phone resumes from. Off publishes nothing.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use cmux_mobile_host::catch_up::answer_args;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::pairing::{DeviceTrust, MacIdentity, Pairing, TrustedDevice};
use cmux_mobile_host::relay_feed::{CHAT_LIST, Feed, FeedTiming, WORKSPACES, chat_surface, enabled_in};
use cmux_mobile_host::relay_publish::{RelayPublishConfig, RelayPublisher, Viewer, viewers};
use cmux_mobile_host::seal::hex;
use cmux_mobile_host::services::Peer;
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::relay_cache::{DEFAULT_BUDGET_BYTES, RelayCache, RelayCacheConfig};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_relay_snapshot::Floor;
use futures_util::{SinkExt, StreamExt};
use p256::SecretKey;
use p256::elliptic_curve::rand_core::OsRng;
use p256::elliptic_curve::sec1::ToEncodedPoint as _;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::Message;

const MAC: &str = "00000000-0000-4000-8000-0000000000aa";
const PHONE: &str = "00000000-0000-4000-8000-0000000000b1";
const S1: &str = "00000000-0000-7000-8000-000000000001";
const S2: &str = "00000000-0000-7000-8000-000000000002";

fn on() -> RelayCacheConfig {
    RelayCacheConfig { enabled: true }
}

fn fake_daemon(dir: &Path) -> tokio::task::JoinHandle<()> {
    let listener = UnixListener::bind(dir.join("main.sock")).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let reply = match request["cmd"].as_str().unwrap() {
                        "list-workspaces" => json!({"id": request["id"], "ok": true, "data": {
                            "revision": "r2",
                            "workspaces": [{"id": "w1", "screens": [{"panes": [{"tabs": [{"id": 7, "title": "shell"}]}]}]}],
                        }}),
                        _ => json!({"id": request["id"], "ok": true}),
                    };
                    let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
                }
            });
        }
    })
}

/// acpmux with two chats; each chat's events run 11..=`latest`. A screenful page is the newest
/// two, a forward page everything after `afterSeq`.
async fn fake_acpmux(latest: Arc<AtomicU64>) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let latest = Arc::clone(&latest);
            tokio::spawn(async move {
                let Ok(socket) = tokio_tungstenite::accept_async(stream).await else { return };
                let (mut sink, mut source) = socket.split();
                while let Some(Ok(Message::Text(text))) = source.next().await {
                    let request: Value = serde_json::from_str(&text).unwrap();
                    let params = &request["params"];
                    let result = match request["method"].as_str().unwrap() {
                        "initialize" => json!({"protocolVersion": 1}),
                        "_acpmux/info" => json!({"sessionId": params["sessionId"]}),
                        "_acpmux/watch" => {
                            json!({"listEpoch": "E", "listSeq": 91, "follow": true, "sessions": [
                                {"sessionId": S1, "title": "one"},
                                {"sessionId": S2, "title": "two"},
                            ]})
                        }
                        "_acpmux/attach" => {
                            let session = params["sessionId"].as_str().unwrap();
                            let last = latest.load(Ordering::SeqCst);
                            let from = if params.get("beforeSeq").is_some_and(|v| !v.is_null()) {
                                last - 1
                            } else {
                                params["afterSeq"].as_u64().unwrap_or(0).max(10) + 1
                            };
                            let events: Vec<Value> = (from..=last)
                                .map(|seq| json!({"seq": seq, "kind": "transcript", "sessionId": session, "msg": {"text": format!("line {seq}")}}))
                                .collect();
                            json!({"session": {"sessionId": session}, "events": events, "hasMore": false,
                                "lastSeq": last, "pageThrough": last})
                        }
                        other => panic!("unexpected {other}"),
                    };
                    let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
                    let _ = sink.send(Message::Text(reply.to_string().into())).await;
                }
            });
        }
    });
    (url, task)
}

fn config(dir: &Path, acpmux_url: String) -> Arc<ServiceConfig> {
    let (_trust, trust) = watch::channel(None::<DeviceTrust>);
    Arc::new(ServiceConfig {
        tui_socket_dir: dir.to_owned(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![],
        acpmux: AcpmuxTarget::Fixed { url: acpmux_url, token: None },
        pairing: Some(Pairing::new(MAC.into(), trust, Arc::new(|_: cmux_mobile_host::control::Event| {}))),
        agent_tab_host: None,
        uploads_dir: dir.join("uploads"),
        chief_socket: None,
        browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
        surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
        viewport_sync: None,
    })
}

fn phone() -> (SecretKey, Vec<Viewer>) {
    let key = SecretKey::random(&mut OsRng);
    let push_keys = cmux_mobile_host::push_keys::PushKeys::memory();
    push_keys.set(PHONE, "identity", &hex(key.public_key().to_encoded_point(false).as_bytes()));
    let mut trust = DeviceTrust::default();
    trust.devices.push(TrustedDevice {
        id: PHONE.into(),
        identity_key: "identity".into(),
        ..TrustedDevice::default()
    });
    let viewers = viewers(&push_keys, &trust);
    assert_eq!(viewers.len(), 1);
    (key, viewers)
}

fn json_of(plaintext: &[u8]) -> Value {
    serde_json::from_slice(plaintext).expect("each relay plaintext is one JSON object")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_phone_reads_the_macs_chats_from_the_relay_after_the_mac_is_gone() {
    let server = FakeSignaling::start(FakeOptions { relay_cache: true, ..FakeOptions::default() }).await;
    let dir = tempfile::tempdir().unwrap();
    let daemon = fake_daemon(dir.path());
    let latest = Arc::new(AtomicU64::new(12));
    let (url, acpmux) = fake_acpmux(Arc::clone(&latest)).await;
    let services = config(dir.path(), url);
    let heads = Arc::clone(&services.pairing.as_ref().unwrap().relay_heads);
    let identity = MacIdentity::generate().unwrap();
    let cache = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), MAC, on());
    let publisher = Arc::new(RelayPublisher::new(
        cache,
        identity.relay_key().clone(),
        7,
        RelayPublishConfig { enabled: true },
    ));
    let source = publisher.source_key();
    let (key, viewers) = phone();
    let timing = FeedTiming::default();
    let mut feed = Feed::new(Arc::clone(&services), None, Arc::clone(&publisher), Arc::clone(&heads));

    // First the list and the tree, then the chats it names.
    let one = feed.flush(&viewers, Instant::now(), &timing).await;
    assert_eq!(one.error, None);
    assert_eq!((one.deltas, one.snapshots, one.refused.as_deref()), (2, 2, None), "{one:?}");
    let two = feed.flush(&viewers, Instant::now(), &timing).await;
    assert_eq!((two.deltas, two.snapshots, two.refused.as_deref()), (2, 2, None), "{two:?}");
    assert!(two.first_screens >= 2);
    let quiet = feed.flush(&viewers, Instant::now(), &timing).await;
    assert_eq!((quiet.deltas, quiet.snapshots), (0, 0), "nothing changed: nothing published");

    // A catch-up reply names where each answered surface stands on the relay.
    let peer = Peer {
        device_id: PHONE.into(),
        session_id: "s".into(),
        video: None,
        session_exposure: None,
        route: None,
        path: None,
        viewport: None,
    };
    let reply = answer_args(&services, &peer, &json!({"v": 1, "chats": [{"sessionId": S1}]})).await.unwrap();
    for surface in [WORKSPACES.to_owned(), CHAT_LIST.to_owned(), chat_surface(S1)] {
        let position = publisher.position(&surface);
        assert_eq!(reply["relay"][&surface], json!({"epoch": 7, "seq": position.seq}), "{surface}: {reply}");
        assert_eq!(position.seq, 1);
    }
    assert!(reply["relay"].get(chat_surface(S2)).is_none(), "only surfaces the reply answered");

    // One more line in S1, then the Mac goes to sleep.
    latest.store(13, Ordering::SeqCst);
    feed.changed(Some(S1));
    let three = feed.flush(&viewers, Instant::now(), &timing).await;
    assert_eq!((three.deltas, three.snapshots), (1, 0), "{three:?}");
    drop(feed);
    daemon.abort();
    acpmux.abort();
    let hits_before = server.relay_cache_hits("snapshot PUT") + server.relay_cache_hits("delta POST");

    let client = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), PHONE, on());
    let mut floor = Floor::default();
    let tree = client.cold_open(MAC, &source, &key, WORKSPACES, &mut floor).await.unwrap().unwrap();
    assert_eq!(json_of(&tree.opened.plaintext)["revision"], "r2");
    let mut floor = Floor::default();
    let list = client.cold_open(MAC, &source, &key, CHAT_LIST, &mut floor).await.unwrap().unwrap();
    let list = json_of(&list.opened.plaintext);
    assert_eq!((list["listEpoch"].clone(), list["listSeq"].clone()), (json!("E"), json!(91)));
    assert_eq!(list["sessions"].as_array().unwrap().len(), 2);

    let chat = chat_surface(S1);
    let mut first = Floor::default();
    let screen = client.cold_open_first_screen(MAC, &source, &key, &chat, &mut first).await.unwrap().unwrap();
    assert_eq!(json_of(&screen.opened.plaintext)["sessionId"], S1);
    let mut floor = Floor::default();
    let opened = client.cold_open(MAC, &source, &key, &chat, &mut floor).await.unwrap().unwrap();
    let page = json_of(&opened.opened.plaintext);
    assert_eq!(page["sessionId"], S1);
    let seqs: Vec<u64> =
        page["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
    assert_eq!(seqs, [11, 12]);
    let mut floors = vec![(chat.clone(), floor)];
    let resumed = client.resume(MAC, &source, &key, &mut floors, DEFAULT_BUDGET_BYTES).await.unwrap();
    let applied: Vec<Value> = resumed.surfaces[0].applied.iter().map(|o| json_of(&o.plaintext)).collect();
    assert_eq!(applied.len(), 1, "the line after the snapshot");
    assert_eq!(applied[0]["sessionId"], S1);
    assert_eq!(applied[0]["events"][0]["seq"], 13);
    assert_eq!(applied[0]["lastSeq"], 13);
    assert_eq!(
        server.relay_cache_hits("snapshot PUT") + server.relay_cache_hits("delta POST"),
        hits_before,
        "the phone only reads"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn off_or_unpaired_sends_no_relay_request() {
    assert!(!enabled_in(|_| None), "LINK_RELAY_CACHE unset is off");
    assert!(!enabled_in(|_| Some("true".into())));
    assert!(enabled_in(|_| Some("on".into())));

    let server = FakeSignaling::start(FakeOptions { relay_cache: true, ..FakeOptions::default() }).await;
    let dir = tempfile::tempdir().unwrap();
    let _daemon = fake_daemon(dir.path());
    let (url, _acpmux) = fake_acpmux(Arc::new(AtomicU64::new(12))).await;
    let services = config(dir.path(), url);
    let heads = Arc::clone(&services.pairing.as_ref().unwrap().relay_heads);
    let identity = MacIdentity::generate().unwrap();
    let (_key, viewers) = phone();
    let timing = FeedTiming::default();

    let cache = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), MAC, on());
    let off = Arc::new(RelayPublisher::new(
        cache.clone(),
        identity.relay_key().clone(),
        1,
        RelayPublishConfig::default(),
    ));
    let mut feed = Feed::new(Arc::clone(&services), None, off, Arc::clone(&heads));
    feed.changed(Some(S1));
    let flushed = feed.flush(&viewers, Instant::now(), &timing).await;
    assert_eq!((flushed.deltas, flushed.snapshots), (0, 0));

    let on_publisher = Arc::new(RelayPublisher::new(
        cache,
        identity.relay_key().clone(),
        2,
        RelayPublishConfig { enabled: true },
    ));
    let mut feed = Feed::new(Arc::clone(&services), None, on_publisher, Arc::clone(&heads));
    let flushed = feed.flush(&[], Instant::now(), &timing).await;
    assert_eq!((flushed.deltas, flushed.snapshots), (0, 0), "no paired phone, nothing to seal to");

    let total: u64 = ["snapshot PUT", "delta POST", "snapshot GET", "delta GET"]
        .iter()
        .map(|kind| server.relay_cache_hits(kind))
        .sum();
    assert_eq!(total, 0);
    assert!(heads.now().is_empty());
    let peer = Peer {
        device_id: PHONE.into(),
        session_id: "s".into(),
        video: None,
        session_exposure: None,
        route: None,
        path: None,
        viewport: None,
    };
    let reply = answer_args(&services, &peer, &json!({"v": 1})).await.unwrap();
    assert!(reply.get("relay").is_none(), "no relay heads while nothing is published: {reply}");
}
