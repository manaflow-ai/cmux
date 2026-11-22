//! `optchat-chief trace` and `optchat-chief stats`: read the monitoring
//! trace (`trace.rs`) back. Read-only; plain text an agent can read line by
//! line, or `--json`.
//!
//! ```text
//! optchat-chief trace [--since 1h] [--turn ID] [--json] [--mux-home DIR | --dir DIR]
//! optchat-chief stats [--since 24h] [--json] [--mux-home DIR | --dir DIR]
//! ```
//!
//! Cache hit rate everywhere is cache_read / (cache_read + cache_write +
//! uncached input), over the tokens the harness reported.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

/// Parsed arguments.
#[derive(Debug, Default, PartialEq)]
pub struct Args {
    pub since_ms: u64,
    pub turn: Option<String>,
    pub json: bool,
    pub dir: Option<PathBuf>,
}

/// `5s`, `30m`, `2h`, `7d` (a bare number is minutes) in milliseconds.
pub fn duration_ms(text: &str) -> Result<u64, String> {
    let text = text.trim();
    let (number, unit) = match text.find(|c: char| !c.is_ascii_digit()) {
        Some(i) => text.split_at(i),
        None => (text, "m"),
    };
    let n: u64 = number
        .parse()
        .map_err(|_| format!("bad duration {text:?} (use 30m, 2h, 7d)"))?;
    let unit_ms = match unit {
        "s" => 1_000,
        "m" => 60_000,
        "h" => 3_600_000,
        "d" => 86_400_000,
        _ => return Err(format!("bad duration {text:?} (use 30m, 2h, 7d)")),
    };
    Ok(n * unit_ms)
}

pub fn parse_args(verb: &str, args: &[String]) -> Result<Args, String> {
    let mut since = if verb == "stats" { "24h" } else { "1h" }.to_owned();
    let mut out = Args::default();
    let mut i = 0;
    while i < args.len() {
        let (key, inline) = match args[i].split_once('=') {
            Some((k, v)) => (k.to_owned(), Some(v.to_owned())),
            None => (args[i].clone(), None),
        };
        let mut value = || -> Result<String, String> {
            if let Some(v) = &inline {
                return Ok(v.clone());
            }
            i += 1;
            args.get(i).cloned().ok_or(format!("{key} needs a value"))
        };
        match key.as_str() {
            "--json" => out.json = true,
            "--since" => since = value()?,
            "--turn" => out.turn = Some(value()?),
            "--mux-home" => out.dir = Some(crate::trace::dir(Path::new(&value()?))),
            "--dir" => out.dir = Some(PathBuf::from(value()?)),
            other => return Err(format!("unknown argument {other}")),
        }
        i += 1;
    }
    let now = chrono::Local::now().timestamp_millis().max(0) as u64;
    out.since_ms = now.saturating_sub(duration_ms(&since)?);
    Ok(out)
}

/// Runs `trace` or `stats`; Ok carries what to print.
pub fn run(verb: &str, args: &[String]) -> Result<String, String> {
    let args = parse_args(verb, args)?;
    let dir = args
        .dir
        .clone()
        .unwrap_or_else(|| crate::trace::dir(&crate::paths::mux_home()));
    let events = read(&dir, args.since_ms)?;
    Ok(match verb {
        "stats" => {
            let s = stats(&events);
            if args.json {
                format!(
                    "{}\n",
                    serde_json::to_string_pretty(&s).map_err(|e| format!("stats: {e}"))?
                )
            } else {
                stats_text(&s, &dir)
            }
        }
        _ => {
            let events = match &args.turn {
                Some(turn) => for_turn(&events, turn),
                None => events,
            };
            if args.json {
                events.iter().map(|e| format!("{e}\n")).collect()
            } else {
                timeline(&events)
            }
        }
    })
}

/// Every event at or after `since_ms`, oldest first.
pub fn read(dir: &Path, since_ms: u64) -> Result<Vec<Value>, String> {
    let since_day = chrono::DateTime::from_timestamp_millis(since_ms as i64)
        .map(|t| {
            t.with_timezone(&chrono::Local)
                .format("%Y-%m-%d")
                .to_string()
        })
        .unwrap_or_default();
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(format!(
                "no trace at {} (the host writes it from this build on)",
                dir.display()
            ));
        }
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.extension().is_some_and(|x| x == "jsonl")
                && p.file_stem()
                    .and_then(|s| s.to_str())
                    .is_some_and(|day| day >= since_day.as_str())
        })
        .collect();
    files.sort();
    let mut events = Vec::new();
    for file in files {
        let text =
            std::fs::read_to_string(&file).map_err(|e| format!("{}: {e}", file.display()))?;
        for line in text.lines() {
            if let Ok(v) = serde_json::from_str::<Value>(line)
                && v.get("ts").and_then(Value::as_u64).unwrap_or(0) >= since_ms
            {
                events.push(v);
            }
        }
    }
    events.sort_by_key(|e| e.get("ts").and_then(Value::as_u64).unwrap_or(0));
    Ok(events)
}

/// Whether turn key `key` is `id`: the whole key, or its first message id.
fn turn_matches(key: &str, id: &str) -> bool {
    key == id || key.split(':').nth(2) == Some(id)
}

/// The events of one turn: its own, plus everything without a turn
/// (nodes, subagents) between its start and its end.
pub fn for_turn(events: &[Value], id: &str) -> Vec<Value> {
    let ts = |e: &Value| e.get("ts").and_then(Value::as_u64).unwrap_or(0);
    let of = |e: &Value| {
        e.get("turn")
            .and_then(Value::as_str)
            .is_some_and(|k| turn_matches(k, id))
    };
    let start = events
        .iter()
        .find(|e| of(e) && e["ev"] == "turn.start")
        .map(ts);
    let end = events
        .iter()
        .rev()
        .find(|e| of(e) && e["ev"] == "turn.end")
        .map(ts)
        .unwrap_or(u64::MAX);
    events
        .iter()
        .filter(|e| {
            of(e) || (e.get("turn").is_none() && start.is_some_and(|s| ts(e) >= s && ts(e) <= end))
        })
        .cloned()
        .collect()
}

fn n(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

/// cache_read / (cache_read + cache_write + input), or None without tokens.
pub fn hit_rate(u: &Value) -> Option<f64> {
    let (read, write, input) = (n(u, "cache_read"), n(u, "cache_write"), n(u, "input"));
    let all = read + write + input;
    (all > 0).then(|| read as f64 / all as f64)
}

fn pct(x: Option<f64>) -> String {
    x.map_or("-".to_owned(), |x| format!("{:.0}%", x * 100.0))
}

fn tokens(u: &Value) -> String {
    if u.is_null() {
        return "tokens not reported".to_owned();
    }
    format!(
        "in {} read {} write {} out {} (hit {})",
        n(u, "input"),
        n(u, "cache_read"),
        n(u, "cache_write"),
        n(u, "output"),
        pct(hit_rate(u))
    )
}

fn clock(ts: u64) -> String {
    chrono::DateTime::from_timestamp_millis(ts as i64)
        .map(|t| {
            t.with_timezone(&chrono::Local)
                .format("%m-%d %H:%M:%S%.3f")
                .to_string()
        })
        .unwrap_or_default()
}

fn short_turn(e: &Value) -> String {
    e.get("turn")
        .and_then(Value::as_str)
        .map(|k| k.split(':').nth(2).unwrap_or(k).to_owned())
        .unwrap_or_default()
}

fn prefix(v: &Value) -> String {
    v.get("prefix")
        .and_then(Value::as_str)
        .map(|p| format!("{p:?}"))
        .unwrap_or_default()
}

/// One line per event.
pub fn timeline(events: &[Value]) -> String {
    let mut out = String::new();
    for e in events {
        let who = match (e.get("turn"), e.get("subagent")) {
            (_, Some(Value::String(id))) => format!("subagent {id}"),
            (Some(_), _) => format!("turn {}", short_turn(e)),
            _ => String::new(),
        };
        let line = match e["ev"].as_str().unwrap_or("") {
            "turn.start" => {
                let v = &e["view"];
                let unchanged = match (
                    v.get("unchanged_prefix_bytes").and_then(Value::as_u64),
                    v.get("prev_bytes").and_then(Value::as_u64),
                ) {
                    (Some(a), Some(b)) if b > 0 => {
                        format!("{:.0}% ({a}/{b} B)", a as f64 * 100.0 / b as f64)
                    }
                    _ => "- (first turn of this host)".to_owned(),
                };
                let pieces: Vec<String> = v["pieces"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|p| {
                        format!(
                            "{}:{}",
                            &p["hash"].as_str().unwrap_or("")
                                [..8.min(p["hash"].as_str().unwrap_or("").len())],
                            n(p, "bytes")
                        )
                    })
                    .collect();
                format!(
                    "turn {} START on {}/{} {} message(s) {:?}, view {} B {} lines, prefix unchanged {unchanged}, settle {} ms, pieces [{}], system {}",
                    short_turn(e),
                    e["harness"].as_str().unwrap_or("?"),
                    e["model"].as_str().unwrap_or("default"),
                    e["messages"].as_array().map_or(0, Vec::len),
                    e["sources"]
                        .as_array()
                        .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>())
                        .unwrap_or_default(),
                    n(v, "bytes"),
                    n(v, "lines"),
                    n(e, "settle_ms"),
                    pieces.join(" "),
                    &e["system"]["hash"].as_str().unwrap_or("")
                        [..8.min(e["system"]["hash"].as_str().unwrap_or("").len())]
                )
            }
            "request" => format!(
                "  {who} request {} {}: {}{}",
                n(e, "n"),
                e["model"].as_str().unwrap_or("?"),
                tokens(&e["usage"]),
                e["ttft_ms"]
                    .as_u64()
                    .map(|t| format!(", first token {t} ms"))
                    .unwrap_or_default()
            ),
            "tool" => format!(
                "  {who} tool {} {} {} ms, args {} B, result {} B{}",
                e["name"].as_str().unwrap_or("?"),
                if e["ok"] == true { "ok" } else { "ERROR" },
                e.get("ms")
                    .and_then(Value::as_u64)
                    .map_or("?".into(), |m| m.to_string()),
                n(e, "args_bytes"),
                n(e, "result_bytes"),
                e.get("error")
                    .map(|x| format!(" {}", prefix(x)))
                    .unwrap_or_default()
            ),
            "turn.end" => format!(
                "turn {} END {} in {} ms: {} request(s), {} tool call(s) ({} failed); {} {}{}{}",
                short_turn(e),
                e["status"].as_str().unwrap_or("?"),
                n(e, "ms"),
                n(e, "requests"),
                n(e, "tools"),
                n(e, "tool_errors"),
                e["usage_scope"].as_str().unwrap_or("turn"),
                tokens(&e["usage"]),
                e.get("cost_usd")
                    .and_then(Value::as_f64)
                    .map(|c| format!(", ${c:.4}"))
                    .unwrap_or_default(),
                e.get("reply")
                    .filter(|r| !r.is_null())
                    .map(|r| format!(", reply {}", prefix(r)))
                    .unwrap_or_default()
            ),
            "node" => format!(
                "node {} {} in {} ms, {} prompt(s), {}{}",
                e["node"].as_str().unwrap_or("?"),
                if e["ok"] == true { "built" } else { "FAILED" },
                n(e, "ms"),
                n(e, "prompts"),
                tokens(&e["usage"]),
                e.get("cost_usd")
                    .and_then(Value::as_f64)
                    .map(|c| format!(", ${c:.4}"))
                    .unwrap_or_default()
            ),
            "spawn" => format!(
                "spawn {} -> {:?}, settle {} ms, view {} B, harness {}",
                e["spawn"].as_str().unwrap_or("?"),
                e["ids"]
                    .as_array()
                    .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>())
                    .unwrap_or_default(),
                n(e, "settle_ms"),
                n(&e["view"], "bytes"),
                e["harness"].as_str().unwrap_or("?")
            ),
            "subagent.start" => format!(
                "subagent {} started (session {}) in {} ms",
                e["id"].as_str().unwrap_or("?"),
                e["session"].as_str().unwrap_or("?"),
                n(e, "ms")
            ),
            "subagent.workspace" => match e.get("workspace") {
                Some(w) => format!(
                    "subagent {} workspace {} {:?}",
                    e["id"].as_str().unwrap_or("?"),
                    w.as_str().unwrap_or("?"),
                    e["name"].as_str().unwrap_or("")
                ),
                None => format!(
                    "subagent {} workspace FAILED {}",
                    e["id"].as_str().unwrap_or("?"),
                    prefix(&e["error"])
                ),
            },
            "subagent.answer" => format!(
                "subagent {} prompt answered: {}{}",
                e["id"].as_str().unwrap_or("?"),
                tokens(&e["usage"]),
                e.get("cost_usd")
                    .and_then(Value::as_f64)
                    .map(|c| format!(", ${c:.4}"))
                    .unwrap_or_default()
            ),
            "subagent.input" => format!(
                "subagent {} got a message from the user: {}",
                e["id"].as_str().unwrap_or("?"),
                prefix(&e["text"])
            ),
            "engine" => format!(
                "ENGINE now harness {} model {} effort {} (was {})",
                e["harness"].as_str().unwrap_or("?"),
                e["model"].as_str().unwrap_or("default"),
                e["effort"].as_str().unwrap_or("default"),
                e["was"].as_str().unwrap_or("-")
            ),
            "subagent.resume" => format!("subagent {} runs again", e["id"].as_str().unwrap_or("?")),
            "subagent.done" => format!(
                "subagent {} DONE in {} ms, {} tool call(s) ({} failed), report {}",
                e["id"].as_str().unwrap_or("?"),
                n(e, "ms"),
                n(e, "tools"),
                n(e, "tool_errors"),
                prefix(&e["report"])
            ),
            "tell" => format!(
                "tell {} from {}: {}",
                e["id"].as_str().unwrap_or("?"),
                e["from"].as_str().unwrap_or("?"),
                prefix(&e["message"])
            ),
            "spawn.report" => format!(
                "spawn {} REPORT logged ({:?}) {} ms after spawn: {}",
                e["spawn"].as_str().unwrap_or("?"),
                e["ids"]
                    .as_array()
                    .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>())
                    .unwrap_or_default(),
                n(e, "ms_since_spawn"),
                prefix(&e["text"])
            ),
            other => format!("{other} {e}"),
        };
        out.push_str(&format!("{} {line}\n", clock(n(e, "ts"))));
    }
    if out.is_empty() {
        out.push_str("(no trace events in this window)\n");
    }
    out
}

#[derive(Default)]
struct Sum {
    input: u64,
    read: u64,
    write: u64,
    output: u64,
    cost: f64,
    costed: bool,
}

impl Sum {
    fn add(&mut self, u: &Value) {
        self.input += n(u, "input");
        self.read += n(u, "cache_read");
        self.write += n(u, "cache_write");
        self.output += n(u, "output");
    }
    fn cost(&mut self, c: Option<f64>) {
        if let Some(c) = c {
            self.cost += c;
            self.costed = true;
        }
    }
    fn json(&self) -> Value {
        let u = json!({"input": self.input, "cache_read": self.read, "cache_write": self.write, "output": self.output});
        json!({
            "usage": u,
            "hit_rate": hit_rate(&u),
            "cost_usd": self.costed.then_some(self.cost),
        })
    }
}

type Tools = BTreeMap<String, (u64, u64, u64)>;

fn add_tool(tools: &mut Tools, e: &Value) {
    let t = tools
        .entry(e["name"].as_str().unwrap_or("?").to_owned())
        .or_default();
    t.0 += 1;
    if e["ok"] != true {
        t.1 += 1;
    }
    t.2 += n(e, "ms");
}

fn tools_json(tools: &Tools) -> Value {
    Value::Object(
        tools
            .iter()
            .map(|(k, (calls, errors, ms))| {
                (
                    k.clone(),
                    json!({"calls": calls, "errors": errors, "mean_ms": ms.checked_div(*calls).unwrap_or(0)}),
                )
            })
            .collect::<Map<_, _>>(),
    )
}

/// The `stats` object.
pub fn stats(events: &[Value]) -> Value {
    let mut turns: BTreeMap<String, Map<String, Value>> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut turn_tools: BTreeMap<String, Tools> = BTreeMap::new();
    let mut all_tools = Tools::new();
    let mut sub_tools = Tools::new();
    let (mut turn_sum, mut first_sum, mut node_sum, mut sub_sum) = (
        Sum::default(),
        Sum::default(),
        Sum::default(),
        Sum::default(),
    );
    let (mut nodes, mut nodes_failed, mut node_ms, mut node_prompts) = (0u64, 0u64, 0u64, 0u64);
    let (mut spawns, mut subs_started, mut subs_done, mut reports, mut tells, mut inputs) =
        (0u64, 0u64, 0u64, 0u64, 0u64, 0u64);
    let mut workspace_failures = 0u64;
    let mut unchanged = Vec::new();
    for e in events {
        let turn = e.get("turn").and_then(Value::as_str).map(str::to_owned);
        match e["ev"].as_str().unwrap_or("") {
            "turn.start" => {
                let key = turn.clone().unwrap_or_default();
                order.push(key.clone());
                let v = &e["view"];
                let frac = match (
                    v.get("unchanged_prefix_bytes").and_then(Value::as_u64),
                    v.get("prev_bytes").and_then(Value::as_u64),
                ) {
                    (Some(a), Some(b)) if b > 0 => Some(a as f64 / b as f64),
                    _ => None,
                };
                if let Some(f) = frac {
                    unchanged.push(f);
                }
                let t = turns.entry(key).or_default();
                t.insert("turn".into(), json!(short_turn(e)));
                t.insert("view_bytes".into(), v["bytes"].clone());
                t.insert("view_prefix_unchanged".into(), json!(frac));
                t.insert("settle_ms".into(), e["settle_ms"].clone());
                t.insert(
                    "messages".into(),
                    json!(e["messages"].as_array().map_or(0, Vec::len)),
                );
                t.insert("sources".into(), e["sources"].clone());
            }
            "request" if turn.is_some() && n(e, "n") == 1 => first_sum.add(&e["usage"]),
            "request" if turn.is_some() => {}
            "request" if e.get("subagent").is_some() => sub_sum.add(&e["usage"]),
            "tool" => {
                if let Some(key) = &turn {
                    add_tool(turn_tools.entry(key.clone()).or_default(), e);
                    add_tool(&mut all_tools, e);
                } else {
                    add_tool(&mut sub_tools, e);
                }
            }
            "turn.end" => {
                let key = turn.clone().unwrap_or_default();
                turn_sum.add(&e["usage"]);
                turn_sum.cost(e.get("cost_usd").and_then(Value::as_f64));
                let t = turns.entry(key).or_default();
                t.insert("ms".into(), e["ms"].clone());
                t.insert("status".into(), e["status"].clone());
                t.insert("harness".into(), e["harness"].clone());
                t.insert("model".into(), e["model"].clone());
                t.insert("requests".into(), e["requests"].clone());
                t.insert("usage".into(), e["usage"].clone());
                t.insert("usage_scope".into(), e["usage_scope"].clone());
                t.insert("hit_rate".into(), json!(hit_rate(&e["usage"])));
                t.insert(
                    "first_request_hit_rate".into(),
                    json!(hit_rate(&e["first_usage"])),
                );
                t.insert("cost_usd".into(), e["cost_usd"].clone());
                t.insert("start_ms".into(), e["start_ms"].clone());
                t.insert("ttft_ms".into(), e["ttft_ms"].clone());
            }
            "node" => {
                nodes += 1;
                if e["ok"] != true {
                    nodes_failed += 1;
                }
                node_ms += n(e, "ms");
                node_prompts += n(e, "prompts");
                node_sum.add(&e["usage"]);
                node_sum.cost(e.get("cost_usd").and_then(Value::as_f64));
            }
            "spawn" => spawns += 1,
            "subagent.start" => subs_started += 1,
            "subagent.done" => subs_done += 1,
            "subagent.answer" => sub_sum.cost(e.get("cost_usd").and_then(Value::as_f64)),
            "subagent.input" => inputs += 1,
            "subagent.workspace" if e.get("error").is_some() => workspace_failures += 1,
            "tell" => tells += 1,
            "spawn.report" => reports += 1,
            _ => {}
        }
    }
    let rows: Vec<Value> = order
        .iter()
        .filter_map(|k| {
            let mut t = turns.get(k)?.clone();
            t.insert(
                "tools".into(),
                tools_json(turn_tools.get(k).unwrap_or(&Tools::new())),
            );
            Some(Value::Object(t))
        })
        .collect();
    let mut ms: Vec<u64> = rows.iter().filter_map(|r| r["ms"].as_u64()).collect();
    ms.sort_unstable();
    let latency = |q: f64| -> Option<u64> { quantile(&ms, q) };
    let spread = |key: &str| {
        let mut v: Vec<u64> = rows.iter().filter_map(|r| r[key].as_u64()).collect();
        v.sort_unstable();
        json!({"p50": quantile(&v, 0.5), "p90": quantile(&v, 0.9), "max": v.last()})
    };
    json!({
        "turns": {
            "count": rows.len(),
            "latency_ms": {"p50": latency(0.5), "p90": latency(0.9), "max": ms.last()},
            // Time to first token: the session's start, then the first
            // request's first token (turns that record it).
            "start_ms": spread("start_ms"),
            "ttft_ms": spread("ttft_ms"),
            "totals": turn_sum.json(),
            "first_request": first_sum.json(),
            "view_prefix_unchanged_mean": (!unchanged.is_empty()).then(|| unchanged.iter().sum::<f64>() / unchanged.len() as f64),
            "tools": tools_json(&all_tools),
            "rows": rows,
        },
        "nodes": {
            "count": nodes,
            "failed": nodes_failed,
            "mean_ms": node_ms.checked_div(nodes).unwrap_or(0),
            "prompts": node_prompts,
            "totals": node_sum.json(),
        },
        "subagents": {
            "spawns": spawns,
            "started": subs_started,
            "finished": subs_done,
            "reports_logged": reports,
            "tells": tells,
            "user_messages": inputs,
            "workspace_failures": workspace_failures,
            "tools": tools_json(&sub_tools),
            "totals": sub_sum.json(),
        },
    })
}

/// The `q` quantile of sorted `v`.
fn quantile(v: &[u64], q: f64) -> Option<u64> {
    (!v.is_empty()).then(|| v[((v.len() - 1) as f64 * q).round() as usize])
}

fn sum_line(s: &Value) -> String {
    format!(
        "{}{}",
        tokens(&s["usage"]),
        s["cost_usd"]
            .as_f64()
            .map(|c| format!(", ${c:.4}"))
            .unwrap_or_default()
    )
}

fn tools_line(t: &Value) -> String {
    let rows: Vec<String> = t
        .as_object()
        .into_iter()
        .flatten()
        .map(|(name, v)| {
            format!(
                "{name} {}x{} ~{} ms",
                n(v, "calls"),
                match n(v, "errors") {
                    0 => String::new(),
                    e => format!(" ({e} failed)"),
                },
                n(v, "mean_ms")
            )
        })
        .collect();
    if rows.is_empty() {
        "none".to_owned()
    } else {
        rows.join(", ")
    }
}

/// `stats` as plain text.
pub fn stats_text(s: &Value, dir: &Path) -> String {
    let t = &s["turns"];
    let mut out = format!("trace: {}\n\nTURNS {}\n", dir.display(), n(t, "count"));
    out.push_str(&format!(
        "  latency ms: p50 {} p90 {} max {}\n",
        t["latency_ms"]["p50"], t["latency_ms"]["p90"], t["latency_ms"]["max"]
    ));
    out.push_str(&format!(
        "  session start ms: p50 {} p90 {}; time to first token ms: p50 {} p90 {}\n",
        t["start_ms"]["p50"], t["start_ms"]["p90"], t["ttft_ms"]["p50"], t["ttft_ms"]["p90"]
    ));
    out.push_str(&format!("  all requests: {}\n", sum_line(&t["totals"])));
    out.push_str(&format!(
        "  first request of each turn (reads what earlier turns cached): {}\n",
        tokens(&t["first_request"]["usage"])
    ));
    out.push_str(&format!(
        "  view prefix unchanged since the previous turn (mean): {}\n",
        pct(t["view_prefix_unchanged_mean"].as_f64())
    ));
    out.push_str(&format!("  tool calls: {}\n", tools_line(&t["tools"])));
    for r in t["rows"].as_array().into_iter().flatten() {
        out.push_str(&format!(
            "  turn {:>6} {:<10} {:<20} {:>7} ms {:>2} req hit {:>4} first-hit {:>4} unchanged {:>4} view {:>6} B{} tools: {}\n",
            r["turn"].as_str().unwrap_or("?"),
            r["status"].as_str().unwrap_or("running"),
            format!(
                "{}/{}",
                r["harness"].as_str().unwrap_or("?"),
                r["model"].as_str().unwrap_or("default")
            ),
            n(r, "ms"),
            n(r, "requests"),
            pct(r["hit_rate"].as_f64()),
            pct(r["first_request_hit_rate"].as_f64()),
            pct(r["view_prefix_unchanged"].as_f64()),
            n(r, "view_bytes"),
            r["cost_usd"].as_f64().map(|c| format!(" ${c:.4}")).unwrap_or_default(),
            tools_line(&r["tools"])
        ));
    }
    let nd = &s["nodes"];
    out.push_str(&format!(
        "\nCOMPACTOR NODES {} ({} failed), mean {} ms, {} prompt(s)\n  {}\n",
        n(nd, "count"),
        n(nd, "failed"),
        n(nd, "mean_ms"),
        n(nd, "prompts"),
        sum_line(&nd["totals"])
    ));
    let sb = &s["subagents"];
    out.push_str(&format!(
        "\nSUBAGENTS spawns {}, started {}, finished {}, reports logged {}, tells {}, user messages {}, workspace failures {}\n  requests: {}\n  tool calls: {}\n",
        n(sb, "spawns"),
        n(sb, "started"),
        n(sb, "finished"),
        n(sb, "reports_logged"),
        n(sb, "tells"),
        n(sb, "user_messages"),
        n(sb, "workspace_failures"),
        sum_line(&sb["totals"]),
        tools_line(&sb["tools"])
    ));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        assert_eq!(duration_ms("90s"), Ok(90_000));
        assert_eq!(duration_ms("2h"), Ok(7_200_000));
        assert_eq!(duration_ms("15"), Ok(900_000));
        assert!(duration_ms("2w").is_err());
    }

    #[test]
    fn hit_rate_counts_uncached_input() {
        let u = json!({"input": 10, "cache_read": 80, "cache_write": 10, "output": 5});
        assert_eq!(hit_rate(&u), Some(0.8));
        assert_eq!(hit_rate(&json!({})), None);
    }

    #[test]
    fn args_in_any_order() {
        let a = parse_args(
            "trace",
            &[
                "--json".into(),
                "--since".into(),
                "2h".into(),
                "--turn=12".into(),
            ],
        )
        .unwrap();
        assert!(a.json);
        assert_eq!(a.turn.as_deref(), Some("12"));
        assert!(parse_args("trace", &["--bogus".into()]).is_err());
    }
}
