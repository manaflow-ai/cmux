//! Orchestration commands: wait, ensure, exec, tag, rules, history,
//! compare, skill, schema, tail cursors. Everything here is meant to be
//! called by another agent or a script, so output is stable and errors
//! carry exit codes (see errors.rs).

use crate::cli::errors::{AppError, Code};
use crate::cli::output::*;
use crate::cli::run::resolve_id;
use crate::client::Client;
use crate::rpc::{Message, method};
use crate::transcript::Transcript;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::io::Write;
use std::sync::Arc;

pub(crate) const SKILL: &str = include_str!("../../skills/acpmux/SKILL.md");
mod presets;
pub(crate) use presets::{defaults, preset};

/// The guide text: the skill file without its frontmatter.
pub(crate) fn guide() -> &'static str {
    SKILL
        .strip_prefix("---\n")
        .and_then(|rest| rest.find("\n---\n").map(|i| &rest[i + 5..]))
        .unwrap_or(SKILL)
        .trim_start()
}

/// `@` or `current` names the caller's own session (ACPMUX_SESSION_ID).
pub(crate) fn expand_session_key(key: &str) -> Result<String> {
    if key == "@" || key == "current" || key == "--current" {
        return std::env::var("ACPMUX_SESSION_ID").map_err(|_| AppError::new(Code::NoSession, "no_current_session", "no current session: ACPMUX_SESSION_ID is not set (are you running inside an acpmux session?)").into());
    }
    Ok(key.to_owned())
}

/// Send an OSC 9 (Ghostty, iTerm2, WezTerm) or OSC 99 (kitty) desktop
/// notification through the terminal, tmux passthrough included.
pub(crate) fn terminal_notify(title: &str, body: &str) {
    let clean = |s: &str| s.chars().filter(|c| !c.is_control()).collect::<String>();
    let (title, body) = (clean(title), clean(body));
    let kitty = std::env::var("KITTY_WINDOW_ID").is_ok()
        || std::env::var("TERM").map(|t| t.contains("kitty")).unwrap_or(false);
    let seq = if kitty {
        format!("\x1b]99;i=1:d=0;{title}\x1b\\\x1b]99;i=1:p=body;{body}\x1b\\")
    } else {
        format!("\x1b]9;{title}: {body}\x1b\\")
    };
    let seq = if std::env::var("TMUX").is_ok() {
        format!("\x1bPtmux;{}\x1b\\", seq.replace('\x1b', "\x1b\x1b"))
    } else {
        seq
    };
    let mut out = std::io::stderr();
    let _ = out.write_all(seq.as_bytes());
    let _ = out.flush();
}

pub(crate) struct WaitOpts {
    pub sessions: Vec<String>,
    pub until: Vec<String>,
    pub all: bool,
    pub timeout: Option<u64>,
    pub print: bool,
    pub notify: bool,
    pub matcher: Option<Matcher>,
}

pub(crate) enum Matcher {
    Text(String),
    Regex(regex::Regex),
}

impl Matcher {
    fn hit(&self, text: &str) -> Option<String> {
        match self {
            Matcher::Text(t) => text.lines().find(|l| l.contains(t.as_str())).map(str::to_owned),
            Matcher::Regex(r) => text.lines().find(|l| r.is_match(l)).map(str::to_owned),
        }
    }
}

/// What the agent produced (replies, tool output, thoughts), for --match.
/// Your own prompts are left out so a wait cannot match its own words.
fn transcript_text(t: &Transcript) -> String {
    t.items
        .iter()
        .filter(|i| !matches!(i, crate::transcript::Item::User { .. }))
        .map(crate::transcript::item_text)
        .collect::<Vec<_>>()
        .join("\n")
}

/// `acpmux wait`: server-side state wait, or a client-side text match.
pub(crate) async fn wait(client: Arc<Client>, opts: WaitOpts, json_out: bool) -> Result<()> {
    // Resolve names first so a typo is exit 4, not a silent no-op.
    let mut ids: Vec<(String, String)> = Vec::new();
    for key in &opts.sessions {
        let key = expand_session_key(key)?;
        let id = resolve_id(&client, &key).await?;
        ids.push((key, id));
    }
    if let Some(matcher) = &opts.matcher {
        if ids.is_empty() {
            return Err(
                AppError::usage("--match and --regex need at least one session name").into()
            );
        }
        return wait_match(client, &ids, matcher, opts.timeout, opts.all, opts.notify, json_out)
            .await;
    }
    let params = json!({
        "sessions": ids.iter().map(|(_, id)| id.clone()).collect::<Vec<_>>(),
        "until": opts.until,
        "all": opts.all,
        "timeoutMs": opts.timeout.map(|s| s * 1000),
    });
    let v = client.request(method::MUX_WAIT, params).await?;
    let sessions = v.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    let resolved = v.get("resolved").and_then(Value::as_array).cloned().unwrap_or_default();
    let timed_out = v.get("timedOut").and_then(Value::as_bool).unwrap_or(false);
    if sessions.is_empty() {
        if json_out {
            print_json(&json!({"sessions": [], "resolved": []}));
        } else {
            println!("nothing is running");
        }
        return Ok(());
    }
    let shown: Vec<Value> = if opts.all || timed_out { sessions.clone() } else { resolved.clone() };
    let mut rows = Vec::new();
    let mut code = 0;
    for s in &shown {
        let id = s.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
        let name = s.get("name").and_then(Value::as_str).unwrap_or(&id).to_owned();
        let status = s.get("status").and_then(Value::as_str).unwrap_or("").to_owned();
        let pending = s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0);
        let reply = if opts.print || json_out {
            last_replies(&client, &id, 1).await.unwrap_or_default().pop().unwrap_or_default()
        } else {
            String::new()
        };
        code = code.max(session_exit_code(s));
        rows.push(json!({"name": name, "sessionId": id, "status": status, "pendingPermissions": pending, "unread": s.get("unread"), "matched": s.get("matched"), "reply": reply}));
        if opts.notify {
            terminal_notify(
                "acpmux",
                &if pending > 0 {
                    format!("{name} needs a permission")
                } else {
                    format!("{name} finished")
                },
            );
        }
    }
    if timed_out {
        code = 3;
    }
    if json_out {
        print_json(&json!({"sessions": rows, "timedOut": timed_out}));
    } else {
        for r in &rows {
            let g = |k: &str| r.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            let pend = r.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0);
            let state =
                if pend > 0 { format!("waiting for permission ({pend})") } else { g("status") };
            println!("{:<24} {}", g("name"), state);
            if opts.print && !g("reply").is_empty() {
                println!("{}", g("reply"));
                println!();
            }
        }
        if timed_out {
            eprintln!("acpmux: timeout: no session resolved in time");
        }
    }
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}

/// Exit code a waited-on session contributes: 2 while it waits for a
/// permission, 1 when its last turn failed, otherwise 0.
fn session_exit_code(s: &Value) -> i32 {
    if s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0 {
        2
    } else if s.pointer("/lastTurn/status").and_then(Value::as_str) == Some("failed") {
        1
    } else {
        0
    }
}

/// Resolve when a session's transcript contains the text (with `all`,
/// when every session's does). Existing text matches at once; then live
/// updates are followed.
async fn wait_match(
    client: Arc<Client>,
    ids: &[(String, String)],
    matcher: &Matcher,
    timeout: Option<u64>,
    all: bool,
    notify: bool,
    json_out: bool,
) -> Result<()> {
    let mut notes =
        client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    let mut transcripts: Vec<(String, String, Transcript)> = Vec::new();
    for (name, id) in ids {
        // The whole history, oldest page first: a match can be old. The
        // first attach subscribes, so nothing written meanwhile is lost.
        let mut t = Transcript::default();
        let mut after = 0u64;
        loop {
            let page = json!({"sessionId": id, "afterSeq": after, "limit": 5000});
            let v = client.request(method::MUX_ATTACH, page).await?;
            let events = v.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
            for e in &events {
                t.apply_event(e);
            }
            let last = events.last().and_then(|e| e.get("seq")).and_then(Value::as_u64);
            match last {
                Some(seq) if v.get("hasMore") == Some(&json!(true)) && seq > after => after = seq,
                _ => break,
            }
        }
        transcripts.push((name.clone(), id.clone(), t));
    }
    let need = if all { transcripts.len() } else { 1 };
    let mut matched = vec![false; transcripts.len()];
    let mut rows: Vec<Value> = Vec::new();
    let report = |name: &str, id: &str, line: &str| {
        if !json_out {
            println!("{name:<24} matched: {line}");
        }
        if notify {
            terminal_notify(
                "acpmux",
                &format!("{name}: {}", line.chars().take(80).collect::<String>()),
            );
        }
        json!({"name": name, "sessionId": id, "matched": ["text"], "line": line})
    };
    for (i, (name, id, t)) in transcripts.iter().enumerate() {
        if rows.len() >= need {
            break;
        }
        if let Some(line) = matcher.hit(&transcript_text(t)) {
            matched[i] = true;
            rows.push(report(name, id, &line));
        }
    }
    let deadline = timeout.map(|s| tokio::time::Instant::now() + std::time::Duration::from_secs(s));
    while rows.len() < need {
        let next = async { notes.recv().await };
        let m = match deadline {
            Some(d) => match tokio::time::timeout_at(d, next).await {
                Ok(m) => m,
                Err(_) => {
                    return Err(AppError::timeout("no session produced the text in time").into());
                }
            },
            None => next.await,
        };
        let Some(Message::Notification { method: m, params }) = m else {
            return Err(client.closed("following the session events"));
        };
        if m == method::MUX_DISCONNECTED {
            return Err(client.closed("following the session events"));
        }
        let p = params.unwrap_or(Value::Null);
        let sid = p.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
        let Some(i) = transcripts.iter().position(|(_, id, _)| *id == sid) else {
            continue;
        };
        if matched[i] {
            continue;
        }
        let (name, id, t) = &mut transcripts[i];
        match m.as_str() {
            method::SESSION_UPDATE => t.apply_update(&p),
            method::MUX_EVENT => t.apply_event(&p),
            _ => continue,
        }
        if let Some(line) = matcher.hit(&transcript_text(t)) {
            matched[i] = true;
            rows.push(report(name, id, &line));
        }
    }
    if json_out {
        print_json(&json!({"sessions": rows, "timedOut": false}));
    }
    Ok(())
}

/// `acpmux ensure NAME`: the session if it exists, else create it.
/// `HARNESS[/MODEL]` → (harness, model). The first slash splits; the model
/// keeps its own slashes (`opencode/zai/glm-5.1` → `opencode`, `zai/glm-5.1`).
pub(crate) fn split_target(spec: &str) -> (String, Option<String>) {
    match spec.split_once('/') {
        Some((h, m)) if !m.is_empty() => (h.to_owned(), Some(m.to_owned())),
        Some((h, _)) => (h.to_owned(), None),
        None => (spec.to_owned(), None),
    }
}

pub(crate) async fn ensure(
    client: Arc<Client>,
    name: &str,
    target: Option<String>,
    preset: Option<String>,
    host: Option<String>,
    cwd: Option<std::path::PathBuf>,
    policy: Option<String>,
    effort: Option<String>,
    json_out: bool,
) -> Result<()> {
    let (agent, model) = match &target {
        Some(t) => {
            let (h, m) = split_target(t);
            (Some(h), m)
        }
        None => (None, None),
    };
    crate::session_name::validate(name).map_err(AppError::usage)?;
    let existing = client.request(method::MUX_SESSIONS, json!({})).await?;
    let full = match &host {
        Some(h) => format!("{h}/{name}"),
        None => name.to_owned(),
    };
    let found = existing.get("sessions").and_then(Value::as_array).and_then(|a| {
        a.iter().find(|s| s.get("name").and_then(Value::as_str) == Some(full.as_str())).cloned()
    });
    let (v, created) = match found {
        Some(s) => (s, false),
        None => {
            let mut meta = json!({"name": name});
            if let Some(a) = &agent {
                meta["harness"] = json!(a);
            }
            if let Some(p) = &preset {
                meta["preset"] = json!(p);
            }
            if let Some(p) = &policy {
                meta["policy"] = json!(p);
            }
            if let Some(h) = &host {
                meta["peer"] = json!(h);
            }
            if let Some(m) = &model {
                meta["model"] = json!(m);
            }
            if let Some(e) = &effort {
                meta["effort"] = json!(e);
            }
            let mut p = json!({"mcpServers": [], "_meta": {"acpmux": meta}});
            match (&host, cwd) {
                (Some(_), Some(c)) => p["cwd"] = json!(c),
                (Some(_), None) => {}
                (None, c) => p["cwd"] = json!(c.unwrap_or(std::env::current_dir()?)),
            }
            let v = client.request(method::SESSION_NEW, p).await?;
            let id = v.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
            (client.request(method::MUX_INFO, json!({"sessionId": id})).await?, true)
        }
    };
    let id = v.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
    if json_out {
        let mut out = v.clone();
        out["created"] = json!(created);
        print_json(&out);
    } else {
        println!(
            "{} {name} ({})",
            if created { "created" } else { "found" },
            &id[..8.min(id.len())]
        );
    }
    Ok(())
}

/// `acpmux history NAME`.
pub(crate) async fn history(
    client: Arc<Client>,
    key: &str,
    limit: usize,
    json_out: bool,
) -> Result<()> {
    let id = resolve_id(&client, &expand_session_key(key)?).await?;
    let v = client.request(method::MUX_HISTORY, json!({"sessionId": id, "limit": limit})).await?;
    if json_out {
        print_json(&v);
        return Ok(());
    }
    let turns = v.get("turns").and_then(Value::as_array).cloned().unwrap_or_default();
    if turns.is_empty() {
        println!("no turns yet");
        return Ok(());
    }
    println!("{:<5} {:<10} {:>7} {:>5} {:>8} PROMPT", "SEQ", "STATUS", "WALL", "TOOLS", "TOKENS");
    for t in turns {
        let g = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
        let wall = t
            .get("wallMs")
            .and_then(Value::as_u64)
            .map(|ms| format!("{:.1}s", ms as f64 / 1000.0))
            .unwrap_or_else(|| "-".into());
        let tokens = t
            .get("tokens")
            .and_then(Value::as_u64)
            .map(|n| n.to_string())
            .unwrap_or_else(|| "-".into());
        println!(
            "{:<5} {:<10} {:>7} {:>5} {:>8} {}",
            t.get("seq").and_then(Value::as_u64).unwrap_or(0),
            g("status"),
            wall,
            t.get("toolCalls").and_then(Value::as_u64).unwrap_or(0),
            tokens,
            short(&g("prompt"), 60)
        );
    }
    Ok(())
}

/// `acpmux session tag NAME k=v… [--remove k] [--ttl S]`.
pub(crate) async fn tag(
    client: Arc<Client>,
    key: &str,
    assignments: Vec<String>,
    remove: Vec<String>,
    ttl: Option<u64>,
    json_out: bool,
) -> Result<()> {
    let id = resolve_id(&client, &expand_session_key(key)?).await?;
    let mut set = serde_json::Map::new();
    for a in &assignments {
        let (k, v) = a
            .split_once('=')
            .ok_or_else(|| AppError::usage(format!("tag must be key=value, got {a:?}")))?;
        set.insert(k.to_owned(), json!(v));
    }
    let v = client
        .request(
            method::MUX_TAG,
            json!({"sessionId": id, "set": set, "remove": remove, "ttlSeconds": ttl}),
        )
        .await?;
    if json_out {
        print_json(&v);
    } else {
        let tags = v.get("tags").and_then(Value::as_object).cloned().unwrap_or_default();
        let list: Vec<String> =
            tags.iter().map(|(k, v)| format!("{k}={}", v.as_str().unwrap_or(""))).collect();
        println!("{}", if list.is_empty() { "no tags".to_owned() } else { list.join(" ") });
    }
    Ok(())
}

/// `acpmux session rules NAME '{json}' | @file | --clear`.
pub(crate) async fn rules(
    client: Arc<Client>,
    key: &str,
    rules: Option<String>,
    clear: bool,
    json_out: bool,
) -> Result<()> {
    let id = resolve_id(&client, &expand_session_key(key)?).await?;
    let value: Value = if clear {
        Value::Null
    } else {
        match rules {
            Some(r) => {
                let text = if let Some(path) = r.strip_prefix('@') {
                    std::fs::read_to_string(path)?
                } else {
                    r
                };
                serde_json::from_str(&text)
                    .map_err(|e| AppError::usage(format!("rules must be JSON: {e}")))?
            }
            None => {
                let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
                let cur = info.get("rulesJson").cloned().unwrap_or(Value::Null);
                if json_out {
                    print_json(&json!({"sessionId": id, "rules": cur}));
                } else if cur.is_null() {
                    println!("no rules (policy decides)");
                } else {
                    println!("{}", serde_json::to_string_pretty(&cur)?);
                }
                return Ok(());
            }
        }
    };
    let v = client.request(method::MUX_SET_RULES, json!({"sessionId": id, "rules": value})).await?;
    if json_out {
        print_json(&v);
    } else {
        println!(
            "{}",
            if v.get("rules").and_then(Value::as_bool).unwrap_or(false) {
                "rules set"
            } else {
                "rules cleared"
            }
        );
    }
    Ok(())
}

/// `acpmux compare a b "prompt"`: one temporary session per harness, run
/// one after another in the same directory so writes cannot race.
pub(crate) async fn compare(
    client: Arc<Client>,
    harnesses: Vec<String>,
    prompt: String,
    cwd: Option<std::path::PathBuf>,
    policy: Option<String>,
    timeout: Option<u64>,
    json_out: bool,
) -> Result<()> {
    let agents = harnesses;
    if agents.is_empty() {
        return Err(AppError::usage("compare needs at least one harness").into());
    }
    let cwd = cwd.unwrap_or(std::env::current_dir()?);
    let mut rows = Vec::new();
    let mut worst = 0;
    for spec in &agents {
        let (agent, model) = split_target(spec);
        let agent = &agent;
        let name = format!(
            "compare-{}-{}",
            agent.replace('/', "-"),
            &uuid::Uuid::now_v7().to_string()[..8]
        );
        let mut meta = json!({"name": name, "harness": agent});
        if let Some(m) = &model {
            meta["model"] = json!(m);
        }
        if let Some(p) = &policy {
            meta["policy"] = json!(p);
        }
        let started = std::time::Instant::now();
        let created = client
            .request(
                method::SESSION_NEW,
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}}),
            )
            .await;
        let row = match created {
            Err(e) => {
                let app = crate::cli::errors::classify(&e);
                worst = worst.max(app.code as i32);
                json!({"harness": spec, "status": "error", "error": e.to_string()})
            }
            Ok(v) => {
                let id = v.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
                let outcome = collect_reply(
                    client.clone(),
                    &id,
                    &prompt,
                    CollectOpts {
                        timeout,
                        on_permission: OnPermission::Wait,
                        stall_secs: 0,
                        retries: 0,
                    },
                    &crate::cli::output::PromptId::new(None),
                )
                .await;
                let wall = started.elapsed().as_millis() as u64;
                let stats = turn_stats(&client, &id).await;
                let _ =
                    client.request(method::MUX_KILL, json!({"sessionId": id, "purge": true})).await;
                match outcome {
                    Ok(r) => {
                        json!({"harness": spec, "status": if r.stop_reason == "cancelled" { "cancelled" } else { "ok" }, "stopReason": r.stop_reason, "wallMs": wall, "tokens": stats.0, "toolCalls": stats.1, "permissions": r.permissions_asked, "permissionsDenied": r.permissions_denied, "reply": r.reply.chars().take(200).collect::<String>()})
                    }
                    Err(e) => {
                        let app = crate::cli::errors::classify(&e);
                        worst = worst.max(app.code as i32);
                        json!({"harness": spec, "status": app.code.name(), "wallMs": wall, "error": app.message})
                    }
                }
            }
        };
        rows.push(row);
    }
    if json_out {
        print_json(&json!({"prompt": prompt, "results": rows}));
    } else {
        println!(
            "{:<10} {:<10} {:>8} {:>7} {:>5} {:>5} REPLY",
            "AGENT", "STATUS", "WALL", "TOKENS", "TOOLS", "PERMS"
        );
        for r in &rows {
            let g = |k: &str| r.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            let n = |k: &str| {
                r.get(k)
                    .and_then(Value::as_u64)
                    .map(|v| v.to_string())
                    .unwrap_or_else(|| "-".into())
            };
            let wall = r
                .get("wallMs")
                .and_then(Value::as_u64)
                .map(|ms| format!("{:.1}s", ms as f64 / 1000.0))
                .unwrap_or_else(|| "-".into());
            let text = if g("reply").is_empty() { g("error") } else { g("reply") };
            println!(
                "{:<10} {:<10} {:>8} {:>7} {:>5} {:>5} {}",
                short(&g("harness"), 10),
                g("status"),
                wall,
                n("tokens"),
                n("toolCalls"),
                n("permissions"),
                short(&text.replace('\n', " "), 60)
            );
        }
    }
    if worst != 0 {
        std::process::exit(worst);
    }
    Ok(())
}

/// (tokens, tool calls) of the last turn, from history.
async fn turn_stats(client: &Arc<Client>, id: &str) -> (Option<u64>, u64) {
    let h = client
        .request(method::MUX_HISTORY, json!({"sessionId": id, "limit": 1}))
        .await
        .unwrap_or(Value::Null);
    let t = h
        .get("turns")
        .and_then(Value::as_array)
        .and_then(|a| a.last())
        .cloned()
        .unwrap_or(Value::Null);
    (
        t.get("tokens").and_then(Value::as_u64),
        t.get("toolCalls").and_then(Value::as_u64).unwrap_or(0),
    )
}

/// `acpmux session tail NAME [--since CURSOR] [--last N] [-f]`.
pub(crate) async fn tail(
    client: Arc<Client>,
    key: &str,
    last: u64,
    since: Option<String>,
    follow: bool,
    suppress_reads: bool,
) -> Result<()> {
    let id = resolve_id(&client, &expand_session_key(key)?).await?;
    let mut notes =
        client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    let events: Vec<Value> = match since {
        Some(cursor) => {
            let seq = parse_cursor(&cursor, &id)?;
            // Subscribe before reading from the cursor, so an event written
            // in between arrives live; the seq check below drops repeats.
            client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await?;
            let v = client
                .request(
                    method::MUX_EVENTS,
                    json!({"sessionId": id, "afterSeq": seq, "limit": 100000}),
                )
                .await?;
            v.get("events").and_then(Value::as_array).cloned().unwrap_or_default()
        }
        None => {
            let v =
                client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": last})).await?;
            v.get("events").and_then(Value::as_array).cloned().unwrap_or_default()
        }
    };
    let stdout = std::io::stdout();
    let mut sup = ReadSuppressor::default();
    let filter = |sup: &mut ReadSuppressor, e: Value| if suppress_reads { sup.apply(e) } else { e };
    // The newest seq printed: a live event at or below it was in the page.
    let mut printed_seq = 0u64;
    for e in events {
        printed_seq = printed_seq.max(e.get("seq").and_then(Value::as_u64).unwrap_or(0));
        let mut lock = stdout.lock();
        let _ = writeln!(lock, "{}", with_cursor(&id, filter(&mut sup, e)));
    }
    if !follow {
        return Ok(());
    }
    while let Some(m) = notes.recv().await {
        if let Message::Notification { method: m, params } = m {
            if m == method::MUX_DISCONNECTED {
                return Err(client.closed("following the session"));
            }
            let p = params.unwrap_or(Value::Null);
            if p.get("sessionId").and_then(Value::as_str) != Some(id.as_str()) {
                continue;
            }
            let seq = if m == method::MUX_EVENT {
                p.get("seq").and_then(Value::as_u64)
            } else {
                p.pointer("/_meta/acpmux/seq").and_then(Value::as_u64)
            };
            if seq.is_some_and(|s| s <= printed_seq) {
                continue;
            }
            let mut lock = stdout.lock();
            let line = if m == method::MUX_EVENT {
                with_cursor(&id, filter(&mut sup, p))
            } else if m == method::SESSION_UPDATE && suppress_reads {
                json!({"method": m, "params": sup.apply_update(p)})
            } else {
                json!({"method": m, "params": p})
            };
            let _ = writeln!(lock, "{line}");
        }
    }
    Ok(())
}

/// A cursor is `<sessionId>:<seq>` or a bare seq.
pub(crate) fn parse_cursor(cursor: &str, id: &str) -> Result<u64> {
    let (sid, seq) = match cursor.rsplit_once(':') {
        Some((s, n)) => (Some(s), n),
        None => (None, cursor),
    };
    if let Some(s) = sid
        && s != id
    {
        return Err(AppError::new(
            Code::Usage,
            "cursor_foreign",
            format!("cursor belongs to session {s}, not {id}"),
        )
        .into());
    }
    seq.parse::<u64>().map_err(|_| {
        AppError::new(
            Code::Usage,
            "cursor_invalid",
            format!("cursor {cursor:?} is not <sessionId>:<seq>"),
        )
        .into()
    })
}

fn with_cursor(id: &str, mut e: Value) -> Value {
    if let Some(seq) = e.get("seq").and_then(Value::as_u64) {
        e["cursor"] = json!(format!("{id}:{seq}"));
    }
    e
}

/// --suppress-reads: blank read-tool payloads but keep the message shape.
/// Stateful, because a `tool_call_update` names only its tool call id: the
/// id is learned from the `tool_call` that announced a read, search or
/// fetch. Raw Claude `claude.user` tool results with a `file` payload are
/// blanked too.
#[derive(Default)]
pub(crate) struct ReadSuppressor {
    read_ids: std::collections::HashSet<String>,
}

impl ReadSuppressor {
    pub(crate) fn apply(&mut self, mut e: Value) -> Value {
        let kind = e.get("kind").and_then(Value::as_str).unwrap_or("").to_owned();
        let placeholder = "[read output suppressed]";
        if kind == "tool_call" || kind == "tool_call_update" {
            let id = e
                .pointer("/msg/params/update/toolCallId")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let is_read_kind = e
                .pointer("/msg/params/update/kind")
                .and_then(Value::as_str)
                .map(|k| matches!(k, "read" | "search" | "fetch"))
                .unwrap_or(false);
            if is_read_kind && let Some(id) = &id {
                self.read_ids.insert(id.clone());
            }
            let is_read =
                is_read_kind || id.as_ref().map(|i| self.read_ids.contains(i)).unwrap_or(false);
            if is_read && let Some(u) = e.pointer_mut("/msg/params/update") {
                if u.get("content").is_some() {
                    u["content"] = json!([{"type": "content", "content": {"type": "text", "text": placeholder}}]);
                }
                if u.get("rawOutput").is_some() {
                    u["rawOutput"] = json!(placeholder);
                }
            }
        } else if kind == "claude.user" && e.pointer("/msg/tool_use_result/file").is_some() {
            if let Some(f) = e.pointer_mut("/msg/tool_use_result/file")
                && f.get("content").is_some()
            {
                f["content"] = json!(placeholder);
            }
            if let Some(arr) = e.pointer_mut("/msg/message/content").and_then(Value::as_array_mut) {
                for c in arr {
                    if c.get("content").is_some() {
                        c["content"] = json!(placeholder);
                    }
                }
            }
        }
        e
    }

    /// The same for the params of a live `session/update` notification,
    /// which carry the update without the event envelope.
    pub(crate) fn apply_update(&mut self, params: Value) -> Value {
        let kind = params.pointer("/update/sessionUpdate").cloned().unwrap_or(Value::Null);
        let mut e = self.apply(json!({"kind": kind, "msg": {"params": params}}));
        e.pointer_mut("/msg/params").map(Value::take).unwrap_or(Value::Null)
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod target_tests;
