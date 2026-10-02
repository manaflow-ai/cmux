//! `acpmux continue` (also `cmux acp continue`): hand a session's work to a
//! new session on another harness through `_acpmux/handoff_*`. Prepare
//! prints the draft first message and its coverage; `--handoff ID` edits,
//! starts or discards it.

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::cli::run::resolve_id;
use crate::client::Client;
use crate::rpc::method;
use anyhow::{Context, Result};
use clap::Args;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Args)]
pub struct ContinueArgs {
    /// The source session (name, id or unique prefix).
    pub session: Option<String>,
    /// The target harness: a family or profile (`codex`, `claude`).
    #[arg(long)]
    pub to: Option<String>,
    /// Show, edit, start or discard this handoff instead of preparing one.
    #[arg(long, conflicts_with_all = ["session", "to", "memory", "policy", "key"])]
    pub handoff: Option<String>,
    /// A checkpoint for the target to start from (a commit or branch); needs --attest.
    #[arg(long)]
    pub checkpoint: Option<String>,
    /// Confirm that you checked the checkpoint.
    #[arg(long, requires = "checkpoint")]
    pub attest: bool,
    /// A memory reference you approve for the target; repeat for more.
    #[arg(long)]
    pub memory: Vec<String>,
    /// The target's permission policy: same (default) or narrower.
    #[arg(long)]
    pub policy: Option<String>,
    /// The handoff key; derived from the session and harness when omitted
    /// (pass a new one to prepare again after a discard).
    #[arg(long)]
    pub key: Option<String>,
    /// Send the first message to the target (a checkpoint is required by then).
    #[arg(long, requires = "handoff")]
    pub start: bool,
    /// With --start: the prompt id (default: the handoff id). Reuse it to retry.
    #[arg(long, requires = "start")]
    pub prompt_id: Option<String>,
    /// Replace the first message with this file's text (`-` reads stdin).
    #[arg(long, requires = "handoff")]
    pub text: Option<PathBuf>,
    /// Discard the handoff and close its never-prompted target.
    #[arg(long, requires = "handoff", conflicts_with_all = ["start", "text", "checkpoint"])]
    pub discard: bool,
}

pub(crate) async fn run(client: Arc<Client>, a: ContinueArgs, json_out: bool) -> Result<()> {
    let checkpoint = a.checkpoint.as_ref().map(|r| json!({"ref": r, "attest": a.attest}));
    let Some(id) = a.handoff.clone() else {
        return prepare(client, a, checkpoint, json_out).await;
    };
    if a.discard {
        let v = client.request(method::MUX_HANDOFF_DISCARD, json!({"handoffId": id})).await?;
        if json_out {
            print_json(&v);
        } else {
            println!("discarded handoff {id}: its target is closed and the source is unchanged");
        }
        return Ok(());
    }
    let mut h = client.request(method::MUX_HANDOFF_GET, json!({"handoffId": id})).await?;
    let text = match &a.text {
        Some(path) => read_text(path)?,
        None => h["capsule"]["text"].as_str().unwrap_or("").to_owned(),
    };
    if !a.start {
        if a.text.is_some() || checkpoint.is_some() {
            let mut p = json!({"handoffId": id, "revision": h["revision"], "draftKey": uuid::Uuid::now_v7().to_string(), "capsule": {"text": text}});
            if let Some(c) = checkpoint {
                p["checkpoint"] = c;
            }
            h = client.request(method::MUX_HANDOFF_DRAFT, p).await?;
        }
        if json_out {
            print_json(&h);
        } else {
            print_handoff(&h);
        }
        return Ok(());
    }
    let prompt_id = a.prompt_id.clone().unwrap_or_else(|| id.clone());
    let mut p = json!({"handoffId": id, "revision": h["revision"], "promptId": prompt_id, "capsule": {"text": text}});
    if let Some(c) = checkpoint {
        p["checkpoint"] = c;
    }
    match client.request(method::MUX_HANDOFF_START, p).await {
        Ok(v) => {
            if json_out {
                print_json(&v);
            } else {
                println!(
                    "{} handoff {id} in session {} (promptId {prompt_id}, turn {})",
                    if v["outcome"] == "started" { "started" } else { "already started" },
                    v["targetSessionId"].as_str().unwrap_or("?"),
                    v["turnId"].as_str().unwrap_or("unknown"),
                );
            }
            Ok(())
        }
        Err(e) => {
            let lower = e.to_string().to_lowercase();
            if !(lower.contains("connection closed") || lower.starts_with("uncertain_delivery")) {
                return Err(e);
            }
            // The capsule may have reached the target: the same promptId
            // retries without a second send.
            Err(AppError::new(
                Code::Runtime,
                "handoff_uncertain",
                format!(
                    "{e}; the start may have reached the target. Run `continue --handoff {id} --start --prompt-id {prompt_id}` again; it never sends twice"
                ),
            )
            .with_prompt(&prompt_id)
            .retryable()
            .into())
        }
    }
}

async fn prepare(
    client: Arc<Client>,
    a: ContinueArgs,
    checkpoint: Option<Value>,
    json_out: bool,
) -> Result<()> {
    let session = a
        .session
        .ok_or_else(|| AppError::usage("continue needs SESSION --to HARNESS, or --handoff ID"))?;
    let to = a.to.ok_or_else(|| AppError::usage("continue needs --to HARNESS"))?;
    let id = resolve_id(&client, &session).await?;
    let key = a.key.unwrap_or_else(|| format!("{id}:{to}"));
    let mut p = json!({"sessionId": id, "harness": to, "handoffKey": key, "memoryRefs": a.memory});
    if let Some(c) = checkpoint {
        p["checkpoint"] = c;
    }
    if let Some(policy) = a.policy {
        p["policy"] = json!(policy);
    }
    let h = client.request(method::MUX_HANDOFF_PREPARE, p).await?;
    if json_out {
        print_json(&h);
    } else {
        print_handoff(&h);
    }
    Ok(())
}

fn read_text(path: &Path) -> Result<String> {
    if path == Path::new("-") {
        let mut s = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin(), &mut s).context("read stdin")?;
        return Ok(s);
    }
    std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))
}

fn print_handoff(h: &Value) {
    let s = |v: &Value| v.as_str().unwrap_or("?").to_owned();
    let id = s(&h["handoffId"]);
    println!("handoff {id}  {}  revision {}", s(&h["state"]), h["revision"]);
    println!(
        "  {} {} -> {} {}  (cwd {})",
        s(&h["source"]["harness"]),
        s(&h["source"]["sessionId"]),
        s(&h["target"]["harness"]),
        s(&h["target"]["sessionId"]),
        s(&h["target"]["cwd"]),
    );
    let ctx = &h["capsule"]["context"];
    println!(
        "  context: seq {}..{}, {} of {} bytes{}",
        ctx["fromSeq"],
        ctx["toSeq"],
        ctx["bytes"],
        ctx["totalBytes"],
        if ctx["truncated"] == true { ", oldest cut" } else { "" },
    );
    let cp = &h["capsule"]["checkpoint"];
    if cp.is_null() {
        println!("  checkpoint: none (start requires one: --checkpoint REF --attest)");
    } else {
        println!("  checkpoint: {} (attested {})", s(&cp["ref"]), s(&cp["attestedAt"]));
    }
    println!("  coverage:");
    for c in h["source"]["coverage"].as_array().into_iter().flatten() {
        println!(
            "    {:<12} {:<12} {}",
            s(&c["item"]),
            s(&c["status"]),
            c["detail"].as_str().unwrap_or("")
        );
    }
    for side in ["source", "target"] {
        let e = &h[side]["enforcement"];
        println!(
            "  {side} enforcement: {} ({})",
            s(&e["policy"]),
            e["detail"].as_str().unwrap_or("")
        );
    }
    println!("--- first message ---\n{}\n---", h["capsule"]["text"].as_str().unwrap_or(""));
    if h["state"] == "draft" {
        println!(
            "next: continue --handoff {id} --start{}",
            if cp.is_null() { " --checkpoint REF --attest" } else { "" }
        );
    }
}
