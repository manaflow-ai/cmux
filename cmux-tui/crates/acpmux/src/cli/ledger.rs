//! `acpmux ledger [--since 7d] [--by repo|pr|day|person|workspace|vendor|model|account]`: what
//! turns on this machine cost (`_acpmux/ledger`, `hub/ledger`). Text: the totals, then one line
//! per group, most spent first. `--json` prints the daemon's reply as is.

use anyhow::Result;
use serde_json::{Value, json};

use crate::cli::output::print_json;
use crate::rpc::method;

#[derive(clap::Args, Debug, Clone, Default)]
pub struct LedgerArgs {
    /// How far back: `30m`, `6h`, `7d` (default 7d).
    #[arg(long)]
    pub since: Option<String>,
    /// Group by one of repo, pr, day, person, workspace, vendor, model, account (default repo).
    #[arg(long, default_value = "repo")]
    pub by: String,
    /// At most this many groups (default 20).
    #[arg(long, default_value_t = 20)]
    pub limit: usize,
}

const DIMS: &[&str] = &["workspace", "repo", "pr", "day", "person", "vendor", "model", "account"];

fn params(args: &LedgerArgs, now: u64) -> Result<Value> {
    if !DIMS.contains(&args.by.as_str()) {
        anyhow::bail!("--by: {:?} is not one of {}", args.by, DIMS.join(", "));
    }
    let since = crate::cli::who_else::duration_ms(args.since.as_deref().unwrap_or("7d"))?;
    Ok(json!({"since": now.saturating_sub(since), "until": now, "groupBy": [args.by], "limit": 0}))
}

fn money(v: &Value) -> String {
    format!("${:.2}", v.as_f64().unwrap_or(0.0))
}

fn text(args: &LedgerArgs, answer: &Value) -> String {
    let t = &answer["totals"];
    let mut out = format!(
        "{} over {} turns in {} sessions ({} by the harness, {} at table prices, {} unpriced turns)\n",
        money(&t["costUsd"]),
        t["turns"],
        t["sessions"],
        money(&t["harnessCostUsd"]),
        money(&t["tableCostUsd"]),
        t["unpricedTurns"],
    );
    let groups = answer["rollups"]
        .get(args.by.as_str())
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for g in groups.iter().take(args.limit) {
        let name = g["label"].as_str().or_else(|| g["key"].as_str()).unwrap_or("?");
        out.push_str(&format!(
            "{:>10}  {:>6} turns  {:>4} sessions  {name}\n",
            money(&g["costUsd"]),
            g["turns"],
            g["sessions"],
        ));
    }
    out
}

pub async fn run(args: LedgerArgs, json_out: bool) -> Result<()> {
    let p = params(&args, crate::store::now_ms())?;
    let client = crate::daemon::connect(true).await?;
    let answer = client.request(method::MUX_LEDGER, p).await?;
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
    fn params_name_the_range_and_one_group() {
        let args = LedgerArgs { since: Some("2d".into()), by: "pr".into(), limit: 5 };
        let p = params(&args, 10 * 86_400_000).unwrap();
        assert_eq!(p["since"], 8 * 86_400_000u64);
        assert_eq!(p["groupBy"], json!(["pr"]));
        assert!(params(&LedgerArgs { by: "colour".into(), ..args }, 0).is_err());
    }

    #[test]
    fn text_lists_the_groups_most_spent_first() {
        let args = LedgerArgs { since: None, by: "repo".into(), limit: 20 };
        let answer = json!({
            "totals": {"costUsd": 3.5, "turns": 4, "sessions": 2, "harnessCostUsd": 3.0,
                       "tableCostUsd": 0.5, "unpricedTurns": 1},
            "rollups": {"repo": [
                {"key": "acme/widgets", "costUsd": 3.0, "turns": 3, "sessions": 1},
                {"key": "none", "costUsd": 0.5, "turns": 1, "sessions": 1}
            ]}
        });
        let out = text(&args, &answer);
        assert!(out.starts_with("$3.50 over 4 turns in 2 sessions"), "{out}");
        let lines: Vec<&str> = out.lines().collect();
        assert!(lines[1].contains("$3.00") && lines[1].ends_with("acme/widgets"), "{out}");
        assert!(lines[2].ends_with("none"), "{out}");
    }
}
