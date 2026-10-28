//! `acpmux resolve LINK|ID|NAME` (`hub/locate.rs`): the session an agent link (the
//! `cmux.com/deeplink/agent?...` of a PR footer), a session id or a name names, on this daemon
//! or a peer, with its host, ids, harness, model, folder, lane, pull requests and last turn.

use anyhow::Result;
use serde_json::{Value, json};

use crate::cli::output::{age, print_json, short};
use crate::rpc::method;

pub async fn run(query: String, json_out: bool) -> Result<()> {
    let query = crate::cli::orchestrate::expand_session_key(&query)?;
    let client = crate::daemon::connect(true).await?;
    let reply = client.request(method::MUX_RESOLVE, json!({"query": query})).await?;
    if json_out {
        print_json(&reply);
        return Ok(());
    }
    let matches = reply["matches"].as_array().cloned().unwrap_or_default();
    for (i, s) in matches.iter().enumerate() {
        if i > 0 {
            println!();
        }
        print!("{}", card(s));
    }
    if matches.len() > 1 {
        println!("\n{} sessions match; the first is the likeliest.", matches.len());
    }
    Ok(())
}

/// One session as `resolve` prints it.
fn card(s: &Value) -> String {
    let text = |k: &str| s[k].as_str().unwrap_or_default().to_owned();
    let mut out = format!("{}  ({}, {})\n", text("name"), text("host"), text("status"));
    let mut row = |label: &str, value: String| {
        if !value.is_empty() {
            out.push_str(&format!("  {label:<9} {value}\n"));
        }
    };
    row("session", format!("{}  ({})", text("qualifiedSessionId"), text("sessionId")));
    row("harness", format!("{} session {}", text("harness"), text("agentSessionId")));
    row("model", model(&s["model"]));
    let branch = s["gitBranch"].as_str().map(|b| format!("  [{b}]")).unwrap_or_default();
    row("cwd", format!("{}{branch}", text("cwd")));
    let lane = &s["lane"];
    if let Some(state) = lane["state"].as_str() {
        let title = lane["title"].as_str().or(s["title"].as_str()).unwrap_or_default();
        row("lane", format!("{state}  {}", short(title, 100)));
    }
    let prs: Vec<&str> =
        s["pullRequests"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    row("PRs", prs.join(" "));
    let turn = &s["lastTurn"];
    if turn.is_object() {
        let how = turn["stopReason"].as_str().or(turn["status"].as_str()).unwrap_or_default();
        let when =
            turn["endedAt"].as_u64().map(|t| format!(", {} ago", age(t))).unwrap_or_default();
        row("last turn", format!("{how}{when}"));
    }
    // The latest message, the agent's or the person's (`LastMessage`), else the last prompt.
    if let Some(text) = s["lastMessage"]["text"].as_str().or(s["lastPrompt"].as_str()) {
        row("last", short(text, 120));
    }
    row("link", text("link"));
    out
}

/// The session's model: a string, or an object with an id or name.
fn model(v: &Value) -> String {
    v.as_str()
        .or_else(|| v["modelId"].as_str())
        .or_else(|| v["id"].as_str())
        .or_else(|| v["name"].as_str())
        .unwrap_or_default()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_card_prints_the_latest_reply_not_the_prompt() {
        let s = json!({
            "name": "b/review", "host": "b", "status": "idle",
            "qualifiedSessionId": "b/m1", "sessionId": "m1",
            "harness": "claude", "agentSessionId": "a1", "model": {"modelId": "opus"},
            "cwd": "/w", "gitBranch": "main",
            "lane": {"state": "idle", "title": "fix it"},
            "pullRequests": ["https://github.com/o/r/pull/1"],
            "lastTurn": {"status": "completed", "stopReason": "end_turn"},
            "lastPrompt": "do the thing",
            "lastMessage": {"role": "agent", "text": "done: #1"},
            "link": "https://cmux.com/deeplink/agent?harness=claude&session=a1&host=b",
        });
        let text = card(&s);
        assert!(text.starts_with("b/review  (b, idle)\n"), "{text}");
        assert!(text.contains("  last      done: #1\n"), "{text}");
        assert!(!text.contains("do the thing"), "{text}");
        assert!(text.contains("  model     opus\n"), "{text}");
        assert!(text.contains("  cwd       /w  [main]\n"), "{text}");
        assert!(text.contains("  PRs       https://github.com/o/r/pull/1\n"), "{text}");
        assert!(text.contains("  last turn end_turn\n"), "{text}");
    }
}
