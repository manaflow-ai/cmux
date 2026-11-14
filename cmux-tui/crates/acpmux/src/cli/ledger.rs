//! `acpmux ledger [--since 7d] [--by repo|pr|day|person|workspace|vendor|model|account]`: what
//! turns on this machine cost (`_acpmux/ledger`, `hub/ledger`). Text: the totals, then one line
//! per group, most spent first. `--json` prints the daemon's reply as is; `--csv` prints every
//! group as one spreadsheet row (an audit's export: cost, where it came from, tokens, cache).

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
    /// Print every group as CSV, with a header row (`--limit` does not cut it).
    #[arg(long)]
    pub csv: bool,
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
        "{} over {} turns in {} sessions ({} by the harness, {} at table prices, {} unpriced turns; cache reads saved {})\n",
        money(&t["costUsd"]),
        t["turns"],
        t["sessions"],
        money(&t["harnessCostUsd"]),
        money(&t["tableCostUsd"]),
        t["unpricedTurns"],
        money(t.get("cacheSavedUsd").unwrap_or(&Value::Null)),
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

/// The CSV columns: the group, then the rollup's fields as the daemon names them.
const CSV_FIELDS: &[&str] = &[
    "costUsd",
    "harnessCostUsd",
    "tableCostUsd",
    "unpricedTurns",
    "inputTokens",
    "outputTokens",
    "cacheReadTokens",
    "cacheWriteTokens",
    "cacheWrite1hTokens",
    "cacheSavedUsd",
    "turns",
    "toolCalls",
    "wallMs",
    "sessions",
];

/// A CSV field: one line with no tab (a paste splits cells on both, and a split cell would
/// dodge the next rule), never read by a spreadsheet as a formula (a leading `=`, `+`, `-` or
/// `@` gets a `'`), and quoted when it holds a comma or quote.
fn csv_field(v: &str) -> String {
    let v: String =
        v.chars().map(|c| if matches!(c, '\t' | '\n' | '\r') { ' ' } else { c }).collect();
    let v = if v.starts_with(['=', '+', '-', '@']) { format!("'{v}") } else { v };
    if v.contains([',', '"']) { format!("\"{}\"", v.replace('"', "\"\"")) } else { v }
}

fn csv(args: &LedgerArgs, answer: &Value) -> String {
    let mut out = format!("{},label,{}\n", args.by, CSV_FIELDS.join(","));
    let groups =
        answer.get("rollups").and_then(|r| r.get(args.by.as_str())).and_then(Value::as_array);
    for g in groups.into_iter().flatten() {
        let key = g.get("key").and_then(Value::as_str).unwrap_or("");
        let label = g.get("label").and_then(Value::as_str).unwrap_or(key);
        let mut line = vec![csv_field(key), csv_field(label)];
        line.extend(CSV_FIELDS.iter().map(|f| match g.get(*f) {
            Some(Value::Number(n)) => n.to_string(),
            _ => "0".into(),
        }));
        out.push_str(&line.join(","));
        out.push('\n');
    }
    out
}

pub async fn run(args: LedgerArgs, json_out: bool) -> Result<()> {
    let p = params(&args, crate::store::now_ms())?;
    let client = crate::daemon::connect(true).await?;
    let answer = client.request(method::MUX_LEDGER, p).await?;
    if json_out {
        print_json(&answer);
    } else if args.csv {
        print!("{}", csv(&args, &answer));
    } else {
        print!("{}", text(&args, &answer));
    }
    Ok(())
}

#[cfg(test)]
mod tests;
