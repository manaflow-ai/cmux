//! A deliberately small `gh`-compatible peer shim.
//!
//! Install this binary as `gh` on a lane and it forwards only the supported
//! action vocabulary to the local acpmux daemon. The daemon, not this process,
//! owns the GitHub login.

use acpmux::client::Client;
use acpmux::config::socket_path;
use acpmux::github_broker::{GithubAction, GithubActionParams};
use acpmux::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::Value;

fn flag(args: &mut Vec<String>, name: &str) -> Option<String> {
    let Some(i) = args.iter().position(|arg| arg == name) else { return None };
    if i + 1 >= args.len() {
        return None;
    }
    let value = args.remove(i + 1);
    args.remove(i);
    Some(value)
}

fn required(value: Option<String>, name: &str) -> Result<String> {
    value.ok_or_else(|| anyhow!("gh broker: {name} is required"))
}

fn parse(mut args: Vec<String>) -> Result<GithubActionParams> {
    let session_id = std::env::var("ACPMUX_SESSION_ID")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| flag(&mut args, "--session"))
        .ok_or_else(|| anyhow!("gh broker: ACPMUX_SESSION_ID or --session is required"))?;
    let repo = flag(&mut args, "--repo");
    let action = match args.first().map(String::as_str) {
        Some("repo") => GithubAction::Read,
        Some("issue") if args.get(1).map(String::as_str) == Some("create") => GithubAction::Issue,
        Some("issue") if args.get(1).map(String::as_str) == Some("comment") => {
            GithubAction::Comment
        }
        Some("pr") if args.get(1).map(String::as_str) == Some("create") => GithubAction::DraftPr,
        Some("pr") if args.get(1).map(String::as_str) == Some("view") => GithubAction::Read,
        Some("push") => GithubAction::Push,
        _ => {
            return Err(anyhow!(
                "gh broker: supported commands are repo view, issue create/comment, pr create --draft/view, and push"
            ));
        }
    };
    if action == GithubAction::DraftPr && !args.iter().any(|arg| arg == "--draft") {
        return Err(anyhow!("gh broker: only draft pull requests are allowed"));
    }
    let repo = match action {
        GithubAction::Read if args.first().map(String::as_str) == Some("repo") => {
            required(repo.or_else(|| args.get(2).cloned()), "--repo")?
        }
        _ => required(repo, "--repo")?,
    };
    let branch = flag(&mut args, "--head").or_else(|| flag(&mut args, "--branch"));
    let base = flag(&mut args, "--base");
    let title = flag(&mut args, "--title");
    let body = flag(&mut args, "--body");
    let head_sha = flag(&mut args, "--sha");
    let issue = flag(&mut args, "--issue")
        .or_else(|| (action == GithubAction::Comment).then(|| args.get(2).cloned()).flatten())
        .or_else(|| {
            (action == GithubAction::Read && args.first().map(String::as_str) == Some("pr"))
                .then(|| args.get(2).cloned())
                .flatten()
        })
        .and_then(|s| s.parse().ok());
    Ok(GithubActionParams {
        session_id,
        action,
        repo,
        branch,
        base,
        head_sha,
        issue,
        title,
        body,
        forwarded: false,
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    let params = parse(std::env::args().skip(1).collect())?;
    let client = Client::connect(&socket_path()).await?;
    let result = client.request(method::MUX_GITHUB_ACTION, serde_json::to_value(params)?).await?;
    if let Some(output) = result.get("output").and_then(Value::as_str) {
        print!("{output}");
    } else {
        println!("{}", serde_json::to_string(&result)?);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mutation_requires_repo_flag_after_session_is_removed() {
        let request = parse(vec![
            "issue".into(),
            "create".into(),
            "--repo".into(),
            "manaflow-ai/cmux".into(),
            "--title".into(),
            "test".into(),
            "--session".into(),
            "session-1".into(),
        ])
        .unwrap();
        assert_eq!(request.repo, "manaflow-ai/cmux");
        assert_eq!(request.session_id, "session-1");
    }

    #[test]
    fn pull_request_read_keeps_issue_number() {
        let request = parse(vec![
            "pr".into(),
            "view".into(),
            "42".into(),
            "--repo".into(),
            "manaflow-ai/cmux".into(),
            "--session".into(),
            "session-1".into(),
        ])
        .unwrap();
        assert_eq!(request.action, GithubAction::Read);
        assert_eq!(request.issue, Some(42));
    }
}
