//! The `tabs` service end to end: phones on a link, a fake daemon feeding
//! the producer, pictures offered by the Mac app.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::control::SessionExposure;
use cmux_mobile_host::pairing::LinkAuth;
use cmux_mobile_host::services::{Peer, serve};
use cmux_mobile_host::tab_snapshots::{self, Part, Tabs};
use cmux_mobile_link::{Channel, ChannelEvent, Link, LinkConfig, Role};
use cmux_tab_snapshots::{BlobHash, Deframer, Message, Mime, Mirror, Resume, Viewport, length_prefixed};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::watch;

/// A daemon that answers the feeder's requests from `tree`.
struct FakeDaemon {
    socket: PathBuf,
    tree: Arc<Mutex<Value>>,
    events: tokio::sync::broadcast::Sender<String>,
    open: Arc<AtomicUsize>,
    remote_hellos: Arc<AtomicUsize>,
    screen_reads: Arc<Mutex<HashMap<u64, usize>>>,
    /// Bumped by [`FakeDaemon::restart`]: every open connection ends.
    run: watch::Sender<u64>,
}

fn tree(tabs: Value) -> Value {
    json!({"workspaces": [{"screens": [{"panes": [{"tabs": tabs}]}]}]})
}

impl FakeDaemon {
    fn start(dir: &Path, tabs: Value) -> Self {
        let socket = dir.join("main.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let daemon = Self {
            socket,
            tree: Arc::new(Mutex::new(tree(tabs))),
            events: tokio::sync::broadcast::channel(64).0,
            open: Arc::default(),
            remote_hellos: Arc::default(),
            screen_reads: Arc::default(),
            run: watch::channel(0).0,
        };
        let run = daemon.run.clone();
        let (tree, events, open, remote, reads) = (
            Arc::clone(&daemon.tree),
            daemon.events.clone(),
            Arc::clone(&daemon.open),
            Arc::clone(&daemon.remote_hellos),
            Arc::clone(&daemon.screen_reads),
        );
        tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let mut run = run.subscribe();
                let (tree, mut events, open, remote, reads) = (
                    Arc::clone(&tree),
                    events.subscribe(),
                    Arc::clone(&open),
                    Arc::clone(&remote),
                    Arc::clone(&reads),
                );
                open.fetch_add(1, Ordering::SeqCst);
                tokio::spawn(async move {
                    let (read, mut write) = stream.into_split();
                    let mut lines = BufReader::new(read).lines();
                    let mut subscribed = false;
                    loop {
                        tokio::select! {
                            line = lines.next_line() => {
                                let Ok(Some(line)) = line else { break };
                                let request: Value = serde_json::from_str(&line).unwrap();
                                let id = request["id"].clone();
                                let reply = match request["cmd"].as_str().unwrap() {
                                    "set-client-info" => {
                                        if request["remote"] == true {
                                            remote.fetch_add(1, Ordering::SeqCst);
                                        }
                                        json!({"id": id, "ok": true})
                                    }
                                    "subscribe" => {
                                        subscribed = true;
                                        json!({"id": id, "ok": true})
                                    }
                                    "list-workspaces" => {
                                        json!({"id": id, "ok": true, "data": tree.lock().unwrap().clone()})
                                    }
                                    "read-screen" => {
                                        let surface = request["surface"].as_u64().unwrap();
                                        let n = {
                                            let mut reads = reads.lock().unwrap();
                                            let n = reads.entry(surface).or_default();
                                            *n += 1;
                                            *n
                                        };
                                        json!({"id": id, "ok": true, "data": {"text": format!("screen {surface} #{n}")}})
                                    }
                                    other => panic!("unexpected {other}"),
                                };
                                if write.write_all(format!("{reply}\n").as_bytes()).await.is_err() {
                                    break;
                                }
                            }
                            _ = run.changed() => break,
                            event = events.recv(), if subscribed => {
                                let Ok(event) = event else { break };
                                if write.write_all(format!("{event}\n").as_bytes()).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    open.fetch_sub(1, Ordering::SeqCst);
                });
            }
        });
        daemon
    }

    /// A new run of the daemon on the same socket, listing `tabs`: the old
    /// run's connections end.
    fn restart(&self, tabs: Value) {
        *self.tree.lock().unwrap() = tree(tabs);
        self.run.send_modify(|n| *n += 1);
    }

    fn emit(&self, event: Value) {
        let _ = self.events.send(event.to_string());
    }
}

/// One phone: its end of a `tabs` channel and a reference mirror.
struct Phone {
    channel: Channel,
    deframer: Deframer,
    mirror: Mirror,
    blobs: Vec<BlobHash>,
    _link: Link,
}

impl Phone {
    async fn send(&self, msg: Message) {
        self.channel.send(Bytes::from(length_prefixed(&msg.encode()).unwrap())).await.unwrap();
    }

    /// Applies whatever arrives within `wait`.
    async fn drain(&mut self, wait: Duration) {
        let _ = tokio::time::timeout(wait, self.until(|_| false)).await;
    }

    /// Applies frames until `done` holds (3 s at most).
    async fn until(&mut self, mut done: impl FnMut(&Mirror) -> bool) {
        tokio::time::timeout(Duration::from_secs(3), async {
            while !done(&self.mirror) {
                if let Some(frame) = self.deframer.next_frame().unwrap() {
                    if let Ok(Message::Blob(b)) = Message::decode(&frame) {
                        self.blobs.push(b.hash);
                    }
                    self.mirror.apply_frame(&frame).unwrap();
                    continue;
                }
                match self.channel.recv().await {
                    Some(ChannelEvent::Data(data)) => self.deframer.push(&data),
                    event => panic!("tabs channel ended: {event:?}"),
                }
            }
        })
        .await
        .expect("phone state in time");
    }
}

/// A phone that opens `tabs` against `tabs::serve` directly (its own [`Tabs`]).
async fn phone(
    tabs: &Arc<Tabs>,
    socket: Option<PathBuf>,
    exposure: Option<watch::Receiver<SessionExposure>>,
) -> Phone {
    let (phone_stream, mac_stream) = tokio::io::duplex(64 * 1024);
    let link = Link::new(phone_stream, Role::Phone, LinkConfig::default(), None);
    let mac = Link::new(mac_stream, Role::Mac, LinkConfig::default(), None);
    let tabs = Arc::clone(tabs);
    tokio::spawn(async move {
        let incoming = mac.accept().await.unwrap();
        let (sender, receiver) = incoming.channel.split();
        let _ = tab_snapshots::serve(&tabs, socket, exposure, &sender, receiver).await;
        sender.close("eof", "").await;
        let _mac = mac;
    });
    let channel = link.open("tabs", json!({})).await.unwrap();
    Phone {
        channel,
        deframer: Deframer::new(16 << 20),
        mirror: Mirror::new(),
        blobs: Vec::new(),
        _link: link,
    }
}

fn ids(mirror: &Mirror) -> Vec<&str> {
    mirror.rows().iter().map(|r| r.tab_id.as_str()).collect()
}

fn filled(mirror: &Mirror) -> bool {
    !mirror.rows().is_empty() && mirror.rows().iter().all(|r| r.hashes().all(|h| mirror.holds(&h)))
}

async fn eventually(what: &str, mut check: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while !check() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("{what} in time"));
}

fn two_tabs() -> Value {
    json!([
        {"surface": 7, "kind": "pty", "title": "zsh", "size": {"cols": 100, "rows": 30}},
        {"surface": 8, "kind": "browser", "title": "Docs"},
    ])
}

#[tokio::test]
async fn a_phone_doing_have_resume_viewport_gets_the_manifest_and_pushed_blobs() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = FakeDaemon::start(dir.path(), two_tabs());
    let tabs = Arc::new(Tabs::new("run-2"));
    tabs.offer_image("8", Part::Favicon, b"fav8".to_vec(), 0, 0, Mime::Png, 10);
    tabs.offer_image("8", Part::Thumb, b"thumb8".to_vec(), 576, 768, Mime::Jpeg, 10);
    let mut p = phone(&tabs, Some(daemon.socket.clone()), None).await;
    // The phone holds the favicon from before and a rev of an older run.
    p.mirror.import_held([BlobHash::of(b"fav8")]);
    p.send(Message::Have(vec![BlobHash::of(b"fav8")])).await;
    p.send(Message::Resume(Resume { epoch: "run-1".into(), rev: 40 })).await;
    p.send(Message::Viewport(Viewport::default())).await;
    p.until(|m| ids(m) == ["7", "8"] && filled(m) && m.rows()[0].screen_hash.is_some()).await;
    assert_eq!(p.mirror.epoch(), "run-2");
    let terminal = &p.mirror.rows()[0];
    assert_eq!((terminal.screen_cols, terminal.screen_rows), (100, 30));
    assert!(p.mirror.holds(&BlobHash::of(b"screen 7 #1")));
    assert!(p.blobs.contains(&BlobHash::of(b"thumb8")));
    assert!(!p.blobs.contains(&BlobHash::of(b"fav8")), "a blob in `have` is not pushed");

    // Output on the terminal is read again and arrives as a delta and a blob.
    daemon.emit(json!({"event": "surface-output", "surface": 7}));
    p.until(|m| m.holds(&BlobHash::of(b"screen 7 #2")) && filled(m)).await;
    // A new tab from a tree event.
    daemon.tree.lock().unwrap()["workspaces"][0]["screens"][0]["panes"][0]["tabs"]
        .as_array_mut()
        .unwrap()
        .insert(0, json!({"surface": 9, "kind": "browser", "title": "New"}));
    daemon.emit(json!({"event": "tab-created", "surface": 9}));
    p.until(|m| ids(m) == ["9", "7", "8"]).await;
    // A picture offered later is pushed.
    tabs.offer_image("9", Part::Thumb, b"thumb9".to_vec(), 576, 768, Mime::Jpeg, 20);
    p.until(|m| m.holds(&BlobHash::of(b"thumb9"))).await;
    assert!(daemon.remote_hellos.load(Ordering::SeqCst) >= 2, "the feeder says remote: true");
}

#[tokio::test]
async fn a_second_phone_gets_the_same_blobs_from_the_one_store() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = FakeDaemon::start(dir.path(), two_tabs());
    let tabs = Arc::new(Tabs::new("run"));
    tabs.offer_image("8", Part::Thumb, b"thumb8".to_vec(), 576, 768, Mime::Jpeg, 10);
    let mut first = phone(&tabs, Some(daemon.socket.clone()), None).await;
    first.send(Message::Viewport(Viewport::default())).await;
    first.until(|m| ids(m) == ["7", "8"] && filled(m) && m.rows()[0].screen_hash.is_some()).await;
    let mut second = phone(&tabs, Some(daemon.socket.clone()), None).await;
    second.send(Message::Viewport(Viewport::default())).await;
    second.until(|m| ids(m) == ["7", "8"] && filled(m) && m.rows()[0].screen_hash.is_some()).await;
    let a: HashSet<_> = first.blobs.iter().collect();
    let b: HashSet<_> = second.blobs.iter().collect();
    assert_eq!(a, b);
    assert_eq!(tabs.stored_blobs(), a.len());
    assert_eq!(tabs.feeds_started(), 1, "both phones share one feeder");
    assert_eq!(daemon.screen_reads.lock().unwrap().get(&7), Some(&1), "the screen was read once for both");
}

#[tokio::test]
async fn a_tab_of_a_chat_the_peer_may_not_see_is_absent() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = FakeDaemon::start(
        dir.path(),
        json!([
            {"surface": 7, "kind": "pty", "title": "zsh"},
            {"surface": 9, "kind": "conversation", "title": "Secret", "agent_session": "s-blocked"},
        ]),
    );
    let tabs = Arc::new(Tabs::new("run"));
    tabs.offer_image("9", Part::Thumb, b"secret".to_vec(), 576, 768, Mime::Jpeg, 10);
    let mut blocked = SessionExposure { configured: true, ..SessionExposure::default() };
    blocked.blocked.insert("s-blocked".into());
    let (exposure, rx) = watch::channel(blocked);
    let mut p = phone(&tabs, Some(daemon.socket.clone()), Some(rx)).await;
    p.send(Message::Viewport(Viewport::default())).await;
    p.until(|m| ids(m) == ["7"] && filled(m) && m.rows()[0].screen_hash.is_some()).await;
    eventually("the feeder listed the hidden tab", || tabs.tab_ids().len() == 2).await;
    // Even a `want` for its picture is not served.
    p.send(Message::Want(vec![BlobHash::of(b"secret")])).await;
    p.drain(Duration::from_millis(300)).await;
    assert!(!p.blobs.contains(&BlobHash::of(b"secret")));
    assert_eq!(ids(&p.mirror), ["7"]);

    // Exposing the chat shows it at once.
    exposure.send_replace(SessionExposure { configured: true, ..SessionExposure::default() });
    p.until(|m| ids(m) == ["7", "9"] && m.holds(&BlobHash::of(b"secret"))).await;
    // An unavailable exposure hides every tab.
    exposure.send_replace(SessionExposure { available: false, ..SessionExposure::default() });
    p.until(|m| m.rows().is_empty()).await;
}

#[tokio::test]
async fn a_new_daemon_run_is_a_new_epoch_and_no_old_surface_survives() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = FakeDaemon::start(dir.path(), two_tabs());
    let tabs = Arc::new(Tabs::new("run-a"));
    tabs.offer_image("8", Part::Thumb, b"thumb8".to_vec(), 576, 768, Mime::Jpeg, 10);
    let mut p = phone(&tabs, Some(daemon.socket.clone()), None).await;
    p.send(Message::Viewport(Viewport::default())).await;
    p.until(|m| ids(m) == ["7", "8"] && filled(m) && m.rows()[0].screen_hash.is_some()).await;
    assert_eq!(p.mirror.epoch(), "run-a");
    let old_rev = tabs.rev();
    // A picture for a surface the old run lists only later.
    tabs.offer_image("11", Part::Thumb, b"thumb11".to_vec(), 576, 768, Mime::Jpeg, 11);

    // The new run numbers its surfaces again: 8 is now a terminal, 11 a page.
    daemon.restart(json!([
        {"surface": 8, "kind": "pty", "title": "bash", "size": {"cols": 80, "rows": 24}},
        {"surface": 11, "kind": "browser", "title": "New page"},
    ]));
    p.until(|m| m.epoch() != "run-a" && ids(m) == ["8", "11"] && m.rows()[0].screen_hash.is_some()).await;
    let epoch = tabs.epoch();
    assert_eq!(p.mirror.epoch(), epoch);
    let (eight, eleven) = (&p.mirror.rows()[0], &p.mirror.rows()[1]);
    assert_eq!((eight.title.as_str(), eight.thumb_hash), ("bash", None), "8's old thumbnail is gone");
    assert_eq!(eleven.thumb_hash, None, "a picture held for an old surface is gone");
    assert_eq!(tabs.feeds_started(), 1, "the same feeder reconnected");

    // A phone resuming from the old run gets a manifest of the new one.
    let mut back = phone(&tabs, Some(daemon.socket.clone()), None).await;
    back.send(Message::Resume(Resume { epoch: "run-a".into(), rev: old_rev })).await;
    back.send(Message::Viewport(Viewport::default())).await;
    back.until(|m| ids(m) == ["8", "11"]).await;
    assert_eq!(back.mirror.epoch(), epoch);
}

fn config(dir: &Path) -> Arc<ServiceConfig> {
    Arc::new(ServiceConfig {
        tui_socket_dir: dir.to_owned(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![],
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        pairing: None,
        agent_tab_host: None,
        uploads_dir: dir.join("uploads"),
        chief_socket: None,
        browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
        surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
    })
}

/// Through `services::serve` (the process's shared [`tab_snapshots::TABS`]);
/// the only test in this binary that uses it.
#[tokio::test]
async fn the_feeder_runs_while_a_phone_has_tabs_open_and_stops_when_the_last_leaves() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = FakeDaemon::start(dir.path(), two_tabs());
    let config = config(dir.path());
    let (phone_stream, mac_stream) = tokio::io::duplex(64 * 1024);
    let link = Link::new(phone_stream, Role::Phone, LinkConfig::default(), None);
    let mac = Link::new(mac_stream, Role::Mac, LinkConfig::default(), None);
    tokio::spawn(async move {
        loop {
            let Some(incoming) = mac.accept().await else { return };
            let peer = Peer {
                device_id: "p".into(),
                session_id: "s".into(),
                video: None,
                session_exposure: None,
                path: None,
            };
            tokio::spawn(serve(Arc::clone(&config), peer, Arc::new(LinkAuth::default()), incoming));
        }
    });
    let tabs = &*tab_snapshots::TABS;
    let open = |link: &Link| {
        let link = link.clone();
        async move {
            let channel = link.open("tabs", json!({})).await.unwrap();
            let p = Phone {
                channel,
                deframer: Deframer::new(16 << 20),
                mirror: Mirror::new(),
                blobs: Vec::new(),
                _link: link,
            };
            p.send(Message::Viewport(Viewport::default())).await;
            p
        }
    };
    let mut a = open(&link).await;
    let mut b = open(&link).await;
    a.until(|m| ids(m) == ["7", "8"]).await;
    b.until(|m| ids(m) == ["7", "8"]).await;
    assert!(tabs.feeder_running());
    assert_eq!(daemon.open.load(Ordering::SeqCst), 2, "one feeder: an event and a query connection");

    a.channel.close("eof", "").await;
    eventually("one phone left", || tabs.phones() == 1).await;
    assert!(tabs.feeder_running(), "a phone still has tabs open");
    b.channel.close("eof", "").await;
    eventually("the feeder stopped", || !tabs.feeder_running()).await;
    eventually("its daemon connections closed", || daemon.open.load(Ordering::SeqCst) == 0).await;
    let reads = daemon.screen_reads.lock().unwrap().get(&7).copied();
    daemon.emit(json!({"event": "surface-output", "surface": 7}));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(daemon.screen_reads.lock().unwrap().get(&7).copied(), reads, "nothing polls with no phone");

    // A phone that comes back starts it again.
    let started = tabs.feeds_started();
    let mut c = open(&link).await;
    c.until(|m| ids(m) == ["7", "8"]).await;
    assert_eq!(tabs.feeds_started(), started + 1);
}
