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
    let list: Vec<String> = o.iter().map(|(k, v)| format!("{k}={v}")).collect();
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

/// The scorecard of a copied state directory, read in this process (`--home`).
fn offline(home: &std::path::Path, p: &Value) -> Result<Value> {
    let canon = |d: &std::path::Path| std::fs::canonicalize(d).unwrap_or_else(|_| d.to_owned());
    if canon(home) == canon(&crate::config::home()) {
        anyhow::bail!(
            "--home {}: that is the live state directory; copy it first (cp -a) or ask the daemon (no --home)",
            home.display()
        );
    }
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

pub async fn run(args: ScorecardArgs, json_out: bool) -> Result<()> {
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
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn params_name_the_range_and_the_steer_window() {
        let args = ScorecardArgs {
            since: Some("2d".into()),
            by: "feature".into(),
            steer_window: Some(30),
            limit: 5,
            home: None,
        };
        let p = params(&args, 10 * 86_400_000).unwrap();
        assert_eq!(p["since"], 8 * 86_400_000u64);
        assert_eq!(p["steerWindowS"], 30);
        assert!(params(&ScorecardArgs { by: "colour".into(), ..args }, 0).is_err());
    }

    #[test]
    fn text_says_when_no_feature_ran() {
        let args = ScorecardArgs { by: "feature".into(), ..ScorecardArgs::default() };
        let a = json!({"since": 1, "until": 2, "steerWindowS": 60,
            "totals": {"turns": 3, "sessions": 1, "steeringRate": 0.5, "ttfu": {}, "firstModel": {}},
            "byFeature": {}});
        let t = text(&args, &a);
        assert!(t.contains("every turn is the baseline"), "{t}");
        assert!(t.contains("0.500"), "{t}");
    }
}
