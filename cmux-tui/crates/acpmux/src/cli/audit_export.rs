//! `acpmux audit-export`: the hash-chained audit log (`hub/audit_log.rs`, `_acpmux/audit`) as
//! JSON lines on stdout, one entry per line, oldest first (RFD 0211, org admin: "the audit log
//! exported as JSON lines to the org's bucket or SIEM"; Leo: "security/sandboxing... how will that
//! work? what about if someone wants to lock down a vm? lock down their app?"). It pages the whole
//! range; the last `seq` it wrote goes to stderr as `next-cursor N`, so a shipper resumes with
//! `--cursor N` and sends nothing twice. `--verify` checks the chain first and exits 1, writing no
//! line, when it is broken. The bucket or SIEM is the pipe's other end
//! (`acpmux audit-export | aws s3 cp - s3://...`).

use std::io::Write as _;
use std::sync::Arc;

use anyhow::{Result, bail};
use serde_json::{Value, json};

use crate::client::Client;
use crate::rpc::method;

/// One page's size: the hub's most.
const PAGE: u64 = 1000;

/// What to export.
#[derive(Debug, Default, Clone, clap::Args)]
pub struct ExportArgs {
    /// Only entries at or after this time (Unix ms).
    #[arg(long)]
    pub since: Option<u64>,
    /// Only entries before this time (Unix ms).
    #[arg(long)]
    pub until: Option<u64>,
    /// Only this session's entries.
    #[arg(long = "session")]
    pub session_id: Option<String>,
    /// Only entries after this `seq` (the `next-cursor` an earlier export printed).
    #[arg(long)]
    pub cursor: Option<u64>,
    /// Check the hash chain first; a broken one exports nothing and exits 1.
    #[arg(long)]
    pub verify: bool,
}

/// The `_acpmux/audit` params of the page after `cursor`.
pub(crate) fn params(args: &ExportArgs, cursor: Option<u64>, verify: bool) -> Value {
    json!({
        "since": args.since,
        "until": args.until,
        "sessionId": args.session_id,
        "cursor": cursor,
        "limit": PAGE,
        "verify": verify,
    })
}

/// A page's JSON lines, its last entry's `seq`, and the cursor of the page after it (None: done).
pub(crate) fn page_lines(page: &Value) -> (Vec<String>, Option<u64>, Option<u64>) {
    let entries = page.get("entries").and_then(Value::as_array).cloned().unwrap_or_default();
    let last = entries.iter().rev().find_map(|entry| entry.get("seq").and_then(Value::as_u64));
    let lines = entries.iter().map(Value::to_string).collect();
    (lines, last, page.get("next").and_then(Value::as_u64))
}

/// The chain's break, when a `verify` page reports one.
pub(crate) fn broken(page: &Value) -> Option<String> {
    let verify = page.get("verify")?;
    (verify.get("ok").and_then(Value::as_bool) != Some(true)).then(|| verify.to_string())
}

pub(crate) async fn run(client: Arc<Client>, args: ExportArgs) -> Result<()> {
    let mut cursor = args.cursor;
    let mut first = true;
    let mut last = cursor;
    let mut out = std::io::stdout().lock();
    loop {
        // The chain is checked once, on the first page: each check reads the whole file.
        let page =
            client.request(method::MUX_AUDIT, params(&args, cursor, first && args.verify)).await?;
        if first && let Some(why) = broken(&page) {
            bail!("the audit chain is broken: {why}");
        }
        first = false;
        let (lines, page_last, next) = page_lines(&page);
        for line in &lines {
            writeln!(out, "{line}")?;
        }
        last = page_last.or(last);
        match next {
            Some(next) if !lines.is_empty() => cursor = Some(next),
            _ => break,
        }
    }
    out.flush()?;
    if let Some(last) = last {
        eprintln!("next-cursor {last}");
    }
    Ok(())
}

#[cfg(test)]
#[path = "audit_export_tests.rs"]
mod tests;
