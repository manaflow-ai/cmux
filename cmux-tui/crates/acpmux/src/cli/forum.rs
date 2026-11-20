//! `acpmux forum announce|rules|ack` (hq#2570): the forum methods
//! (`server/forum.rs`) from a shell. Inside an agent session the CLI carries
//! the session's caller token (`client.rs`), so it posts and acks as that
//! session, as the `cmux-forum` MCP server does. A person posts from the app.

use anyhow::Result;
use clap::Parser;
use clap::Subcommand;
use serde_json::json;

use crate::rpc::method;

#[derive(Subcommand)]
pub enum ForumCmd {
    /// Read your work threads, or one thread's posts.
    Threads {
        #[arg(long)]
        channel: Option<String>,
        #[arg(long)]
        thread: Option<String>,
        #[arg(long)]
        session_id: Option<String>,
        /// Continue a bounded page with the previous response's nextCursor.
        #[arg(long)]
        cursor: Option<String>,
    },
    /// Post typed work through the existing durable message transport.
    Post {
        recipient: String,
        #[arg(long)]
        channel: String,
        #[arg(long)]
        thread: String,
        #[arg(long, value_enum)]
        kind: crate::forum::work::Kind,
        #[arg(long)]
        key: String,
        #[arg(long)]
        source: String,
        body: Vec<String>,
    },
    /// Route a supported tool notice to a work thread; fails if unrecognized.
    Ingest {
        recipient: String,
        #[arg(long)]
        sender: String,
        body: Vec<String>,
    },
    /// Claim or renew your thread's lease; renewals must name the epoch.
    Claim {
        channel: String,
        thread: String,
        #[arg(long)]
        epoch: Option<u64>,
        #[arg(long, default_value_t = 300)]
        lease_seconds: u64,
    },
    /// Post a rule every session reads; a new post on the key replaces it.
    Announce {
        /// What the rule is about, e.g. builds. One rule per key.
        #[arg(long)]
        key: String,
        /// Also message every live session now ("stop doing X now").
        #[arg(long)]
        urgent: bool,
        /// End the key's rule instead of posting one.
        #[arg(long, conflicts_with = "body")]
        retire: bool,
        /// The rule.
        #[arg(required_unless_present = "retire")]
        body: Vec<String>,
    },
    /// The current rules, newest per key.
    Rules,
    /// Mark a rule as read.
    Ack { post_id: String },
}

pub async fn run(cmd: ForumCmd, json_out: bool) -> Result<()> {
    let (m, params) = match cmd {
        ForumCmd::Post { recipient, channel, thread, kind, key, source, body } => {
            let input = crate::forum::work::Input {
                channel,
                thread,
                kind,
                key,
                source,
                body: body.join(" "),
            };
            return send(&recipient, input, json_out).await;
        }
        ForumCmd::Ingest { recipient, sender, body } => {
            let text = if body.is_empty() || body == ["-"] {
                use std::io::Read;
                let mut text = String::new();
                std::io::stdin()
                    .take((crate::forum::MAX_BODY_BYTES + 1) as u64)
                    .read_to_string(&mut text)?;
                text.trim_end().to_owned()
            } else {
                body.join(" ")
            };
            let input = crate::forum::work::ingest(&sender, &text, crate::store::now_ms())
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "forum.unsupported_notice: send this notice through its ordinary route"
                    )
                })?;
            return send(&recipient, input, json_out).await;
        }
        ForumCmd::Threads { channel, thread, session_id, cursor } => (
            method::MUX_FORUM_THREADS,
            json!({"channel": channel, "thread": thread, "sessionId": session_id, "cursor":cursor}),
        ),
        ForumCmd::Claim { channel, thread, epoch, lease_seconds } => (
            method::MUX_FORUM_CLAIM,
            json!({"channel":channel,"thread":thread,"epoch":epoch,"leaseSeconds":lease_seconds}),
        ),
        ForumCmd::Announce { key, urgent, retire, body } => (
            method::MUX_FORUM_ANNOUNCE,
            json!({"key": key, "body": body.join(" "), "urgent": urgent, "retire": retire}),
        ),
        ForumCmd::Rules => (method::MUX_FORUM_RULES, json!({})),
        ForumCmd::Ack { post_id } => (method::MUX_FORUM_ACK, json!({"postId": post_id})),
    };
    let client = crate::daemon::connect(false).await?;
    let reply = client.request(m, params).await?;
    if json_out || matches!(m, method::MUX_FORUM_THREADS | method::MUX_FORUM_CLAIM) {
        println!("{}", serde_json::to_string_pretty(&reply)?);
    } else if m == method::MUX_FORUM_RULES {
        println!("{}", crate::forum_mcp::rules_text(&reply));
    } else if m == method::MUX_FORUM_ANNOUNCE {
        println!("{}", crate::forum_mcp::announce_text(&reply));
    } else {
        println!("Acknowledged.");
    }
    Ok(())
}

async fn send(recipient: &str, input: crate::forum::work::Input, json_out: bool) -> Result<()> {
    // Parse the existing send grammar and execute its own path: caller-token binding,
    // peer routing, team hub, lane relay, durable retries and receipt ids stay together.
    let wire = input.wire()?;
    let key =
        serde_json::to_vec(&(recipient, &input.channel, &input.thread, &input.key, &input.source))?;
    let prompt_id = format!("forum-{}", crate::sha256::sha256_hex(&key));
    let args = crate::cli::command::Cli::try_parse_from([
        "acpmux",
        "send",
        "--no-wait",
        "--class",
        "fyi",
        "--from",
        "forum",
        "--prompt-id",
        &prompt_id,
        recipient,
        &wire,
    ])?;
    let command =
        args.command.ok_or_else(|| anyhow::anyhow!("forum.send: send command was not parsed"))?;
    Box::pin(crate::cli::run::run_client(command, json_out, false)).await
}
