//! A stand-in for the Mac app's simulator surface source in tests (never
//! shipped): `sf/1` on loopback with the real launch rule (the hello must
//! carry the per-launch secret), a 390x844 screen that changes every 33 ms,
//! placeholder access units for each `encode`, and every other line hostd
//! sends (touches, text, keys, buttons, visibility) recorded in `inputs`.
//!
//! Included with `#[path]` by cmux-mobile-host's and cmux-mobile-link-ffi's tests.

#![allow(dead_code)]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_mobile_host::browser::{HostGuard, LaunchRequest, Launcher, RunningHost};
use cmux_mobile_host::surface::{SourceDeframer, SourceFrame, surface_clock_us};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

pub type Inputs = Arc<Mutex<Vec<Value>>>;

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

/// A launcher of fake sources; each records hostd's lines into `inputs`.
pub fn launcher(inputs: Inputs) -> Launcher {
    Arc::new(move |_request: LaunchRequest| {
        let inputs = Arc::clone(&inputs);
        Box::pin(async move {
            let listener = TcpListener::bind("127.0.0.1:0").await.map_err(|e| e.to_string())?;
            let addr = listener.local_addr().map_err(|e| e.to_string())?;
            let secret = uuid::Uuid::new_v4().simple().to_string();
            let task_secret = secret.clone();
            let task = tokio::spawn(async move {
                while let Ok((stream, _)) = listener.accept().await {
                    let (secret, inputs) = (task_secret.clone(), Arc::clone(&inputs));
                    tokio::spawn(async move { session(stream, &secret, inputs).await });
                }
            });
            Ok(RunningHost { addr, secret, guard: Box::new(TaskGuard(task)) })
        })
    })
}

async fn session(mut stream: TcpStream, secret: &str, inputs: Inputs) {
    let _ = stream.set_nodelay(true);
    let mut frames = SourceDeframer::default();
    let mut buffer = vec![0u8; 64 * 1024];
    // The hello, with the secret.
    loop {
        match frames.next_frame() {
            Ok(Some(SourceFrame::Json(hello))) if hello["t"] == "hello" && hello["secret"] == secret => break,
            Ok(Some(_)) | Err(_) => {
                let _ = stream
                    .write_all(&SourceFrame::Json(json!({"t": "error", "message": "unauthorized"})).encode())
                    .await;
                return;
            }
            Ok(None) => match tokio::time::timeout(Duration::from_secs(3), stream.read(&mut buffer)).await {
                Ok(Ok(n)) if n > 0 => frames.extend(&buffer[..n]),
                _ => return,
            },
        }
    }
    if stream
        .write_all(&SourceFrame::Json(json!({"t": "size", "width": 390, "height": 844})).encode())
        .await
        .is_err()
    {
        return;
    }
    let mut painted = 0u32;
    let mut interval = tokio::time::interval(Duration::from_millis(33));
    loop {
        let mut out = Vec::new();
        tokio::select! {
            read = stream.read(&mut buffer) => match read {
                Ok(0) | Err(_) => return,
                Ok(n) => {
                    frames.extend(&buffer[..n]);
                    while let Ok(Some(frame)) = frames.next_frame() {
                        let SourceFrame::Json(line) = frame else { return };
                        if line["t"] == "encode" {
                            painted += 1;
                            let idr = line["idr"].as_bool().unwrap_or(false) || painted == 1;
                            // SPS, PPS and an IDR slice, or a P slice, then the frame number.
                            let mut au = Vec::new();
                            if idr {
                                au.extend_from_slice(&[0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x1f, 0xda, 0x01, 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80]);
                            }
                            au.extend_from_slice(&[0, 0, 0, 1, if idr { 0x65 } else { 0x41 }]);
                            au.extend(painted.to_be_bytes().map(|b| b | 0x80));
                            au.resize(au.len() + 1500, 0xAB);
                            out.extend(SourceFrame::AccessUnit { idr, capture_us: surface_clock_us(), annex_b: au }.encode());
                        } else {
                            inputs.lock().unwrap().push(line);
                        }
                    }
                }
            },
            _ = interval.tick() => out.extend(SourceFrame::Json(json!({"t": "damage"})).encode()),
        }
        if !out.is_empty() && stream.write_all(&out).await.is_err() {
            return;
        }
    }
}

/// Whether hostd sent a line with `t` whose `key` is `value`.
pub fn has(inputs: &Inputs, t: &str, key: &str, value: &Value) -> bool {
    inputs.lock().unwrap().iter().any(|line| line["t"] == t && &line[key] == value)
}
