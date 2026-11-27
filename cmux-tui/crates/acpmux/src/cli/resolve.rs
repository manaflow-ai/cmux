//! `acpmux resolve LINK|ID|NAME` (`hub/locate.rs`): the session an agent link (the
//! `cmux.com/deeplink/agent?...` of a PR footer), a session id or a name names, on this daemon
//! or a peer, with its host, ids, harness, model, folder, lane, pull requests and last turn.

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::cli::errors::{AppError, Code};
use crate::cli::output::{age, print_json, short};
use crate::rpc::method;

/// Resolve a lifecycle operation once, before sending it to the owning daemon. A name is
/// only a lookup key; every subsequent request carries the stable id and its peer route.
pub(crate) async fn control_id(client: &crate::client::Client, key: &str) -> Result<String> {
    let query = crate::cli::orchestrate::expand_session_key(key)?;
    let reply =
        client.request(method::MUX_RESOLVE, json!({"query": query})).await.map_err(|e| {
            if e.downcast_ref::<crate::client::DaemonError>().is_some_and(|e| e.0.code == -32002) {
                let mut app = AppError::new(Code::NoSession, "no_session", e.to_string());
                app.data = AppError::no_session_from(&query, &e).data;
                app.into()
            } else {
                e
            }
        })?;
    let matches = reply["matches"]
        .as_array()
        .ok_or_else(|| anyhow!("resolve returned no session matches for {query:?}"))?;
    routed_id(one_match(&query, matches)?)
}

/// The one session of `resolve`'s cards a control command acts on: the one live card, else (none
/// live) the one closed card; several are refused (`hub/key_route.rs`).
fn one_match<'a>(query: &str, matches: &'a [Value]) -> Result<&'a Value, AppError> {
    let live: Vec<&Value> = matches.iter().filter(|s| s["status"] != "closed").collect();
    let choices: Vec<&Value> = if live.is_empty() { matches.iter().collect() } else { live };
    match choices.as_slice() {
        [] => Err(AppError::no_session(query)),
        [session] => Ok(session),
        many => Err(ambiguous(query, many)),
    }
}

/// The refusal for `query` naming several sessions (resolve cards): each as `HOST/NAME`, or its
/// qualified id when two share that, the same `session_ambiguous` refusal the daemon gives.
fn ambiguous(query: &str, many: &[&Value]) -> AppError {
    let text = |s: &Value, k: &str| s[k].as_str().unwrap_or_default().to_owned();
    let host_name = |s: &Value| {
        let name = text(s, "name");
        let host = text(s, "host");
        let bare = name.strip_prefix(&format!("{host}/")).unwrap_or(&name).to_owned();
        if host.is_empty() { bare } else { format!("{host}/{bare}") }
    };
    let choices: Vec<Value> = many
        .iter()
        .map(|s| {
            let unique = many.iter().filter(|o| host_name(o) == host_name(s)).count() == 1;
            json!({
                "host": s["host"],
                "name": s["name"],
                "route": s["qualifiedSessionId"],
                "status": s["status"],
                "use": if unique { host_name(s) } else { text(s, "qualifiedSessionId") },
            })
        })
        .collect();
    let list: Vec<&str> = choices.iter().filter_map(|c| c["use"].as_str()).collect();
    AppError::new(
        Code::Usage,
        crate::hub::key_route::AMBIGUOUS,
        format!("{query:?} names {} sessions: {}; name one of them", many.len(), list.join(", ")),
    )
    .with_data(
        json!({"reason": crate::hub::key_route::AMBIGUOUS, "session": query, "choices": choices}),
    )
}

/// The command line to run for each choice of a `session_ambiguous` refusal: this one, with
/// the ambiguous key swapped for the choice.
pub(crate) fn choice_commands(args: &[String], data: &Value) -> Vec<String> {
    let Some(key) = data["session"].as_str() else { return Vec::new() };
    // The session argument: the one argument that is the key, or, when an option's value is the
    // key too (`--from review review`), the one no option precedes.
    let at: Vec<usize> = args
        .iter()
        .enumerate()
        .skip(1)
        .filter(|(_, a)| a.as_str() == key)
        .map(|(i, _)| i)
        .collect();
    let at = match at.as_slice() {
        [one] => *one,
        many => match many.iter().find(|&&i| {
            i.checked_sub(1)
                .and_then(|before| args.get(before))
                .is_some_and(|a| !a.starts_with('-'))
        }) {
            Some(&i) => i,
            None => return Vec::new(),
        },
    };
    let program = args.first().map_or("acpmux", |p| p.rsplit('/').next().unwrap_or(p));
    data["choices"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|c| c["use"].as_str())
        .map(|choice| {
            let mut line = vec![program.to_owned()];
            line.extend(args.iter().enumerate().skip(1).map(|(i, a)| {
                crate::harness_health::channel::quote(if i == at { choice } else { a })
            }));
            line.join(" ")
        })
        .collect()
}

/// A create/resolve reply's stable id, qualified for subsequent requests on this daemon.
pub(crate) fn routed_id(session: &Value) -> Result<String> {
    let id = session["sessionId"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| anyhow!("the daemon returned no stable session id"))?;
    // Local replies retain the unqualified id. For a peer, never lose its route by looking
    // up the bare id a second time: another daemon may hold a copy of the same session.
    Ok(match session["peer"].as_str() {
        Some(peer) if id.strip_prefix(&format!("{peer}/")).is_some() => id.to_owned(),
        Some(peer) => format!("{peer}/{id}"),
        None => id.to_owned(),
    })
}

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
    if s["movedTo"].is_object() {
        row("moved", crate::cli::session_move_plan::moved_to_text(&s["movedTo"]));
    }
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

    /// The refusal names each choice as the command to run, the ambiguous key swapped for it.
    #[test]
    fn an_ambiguous_name_prints_the_exact_command_for_each_host() {
        let data = json!({"reason": "session_ambiguous", "session": "review", "choices": [
            {"use": "mac-a/review"}, {"use": "hb/0199aaaa-1111"},
        ]});
        let args: Vec<String> =
            ["/usr/local/bin/acpmux", "send", "review", "ship it"].map(String::from).into();
        assert_eq!(
            choice_commands(&args, &data),
            ["acpmux send mac-a/review 'ship it'", "acpmux send hb/0199aaaa-1111 'ship it'"]
        );
        let other: Vec<String> = ["acpmux", "ls"].map(String::from).into();
        assert!(choice_commands(&other, &data).is_empty());
        // An option whose value is the key too keeps it.
        let from: Vec<String> =
            ["acpmux", "send", "--from", "review", "review", "hi"].map(String::from).into();
        assert_eq!(choice_commands(&from, &data)[0], "acpmux send --from review mac-a/review hi");
    }

    /// `resolve`'s cards: a closed session counts only when no live one matches.
    #[test]
    fn resolve_cards_skip_closed_sessions_and_refuse_several_live_ones() {
        let closed = json!({"name": "review", "host": "mac-a", "status": "closed",
                            "qualifiedSessionId": "local/m1"});
        let live = json!({"name": "hb/review", "host": "hb", "status": "idle",
                          "qualifiedSessionId": "hb/m3"});
        let other = json!({"name": "cmux16/review", "host": "cmux16", "status": "running",
                           "qualifiedSessionId": "cmux16/m5"});
        let one = [closed.clone(), live.clone()];
        assert_eq!(one_match("review", &one).unwrap()["qualifiedSessionId"], "hb/m3");
        let only_closed = [closed.clone()];
        assert_eq!(one_match("review", &only_closed).unwrap()["qualifiedSessionId"], "local/m1");
        let e = one_match("review", &[closed, live, other]).unwrap_err();
        assert_eq!(e.detail, crate::hub::key_route::AMBIGUOUS);
        assert_eq!(
            e.message,
            "\"review\" names 2 sessions: hb/review, cmux16/review; name one of them"
        );
        assert_eq!(e.data.unwrap()["choices"][1]["use"], "cmux16/review");
    }

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
