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
/// Did this notification come from the agent, not from acpmux's own
/// bookkeeping? Only agent activity resets the stall timer.
fn agent_activity(m: &str, p: &Value) -> bool {
    match m {
        method::SESSION_UPDATE | method::MUX_PERMISSION_PENDING => true,
        method::MUX_EVENT => p.get("dir").and_then(Value::as_str) == Some("in"),
        _ => false,
    }
}

/// How a turn handles permissions when nobody is there to answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OnPermission {
    Wait,
    Deny,
    Fail,
}

impl OnPermission {
    pub(crate) fn parse(s: &str) -> Result<Self> {
        match s {
            "wait" => Ok(Self::Wait),
            "deny" => Ok(Self::Deny),
            "fail" => Ok(Self::Fail),
            other => Err(crate::cli::errors::AppError::usage(format!("--on-permission must be wait, deny or fail, got {other:?}")).into()),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct CollectOpts {
    pub timeout: Option<u64>,
    pub on_permission: OnPermission,
    /// Seconds without any update after the prompt before `prompt_stalled`; 0 disables.
    pub stall_secs: u64,
    pub retries: u32,
}

pub(crate) struct CollectResult {
    pub reply: String,
    pub stop_reason: String,
    pub permissions_asked: u64,
    pub permissions_denied: u64,
}

/// Answer a pending permission on the caller's behalf when the run policy
/// says so. Returns true when the turn should be treated as failed.
async fn auto_answer(client: &Arc<Client>, id: &str, p: &Value, mode: OnPermission) -> bool {
    let pid = p.get("permissionId").and_then(Value::as_str).unwrap_or("");
    let options = p.pointer("/request/options").and_then(Value::as_array).cloned().unwrap_or_default();
    let reject = options.iter().find(|o| o.get("kind").and_then(Value::as_str).map(|k| k.starts_with("reject")).unwrap_or(false)).and_then(|o| o.get("optionId").and_then(Value::as_str)).map(str::to_owned);
    match mode {
        OnPermission::Wait => false,
        OnPermission::Deny | OnPermission::Fail => {
            let _ = client.request(method::MUX_PERMISSION_RESPOND, json!({"sessionId": id, "permissionId": pid, "optionId": reject})).await;
            mode == OnPermission::Fail
        }
    }
}

pub(crate) async fn stream_prompt(client: Arc<Client>, id: &str, text: &str, steer: bool, quiet: bool, json_out: bool, opts: CollectOpts, suppress_reads: bool) -> Result<()> {
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
    let started = tokio::time::Instant::now();
    let deadline = opts.timeout.map(|s| started + std::time::Duration::from_secs(s));
    let mut activity = false;
    let mut asked = 0u64;
    let mut denied = 0u64;
    let mut fail_permission = false;
    let mut suppressor = crate::cli::orchestrate::ReadSuppressor::default();
    let result = loop {
        let stall_at = if opts.stall_secs > 0 && !activity { Some(started + std::time::Duration::from_secs(opts.stall_secs)) } else { None };
        let next_tick = match (deadline, stall_at) {
            (Some(d), Some(s)) => Some(d.min(s)),
            (Some(d), None) => Some(d),
            (None, Some(s)) => Some(s),
            (None, None) => None,
        };
        let tick = async {
            match next_tick {
                Some(t) => tokio::time::sleep_until(t).await,
                None => std::future::pending::<()>().await,
            }
        };
        tokio::select! {
            r = &mut turn => break r?,
            _ = tick => {
                if let Some(d) = deadline
                    && tokio::time::Instant::now() >= d {
                        let _ = client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
                        let _ = tokio::time::timeout(std::time::Duration::from_millis(2500), &mut turn).await;
                        return Err(crate::cli::errors::AppError::timeout(format!("turn cancelled after {}s", opts.timeout.unwrap_or(0))).with_session(id).into());
                    }
                if !activity {
                    return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "prompt_stalled", format!("no update from the agent within {}s of sending; the turn keeps running (acpmux last {id} to check)", opts.stall_secs)).with_session(id).into());
                }
            }
            n = notes.recv() => {
                let Some(m) = n else { return Err(client.closed("streaming the session")) };
                let Message::Notification { method: m, params } = m else { continue };
                if m == method::MUX_DISCONNECTED { return Err(client.closed("streaming the session")); }
                let p = params.unwrap_or(Value::Null);
                if p.get("sessionId").and_then(Value::as_str) != Some(id) { continue; }
                if agent_activity(&m, &p) {
                    activity = true;
                }
                if m == method::MUX_PERMISSION_PENDING {
                    asked += 1;
                    if opts.on_permission != OnPermission::Wait {
                        denied += 1;
                        if auto_answer(&client, id, &p, opts.on_permission).await {
                            fail_permission = true;
                            let _ = client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
                        }
                        continue;
                    }
                }
                if json_out {
                    let p = if m == method::MUX_EVENT && suppress_reads { suppressor.apply(p) } else { p };
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
    if fail_permission || (asked > 0 && denied == asked && opts.on_permission == OnPermission::Deny) {
        return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::PermissionDenied, "all_denied", format!("every permission in the turn was denied ({denied}/{asked})")).with_session(id).into());
    }
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
        if m == method::MUX_DISCONNECTED {
            return Err(client.closed("streaming the session"));
        }
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
        if let Some(last) = t.items.last()
            && printed == t.items.len() - 1 {
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

/// Send a prompt and return the reply without printing. Honors the timeout
/// (cooperative cancel, exit 3), the permission policy (deny answers
/// reject; fail also ends the turn, exit 5), stall detection, and retries:
/// a turn is retried only on an agent-internal error and only if nothing
/// was produced, with backoff capped at 10 s.
pub(crate) async fn collect_reply(client: Arc<Client>, id: &str, text: &str, opts: CollectOpts) -> Result<CollectResult> {
    let mut attempt = 0u32;
    loop {
        match collect_once(client.clone(), id, text, opts).await {
            Ok(r) => return Ok(r),
            Err(e) => {
                let retryable = e.downcast_ref::<crate::cli::errors::AppError>().map(|a| a.retryable).unwrap_or(false);
                if !retryable || attempt >= opts.retries {
                    return Err(e);
                }
                attempt += 1;
                let backoff = std::time::Duration::from_millis((1000u64 * 2u64.pow(attempt.min(4))).min(10_000));
                eprintln!("acpmux: agent error, retry {attempt}/{} in {:?}", opts.retries, backoff);
                tokio::time::sleep(backoff).await;
            }
        }
    }
}

async fn collect_once(client: Arc<Client>, id: &str, text: &str, opts: CollectOpts) -> Result<CollectResult> {
    let mut notes = client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await?;
    let c = client.clone();
    let id2 = id.to_owned();
    let text2 = text.to_owned();
    let mut turn = tokio::spawn(async move { c.request(method::SESSION_PROMPT, json!({"sessionId": id2, "prompt": [{"type": "text", "text": text2}]})).await });
    let mut t = Transcript::default();
    let started = tokio::time::Instant::now();
    let deadline = opts.timeout.map(|s| started + std::time::Duration::from_secs(s));
    let mut activity = false;
    let mut produced = false;
    let mut asked = 0u64;
    let mut denied = 0u64;
    let mut fail_permission = false;
    let result = loop {
        let stall_at = if opts.stall_secs > 0 && !activity { Some(started + std::time::Duration::from_secs(opts.stall_secs)) } else { None };
        let next_tick = [deadline, stall_at].into_iter().flatten().min();
        let tick = async {
            match next_tick {
                Some(t) => tokio::time::sleep_until(t).await,
                None => std::future::pending::<()>().await,
            }
        };
        tokio::select! {
            r = &mut turn => break r?,
            _ = tick => {
                if let Some(d) = deadline
                    && tokio::time::Instant::now() >= d {
                        let _ = client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
                        let _ = tokio::time::timeout(std::time::Duration::from_millis(2500), &mut turn).await;
                        return Err(crate::cli::errors::AppError::timeout(format!("turn cancelled after {}s", opts.timeout.unwrap_or(0))).with_session(id).into());
                    }
                if !activity {
                    return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "prompt_stalled", format!("no update from the agent within {}s of sending; the turn keeps running (acpmux last {id} to check)", opts.stall_secs)).with_session(id).into());
                }
            }
            n = notes.recv() => {
                let Some(m) = n else { return Err(client.closed("streaming the session")) };
                let Message::Notification { method: m, params } = m else { continue };
                if m == method::MUX_DISCONNECTED { return Err(client.closed("streaming the session")); }
                let p = params.unwrap_or(Value::Null);
                if p.get("sessionId").and_then(Value::as_str) != Some(id) { continue; }
                if agent_activity(&m, &p) {
                    activity = true;
                }
                match m.as_str() {
                    method::SESSION_UPDATE => { produced = true; t.apply_update(&p) }
                    method::MUX_EVENT => {
                        // Rules and policies answer on the server; count those too.
                        if p.get("kind").and_then(Value::as_str) == Some("permission_auto") {
                            asked += 1;
                            if p.pointer("/msg/optionId").and_then(Value::as_str).map(|o| o.starts_with("reject") || o == "no").unwrap_or(false) {
                                denied += 1;
                            }
                        }
                        t.apply_event(&p)
                    }
                    method::MUX_PERMISSION_PENDING => {
                        asked += 1;
                        produced = true;
                        match opts.on_permission {
                            OnPermission::Wait => {
                                let title = p.pointer("/request/toolCall/title").and_then(Value::as_str).unwrap_or("permission");
                                eprintln!("permission needed: {title}  (acpmux session allow {id} | acpmux session deny {id})");
                            }
                            mode => {
                                denied += 1;
                                if auto_answer(&client, id, &p, mode).await {
                                    fail_permission = true;
                                    let _ = client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    };
    if fail_permission || (asked > 0 && denied == asked && opts.on_permission == OnPermission::Deny) {
        return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::PermissionDenied, "all_denied", format!("every permission in the turn was denied ({denied}/{asked})")).with_session(id).into());
    }
    let result = match result {
        Ok(v) => v,
        Err(e) => {
            // ACP internal (-32603) or parse (-32700) errors with nothing
            // produced are the only retryable failures.
            let msg = e.to_string();
            let retryable = !produced && (msg.contains("-32603") || msg.contains("-32700") || msg.to_lowercase().contains("internal error"));
            let mut app = crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "agent_error", msg).with_session(id);
            if retryable {
                app = app.retryable();
            }
            return Err(app.into());
        }
    };
    let reply = t.items.iter().rev().find_map(|i| match i { Item::Assistant { text } => Some(text.clone()), _ => None }).unwrap_or_default();
    let stop_reason = result.get("stopReason").and_then(Value::as_str).unwrap_or("end_turn").to_owned();
    Ok(CollectResult { reply, stop_reason, permissions_asked: asked, permissions_denied: denied })
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
