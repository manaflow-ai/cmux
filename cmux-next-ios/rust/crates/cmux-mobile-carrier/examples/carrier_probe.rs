//! A live check of the phone's carrier from a shell: dial one Cloud machine
//! as the iOS app does and send it daemon request lines.
//!
//! ```text
//! CARRIER_API=https://cloud-api-staging.cmux.dev CARRIER_MACHINE=vm_… \
//! CARRIER_TOKEN_FILE=/path/0600-token [CARRIER_TEAM=team_…] \
//! cargo run -p cmux-mobile-carrier --example carrier_probe -- \
//!   '{"cmd":"identify"}' '{"cmd":"list-workspaces"}'
//! ```
//!
//! Each argument is one request (its `id` is added); the probe prints each
//! reply line, then the dial's timings. The token is read from a file and is
//! never printed. Each run dials with a new Noise key, as a new phone would.

use std::sync::Arc;
use std::time::Duration;

use cmux_mobile_carrier::{CarrierSession, NoiseIdentity, Platform, generate_private_key};
use serde_json::Value;
use tokio::time::Instant;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("carrier_probe: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let env = |name: &str| std::env::var(name).map_err(|_| format!("{name} is not set"));
    let api = env("CARRIER_API")?;
    let machine = env("CARRIER_MACHINE")?;
    let token = std::fs::read_to_string(env("CARRIER_TOKEN_FILE")?)
        .map_err(|error| format!("token file: {error}"))?
        .trim()
        .to_owned();
    let team = std::env::var("CARRIER_TEAM").ok();
    let platform = Arc::new(Platform::new(&api, team, &machine, token).map_err(|e| e.to_string())?);
    let key = generate_private_key().map_err(|e| e.to_string())?;
    let identity = NoiseIdentity::from_private(*key);

    let started = Instant::now();
    let session = CarrierSession::dial(
        platform,
        identity,
        "carrier-probe".into(),
        Instant::now() + Duration::from_secs(90),
    )
    .await
    .map_err(|e| format!("dial: {e}"))?;
    let dialed = started.elapsed();
    let stream = session.open_stream().await.map_err(|e| format!("stream: {e}"))?;
    println!("dialed in {} ms", dialed.as_millis());

    let mut pending = Vec::new();
    for (index, arg) in std::env::args().skip(1).enumerate() {
        let mut request: Value = serde_json::from_str(&arg).map_err(|e| format!("{arg}: {e}"))?;
        let id = format!("p{index}");
        request["id"] = Value::String(id.clone());
        let mut line = request.to_string();
        line.push('\n');
        let sent = Instant::now();
        stream.send(line.as_bytes()).await.map_err(|e| format!("send: {e}"))?;
        pending.push((id, sent));
    }

    let mut buffer = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(30);
    while !pending.is_empty() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let Ok(Some(bytes)) = tokio::time::timeout(remaining, stream.receive()).await else {
            return Err(format!("no reply to {:?}", pending.iter().map(|p| &p.0).collect::<Vec<_>>()));
        };
        buffer.extend_from_slice(&bytes);
        while let Some(end) = buffer.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=end).collect();
            let text = String::from_utf8_lossy(&line[..line.len() - 1]).into_owned();
            let id = serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|v| v.get("id").and_then(Value::as_str).map(str::to_owned));
            if let Some(index) = pending.iter().position(|(p, _)| Some(p) == id.as_ref()) {
                let (id, sent) = pending.remove(index);
                println!("{id} {} ms: {text}", sent.elapsed().as_millis());
            } else {
                println!("event: {text}");
            }
        }
    }
    stream.close().await;
    session.close().await;
    Ok(())
}
