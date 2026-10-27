//! cmux-mobile-stub-tui: a stand-in cmux-tui session socket for hosts without
//! cmux-tui. Listens on `<dir>/<session>.sock` and answers every request
//! line with `{"id":..,"ok":true,"data":{"stub":true,"cmd":..}}`
//! (`identify` also reports `protocol: 12`).
//!
//!   cmux-mobile-stub-tui <socket dir> [session]

use anyhow::{Context, Result};
use cmux_mobile_host::tasks::{Ended, TaskScope};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let dir =
        std::path::PathBuf::from(args.next().context("usage: cmux-mobile-stub-tui <socket dir> [session]")?);
    let session = args.next().unwrap_or_else(|| "main".into());
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{session}.sock"));
    let _ = std::fs::remove_file(&path);
    let listener = tokio::net::UnixListener::bind(&path)?;
    eprintln!("cmux-mobile-stub-tui listening on {}", path.display());
    let mut clients = TaskScope::<()>::default();
    loop {
        let stream = tokio::select! {
            accepted = listener.accept() => accepted?.0,
            ended = clients.ended() => {
                if let Ended::Panicked((), message) = ended {
                    eprintln!("cmux-mobile-stub-tui: a client failed: {message}");
                }
                continue;
            }
        };
        clients.spawn((), async move {
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                // A line that is not JSON gets the answer of a request with no id or command.
                let request: Value = serde_json::from_str(&line).unwrap_or_default();
                let field = |key: &str| request.get(key).cloned().unwrap_or_default();
                let mut data = serde_json::json!({"stub": true, "cmd": field("cmd")});
                if request.get("cmd").and_then(Value::as_str) == Some("identify") {
                    data = serde_json::json!({"stub": true, "app": "cmux-mobile-stub-tui", "protocol": 12});
                }
                let answer = serde_json::json!({"id": field("id"), "ok": true, "data": data});
                if write.write_all(format!("{answer}\n").as_bytes()).await.is_err() {
                    return;
                }
            }
        });
    }
}
