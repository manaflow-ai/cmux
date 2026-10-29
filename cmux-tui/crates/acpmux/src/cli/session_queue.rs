//! `acpmux session queue list|remove|clear SESSION`: a session's waiting prompts, read and taken
//! out without hand-written JSON-RPC. A coordinator held 319 queued agent messages while its
//! harness was unavailable (2026-10-29), and the only way to drop them was `_acpmux/queue_remove`
//! by hand over the socket.
//!
//! - `list` reads the session summary's `queue` (`_acpmux/info`): one row per prompt, its id,
//!   sender, age and first line; `--json` adds each prompt's whole `text` (`_acpmux/queue_text`,
//!   one request per prompt, since the summary carries a 200-character preview).
//! - `remove` and `clear` take prompts out one by one through `_acpmux/queue_remove`, the request
//!   the app's queue rows use: the session log records each `queue_removed`, and the daemon's own
//!   checks (`author.rs`, a chat being moved, Full access by a machine) hold as they do there.
//! - `clear --from-agents` takes only other agents' messages (`fromAgent` set), never the
//!   person's own prompts; without the flag it refuses.
//!
//! A peer's session (`host/name`) is resolved once (`resolve::control_id`) and every request
//! carries its routed id, so the peer daemon answers as it does for `session resume`.

use crate::cli::errors::{AppError, Code};
use crate::cli::output::{age, print_json, short};
use crate::client::Client;
use crate::rpc::method;
use anyhow::Result;
use clap::Subcommand;
use serde_json::{Value, json};

#[derive(Subcommand, Debug, Clone, PartialEq, Eq)]
pub enum QueueCmd {
    /// One row per queued prompt: its id, who sent it, how long it has waited and its first
    /// line, in the order they run. With --json, each prompt's whole text.
    #[command(alias = "ls")]
    List { session: String },
    /// Take these queued prompts out; each is reported removed or not found.
    #[command(alias = "rm")]
    Remove {
        session: String,
        #[arg(required = true, value_name = "PROMPT_ID")]
        prompt_ids: Vec<String>,
    },
    /// Take out every queued message another agent sent (`--from-agents`); the person's own
    /// prompts stay queued.
    Clear {
        session: String,
        /// Only other agents' messages. Required: clear never takes the person's prompts.
        #[arg(long)]
        from_agents: bool,
        /// List what it would take out, and take nothing.
        #[arg(long)]
        dry_run: bool,
    },
}

pub async fn run(client: &Client, cmd: QueueCmd, json_out: bool) -> Result<()> {
    match cmd {
        QueueCmd::List { session } => {
            let id = crate::cli::resolve::control_id(client, &session).await?;
            let mut queue = queue(client, &id).await?;
            if json_out {
                for item in &mut queue {
                    with_full_text(client, &id, item).await;
                }
                print_json(&json!({"sessionId": id, "queue": queue}));
            } else {
                for line in list_lines(&queue) {
                    println!("{line}");
                }
            }
            Ok(())
        }
        QueueCmd::Remove { session, prompt_ids } => {
            let id = crate::cli::resolve::control_id(client, &session).await?;
            let mut results = Vec::with_capacity(prompt_ids.len());
            for prompt_id in &prompt_ids {
                results.push(remove_one(client, &id, prompt_id).await);
            }
            report(&id, &results, json_out, false)
        }
        QueueCmd::Clear { session, from_agents, dry_run } => {
            if !from_agents {
                return Err(AppError::usage(
                    "clear takes only other agents' messages, never your own prompts: pass \
                     --from-agents (or remove PROMPT_ID... for specific prompts)",
                )
                .into());
            }
            let id = crate::cli::resolve::control_id(client, &session).await?;
            let targets: Vec<Value> =
                queue(client, &id).await?.into_iter().filter(is_from_agent).collect();
            if dry_run {
                if json_out {
                    print_json(&json!({"sessionId": id, "dryRun": true, "wouldRemove": targets}));
                } else {
                    println!("would remove {} queued agent message(s):", targets.len());
                    for line in list_lines(&targets).into_iter().skip(1) {
                        println!("{line}");
                    }
                }
                return Ok(());
            }
            let mut results = Vec::with_capacity(targets.len());
            for item in &targets {
                let prompt_id = item["promptId"].as_str().unwrap_or_default();
                results.push(remove_one(client, &id, prompt_id).await);
            }
            // One that left the queue meanwhile (it ran or its sender took it back) is no failure.
            report(&id, &results, json_out, true)
        }
    }
}

/// The session's queue in run order (`_acpmux/info` `queue`).
async fn queue(client: &Client, id: &str) -> Result<Vec<Value>> {
    let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    Ok(info["queue"].as_array().cloned().unwrap_or_default())
}

/// `item` with its whole text (`text`, from `_acpmux/queue_text`) beside the summary's
/// 200-character `prompt` preview. One that left the queue meanwhile, or a daemon too old to
/// answer, leaves `text` null and says why in `textError`.
async fn with_full_text(client: &Client, id: &str, item: &mut Value) {
    let prompt_id = item["promptId"].as_str().unwrap_or_default().to_owned();
    let params = json!({"sessionId": id, "promptId": prompt_id});
    let (text, error) = match client.request(method::MUX_QUEUE_TEXT, params).await {
        Ok(v) => (v["text"].clone(), Value::Null),
        Err(e) => (Value::Null, json!(e.to_string())),
    };
    item["text"] = text;
    if !error.is_null() {
        item["textError"] = error;
    }
}

/// Another agent's message: `fromAgent` names its sender. The person's own prompt, and a
/// teammate's in a shared chat (`author`), have none.
fn is_from_agent(item: &Value) -> bool {
    item["fromAgent"].as_str().is_some_and(|s| !s.is_empty())
}

/// Who sent a queued prompt, as a row shows it.
fn sender(item: &Value) -> String {
    if let Some(agent) = item["fromAgent"].as_str().filter(|s| !s.is_empty()) {
        // The sending session, when the daemon bound it (`fromSessionId`).
        return match item["fromSessionId"].as_str().filter(|s| !s.is_empty()) {
            Some(from) => format!("{agent} ({})", from.get(..8).unwrap_or(from)),
            None => agent.to_owned(),
        };
    }
    match item["author"]["name"].as_str() {
        Some(name) => format!("person:{name}"),
        None => "person".to_owned(),
    }
}

/// The rows `list` prints: a header, then one line per prompt, then a count.
fn list_lines(queue: &[Value]) -> Vec<String> {
    if queue.is_empty() {
        return vec!["queue is empty".to_owned()];
    }
    let id_w = queue.iter().map(|q| q["promptId"].as_str().unwrap_or("").len()).max();
    let id_w = id_w.unwrap_or(0).max("PROMPT ID".len());
    let senders: Vec<String> = queue.iter().map(sender).collect();
    let from_w = senders.iter().map(String::len).max().unwrap_or(0).max("FROM".len());
    let mut lines = vec![format!("{:id_w$}  {:from_w$}  {:>5}  TEXT", "PROMPT ID", "FROM", "AGE")];
    for (q, from) in queue.iter().zip(&senders) {
        let held = if q["held"] == true { "[held] " } else { "" };
        let preview = short(q["prompt"].as_str().unwrap_or(""), 100);
        lines.push(format!(
            "{:id_w$}  {from:from_w$}  {:>5}  {held}{preview}",
            q["promptId"].as_str().unwrap_or("?"),
            q["queuedAt"].as_u64().map(age).unwrap_or_default(),
        ));
    }
    let agents = queue.iter().filter(|q| is_from_agent(q)).count();
    lines.push(format!("{} queued ({agents} from agents)", queue.len()));
    lines
}

/// One prompt's outcome: `removed`, `not_found` (not waiting: it started, ended or was already
/// taken out), or `refused` with the daemon's reason.
async fn remove_one(client: &Client, id: &str, prompt_id: &str) -> Value {
    let params = json!({"sessionId": id, "promptId": prompt_id});
    match client.request(method::MUX_QUEUE_REMOVE, params).await {
        Ok(v) if v["removed"] == true => json!({"promptId": prompt_id, "status": "removed"}),
        Ok(_) => json!({"promptId": prompt_id, "status": "not_found"}),
        Err(e) => json!({"promptId": prompt_id, "status": "refused", "error": e.to_string()}),
    }
}

/// Prints each outcome; an error when any prompt was refused, or (unless `gone_ok`) not found.
fn report(id: &str, results: &[Value], json_out: bool, gone_ok: bool) -> Result<()> {
    let count = |status: &str| results.iter().filter(|r| r["status"] == status).count();
    let (removed, not_found, refused) = (count("removed"), count("not_found"), count("refused"));
    if json_out {
        print_json(&json!({
            "sessionId": id,
            "removed": removed,
            "notFound": not_found,
            "refused": refused,
            "results": results,
        }));
    } else {
        for r in results {
            let prompt_id = r["promptId"].as_str().unwrap_or("?");
            match r["status"].as_str() {
                Some("removed") => println!("removed    {prompt_id}"),
                Some("not_found") => println!("not found  {prompt_id} (not in the queue)"),
                _ => println!("refused    {prompt_id}: {}", r["error"].as_str().unwrap_or("")),
            }
        }
        println!("{removed} removed, {not_found} not found, {refused} refused");
    }
    if refused > 0 || (!gone_ok && not_found > 0) {
        let failed = if gone_ok { refused } else { refused + not_found };
        return Err(AppError::new(
            Code::Runtime,
            "queue.not_removed",
            format!("{failed} of {} queued prompt(s) were not removed", results.len()),
        )
        .into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, from: Option<&str>, text: &str) -> Value {
        json!({"promptId": id, "fromAgent": from, "prompt": text, "queuedAt": 0, "held": false})
    }

    #[test]
    fn only_another_agents_message_is_from_an_agent() {
        assert!(is_from_agent(&item("a", Some("lane-a"), "x")));
        assert!(!is_from_agent(&item("p", None, "x")));
        assert!(!is_from_agent(&item("e", Some(""), "x")));
        let teammate =
            json!({"promptId": "t", "fromAgent": null, "author": {"id": "u", "name": "Ana"}});
        assert!(!is_from_agent(&teammate));
        assert_eq!(sender(&teammate), "person:Ana");
        let bound = json!({"fromAgent": "lane-a", "fromSessionId": "0193f1a2-b3c4-7d5e"});
        assert_eq!(sender(&bound), "lane-a (0193f1a2)");
    }

    #[test]
    fn list_names_each_sender_on_one_line_and_counts_the_agents() {
        let lines = list_lines(&[
            item("p-1", None, "mine\nsecond line"),
            item("p-2", Some("lane-a"), "hi"),
        ]);
        assert!(lines[0].starts_with("PROMPT ID"), "{lines:?}");
        assert!(
            lines[1].contains("p-1")
                && lines[1].contains("person")
                && lines[1].contains("mine second line")
        );
        assert!(lines[2].contains("p-2") && lines[2].contains("lane-a"));
        assert_eq!(lines[3], "2 queued (1 from agents)");
        assert_eq!(list_lines(&[]), vec!["queue is empty".to_owned()]);
    }

    #[test]
    fn remove_fails_on_an_unknown_id_and_clear_does_not() {
        let results = [
            json!({"promptId": "a", "status": "removed"}),
            json!({"promptId": "b", "status": "not_found"}),
        ];
        assert!(report("s", &results, true, false).is_err());
        assert!(report("s", &results, true, true).is_ok());
        let refused = [json!({"promptId": "a", "status": "refused", "error": "moving"})];
        assert!(report("s", &refused, true, true).is_err());
    }
}
