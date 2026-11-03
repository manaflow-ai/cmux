//! `acpmux bead link|unlink|ls` (`beads.rs`): the tracker beads a session works on, as its
//! `bead:<id>` tags, set through `_acpmux/tag` (which reaches a peer's session too) and read
//! back through `_acpmux/resolve`. Also the `--bead` of `acpmux task new`.

use anyhow::Result;
use clap::Subcommand;
use serde_json::{Map, Value, json};

use crate::cli::output::print_json;
use crate::client::Client;
use crate::rpc::method;

#[derive(Subcommand)]
pub enum BeadCmd {
    /// Link SESSION to beads: `acpmux resolve <bead id>` then finds it, and its summary lists them.
    Link { session: String, ids: Vec<String> },
    /// Unlink beads from SESSION.
    Unlink { session: String, ids: Vec<String> },
    /// The sessions bead ID is linked to (here or on a peer); with --session, SESSION's beads.
    #[command(alias = "list")]
    Ls {
        /// A bead id, or with --session a session.
        query: String,
        /// QUERY is a session: list its beads.
        #[arg(long)]
        session: bool,
    },
}

/// Links `ids` to session `key` (none: nothing to do). Each is checked first.
pub(crate) async fn link(client: &Client, key: &str, ids: &[String]) -> Result<Value> {
    crate::beads::checked(ids)?;
    if ids.is_empty() {
        return Ok(Value::Null);
    }
    let now = crate::store::now_ms().to_string();
    let set: Map<String, Value> =
        ids.iter().map(|id| (crate::beads::tag_key(id), json!(now))).collect();
    client.request(method::MUX_TAG, json!({"sessionId": key, "set": set})).await
}

pub async fn run(cmd: BeadCmd, json_out: bool) -> Result<()> {
    let client = crate::daemon::connect(true).await?;
    let expand = crate::cli::orchestrate::expand_session_key;
    let reply = match &cmd {
        BeadCmd::Link { session, ids } | BeadCmd::Unlink { session, ids } => {
            anyhow::ensure!(!ids.is_empty(), "name at least one bead id");
            let key = expand(session)?;
            if matches!(cmd, BeadCmd::Link { .. }) {
                link(&client, &key, ids).await?
            } else {
                crate::beads::checked(ids)?;
                let remove: Vec<String> = ids.iter().map(|id| crate::beads::tag_key(id)).collect();
                client.request(method::MUX_TAG, json!({"sessionId": key, "remove": remove})).await?
            }
        }
        BeadCmd::Ls { query, session: true } => {
            client.request(method::MUX_RESOLVE, json!({"query": expand(query)?})).await?
        }
        BeadCmd::Ls { query, session: false } => {
            crate::beads::checked(std::slice::from_ref(query))?;
            client.request(method::MUX_RESOLVE, json!({"query": query, "bead": true})).await?
        }
    };
    if json_out {
        print_json(&reply);
        return Ok(());
    }
    match cmd {
        BeadCmd::Ls { session: false, .. } => {
            for s in reply["matches"].as_array().into_iter().flatten() {
                let text = |k: &str| s[k].as_str().unwrap_or_default().to_owned();
                println!("{}  ({}, {})", text("name"), text("host"), text("status"));
            }
        }
        BeadCmd::Ls { .. } => print_beads(&crate::beads::of_tags(&reply["session"]["tags"])),
        _ => print_beads(&crate::beads::of_tags(&reply["tags"])),
    }
    Ok(())
}

fn print_beads(ids: &[String]) {
    if ids.is_empty() {
        println!("No beads.");
    }
    ids.iter().for_each(|id| println!("{id}"));
}
