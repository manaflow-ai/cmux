//! `acpmux gh-read PATH`: one GitHub read of a `repos/OWNER/REPO/...` path through the daemon's
//! one poller per machine (`_acpmux/github/read`, `pr_poller::Poller::get`), so N agents reading
//! one run, issue or file within `--fresh` cost one GitHub call, and a re-read is a conditional
//! request a 304 answers for free. It replaces the shared read cache of the fleet's `gh_quota.py`
//! shim (leo-workspace `tools/gh_quota.py`, group 3).
//!
//! Prints the body as JSON; `--json` prints `{data, poller}` (where it came from, its age, the
//! budget). A stale answer (the budget spent, or GitHub failing) prints with its note on stderr.
//! A refusal (no kept answer, a 4xx) exits non-zero with GitHub's or the budget's reason.

use crate::cli::output::print_json;
use crate::daemon::connect;
use crate::rpc::method;
use anyhow::Result;
use serde_json::{Value, json};

#[derive(clap::Args, Debug)]
pub struct GhReadArgs {
    /// `repos/OWNER/REPO/...`, with its query (`repos/o/r/actions/runs/1/jobs?per_page=100`).
    pub path: String,
    /// The oldest kept answer, in seconds, that may answer instead of a read (at most 3600).
    #[arg(long)]
    pub fresh: Option<u64>,
}

pub async fn run(args: GhReadArgs, json_out: bool) -> Result<()> {
    let client = connect(true).await?;
    let mut params = json!({"path": args.path});
    if let (Some(fresh), Some(p)) = (args.fresh, params.as_object_mut()) {
        p.insert("freshSecs".to_owned(), json!(fresh));
    }
    let reply = client.request(method::MUX_GITHUB_READ, params).await?;
    if json_out {
        print_json(&reply);
        return Ok(());
    }
    let poller = reply.get("poller").cloned().unwrap_or(Value::Null);
    if poller.get("source").and_then(Value::as_str) == Some("stale") {
        let age = poller.get("ageSecs").and_then(Value::as_u64).unwrap_or(0);
        let note = poller.get("note").and_then(Value::as_str).unwrap_or("not refreshed");
        eprintln!("gh-read: stale answer, {age}s old: {note}");
    }
    print_json(reply.get("data").unwrap_or(&Value::Null));
    Ok(())
}
