//! `acpmux pr-feedback PR --kind checks|comments [--session CHAT]`: the Changes row's "Fix
//! failing checks" and "Send review comments" from a shell (`crate::pr_feedback`). Without
//! `--session` it reads here and prints the draft (`--json` the whole answer); with it the chat's
//! daemon reads, in the chat's folder, and the draft goes after the chat's saved composer draft,
//! unsent, where the app's composer shows it next. Exit 1 when there is nothing to send.

use super::errors::{AppError, Code};
use crate::pr_feedback::{self, Kind};
use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

#[derive(clap::Args, Debug)]
pub struct PrFeedbackArgs {
    /// The pull request: its number, #number or URL.
    pub pr: String,
    /// OWNER/REPO (default: the URL's, or the folder's origin).
    #[arg(long, short = 'R')]
    pub repo: Option<String>,
    /// What to draft: this branch's own failing checks, or the unresolved review comments.
    #[arg(long, value_enum, default_value = "checks")]
    pub kind: Kind,
    /// Put the draft in this chat's composer (its name or id) instead of printing it. Never sent.
    #[arg(long)]
    pub session: Option<String>,
}

/// The saved draft with `add` after it, a blank line between.
pub(crate) fn appended(saved: Option<&str>, add: &str) -> String {
    match saved.map(str::trim_end).filter(|s| !s.is_empty()) {
        Some(saved) => format!("{saved}\n\n{add}"),
        None => add.to_owned(),
    }
}

pub async fn run(args: PrFeedbackArgs, json_out: bool) -> Result<()> {
    let answer = match &args.session {
        None => {
            let (pr, repo, kind) = (args.pr.clone(), args.repo.clone(), args.kind);
            tokio::task::spawn_blocking(move || {
                let ctx = pr_feedback::ctx()?;
                let cwd = std::env::current_dir().ok();
                pr_feedback::fetch(&ctx, cwd.as_deref(), &pr, repo.as_deref(), kind)
            })
            .await?
            .map_err(|e| anyhow!(e))?
        }
        Some(session) => {
            let client = crate::client::Client::connect(&crate::config::socket_path()).await?;
            let kind = match args.kind {
                Kind::Checks => "checks",
                Kind::Comments => "comments",
            };
            let answer = client
                .request(
                    method::MUX_PR_FEEDBACK,
                    json!({"sessionId": session, "pr": args.pr, "repo": args.repo, "kind": kind}),
                )
                .await?;
            if answer.get("empty").and_then(Value::as_bool) != Some(true) {
                let add = answer.get("draft").and_then(Value::as_str).unwrap_or_default();
                let saved =
                    client.request(method::MUX_DRAFT_GET, json!({"sessionId": session})).await?;
                let text = appended(saved.get("draft").and_then(Value::as_str), add);
                client
                    .request(method::MUX_DRAFT_SET, json!({"sessionId": session, "text": text}))
                    .await?;
            }
            answer
        }
    };
    let draft = answer.get("draft").and_then(Value::as_str).unwrap_or_default();
    if answer.get("empty").and_then(Value::as_bool) == Some(true) {
        return Err(AppError::new(Code::Runtime, "nothing_to_send", draft)
            .with_data(answer)
            .into());
    }
    if json_out {
        crate::cli::output::print_json(&answer);
    } else if let Some(session) = &args.session {
        println!("in {session}'s composer, not sent:\n\n{draft}");
    } else {
        print!("{draft}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_draft_goes_after_what_is_typed() {
        assert_eq!(super::appended(None, "Fix it"), "Fix it");
        assert_eq!(super::appended(Some("  \n"), "Fix it"), "Fix it");
        assert_eq!(super::appended(Some("Also this\n"), "Fix it"), "Also this\n\nFix it");
    }
}
