//! `acpmux channel listen SERVICE` and `acpmux channel open [HOST] SERVICE`: agent byte channels
//! (`server/channels.rs`) from a shell. A listener prints one JSON line per event (`opened`,
//! `data`, `closed`); `--echo` sends each channel's bytes back. An opener sends stdin line by
//! line and prints what comes back, as netcat does; `--text T --reply` sends one message, prints
//! the first answer and exits, which is what an agent asking another agent wants.

use std::time::Instant;

use anyhow::{Result, bail};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::cli::output::print_json;
use crate::rpc::{Message, method};

#[derive(clap::Subcommand, Debug, Clone)]
pub enum ChannelCommand {
    /// Listen on SERVICE on this machine and print each channel's events as JSON lines.
    Listen {
        service: String,
        /// Send every channel's bytes back on it.
        #[arg(long)]
        echo: bool,
        /// Exit when the first channel closes.
        #[arg(long)]
        once: bool,
    },
    /// Open a channel to SERVICE on HOST (a peer's name; none: this machine). Sends stdin line by
    /// line and prints what comes back.
    Open {
        /// The peer, or the service when only one word is given.
        first: String,
        /// The service on that peer.
        service: Option<String>,
        /// Bytes sent with the open itself (no round trip before them).
        #[arg(long)]
        text: Option<String>,
        /// Print the first answer and exit (with `--text`), stdin unread.
        #[arg(long)]
        reply: bool,
    },
}

fn bytes_of(params: &Value) -> String {
    if let Some(text) = params.get("text").and_then(Value::as_str) {
        return text.to_owned();
    }
    let data = params.get("data").and_then(Value::as_str).unwrap_or_default();
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD
        .decode(data)
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default()
}

pub async fn run(command: ChannelCommand, json_out: bool) -> Result<()> {
    match command {
        ChannelCommand::Listen { service, echo, once } => listen(&service, echo, once).await,
        ChannelCommand::Open { first, service, text, reply } => {
            let (peer, service) = match service {
                Some(service) => (Some(first), service),
                None => (None, first),
            };
            open(peer, &service, text, reply, json_out).await
        }
    }
}

async fn listen(service: &str, echo: bool, once: bool) -> Result<()> {
    let client = crate::daemon::connect(true).await?;
    let Some(mut notes) = client.notifications().await else { bail!("no notification stream") };
    client.request(method::MUX_CHANNEL_LISTEN, json!({"service": service})).await?;
    print_json(&json!({"event": "listening", "service": service}));
    while let Some(msg) = notes.recv().await {
        let Message::Notification { method: m, params: Some(params) } = msg else { continue };
        let id = params.get("channelId").cloned().unwrap_or(Value::Null);
        let event = match m.as_str() {
            method::MUX_CHANNEL_OPENED => "opened",
            method::MUX_CHANNEL_DATA => "data",
            method::MUX_CHANNEL_CLOSED => "closed",
            _ => continue,
        };
        let mut line = params.clone();
        line["event"] = json!(event);
        print_json(&line);
        let carries = params.get("text").is_some() || params.get("data").is_some();
        if echo && event != "closed" && carries {
            let mut back = json!({"channelId": id});
            for key in ["text", "data"] {
                if let Some(v) = params.get(key) {
                    back[key] = v.clone();
                }
            }
            client.notify(method::MUX_CHANNEL_SEND, back).await?;
        }
        if once && event == "closed" {
            break;
        }
    }
    Ok(())
}

async fn open(
    peer: Option<String>,
    service: &str,
    text: Option<String>,
    reply: bool,
    json_out: bool,
) -> Result<()> {
    if reply && text.is_none() {
        bail!("--reply needs --text");
    }
    let client = crate::daemon::connect(true).await?;
    let Some(mut notes) = client.notifications().await else { bail!("no notification stream") };
    let mut params = json!({"service": service});
    if let Some(peer) = &peer {
        params["peer"] = json!(peer);
    }
    if let Some(text) = &text {
        params["text"] = json!(text);
    }
    let started = Instant::now();
    let answer = client.request(method::MUX_CHANNEL_OPEN, params).await?;
    let open_ms = started.elapsed().as_secs_f64() * 1000.0;
    let Some(id) = answer.get("channelId").and_then(Value::as_str).map(str::to_owned) else {
        bail!("the daemon named no channel: {answer}");
    };
    let mine = |p: &Value| p.get("channelId").and_then(Value::as_str) == Some(id.as_str());
    if reply {
        while let Some(msg) = notes.recv().await {
            let Message::Notification { method: m, params: Some(p) } = msg else { continue };
            if !mine(&p) {
                continue;
            }
            if m == method::MUX_CHANNEL_CLOSED {
                let reason = p.get("reason").and_then(Value::as_str).unwrap_or("closed");
                bail!("channel closed before an answer: {reason}");
            }
            if m == method::MUX_CHANNEL_DATA {
                let first_ms = started.elapsed().as_secs_f64() * 1000.0;
                let text = bytes_of(&p);
                client.notify(method::MUX_CHANNEL_CLOSE, json!({"channelId": id})).await?;
                if json_out {
                    print_json(&json!({
                        "channelId": id, "reply": text, "openMs": open_ms, "firstReplyMs": first_ms,
                    }));
                } else {
                    println!("{text}");
                }
                return Ok(());
            }
        }
        bail!("the daemon connection ended");
    }
    let mut stdin = BufReader::new(tokio::io::stdin()).lines();
    let mut stdout = tokio::io::stdout();
    let mut stdin_open = true;
    loop {
        tokio::select! {
            line = stdin.next_line(), if stdin_open => match line? {
                Some(line) => {
                    let send = json!({"channelId": id, "text": format!("{line}\n")});
                    client.notify(method::MUX_CHANNEL_SEND, send).await?;
                }
                None => {
                    stdin_open = false;
                    client.notify(method::MUX_CHANNEL_CLOSE, json!({"channelId": id})).await?;
                }
            },
            msg = notes.recv() => {
                let Some(msg) = msg else { break };
                let Message::Notification { method: m, params: Some(p) } = msg else { continue };
                if !mine(&p) {
                    continue;
                }
                if m == method::MUX_CHANNEL_CLOSED {
                    break;
                }
                if m == method::MUX_CHANNEL_DATA {
                    stdout.write_all(bytes_of(&p).as_bytes()).await?;
                    stdout.flush().await?;
                }
            }
        }
    }
    Ok(())
}
