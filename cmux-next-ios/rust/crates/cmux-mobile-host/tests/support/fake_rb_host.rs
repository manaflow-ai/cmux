//! A stand-in for the app's browser host in tests (never shipped): the rd
//! stream carrier on loopback with the real launch rule (the hello's token
//! must be the per-launch secret), the shared rd media engine packetizing
//! placeholder access units, and a tiny page that answers rb messages:
//! `rb.navigate` with `rb.page`, `rb.screen` with `rb.screen_applied`, and
//! every rb input event with an `rb.tooltip` naming it.
//!
//! Included with `#[path]` by cmux-mobile-host's and cmux-mobile-link-ffi's tests.

#![allow(dead_code)]

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use cmux_mobile_host::browser::{HostGuard, LaunchRequest, Launcher, RunningHost};
use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{Encoded, EngineConfig, MediaEngine, Output};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::{InputEvent, STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer, encode_stream_frame};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

struct TaskGuard(tokio::task::JoinHandle<()>);

impl HostGuard for TaskGuard {
    fn alive(&mut self) -> bool {
        !self.0.is_finished()
    }
}

impl Drop for TaskGuard {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// A launcher of fake hosts; `launches` counts them.
pub fn launcher(launches: Arc<AtomicUsize>) -> Launcher {
    Arc::new(move |request: LaunchRequest| {
        let launches = Arc::clone(&launches);
        Box::pin(async move {
            launches.fetch_add(1, Ordering::SeqCst);
            let listener = TcpListener::bind("127.0.0.1:0").await.map_err(|e| e.to_string())?;
            let addr: SocketAddr = listener.local_addr().map_err(|e| e.to_string())?;
            let secret = format!("{:064x}", launches.load(Ordering::SeqCst) as u128 * 0x1234_5678_9abc);
            let task_secret = secret.clone();
            let task = tokio::spawn(async move {
                let mut url = request.url;
                while let Ok((stream, _)) = listener.accept().await {
                    url = session(stream, &task_secret, url).await;
                }
            });
            Ok(RunningHost { addr, secret, guard: Box::new(TaskGuard(task)) })
        })
    })
}

fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    encode_stream_frame(kind, payload, &mut out).unwrap();
    out
}

fn control(c: &Control) -> Vec<u8> {
    frame(STREAM_CONTROL, &serde_json::to_vec(c).unwrap())
}

fn rb(body: Value) -> Vec<u8> {
    control(&Control::Service { service: "rb/1".into(), body })
}

fn page(url: &str) -> Vec<u8> {
    rb(json!({"t": "rb.page", "url": url, "title": format!("Fake: {url}"), "loading": false,
              "can_go_back": url != "about:blank", "can_go_forward": false}))
}

/// One viewer; returns the page URL it left.
async fn session(mut stream: TcpStream, secret: &str, mut url: String) -> String {
    let _ = stream.set_nodelay(true);
    let mut deframer = StreamDeframer::default();
    let mut buf = vec![0u8; 64 * 1024];
    // The hello, within 3 s, with the secret.
    let hello = loop {
        if let Ok(Some((STREAM_CONTROL, payload))) = deframer.next_frame() {
            break serde_json::from_slice::<Control>(&payload).ok();
        }
        match tokio::time::timeout(Duration::from_secs(3), stream.read(&mut buf)).await {
            Ok(Ok(n)) if n > 0 => deframer.extend(&buf[..n]),
            _ => return url,
        }
    };
    // Frames that came in with the hello (hostd sends the file policy and a first
    // page right after it): replayed as the first read, as the real host's session
    // drains its deframer before reading.
    let mut replay = Vec::new();
    while let Ok(Some((kind, payload))) = deframer.next_frame() {
        let _ = encode_stream_frame(kind, &payload, &mut replay);
    }
    let authorized = matches!(&hello, Some(Control::Hello { token: Some(t), service, .. }) if t.0 == secret && service == "rb/1");
    if !authorized {
        let _ = stream.write_all(&control(&Control::Refused { reason: "unauthorized".into() })).await;
        return url;
    }
    let mut out = control(&Control::Welcome {
        encoder: "fake".into(),
        width: 390,
        height: 844,
        max_datagram: 1332,
        carrier: "stream".into(),
        service: "rb/1".into(),
        caps: vec!["input.service".into()],
    });
    out.extend(control(&Control::Started { session: 1 }));
    out.extend(rb(json!({"t": "rb.opened", "session": 1, "main_stream": 0})));
    out.extend(page(&url));
    if stream.write_all(&out).await.is_err() {
        return url;
    }
    let t0 = Instant::now();
    let now = || t0.elapsed().as_micros() as u64;
    let mut engine = MediaEngine::new(
        EngineConfig { width: 390, height: 844, max_fps: 30, max_datagram: 1332, ..EngineConfig::default() },
        now(),
    );
    let mut pending = engine.start(now());
    let mut interval = tokio::time::interval(Duration::from_millis(33));
    let mut painted = 0u32;
    let mut history: Vec<String> = Vec::new();
    loop {
        let mut out = Vec::new();
        if let Some(req) = pending.take() {
            painted += 1;
            // A placeholder access unit: an Annex-B start code and the frame
            // number; an IDR carries an SPS and a PPS first, as VideoToolbox's do.
            let mut au = Vec::new();
            if req.force_idr {
                au.extend_from_slice(&[
                    0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x1f, 0xda, 0x01, 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80,
                ]);
            }
            au.extend_from_slice(&[0, 0, 0, 1, if req.force_idr { 0x65 } else { 0x41 }]);
            au.extend(painted.to_be_bytes().map(|b| b | 0x80));
            au.resize(au.len() + 2500, 0xAB);
            let encoded = Encoded { access_unit: au, idr: req.force_idr, t_capture_us: now() };
            if let Ok(o) = engine.encoded(&req, Some(encoded), now()) {
                pending = emit(&mut out, o);
            }
        }
        let first = std::mem::take(&mut replay);
        tokio::select! {
            read = async {
                if first.is_empty() {
                    stream.read(&mut buf).await
                } else {
                    buf[..first.len()].copy_from_slice(&first);
                    Ok(first.len())
                }
            } => match read {
                Ok(0) | Err(_) => return url,
                Ok(n) => {
                    deframer.extend(&buf[..n]);
                    while let Ok(Some((kind, payload))) = deframer.next_frame() {
                        if kind == STREAM_DATAGRAM {
                            let o = engine.on_datagram(&payload, true, now());
                            for event in &o.inject {
                                if let InputEvent::Service { bytes, .. } = event {
                                    let event: Value = serde_json::from_slice(bytes).unwrap_or(Value::Null);
                                    out.extend(rb(json!({"t": "rb.tooltip", "text": event.to_string()})));
                                }
                            }
                            pending = pending.or(emit(&mut out, o));
                        } else if let Ok(Control::Service { body, .. }) = serde_json::from_slice::<Control>(&payload) {
                            match body["t"].as_str() {
                                Some("rb.navigate") => {
                                    history.push(std::mem::replace(&mut url, body["url"].as_str().unwrap_or_default().to_owned()));
                                    out.extend(page(&url));
                                }
                                // A hung page (tests of the phone's watchdog): nothing is read or answered again.
                                Some("rb.find") if body["query"] == "hang" => std::future::pending::<()>().await,
                                // A link the page follows by itself (a click inside it).
                                Some("rb.find") if body["query"].as_str().is_some_and(|q| q.starts_with("goto:")) => {
                                    let to = body["query"].as_str().unwrap_or_default()["goto:".len()..].to_owned();
                                    history.push(std::mem::replace(&mut url, to));
                                    out.extend(page(&url));
                                }
                                Some("rb.history") if body["op"] == "back" => {
                                    if let Some(previous) = history.pop() {
                                        url = previous;
                                        out.extend(page(&url));
                                    }
                                }
                                Some("rb.screen") | Some("rb.open") => {
                                    let screen = &body["screen"];
                                    let scale = screen["scale"].as_f64().unwrap_or(2.0);
                                    let w = (screen["css_width"].as_f64().unwrap_or(390.0) * scale).ceil();
                                    let h = (screen["css_height"].as_f64().unwrap_or(844.0) * scale).ceil();
                                    out.extend(rb(json!({"t": "rb.screen_applied", "seq": body["seq"].as_u64().unwrap_or(0),
                                        "pixel_width": w, "pixel_height": h, "scale": scale})));
                                }
                                _ => {}
                            }
                        }
                    }
                }
            },
            _ = interval.tick() => {
                let full = Rect { x: 0, y: 0, width: 390, height: 844 };
                pending = pending.or(engine.damage(0, full, now()));
                let o = engine.tick(true, now());
                pending = pending.or(emit(&mut out, o));
            }
        }
        if !out.is_empty() && stream.write_all(&out).await.is_err() {
            return url;
        }
    }
}

fn emit(out: &mut Vec<u8>, o: Output) -> Option<cmux_rd_engine::EncodeRequest> {
    for d in &o.datagrams {
        out.extend(frame(STREAM_DATAGRAM, d));
    }
    o.encode
}
