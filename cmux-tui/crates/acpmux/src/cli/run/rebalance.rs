//! `acpmux session rebalance`: one pass of the lane rebalancer on this host (`crate::rebalance`
//! decides; this reads the daemon, moves, and writes receipts). A host over its
//! `lanes.max_lanes` sends its excess sessions that sit at a turn boundary, holding nothing, to
//! the hosts `_acpmux/place` gives room, each through `acpmux session move --after-turn` (the one
//! move path, with its own checks). With no host that has room, it asks the fleet for a fresh
//! machine once a pass (`lane_overflow.providers`, `hub/admission_scale_up.rs`).
//!
//! Receipts and pass records: `$ACPMUX_HOME/rebalance.jsonl`. `--undo ID` moves a receipt's
//! session back. Off unless the registry's `lane_overflow.rebalance.enabled` is true: a pass then
//! only plans and records what it would move (`--force` acts anyway).

use super::*;
use crate::rebalance as rb;
use std::io::Write as _;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// What one call does.
pub(crate) struct Args {
    pub dry_run: bool,
    pub force: bool,
    pub max_moves: Option<usize>,
    pub timeout: u64,
    pub undo: Option<String>,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn log_path() -> PathBuf {
    home().join("rebalance.jsonl")
}

fn append(line: &Value) {
    let path = log_path();
    let wrote = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .and_then(|mut f| writeln!(f, "{line}"));
    if let Err(e) = wrote {
        eprintln!("acpmux: rebalance: could not write {}: {e}", path.display());
    }
}

fn receipt_by_id(id: &str) -> Option<Value> {
    let text = std::fs::read_to_string(log_path()).ok()?;
    text.lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|v| v.get("id").and_then(Value::as_str) == Some(id))
        .last()
}

/// The local session list's rows, and whether the daemon lists `session-idle-facts-v1`.
async fn read_here(client: &Client) -> Result<(Vec<Value>, bool)> {
    let status = client.request(method::MUX_STATUS, json!({})).await?;
    let facts = status
        .pointer("/capabilities")
        .and_then(Value::as_array)
        .is_some_and(|ids| ids.iter().any(|x| x == rb::IDLE_FACTS));
    let list = client.whole_list(method::MUX_SESSIONS, json!({})).await?;
    let rows = list.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    Ok((rows, facts))
}

/// Runs `acpmux session move ARGS --json` (the one move path), bounded: its answer's JSON.
async fn session_move(args: &[&str], bound: Duration) -> Result<Value, String> {
    use std::process::Stdio;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut command = tokio::process::Command::new(exe);
    command
        .args(["session", "move"])
        .args(args)
        .arg("--json")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let out = tokio::time::timeout(bound, command.output())
        .await
        .map_err(|_| format!("session move ran past {}s", bound.as_secs()))?
        .map_err(|e| e.to_string())?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let last = stdout.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("");
    match serde_json::from_str::<Value>(last.trim()) {
        Ok(v) => Ok(v),
        Err(_) => {
            let err = String::from_utf8_lossy(&out.stderr);
            Err(err.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("no answer").to_owned())
        }
    }
}

/// Asks the fleet for a fresh machine through `lane_overflow.providers`, once: the first host a
/// provider answers, or why none did.
async fn spill(registry: &Value, here: &str) -> Value {
    use crate::hub::admission_scale_up as up;
    let source = crate::placement::registry_path().unwrap_or_default();
    let Some(plan) = up::plan(registry, &source, here, up::workspace_of(&source).as_deref()) else {
        return json!({"asked": false, "why": "no lane_overflow.providers here"});
    };
    let mut tried = Vec::new();
    for p in plan.providers {
        let name = p.name.clone();
        let bound = plan.budget + Duration::from_secs(10);
        let answer = tokio::task::spawn_blocking(move || up::run_provider_blocking(&p, bound))
            .await
            .unwrap_or_else(|e| up::Answer::Failed { why: e.to_string(), terminal: false });
        match answer {
            up::Answer::Host(host) => {
                return json!({"asked": true, "provider": name, "host": host, "tried": tried});
            }
            up::Answer::Failed { why, terminal } => {
                tried.push(json!({"provider": name, "error": why}));
                if terminal {
                    break;
                }
            }
        }
    }
    json!({"asked": true, "host": null, "tried": tried})
}

pub(crate) async fn run(args: Args, json_out: bool) -> Result<()> {
    if let Some(id) = &args.undo {
        return undo(id, args.timeout, json_out).await;
    }
    let registry = crate::placement::load_registry();
    let mut conf = rb::conf(registry.as_ref());
    if let Some(n) = args.max_moves {
        conf.max_moves = n;
    }
    let here = crate::host_pressure::host_name();
    let (cap, _) = crate::session_budget::lanes_of(registry.as_ref(), &here);
    let client = connect(true).await?;
    let (rows, facts) = read_here(&client).await?;
    let started = now_ms();
    let mut targets = Vec::new();
    let mut place_error = None;
    let over = cap.is_some_and(|c| rows.iter().filter(|r| rb::counts_live(r)).count() as u64 > c);
    if over {
        match client
            .request(
                "_acpmux/place",
                json!({"work": "agent", "offInteractive": true, "outdatedOk": true}),
            )
            .await
        {
            Ok(v) => targets = rb::targets(&v, registry.as_ref(), &here),
            Err(e) => place_error = Some(format!("{e:#}")),
        }
    }
    let plan = rb::plan(&rows, facts, cap, targets, &conf, started);
    let acting = !args.dry_run && (conf.enabled || args.force);
    let mut pass = plan.to_json();
    if let Some(o) = pass.as_object_mut() {
        o.insert("kind".into(), json!("pass"));
        o.insert("atMs".into(), json!(started));
        o.insert("host".into(), json!(here));
        o.insert("idleFacts".into(), json!(facts));
        o.insert("enabled".into(), json!(conf.enabled));
        o.insert("acting".into(), json!(acting));
        o.insert("placeError".into(), json!(place_error));
    }
    let mut done = Vec::new();
    if acting {
        let bound = Duration::from_secs(args.timeout + 120);
        for (n, m) in plan.moves.iter().enumerate() {
            let id = format!("rb-{started}-{n}");
            // Read again just before: a chat prompted since the plan stays.
            let still: Result<(), String> = match read_here(&client).await {
                Ok((rows, facts)) => {
                    match rows
                        .iter()
                        .find(|r| r.get("sessionId").and_then(Value::as_str) == Some(&m.session_id))
                    {
                        Some(r) => match rb::held(r, facts, now_ms(), conf.min_idle_secs * 1000) {
                            Some(why) => Err(format!("held since the plan: {why}")),
                            None => Ok(()),
                        },
                        None => Err("gone since the plan".into()),
                    }
                }
                Err(e) => Err(format!("{e:#}")),
            };
            let mut d = rb::Done {
                source: here.clone(),
                session_id: m.session_id.clone(),
                name: m.name.clone(),
                target: m.target.clone(),
                error: still.err(),
                ..rb::Done::default()
            };
            if d.error.is_none() {
                let t0 = Instant::now();
                let timeout = args.timeout.to_string();
                let answer = session_move(
                    &[&m.session_id, "--machine", &m.target, "--after-turn", "--timeout", &timeout],
                    bound,
                )
                .await;
                d.unavailable_ms = t0.elapsed().as_millis() as u64;
                match answer.and_then(|v| rb::moved_to(&v)) {
                    Ok(there) => d.there = Some(there),
                    Err(e) => d.error = Some(e),
                }
            }
            let r = rb::receipt(&id, now_ms(), &d, &plan.why);
            append(&r);
            done.push(r);
        }
        if plan.spill > 0
            && let Some(reg) = registry.as_ref()
        {
            let asked = spill(reg, &here).await;
            if let Some(o) = pass.as_object_mut() {
                o.insert("fresh".into(), asked);
            }
        }
    }
    if let Some(o) = pass.as_object_mut() {
        o.insert("done".into(), json!(done));
    }
    append(&pass);
    if json_out {
        print_json(&pass);
        return Ok(());
    }
    println!("{here}: {}", plan.why);
    for m in &plan.moves {
        let verb = if acting { "moving" } else { "would move" };
        println!("  {verb} {} ({}) to {}", m.name, m.session_id, m.target);
    }
    for r in &done {
        match r.get("error").and_then(Value::as_str) {
            None => println!(
                "  moved {} in {} ms; undo: {}",
                r["name"].as_str().unwrap_or(""),
                r["unavailableMs"],
                r["undo"].as_str().unwrap_or("")
            ),
            Some(e) => println!("  {} did not move: {e}", r["name"].as_str().unwrap_or("")),
        }
    }
    if !acting && !plan.moves.is_empty() {
        println!(
            "  (planned only: lane_overflow.rebalance.enabled is off in the registry; --force acts)"
        );
    }
    Ok(())
}

async fn undo(id: &str, timeout: u64, json_out: bool) -> Result<()> {
    let r = receipt_by_id(id)
        .ok_or_else(|| anyhow!("no rebalance receipt {id} in {}", log_path().display()))?;
    let (host, there) = rb::undo_of(&r).map_err(|e| anyhow!("{id}: {e}"))?;
    let t0 = Instant::now();
    let key = format!("{host}/{there}");
    let to = timeout.to_string();
    let answer = session_move(
        &[&key, "--machine", "local", "--after-turn", "--timeout", &to],
        Duration::from_secs(timeout + 120),
    )
    .await;
    let mut d = rb::Done {
        source: host.clone(),
        session_id: there.clone(),
        name: r["name"].as_str().unwrap_or_default().to_owned(),
        target: crate::host_pressure::host_name(),
        unavailable_ms: t0.elapsed().as_millis() as u64,
        undoes: Some(id.to_owned()),
        ..rb::Done::default()
    };
    match answer.and_then(|v| rb::moved_to(&v)) {
        Ok(back) => d.there = Some(back),
        Err(e) => d.error = Some(e),
    }
    let out = rb::receipt(&format!("{id}-undo-{}", now_ms()), now_ms(), &d, "undo");
    append(&out);
    if json_out {
        print_json(&out);
    } else if let Some(e) = &d.error {
        println!("{id}: did not move back: {e}");
    } else {
        println!("{id}: {} is back here", d.name);
    }
    if d.error.is_some() { Err(anyhow!("undo failed")) } else { Ok(()) }
}
