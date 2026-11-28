//! The old endpoint taps the same byte stream the production Link reads and writes.
//! No observer, additional parsing or lock is installed in a shipping build.
#[path = "wire_lockstep/host_service.rs"]
mod host_service;
#[path = "wire_lockstep/manifest.rs"]
mod manifest;
#[path = "wire_lockstep/signals.rs"]
mod signals;
#[path = "wire_lockstep/worker.rs"]
mod worker;

use std::collections::HashMap;
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::frame::{Frame, FrameCodec, FrameError, FrameType};
use cmux_mobile_link::link::{self, ChannelEvent, Lane, Link, LinkConfig, Role};
use cmux_mobile_link::names::{ALL, FILE_PREVIEW, PHONE_FRAMES, Side};
use cmux_wire_lockstep::{Dir, OldPeer, Tap};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::io::DuplexStream;
use tokio_util::codec::Framed;

fn pair(role: Role) -> (Link, DuplexStream) {
    let (new, old) = tokio::io::duplex(64 * 1024);
    (Link::new(new, role, LinkConfig { keepalive: None, ..Default::default() }, None), old)
}

struct OldWire<'a> {
    io: Framed<DuplexStream, FrameCodec>,
    peer: &'a OldPeer,
    tap: &'a Tap,
    services: HashMap<u32, String>,
}

impl<'a> OldWire<'a> {
    fn new(io: DuplexStream, peer: &'a OldPeer, tap: &'a Tap) -> Self {
        Self { io: Framed::new(io, FrameCodec), peer, tap, services: HashMap::new() }
    }

    fn record(&self, dir: Dir, name: impl Into<String>) {
        let name = name.into();
        if dir == Dir::Received {
            assert!(self.peer.knows(&name), "old fixture tried to send {name}");
        }
        self.tap.record(dir, name);
    }

    fn observe(&mut self, dir: Dir, frame: &Frame) {
        self.record(dir, frame.kind.wire_name());
        let message = match frame.kind {
            FrameType::Data if self.services.get(&frame.channel).is_some_and(|s| s == "phone-frames") => {
                let line: Value = serde_json::from_slice(&frame.payload).expect("phone-frames JSON");
                let kind = line["kind"].as_str().unwrap();
                self.record(dir, format!("control:phone-frames/{kind}"));
                for key in line.as_object().unwrap().keys() {
                    self.record(dir, format!("field:phone-frames/{kind}#{key}"));
                }
                return;
            }
            FrameType::Data if self.services.get(&frame.channel).is_some_and(|s| s == "auth") => "auth",
            FrameType::Open => "open",
            FrameType::Close => "close",
            FrameType::Data if self.services.get(&frame.channel).is_some_and(|s| s == "version") => "version",
            FrameType::Data if self.services.get(&frame.channel).is_some_and(|s| s == "file-preview") => {
                // Only the first data frame is JSON. All subsequent bytes are the file itself.
                self.services.remove(&frame.channel);
                "file-preview"
            }
            _ => return,
        };
        let value: Value = serde_json::from_slice(&frame.payload).expect("wire JSON");
        for key in value.as_object().unwrap().keys() {
            self.record(dir, format!("field:{message}#{key}"));
        }
        if message == "open" {
            let service = value["service"].as_str().unwrap();
            self.record(dir, format!("service:{service}"));
            if let Some(args) = value["args"].as_object() {
                for key in args.keys() {
                    self.record(dir, format!("param:{service}#{key}"));
                }
                if matches!(service, "auth" | "pair-requests")
                    && let Some(action) = args.get("action").and_then(Value::as_str)
                {
                    self.record(dir, format!("control:{service}/{action}"));
                }
                if service == "surface"
                    && args.get("tab").and_then(Value::as_str).is_some_and(|tab| tab.starts_with("c~"))
                {
                    self.record(dir, "control:surface.tab/c~");
                }
            }
            self.services.insert(frame.channel, service.into());
        } else if message == "close" {
            self.record(dir, format!("control:close/{}", value["code"].as_str().unwrap()));
            self.services.remove(&frame.channel);
        }
    }

    async fn send(&mut self, frame: Frame) {
        self.observe(Dir::Received, &frame);
        self.io.send(frame).await.unwrap();
    }

    async fn json(&mut self, id: u32, kind: FrameType, body: Value) {
        self.send(Frame::new(id, kind, serde_json::to_vec(&body).unwrap())).await;
    }

    async fn recv(&mut self) -> Result<Frame, FrameError> {
        let frame = self.io.next().await.expect("peer stream open")?;
        // An old FrameCodec fails on the discriminant before interpreting its payload.
        if !self.peer.knows(frame.kind.wire_name()) {
            self.tap.record(Dir::Sent, frame.kind.wire_name());
            self.tap.refused(Dir::Sent, frame.kind.wire_name());
            self.io.close().await?;
            return Err(FrameError::UnknownType(frame.kind as u8));
        }
        self.observe(Dir::Sent, &frame);
        Ok(frame)
    }

    async fn as_host(&mut self) {
        while let Ok(frame) = self.recv().await {
            match frame.kind {
                FrameType::Open => {
                    let s = self.services[&frame.channel].clone();
                    let code = if !self.peer.knows(&format!("service:{s}")) {
                        self.tap.refused(Dir::Sent, format!("service:{s}"));
                        "unknown_service"
                    } else if s == "version" {
                        let caps: Vec<_> = ALL
                            .iter()
                            .filter(|c| c.side == Side::Host && self.peer.lists(c.name))
                            .map(|c| c.name)
                            .collect();
                        let link = self.peer.manifest().versions["hostd-link"];
                        self.json(
                            frame.channel,
                            FrameType::Data,
                            json!({"hostd":"old","link":link,"capabilities":caps}),
                        )
                        .await;
                        "eof"
                    } else if s == link::PARK_SERVICE {
                        link::PARKED
                    } else {
                        assert_eq!(s, "echo", "unimplemented old fixture service");
                        continue;
                    };
                    self.json(frame.channel, FrameType::Close, json!({"code":code,"reason":""})).await;
                }
                FrameType::Data => self.send(frame).await,
                FrameType::Ping => {
                    self.send(Frame::new(0, FrameType::Pong, frame.payload)).await;
                    return;
                }
                FrameType::Close => {}
                _ => panic!("unexpected phone frame {:?}", frame.kind),
            }
        }
    }
}

async fn run_new_phone(old: OldPeer) {
    let tap = Tap::new();
    let (phone, io) = pair(Role::Phone);
    let mut wire = OldWire::new(io, &old, &tap);
    let client = async {
        let mut version = phone.open("version", json!({})).await.unwrap();
        let Some(ChannelEvent::Data(data)) = version.recv().await else { panic!("no old host version") };
        let reply: Value = serde_json::from_slice(&data).unwrap();
        let advertised = reply["capabilities"].as_array().unwrap();
        for cap in ALL.iter().filter(|cap| cap.side == Side::Host) {
            assert_eq!(advertised.contains(&json!(cap.name)), old.lists(cap.name));
        }
        assert!(matches!(version.recv().await, Some(ChannelEvent::Closed(c)) if c.code == "eof"));
        let mut echo = phone.open_on("echo", json!({}), Lane::Input).await.unwrap();
        echo.send(Bytes::from_static(b"phone")).await.unwrap();
        assert!(matches!(echo.recv().await, Some(ChannelEvent::Data(data)) if data == b"phone"[..]));
        echo.close("eof", "").await;
        assert_eq!(
            phone.park(Duration::from_secs(60), Duration::from_secs(1)).await.unwrap(),
            old.knows("service:_link.park")
        );
        phone.resume();
        phone.ping().await.unwrap();
    };
    tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(client, wire.as_host());
    })
    .await
    .unwrap();
    tap.assert_lockstep(&manifest::manifest(), &old);
}

#[tokio::test]
async fn new_phone_against_base_host() {
    run_new_phone(manifest::base()).await;
}

#[tokio::test]
#[ignore = "phone probes _link.park before learning whether the old host serves it"]
async fn new_phone_against_pre_park_host() {
    let mut before = manifest::base().manifest().clone();
    for name in [
        "service:_link.park",
        "param:_link.park#hold_ms",
        "param:_link.park#encoding",
        "control:close/parked",
    ] {
        before.legacy.remove(name);
    }
    before.capabilities.remove(link::PARK_ENCODING);
    run_new_phone(OldPeer::new(before)).await;
}

#[tokio::test]
async fn new_host_against_base_phone() {
    let old = manifest::base();
    let (host, io) = pair(Role::Mac);
    let tap = Tap::new();
    let mut wire = OldWire::new(io, &old, &tap);
    let has_preview = old.lists(FILE_PREVIEW);
    let has_clock = old.lists(PHONE_FRAMES) && old.knows("control:phone-frames/clock");
    let phone = async {
        wire.json(1, FrameType::Open, json!({"service":"version","args":{}})).await;
        let version = wire.recv().await.unwrap();
        assert_eq!((version.kind, version.channel), (FrameType::Data, 1));
        let reply: Value = serde_json::from_slice(&version.payload).unwrap();
        let caps = reply["capabilities"].as_array().unwrap();
        assert_eq!(wire.recv().await.unwrap().kind, FrameType::Close);
        if has_preview {
            assert!(caps.contains(&json!(FILE_PREVIEW)));
            let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/wire_lockstep/host_service.rs");
            let expected = include_bytes!("wire_lockstep/host_service.rs");
            wire.json(7, FrameType::Open, json!({"service":"file-preview","args":{"path":path}})).await;
            let metadata = wire.recv().await.unwrap();
            assert_eq!(metadata.kind, FrameType::Data);
            assert_eq!(serde_json::from_slice::<Value>(&metadata.payload).unwrap()["size"], expected.len());
            let mut bytes = Vec::new();
            loop {
                let frame = wire.recv().await.unwrap();
                assert_eq!(frame.channel, 7);
                if frame.kind == FrameType::Close {
                    assert_eq!(serde_json::from_slice::<Value>(&frame.payload).unwrap()["code"], "eof");
                    break;
                }
                assert_eq!(frame.kind, FrameType::Data);
                bytes.extend_from_slice(&frame.payload);
            }
            assert_eq!(bytes, expected.as_slice());
        }
        if has_clock {
            assert!(caps.contains(&json!(PHONE_FRAMES)));
            wire.json(9, FrameType::Open, json!({"service":"phone-frames","args":{}})).await;
            wire.json(9, FrameType::Data, json!({"kind":"clock","t0":1})).await;
            let reply = wire.recv().await.unwrap();
            assert_eq!((reply.channel, reply.kind), (9, FrameType::Data));
            let clock: Value = serde_json::from_slice(&reply.payload).unwrap();
            assert_eq!(clock["kind"], "clock");
            assert_eq!(clock["t0"].as_f64(), Some(1.0));
            wire.json(9, FrameType::Close, json!({"code":"eof","reason":""})).await;
        }
        wire.json(3, FrameType::Open, json!({"service":"echo","args":{}})).await;
        wire.send(Frame::new(3, FrameType::Data, Bytes::from_static(b"old phone"))).await;
        assert_eq!(wire.recv().await.unwrap().payload, b"old phone"[..]);
        if old.knows("service:_link.park") {
            // Even a peer that decodes type 5 has not opted into it on this park.
            wire.json(5, FrameType::Open, json!({"service":link::PARK_SERVICE,"args":{"hold_ms":60000}}))
                .await;
            let parked = wire.recv().await.unwrap();
            assert_eq!((parked.kind, parked.channel), (FrameType::Close, 5));
            assert_eq!(serde_json::from_slice::<Value>(&parked.payload).unwrap()["code"], link::PARKED);
        }
        wire.json(3, FrameType::Close, json!({"code":"eof","reason":""})).await;
        wire.send(Frame::new(0, FrameType::Ping, [0u8; 8].to_vec())).await;
        assert_eq!(wire.recv().await.unwrap().kind, FrameType::Pong);
    };
    let server = async {
        // The Link itself handles park and ping. Dispatch every application Open to hostd.
        for _ in 0..2 + usize::from(has_preview) + usize::from(has_clock) {
            host_service::serve(host.accept().await.unwrap()).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(phone, server);
    })
    .await
    .unwrap();
    tap.assert_lockstep(&manifest::manifest(), &old);
}

// A held, compressible write is the only production sender of frame 5. Run the
// same write with and without the per-park decoder advertisement.
async fn parked_write(old: OldPeer, opt_in: bool) {
    let (host, io) = pair(Role::Mac);
    let tap = Tap::new();
    let mut wire = OldWire::new(io, &old, &tap);
    let (parked, wait_park) = tokio::sync::oneshot::channel();
    let (queued, wait_write) = tokio::sync::oneshot::channel();
    let body = Bytes::from(vec![b'A'; 4096]);
    let phone = async {
        wire.json(1, FrameType::Open, json!({"service":"echo","args":{}})).await;
        let mut args = json!({"hold_ms":60000});
        if opt_in {
            assert!(old.lists(link::PARK_ENCODING));
            args["encoding"] = json!(link::PARK_ENCODING);
        }
        wire.json(3, FrameType::Open, json!({"service":link::PARK_SERVICE,"args":args})).await;
        let confirmation = wire.recv().await.unwrap();
        assert_eq!((confirmation.channel, confirmation.kind), (3, FrameType::Close));
        assert_eq!(serde_json::from_slice::<Value>(&confirmation.payload).unwrap()["code"], link::PARKED);
        parked.send(()).unwrap();
        wait_write.await.unwrap();
        wire.send(Frame::new(0, FrameType::Ping, [0u8; 8].to_vec())).await;
        let mut received = false;
        let mut pong = false;
        while !received || !pong {
            let frame = wire.recv().await.unwrap();
            match frame.kind {
                FrameType::Pong => pong = true,
                FrameType::Data | FrameType::DeflatedData => {
                    assert_eq!(frame.channel, 1);
                    if opt_in {
                        assert_eq!(frame.kind, FrameType::DeflatedData);
                        assert_eq!(&frame.payload[..4], &(body.len() as u32).to_be_bytes());
                    } else {
                        assert_eq!(frame.kind, FrameType::Data);
                        assert_eq!(frame.payload, body);
                    }
                    received = true;
                }
                _ => panic!("unexpected parked write {frame:?}"),
            }
        }
        wire.json(1, FrameType::Close, json!({"code":"eof","reason":""})).await;
    };
    let mac = async {
        let mut channel = host.accept().await.unwrap().channel;
        wait_park.await.unwrap();
        channel.send(body.clone()).await.unwrap();
        queued.send(()).unwrap();
        assert!(matches!(channel.recv().await, Some(ChannelEvent::Closed(c)) if c.code == "eof"));
    };
    tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(phone, mac);
    })
    .await
    .unwrap();
    tap.assert_lockstep(&manifest::manifest(), &old);
}

#[tokio::test]
async fn deflated_data_requires_per_park_opt_in() {
    let old = manifest::base();
    if old.knows("service:_link.park") {
        if old.lists(link::PARK_ENCODING) {
            parked_write(old.clone(), true).await;
        }
        let mut without_deflate = old.manifest().clone();
        without_deflate.capabilities.remove(link::PARK_ENCODING);
        parked_write(OldPeer::new(without_deflate), false).await;
    }
}

#[tokio::test]
async fn unknown_frame_closes_the_old_endpoint_and_is_reported() {
    let mut before = manifest::base().manifest().clone();
    before.legacy.remove(FrameType::Ping.wire_name());
    let old = OldPeer::new(before);
    let tap = Tap::new();
    let (phone, io) = pair(Role::Phone);
    let receiver = async {
        let mut wire = OldWire::new(io, &old, &tap);
        assert!(matches!(wire.recv().await, Err(FrameError::UnknownType(n)) if n == FrameType::Ping as u8));
    };
    tokio::time::timeout(Duration::from_secs(5), async {
        let (ping, ()) = tokio::join!(phone.ping(), receiver);
        assert!(ping.is_err(), "the old codec closed the link");
    })
    .await
    .unwrap();
    let problems = tap.one_sided(&manifest::manifest(), &old);
    assert!(problems.iter().any(|p| p.contains("frame:ping=3: refused")));
}

#[tokio::test]
async fn undecodable_frame_stops_the_production_link() {
    use tokio::io::AsyncWriteExt;
    let (host, mut io) = pair(Role::Mac);
    let unknown = (0..=u8::MAX).find(|n| FrameType::ALL.iter().all(|kind| *kind as u8 != *n)).unwrap();
    // A valid empty frame header with a discriminant the shipping decoder does not recognize.
    io.write_all(&[0, 0, 0, 5, 0, 0, 0, 0, unknown]).await.unwrap();
    let reason = tokio::time::timeout(Duration::from_secs(1), host.closed()).await.unwrap();
    assert!(reason.contains(&FrameError::UnknownType(unknown).to_string()), "{reason}");
}
