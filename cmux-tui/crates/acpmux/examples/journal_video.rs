//! Prepare the 7-second browser preview consumed by webviews/scripts/journal-video.ts.
//! A session uses the daemon's ordinary journal pages. An exported NDJSON journal is
//! read through the same adapter, keeping the file open between pages.
use acpmux::client::Client;
use acpmux::journal_replay::{self, JournalPage, ReplayPlan};
use acpmux::rpc::method;
use acpmux::store::EventRecord;
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use std::fs::File;
use std::io::{BufRead, BufReader};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Reply {
    events: Vec<EventRecord>,
    has_more: bool,
    page_through: u64,
    last_seq: u64,
    created_at: u64,
}

fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    ensure!(args.len() == 2, "expected --session ID or --fixture FILE");
    let mut plan = ReplayPlan::default();
    let work = match args[0].as_str() {
        "--fixture" => {
            let mut lines = BufReader::new(File::open(&args[1])?).lines().peekable();
            journal_replay::read(
                |_, limit| {
                    let mut events = Vec::new();
                    while events.len() < limit {
                        let Some(line) = lines.next() else { break };
                        let line = line?;
                        if !line.trim().is_empty() {
                            events.push(
                                serde_json::from_str(&line).context("invalid journal record")?,
                            );
                        }
                    }
                    Ok(JournalPage { events, has_more: lines.peek().is_some(), page_through: 0 })
                },
                |event| plan.apply(event),
            )?
        }
        "--session" => {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
            let client = runtime.block_on(Client::connect(&acpmux::config::socket_path()))?;
            let mut snapshot = None;
            journal_replay::read(
                |after, limit| {
                    let raw = runtime.block_on(client.request(
                        method::MUX_EVENTS,
                        json!({
                            "sessionId": args[1], "afterSeq": after, "limit": limit
                        }),
                    ))?;
                    let reply: Reply = serde_json::from_value(raw)?;
                    let (created, end) =
                        *snapshot.get_or_insert((reply.created_at, reply.last_seq));
                    ensure!(
                        reply.created_at == created && reply.last_seq >= end,
                        "journal changed generation during replay"
                    );
                    ensure!(reply.events.len() <= limit, "daemon exceeded page limit");
                    let through = reply
                        .events
                        .iter()
                        .map(|event| event.seq)
                        .max()
                        .unwrap_or(0)
                        .max(reply.page_through);
                    ensure!(reply.has_more || through >= end, "journal ended before snapshot head");
                    Ok(JournalPage {
                        events: reply.events.into_iter().filter(|event| event.seq <= end).collect(),
                        has_more: through < end,
                        page_through: through.min(end),
                    })
                },
                |event| plan.apply(event),
            )?
        }
        _ => anyhow::bail!("expected --session ID or --fixture FILE"),
    };
    ensure!(work.reduced > 0, "journal is empty");
    const FPS: u64 = 25;
    const FRAMES: u64 = 7 * FPS;
    let mut shots: Vec<Value> = Vec::new();
    let mut index = 0;
    let mut previous = None;
    for frame in 0..FRAMES {
        let time = u128::from(plan.duration) * u128::from(frame) / u128::from(FRAMES - 1);
        while index + 1 < plan.transitions.len()
            && u128::from(plan.transitions[index + 1].time) <= time
        {
            index += 1;
        }
        if previous != Some(index) {
            shots.push(json!({"frame":frame,"transition":plan.transitions[index]}));
            previous = Some(index);
        }
    }
    serde_json::to_writer(
        std::io::stdout().lock(),
        &json!({
            "work":work, "durationMs":plan.duration, "visualTransitions":plan.transitions.len(),
            "fps":FPS, "frames":FRAMES, "shots":shots,
        }),
    )?;
    Ok(())
}
