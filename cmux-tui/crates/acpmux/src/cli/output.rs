//! Printing helpers and the streaming/attach views for the CLI.


use acpmux::client::Client;
use acpmux::rpc::{Message, method};
use acpmux::transcript::{Item, Transcript};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::sync::Arc;

pub(crate) fn arg_or_stdin(words: &[String]) -> Result<String> {
    let joined = words.join(" ");
    if !joined.is_empty() && joined != "-" {
        return Ok(joined);
    }
    let mut s = String::new();
    std::io::stdin().read_to_string(&mut s)?;
    let s = s.trim_end().to_owned();
    if s.is_empty() {
        return Err(anyhow!("empty prompt"));
    }
    Ok(s)
}

pub(crate) fn print_json(v: &Value) {
    println!("{}", serde_json::to_string_pretty(v).unwrap_or_default());
}

pub(crate) fn short(s: &str, n: usize) -> String {
    let s: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() > n {
        format!("{}…", s.chars().take(n.saturating_sub(1)).collect::<String>())
    } else {
        s
    }
}

pub(crate) fn age(ms: u64) -> String {
    let now = acpmux::store::now_ms();
    let d = now.saturating_sub(ms) / 1000;
    if d < 60 {
        format!("{d}s")
    } else if d < 3600 {
        format!("{}m", d / 60)
    } else if d < 86_400 {
        format!("{}h", d / 3600)
    } else {
        format!("{}d", d / 86_400)
    }
}

/// Send a prompt and print the reply as it streams.
pub(crate) async fn stream_prompt(client: Arc<Client>, id: &str, text: &str, steer: bool, quiet: bool, json_out: bool) -> Result<()> {
    let mut notes = client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await?;
    let c = client.clone();
    let id2 = id.to_owned();
    let text2 = text.to_owned();
    let turn = tokio::spawn(async move {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id2, "prompt": [{"type": "text", "text": text2}], "_meta": {"acpmux": {"steer": steer}}}),
        )
        .await
    });
    let mut t = Transcript::default();
    let mut printed_assistant = 0usize;
    let mut last_tool = String::new();
    let stdout = std::io::stdout();
    let mut turn = turn;
    let result = loop {
        tokio::select! {
            r = &mut turn => break r?,
            n = notes.recv() => {
                let Some(m) = n else { return Err(anyhow!("daemon connection closed")) };
                let Message::Notification { method: m, params } = m else { continue };
                let p = params.unwrap_or(Value::Null);
                if p.get("sessionId").and_then(Value::as_str) != Some(id) { continue; }
                if json_out {
                    println!("{}", json!({"method": m, "params": p}));
                    continue;
                }
                match m.as_str() {
                    method::SESSION_UPDATE => {
                        t.apply_update(&p);
                        if quiet { continue; }
                        let mut out = stdout.lock();
                        if let Some(Item::Assistant { text }) = t.items.last() {
                            if text.len() > printed_assistant {
                                let _ = write!(out, "{}", &text[printed_assistant..]);
                                let _ = out.flush();
                                printed_assistant = text.len();
                            }
                        } else {
                            printed_assistant = 0;
                        }
                        if let Some(Item::Tool { title, status, kind, .. }) = t.items.last() {
                            let line = format!("[{kind} {status}] {title}");
                            if line != last_tool {
                                let _ = writeln!(out, "\n\x1b[2m{line}\x1b[0m");
                                last_tool = line;
                            }
                        }
                    }
                    method::MUX_PERMISSION_PENDING => {
                        let title = p.pointer("/request/toolCall/title").and_then(Value::as_str).unwrap_or("permission");
                        eprintln!("\n\x1b[33mpermission needed:\x1b[0m {title}  (answer with: acpmux allow {id} | acpmux deny {id})");
                    }
                    _ => {}
                }
            }
        }
    };
    match result {
        Ok(v) => {
            if quiet {
                if let Some(Item::Assistant { text }) = t.items.iter().rev().find(|i| matches!(i, Item::Assistant { .. })) {
                    println!("{text}");
                }
            } else if json_out {
                print_json(&v);
            } else {
                let stop = v.get("stopReason").and_then(Value::as_str).unwrap_or("end_turn");
                if stop != "end_turn" {
                    eprintln!("\n\x1b[2m[{stop}]\x1b[0m");
                } else {
                    println!();
                }
            }
            Ok(())
        }
        Err(e) => Err(e),
    }
}

/// Plain streaming attach: prints everything that happens in the session.
pub(crate) async fn plain_attach(client: Arc<Client>, id: &str) -> Result<()> {
    let mut notes = client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    let v = client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 200})).await?;
    let mut t = Transcript::default();
    for e in v.get("events").and_then(Value::as_array).cloned().unwrap_or_default() {
        t.apply_event(&e);
    }
    for item in &t.items {
        print_item(item);
    }
    let mut printed = t.items.len();
    let mut assistant_len = 0usize;
    while let Some(m) = notes.recv().await {
        let Message::Notification { method: m, params } = m else { continue };
        let p = params.unwrap_or(Value::Null);
        if p.get("sessionId").and_then(Value::as_str) != Some(id) {
            continue;
        }
        match m.as_str() {
            method::SESSION_UPDATE => t.apply_update(&p),
            method::MUX_EVENT => t.apply_event(&p),
            _ => continue,
        }
        // Print new whole items, and stream the trailing assistant item.
        while printed < t.items.len().saturating_sub(1) {
            print_item(&t.items[printed]);
            printed += 1;
            assistant_len = 0;
        }
        if let Some(last) = t.items.last() {
            if printed == t.items.len() - 1 {
                match last {
                    Item::Assistant { text } => {
                        if assistant_len == 0 {
                            print!("\x1b[1massistant:\x1b[0m ");
                        }
                        if text.len() > assistant_len {
                            print!("{}", &text[assistant_len..]);
                            let _ = std::io::stdout().flush();
                            assistant_len = text.len();
                        }
                    }
                    Item::Thought { .. } => {}
                    other => {
                        print_item(other);
                        printed += 1;
                        assistant_len = 0;
                    }
                }
            }
        }
    }
    Ok(())
}

pub(crate) fn print_item(item: &Item) {
    match item {
        Item::User { text, steer, queued } => println!("\x1b[36muser{}:\x1b[0m {text}", if *steer { " (steer)" } else if *queued { " (queued)" } else { "" }),
        Item::Assistant { text } => println!("\x1b[1massistant:\x1b[0m {text}"),
        Item::Thought { text } => println!("\x1b[2mthought: {}\x1b[0m", short(text, 200)),
        Item::Tool { title, kind, status, .. } => println!("\x1b[2m[{kind} {status}] {title}\x1b[0m"),
        Item::Plan { entries } => {
            println!("\x1b[35mplan:\x1b[0m");
            for (s, c) in entries {
                println!("  [{s}] {c}");
            }
        }
        Item::Permission { title, decided, .. } => match decided {
            Some(d) => println!("\x1b[33mpermission {title}: {d}\x1b[0m"),
            None => println!("\x1b[33mpermission needed: {title}\x1b[0m"),
        },
        Item::Status { text } => println!("\x1b[2m-- {text}\x1b[0m"),
        Item::TurnEnd { stop } => println!("\x1b[2m-- turn end ({stop})\x1b[0m"),
        Item::Error { text } => println!("\x1b[31merror: {text}\x1b[0m"),
        Item::Stderr { text } => println!("\x1b[2mstderr: {text}\x1b[0m"),
    }
}

/// Send a prompt and return (last reply text, stop reason) without printing.
pub(crate) async fn collect_reply(client: Arc<Client>, id: &str, text: &str) -> Result<(String, String)> {
    let mut notes = client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await?;
    let c = client.clone();
    let id2 = id.to_owned();
    let text2 = text.to_owned();
    let mut turn = tokio::spawn(async move { c.request(method::SESSION_PROMPT, json!({"sessionId": id2, "prompt": [{"type": "text", "text": text2}]})).await });
    let mut t = Transcript::default();
    let result = loop {
        tokio::select! {
            r = &mut turn => break r?,
            n = notes.recv() => {
                let Some(m) = n else { return Err(anyhow!("daemon connection closed")) };
                let Message::Notification { method: m, params } = m else { continue };
                let p = params.unwrap_or(Value::Null);
                if p.get("sessionId").and_then(Value::as_str) != Some(id) { continue; }
                match m.as_str() {
                    method::SESSION_UPDATE => t.apply_update(&p),
                    method::MUX_EVENT => t.apply_event(&p),
                    method::MUX_PERMISSION_PENDING => {
                        let title = p.pointer("/request/toolCall/title").and_then(Value::as_str).unwrap_or("permission");
                        eprintln!("permission needed: {title}  (acpmux session allow {id} | acpmux session deny {id})");
                    }
                    _ => {}
                }
            }
        }
    };
    let reply = t.items.iter().rev().find_map(|i| match i { Item::Assistant { text } => Some(text.clone()), _ => None }).unwrap_or_default();
    let result = result?;
    let stop = result.get("stopReason").and_then(Value::as_str).unwrap_or("end_turn").to_owned();
    Ok((reply, stop))
}

/// The last `count` assistant replies of a session, oldest first.
pub(crate) async fn last_replies(client: &Arc<Client>, id: &str, count: usize) -> Result<Vec<String>> {
    let v = client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 5000})).await?;
    let mut t = Transcript::default();
    for e in v.get("events").and_then(Value::as_array).cloned().unwrap_or_default() {
        t.apply_event(&e);
    }
    let mut out: Vec<String> = t.items.iter().rev().filter_map(|i| match i { Item::Assistant { text } => Some(text.clone()), _ => None }).take(count.max(1)).collect();
    out.reverse();
    Ok(out)
}

/// Wait until each target session is no longer running, or needs a
/// permission answer. Returns (name, id, status, pending) per session.
pub(crate) async fn wait_sessions(client: Arc<Client>, targets: &[(String, String)], timeout: Option<u64>, any: bool) -> Result<Vec<(String, String, String, u64)>> {
    let mut notes = client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    client.request(method::MUX_WATCH, json!({"enabled": true})).await?;
    let deadline = timeout.map(|s| tokio::time::Instant::now() + std::time::Duration::from_secs(s));
    let snapshot = |client: Arc<Client>| async move {
        let v = client.request(method::MUX_SESSIONS, json!({})).await?;
        Ok::<Vec<Value>, anyhow::Error>(v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default())
    };
    loop {
        let sessions = snapshot(client.clone()).await?;
        let mut states = Vec::new();
        for (name, id) in targets {
            let s = sessions.iter().find(|s| s.get("sessionId").and_then(Value::as_str) == Some(id));
            let status = s.and_then(|s| s.get("status").and_then(Value::as_str)).unwrap_or("closed").to_owned();
            let pending = s.and_then(|s| s.get("pendingPermissions").and_then(Value::as_u64)).unwrap_or(0);
            states.push((name.clone(), id.clone(), status, pending));
        }
        let done = |st: &(String, String, String, u64)| st.2 != "running" || st.3 > 0;
        let finished = if any { states.iter().any(done) } else { states.iter().all(done) };
        if finished || targets.is_empty() {
            return Ok(states);
        }
        // Sleep until something changes, or a bounded poll interval passes.
        let poll = tokio::time::sleep(std::time::Duration::from_millis(1500));
        tokio::pin!(poll);
        tokio::select! {
            _ = &mut poll => {}
            n = notes.recv() => {
                if n.is_none() { return Err(anyhow!("daemon connection closed")); }
            }
        }
        if let Some(d) = deadline {
            if tokio::time::Instant::now() >= d {
                return Ok(states);
            }
        }
    }
}
