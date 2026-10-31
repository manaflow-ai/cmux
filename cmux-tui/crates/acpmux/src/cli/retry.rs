//! `acpmux retry SESSION [--subagent ID]`: retry a session's failed last turn now, in the same
//! session, through `_acpmux/retry` (`hub/auto_resume/retry_turn.rs`), taking over a retry that
//! waits: the failed prompt goes again (a continuation when the turn had output). Refused with
//! `retry.busy` while a turn runs, `retry.stopped` when Stop comes first and
//! `retry.nothing_failed` when the last turn did not fail. `--subagent` resumes that failed subagent
//! instead (`hub/subagent_retry_manual.rs`): `retry.unknown_subagent` when the chat has none.

use crate::cli::output::print_json;
use crate::cli::resolve::control_id;
use crate::daemon::connect;
use crate::rpc::method;
use anyhow::Result;
use cmux_json::JsonSet as _;
use serde_json::json;

#[derive(clap::Args)]
pub struct RetryArgs {
    /// The session's stable id, name or unique prefix, optionally qualified as HOST/NAME.
    pub session: String,
    /// One of the session's failed subagents, by its id or agent id: resumed in the session.
    #[arg(long)]
    pub subagent: Option<String>,
}

pub async fn run(args: RetryArgs, json_out: bool) -> Result<()> {
    let client = connect(true).await?;
    let id = control_id(&client, &args.session).await?;
    let mut params = json!({"sessionId": id});
    if let Some(subagent) = args.subagent {
        params.set("subagentId", json!(subagent));
    }
    let v = client.request(method::MUX_RETRY, params).await?;
    if json_out {
        print_json(&v);
    } else {
        println!("retrying: {}", v["promptId"].as_str().unwrap_or("?"));
    }
    Ok(())
}
