//! `acpmux scorecard [--since 7d] [--by set|feature|session] [--steer-window 60]`: the
//! harness-magic scorecard of this machine's turns (`_acpmux/scorecard`, `crate::scorecard`):
//! tokens and leo-units per settled pull request, steering rate, time to the first useful
//! result, firstModelMs, requests per turn, cache-hit ratio and every `harnessMagic` counter,
//! split by the features the turns ran with. `--json` prints the daemon's reply as is.

use anyhow::Result;
use serde_json::{Value, json};

use crate::cli::output::print_json;
use crate::rpc::method;

#[derive(clap::Args, Debug, Clone, Default)]
pub struct ScorecardArgs {
    /// How far back: `30m`, `6h`, `7d` (default 7d).
    #[arg(long)]
    pub since: Option<String>,
    /// Group the text by `set` (the feature sets turns ran with), `feature` (each feature on
    /// against off) or `session` (the sessions that spent most). Default set.
    #[arg(long, default_value = "set")]
    pub by: String,
    /// A prompt this many seconds after a turn's end counts as its steer (default 60).
    #[arg(long)]
    pub steer_window: Option<u64>,
    /// At most this many sessions with `--by session` (default 20).
    #[arg(long, default_value_t = 20)]
    pub limit: usize,
    /// Read a copy of a state directory (its `sessions/`, `journal/` and `config.json`) in this
    /// process instead of asking the daemon: a baseline from a host whose daemon predates
    /// `_acpmux/scorecard`. Never the live state directory a daemon writes.
    #[arg(long, value_name = "DIR")]
    pub home: Option<std::path::PathBuf>,
    /// Fail (exit 1) when any turn in the range churned its cached prefix (RFD 0158 §1:
    /// `harnessMagic.cacheAlarm.collapses` or `callChurn`): the replay's no-churn assertion.
    #[arg(long)]
    pub assert_no_churn: bool,
    #[command(subcommand)]
    pub cmd: Option<ScorecardCmd>,
}

#[derive(clap::Subcommand, Debug, Clone)]
pub enum ScorecardCmd {
    /// Replay recorded session logs against RFD 0161's cache-prefix invariants with no model
    /// call (1: each call's context extends the last; 2: model, tools and system prompt
    /// unchanged; 3: no tool result over the output cap; 4: re-reads after a compaction or
    /// surgery bounded; 5: no cache-read collapse without a declared compaction or surgery).
    /// Fails (exit 1) on a violation, for CI.
    Replay(ReplayArgs),
}

#[derive(clap::Args, Debug, Clone, Default)]
pub struct ReplayArgs {
    /// Session ids, unique id prefixes or names (every session when none).
    pub sessions: Vec<String>,
    /// Read a copy of a state directory (a fixture set for CI) in this process instead of
    /// asking the daemon. Never the live state directory a daemon writes.
    #[arg(long, value_name = "DIR")]
    pub home: Option<std::path::PathBuf>,
}

const BYS: &[&str] = &["set", "feature", "session"];

fn params(args: &ScorecardArgs, now: u64) -> Result<Value> {
    if !BYS.contains(&args.by.as_str()) {
        anyhow::bail!("--by: {:?} is not one of {}", args.by, BYS.join(", "));
    }
    let since = crate::cli::who_else::duration_ms(args.since.as_deref().unwrap_or("7d"))?;
    let mut p = json!({"since": now.saturating_sub(since), "until": now});
    if let Some(s) = args.steer_window {
        p["steerWindowS"] = json!(s);
    }
    Ok(p)
}

fn num(v: &Value, digits: usize) -> String {
    match v.as_f64() {
        Some(f) => format!("{f:.digits$}"),
        None => "-".into(),
    }
}

fn secs(v: &Value) -> String {
    match v.as_u64() {
        Some(ms) => format!("{:.1}s", ms as f64 / 1000.0),
        None => "-".into(),
    }
}

fn mtok(v: &Value) -> String {
    match v.as_f64() {
        Some(t) => format!("{:.2}M", t / 1e6),
        None => "-".into(),
    }
}

/// One line of a group's numbers.
fn line(name: &str, m: &Value) -> String {
    format!(
        "{name:<24} {:>5} turns {:>4} sess  steer/turn {:>5}  steers/100 {:>5}  ttfu p50 {:>7} p90 {:>7}  firstModel p50 {:>6}  req/turn {:>5}  cache {:>5}  {:>9} tok {:>8} LU  PRs {}/{}  tok/PR {:>8}  LU/PR {:>7}\n",
        m["turns"],
        m["sessions"],
        num(&m["steeringRate"], 3),
        num(&m["steersPer100Prompts"], 1),
        secs(&m["ttfu"]["medianMs"]),
        secs(&m["ttfu"]["p90Ms"]),
        secs(&m["firstModel"]["medianMs"]),
        num(&m["requestsPerTurn"], 1),
        num(&m["cacheHitRatio"], 3),
        mtok(&m["totalTokens"]),
        num(&m["leoUnits"], 2),
        m["prsSettled"],
        m["prsOpened"],
        mtok(&m["tokensPerSettledPr"]),
        num(&m["leoUnitsPerSettledPr"], 2),
    )
}

fn counters(m: &Value) -> String {
    let Some(o) = m["harnessMagic"].as_object().filter(|o| !o.is_empty()) else {
        return String::new();
    };
    let mut list: Vec<String> = o.iter().map(|(k, v)| format!("{k}={v}")).collect();
    // RFD 0160's hit rate: attached files the turns then read or edited, over those attached.
    if let (Some(hits), Some(files)) = (
        o.get("prefetch.hits").and_then(Value::as_f64),
        o.get("prefetch.files").and_then(Value::as_f64).filter(|f| *f > 0.0),
    ) {
        list.push(format!("prefetch.hitRate={:.2}", hits / files));
    }
    format!("  harnessMagic: {}\n", list.join(" "))
}

fn text(args: &ScorecardArgs, a: &Value) -> String {
    let mut out =
        format!("scorecard {}..{} (steer window {}s)\n", a["since"], a["until"], a["steerWindowS"]);
    out.push_str(&line("all", &a["totals"]));
    out.push_str(&counters(&a["totals"]));
    out.push_str(&format!(
        "attributed: {} tokens, {} leo-units per settled PR (sessions that opened one)\n",
        mtok(&a["attributedTokensPerSettledPr"]),
        num(&a["attributedLeoUnitsPerSettledPr"], 2)
    ));
    match args.by.as_str() {
        "feature" => {
            let features = a["byFeature"].as_object().cloned().unwrap_or_default();
            if features.is_empty() {
                out.push_str(
                    "no harness-magic feature ran in the range: every turn is the baseline\n",
                );
            }
            for (f, split) in features {
                out.push_str(&line(&format!("{f} on"), &split["on"]));
                out.push_str(&counters(&split["on"]));
                out.push_str(&line(&format!("{f} off"), &split["off"]));
            }
        }
        "session" => {
            for s in a["sessions"].as_array().into_iter().flatten().take(args.limit) {
                let name = s["name"].as_str().unwrap_or("?");
                let id = s["id"].as_str().unwrap_or("");
                let label: String =
                    format!("{} {}", &id[..id.len().min(8)], name).chars().take(24).collect();
                out.push_str(&line(&label, s));
            }
        }
        _ => {
            for (set, m) in a["byEnabledSet"].as_object().into_iter().flatten() {
                out.push_str(&line(set, m));
                out.push_str(&counters(m));
            }
        }
    }
    out
}

/// Refuses the live state directory (`--home`).
fn copied_home(home: &std::path::Path) -> Result<()> {
    let canon = |d: &std::path::Path| std::fs::canonicalize(d).unwrap_or_else(|_| d.to_owned());
    if canon(home) == canon(&crate::config::home()) {
        anyhow::bail!(
            "--home {}: that is the live state directory; copy it first (cp -a) or ask the daemon (no --home)",
            home.display()
        );
    }
    Ok(())
}

/// The replay's text: one line a session, one a violation.
fn replay_text(a: &Value) -> String {
    let mut out = String::new();
    for s in a["sessions"].as_array().into_iter().flatten() {
        let id = s["session"].as_str().unwrap_or("");
        let n = s["violations"].as_array().map_or(0, Vec::len);
        out.push_str(&format!(
            "{} {:<8} {} calls {} inits  {}\n",
            id.chars().take(12).collect::<String>(),
            s["harness"].as_str().unwrap_or(""),
            s["calls"],
            s["inits"],
            if n == 0 { "ok".to_owned() } else { format!("{n} violation(s)") }
        ));
        for v in s["violations"].as_array().into_iter().flatten() {
            out.push_str(&format!(
                "  invariant {} {} at seq {}: {}\n",
                v["invariant"],
                v["name"].as_str().unwrap_or(""),
                v["seq"],
                v["detail"].as_str().unwrap_or("")
            ));
        }
    }
    for m in a["missing"].as_array().into_iter().flatten() {
        out.push_str(&format!("{}: no such session\n", m.as_str().unwrap_or("")));
    }
    let list = |key: &str| -> String {
        let n: Vec<String> =
            a[key].as_array().into_iter().flatten().map(|v| v["invariant"].to_string()).collect();
        n.join(", ")
    };
    let not_yet = list("notYet");
    out.push_str(&format!(
        "{} session(s), {} violation(s); invariants {} checked{}\n",
        a["sessions"].as_array().map_or(0, Vec::len),
        a["violations"],
        list("checked"),
        if not_yet.is_empty() { String::new() } else { format!(", {not_yet} not yet") }
    ));
    out
}

async fn replay(args: ReplayArgs, json_out: bool) -> Result<()> {
    let answer = match args.home {
        Some(home) => {
            copied_home(&home)?;
            let sessions = args.sessions.clone();
            tokio::task::spawn_blocking(move || -> Result<Value> {
                let config =
                    crate::config::Config::load_from(&home.join("config.json")).unwrap_or_default();
                let store = crate::store::open(&config.store, &home)?;
                Ok(crate::scorecard_replay::to_value(&crate::scorecard_replay::replay(
                    &*store, &sessions,
                )?))
            })
            .await??
        }
        None => {
            let client = crate::daemon::connect(true).await?;
            client.request(method::MUX_SCORECARD_REPLAY, json!({"sessions": args.sessions})).await?
        }
    };
    if json_out {
        print_json(&answer);
    } else {
        print!("{}", replay_text(&answer));
    }
    // A violation or a missing session fails the command (exit 1), for CI.
    let violations = answer.get("violations").and_then(Value::as_u64).unwrap_or(0);
    let missing = answer.get("missing").and_then(Value::as_array).map_or(0, Vec::len);
    if violations > 0 || missing > 0 {
        anyhow::bail!("scorecard replay: {violations} violation(s), {missing} missing session(s)");
    }
    Ok(())
}

/// The scorecard of a copied state directory, read in this process (`--home`).
fn offline(home: &std::path::Path, p: &Value) -> Result<Value> {
    copied_home(home)?;
    let config = crate::config::Config::load_from(&home.join("config.json")).unwrap_or_default();
    let claude_stdio: std::collections::HashSet<String> = config
        .harnesses
        .iter()
        .filter(|(_, h)| h.kind == crate::config::HarnessKind::ClaudeStdio)
        .map(|(name, _)| name.clone())
        .collect();
    let store = crate::store::open(&config.store, home)?;
    let options = crate::scorecard::ScorecardOptions::from_params(p, crate::store::now_ms());
    let card = crate::scorecard::summarize_with(&*store, &options, &|meta| {
        claude_stdio.contains(&meta.harness) || meta.input_excludes_cache()
    })?;
    Ok(crate::scorecard::to_value(&card))
}

pub async fn run(mut args: ScorecardArgs, json_out: bool) -> Result<()> {
    if let Some(ScorecardCmd::Replay(r)) = args.cmd.take() {
        return replay(r, json_out).await;
    }
    let p = params(&args, crate::store::now_ms())?;
    let answer = match args.home.as_deref() {
        Some(home) => {
            let (home, p) = (home.to_owned(), p.clone());
            tokio::task::spawn_blocking(move || offline(&home, &p)).await??
        }
        None => {
            let client = crate::daemon::connect(true).await?;
            client.request(method::MUX_SCORECARD, p).await?
        }
    };
    if json_out {
        print_json(&answer);
    } else {
        print!("{}", text(&args, &answer));
    }
    if args.assert_no_churn {
        no_churn(&answer)?;
    }
    Ok(())
}

/// `--assert-no-churn`: an error naming the churn count when there was any.
fn no_churn(answer: &Value) -> Result<()> {
    match crate::scorecard::churn(answer) {
        0 => Ok(()),
        n => anyhow::bail!(
            "cache alarm: {n} prefix churn(s) in the range ({}); RFD 0158 §1 holds the cached prefix fixed inside a session",
            crate::scorecard::CHURN_COUNTERS.join(", ")
        ),
    }
}

#[cfg(test)]
#[path = "scorecard_tests.rs"]
mod tests;
