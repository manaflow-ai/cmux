//! Session history upkeep commands: transcript offload, retention, history delete and history
//! offload, each one daemon request and its report. `extra.rs` dispatches to them.

use super::*;

/// `daemon transcript-offload`: old Claude and Codex transcripts copied to cloud history, or with `--dry-run` the pass computed here.
pub(super) async fn transcript_offload(args: TranscriptOffloadArgs, json_out: bool) -> Result<()> {
    let v = if args.dry_run {
        transcript_dry_run(args.older_than_days)?
    } else {
        let client = connect(true).await?;
        client
            .request(
                method::MUX_TRANSCRIPT_OFFLOAD,
                json!({"olderThanDays": args.older_than_days, "restoreAll": args.restore_all}),
            )
            .await?
    };
    if json_out {
        print_json(&v);
    } else if let Some(n) = v.get("restored") {
        println!("{n} transcript(s) back from cloud history");
    } else {
        print_transcript_report(&v);
    }
    Ok(())
}

/// `daemon retention`: old chats archived and their logs reclaimed.
pub(super) async fn retention(args: RetentionArgs, json_out: bool) -> Result<()> {
    let client = connect(true).await?;
    let archive = args.archive.map(std::path::absolute).transpose()?;
    let v = client
        .request(
            method::MUX_RETENTION,
            json!({"dryRun": args.dry_run, "archive": archive, "olderThanDays": args.older_than_days, "only": args.only, "unreadOnly": args.unread_only}),
        )
        .await?;
    if json_out {
        print_json(&v);
    } else {
        let mb = |key: &str| v[key].as_u64().unwrap_or(0) as f64 / 1_048_576.0;
        println!(
            "{} closed chats older than {} days: {:.1} MB of {:.1} MB {}",
            v["chats"],
            v["olderThanDays"],
            mb("freedBytes"),
            mb("bytesBefore"),
            if args.dry_run { "would be freed (dry run)" } else { "freed" }
        );
        println!("skipped: {}", v["skipped"]);
        let read_back = v.get("readBack").and_then(|r| r.as_array());
        for chat in read_back.into_iter().flatten() {
            let text = |key: &str| chat.get(key).and_then(|x| x.as_str()).unwrap_or("?");
            let num = |key: &str| chat.get(key).and_then(|x| x.as_u64()).unwrap_or(0);
            println!(
                "{}: {} -> {} bytes, reads back the same {} rows (digest {})",
                text("sessionId"),
                num("bytesBefore"),
                num("bytesAfter"),
                num("rows"),
                text("digest")
            );
        }
    }
    Ok(())
}

/// `daemon history-delete`: chats unchanged past their age deleted, exported first if asked.
pub(super) async fn history_delete(args: HistoryDeleteArgs, json_out: bool) -> Result<()> {
    let client = connect(true).await?;
    let export = args.export.map(std::path::absolute).transpose()?;
    let v = client
        .request(
            method::MUX_HISTORY_DELETE,
            json!({"dryRun": args.dry_run, "olderThanDays": args.older_than_days, "export": export}),
        )
        .await?;
    if json_out {
        print_json(&v);
    } else {
        print_history_report(
            &v,
            if args.dry_run { "would be deleted (preview)" } else { "deleted" },
            "deleted",
        );
    }
    Ok(())
}

/// `daemon history-offload`: chats unchanged past their age moved to cloud history.
pub(super) async fn history_offload(args: HistoryOffloadArgs, json_out: bool) -> Result<()> {
    let client = connect(true).await?;
    let v = client
        .request(
            method::MUX_HISTORY_OFFLOAD,
            json!({"dryRun": args.dry_run, "olderThanDays": args.older_than_days}),
        )
        .await?;
    if json_out {
        print_json(&v);
    } else {
        print_history_report(
            &v,
            if args.dry_run { "would be offloaded (dry run)" } else { "offloaded" },
            "offloaded",
        );
    }
    Ok(())
}

/// `daemon transcript-offload --dry-run`: the pass's report with nothing uploaded or changed,
/// in this process, as if local removal were on (what would go). The daemon's pass also keeps
/// pinned and busy chats' files, which this cannot see.
fn transcript_dry_run(older_than_days: Option<u32>) -> Result<Value> {
    let home = dirs::home_dir().ok_or_else(|| anyhow::anyhow!("no home folder"))?;
    let days = u64::from(older_than_days.unwrap_or(14));
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    let policy = cmux_session_cloud::transcripts::Policy {
        older_than_ms: days.saturating_mul(86_400_000),
        delete_local: true,
        keep: Default::default(),
        now_ms,
    };
    let report = cmux_session_cloud::transcripts::pass(
        &home,
        &crate::config::home(),
        None,
        &policy,
        true,
        &|| false,
    )?;
    Ok(serde_json::to_value(report)?)
}

fn print_transcript_report(v: &Value) {
    let mb = |key: &str| v[key].as_u64().unwrap_or(0) as f64 / 1_048_576.0;
    let dry = v["dryRun"].as_bool().unwrap_or(false);
    println!("{} transcripts, {:.1} MB, by agent {}", v["files"], mb("bytes"), v["byAgent"]);
    println!(
        "{} {} ({:.1} MB), {} already copied",
        v["copied"],
        if dry { "would be copied" } else { "copied" },
        mb("copiedBytes"),
        v["unchanged"]
    );
    println!(
        "{} {} locally ({:.1} MB)",
        v["removed"],
        if dry { "would be removed" } else { "removed" },
        mb("removedBytes")
    );
    println!("skipped: {}", v["skipped"]);
    for e in v["errors"].as_array().into_iter().flatten() {
        println!("error: {}", e.as_str().unwrap_or("?"));
    }
}

/// The text form of a `_acpmux/history_delete` or `_acpmux/history_offload` report.
fn print_history_report(v: &Value, verb: &str, key: &str) {
    let count = v.get(key).or_else(|| v.get("wouldDelete")).or_else(|| v.get("wouldOffload"));
    println!(
        "{} chats unchanged for over {} days {verb}: {:.1} MB",
        count.and_then(Value::as_u64).unwrap_or(0),
        v["olderThanDays"],
        v["bytes"].as_u64().unwrap_or(0) as f64 / 1_048_576.0,
    );
    for chat in v["chats"].as_array().into_iter().flatten() {
        let bytes = chat.get("bytes").or_else(|| chat.get("archiveBytes")).and_then(Value::as_u64);
        println!(
            "  {}  {}d  {:.1} MB  {}",
            chat["sessionId"].as_str().unwrap_or("?"),
            chat["idleDays"],
            bytes.unwrap_or(0) as f64 / 1_048_576.0,
            chat["name"].as_str().unwrap_or(""),
        );
    }
    println!("skipped: {}", v["skipped"]);
    if let Some(to) = v.get("export").and_then(Value::as_str) {
        println!("exported to {to}");
    }
}
