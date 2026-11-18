//! `acpmux session rewind` (`cmux acp session rewind`): back to before a prompt of a chat on this
//! machine, its conversation, its files or both (`_acpmux/rewind`, `hub/turn_rewind.rs`), and
//! `--undo` to put a rewind's files back (`_acpmux/rewind_undo`).

use crate::cli::output::print_json;
use crate::cli::run::resolve_id;
use crate::daemon::connect;
use crate::rpc::method;
use anyhow::{Result, bail};
use serde_json::{Map, Value, json};

/// `session rewind`'s arguments.
#[derive(clap::Args, Debug, Clone)]
pub struct RewindArgs {
    /// The chat.
    pub session: String,
    /// The prompt to go back to before: its promptId.
    #[arg(long, conflicts_with = "seq")]
    pub prompt: Option<String>,
    /// The prompt to go back to before: the seq of its record (`session log`).
    #[arg(long)]
    pub seq: Option<u64>,
    /// Also reset the chat's files to the checkpoint taken before that prompt
    /// (`agents.turnCheckpoints` must have been on).
    #[arg(long)]
    pub files: bool,
    /// Leave the conversation as it is (with --files: reset the files only).
    #[arg(long, requires = "files")]
    pub files_only: bool,
    /// Say what a rewind would do, and change nothing.
    #[arg(long)]
    pub dry_run: bool,
    /// Put back the files a rewind reset, from its safety checkpoint (the rewind's
    /// `undo.safetyCheckpointId`).
    #[arg(long, value_name = "SAFETY_CHECKPOINT_ID", conflicts_with_all = ["prompt", "seq", "files", "dry_run"])]
    pub undo: Option<String>,
}

pub(crate) async fn run(args: &RewindArgs, json_out: bool) -> Result<()> {
    let client = connect(true).await?;
    let id = resolve_id(&client, &args.session).await?;
    if let Some(safety) = &args.undo {
        let v = client
            .request(
                method::MUX_REWIND_UNDO,
                json!({"sessionId": id, "safetyCheckpointId": safety}),
            )
            .await?;
        if json_out {
            print_json(&v)
        } else {
            println!(
                "put back {} files",
                v.get("filesRestored").and_then(Value::as_u64).unwrap_or(0)
            );
        }
        return Ok(());
    }
    let mut params = Map::new();
    params.insert("sessionId".into(), json!(id));
    params.insert("conversation".into(), json!(!args.files_only));
    params.insert("files".into(), json!(args.files));
    params.insert("dryRun".into(), json!(args.dry_run));
    match (&args.prompt, args.seq) {
        (Some(prompt), _) => params.insert("promptId".into(), json!(prompt)),
        (None, Some(seq)) => params.insert("seq".into(), json!(seq)),
        (None, None) => bail!("name the prompt: --prompt PROMPT_ID or --seq SEQ"),
    };
    let v = client.request(method::MUX_REWIND, Value::Object(params)).await?;
    if json_out {
        print_json(&v);
    } else if args.dry_run {
        print!("{}", dry_run_text(&v));
    } else {
        print!("{}", applied_text(&v));
    }
    Ok(())
}

fn dry_run_text(v: &Value) -> String {
    let mut out = String::new();
    out.push_str(match v.get("conversation").and_then(Value::as_str) {
        Some(_) => "conversation: can go back (a new chat, this one stays)\n",
        None => "conversation: this chat's agent cannot go back to before a prompt\n",
    });
    if let Some(files) = v.get("files").and_then(Value::as_object) {
        let total = files.get("total").and_then(Value::as_u64).unwrap_or(0);
        out.push_str(&format!("files: {total} would be reset\n"));
        for path in files.get("paths").and_then(Value::as_array).into_iter().flatten() {
            if let Some(path) = path.as_str() {
                out.push_str(&format!("  {path}\n"));
            }
        }
    } else if let Some(why) = v.pointer("/filesBlocked/message").and_then(Value::as_str) {
        out.push_str(&format!("files: cannot be reset: {why}\n"));
    }
    out
}

fn applied_text(v: &Value) -> String {
    let mut out = String::new();
    if let Some(new) = v.get("sessionId").and_then(Value::as_str) {
        out.push_str(&format!("rewound chat: {new}\n"));
    }
    let restored = v.get("filesRestored").and_then(Value::as_u64).unwrap_or(0);
    if let Some(safety) = v.pointer("/undo/safetyCheckpointId").and_then(Value::as_str) {
        out.push_str(&format!("files reset: {restored}; undo with --undo {safety}\n"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_dry_run_names_the_files_or_why_not() {
        let ready =
            json!({"conversation": "native", "files": {"total": 2, "paths": ["a.rs", "b.rs"]}});
        let text = dry_run_text(&ready);
        assert!(
            text.contains("can go back")
                && text.contains("2 would be reset")
                && text.contains("  b.rs")
        );
        let blocked = json!({"conversation": null, "files": null, "filesBlocked": {"reason": "shared", "message": "another chat is working in this folder"}});
        let text = dry_run_text(&blocked);
        assert!(text.contains("cannot go back") && text.contains("another chat is working"));
    }

    #[test]
    fn the_rewind_says_how_to_undo_its_files() {
        let v = json!({"sessionId": "new", "filesRestored": 3, "undo": {"sessionId": "old", "safetyCheckpointId": "ckpt_s"}});
        let text = applied_text(&v);
        assert!(text.contains("rewound chat: new") && text.contains("--undo ckpt_s"));
    }
}
