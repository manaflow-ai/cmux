//! `acpmux forum announce|rules|ack` (hq#2570): the forum methods
//! (`server/forum.rs`) from a shell. Inside an agent session the CLI carries
//! the session's caller token (`client.rs`), so it posts and acks as that
//! session, as the `cmux-forum` MCP server does. A person posts from the app.

use anyhow::Result;
use clap::Subcommand;
use serde_json::json;

use crate::rpc::method;

#[derive(Subcommand)]
pub enum ForumCmd {
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
        ForumCmd::Announce { key, urgent, retire, body } => (
            method::MUX_FORUM_ANNOUNCE,
            json!({"key": key, "body": body.join(" "), "urgent": urgent, "retire": retire}),
        ),
        ForumCmd::Rules => (method::MUX_FORUM_RULES, json!({})),
        ForumCmd::Ack { post_id } => (method::MUX_FORUM_ACK, json!({"postId": post_id})),
    };
    let client = crate::daemon::connect(false).await?;
    let reply = client.request(m, params).await?;
    if json_out {
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
