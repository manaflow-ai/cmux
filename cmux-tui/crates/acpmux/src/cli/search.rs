//! `acpmux search TEXT [--session ID|NAME|self] [--machine MACHINE|all] [--role user|assistant|tool]
//! [--since DUR] [--limit N] [--context BYTES]`: where TEXT was said in the Claude Code and Codex
//! transcripts here (and on peers with `--machine all`), newest first, each hit with its session,
//! turn, line, time, role and the text around it as written (`_acpmux/transcript_search`,
//! `transcript_search.rs`).
//!
//! Leo, 2026-11-18: "shouldn't you be able to like have better tools for finding stuff?" The desktop
//! coordinator took 7 tool calls to find a phrase it had written earlier in its own 542 MB
//! transcript: ugrep hit its regex limits, BSD grep its 255 repeat cap, a plain grep ran past 120 s.
//!
//! `--session self` is the session this shell runs in: the harness's own id (Claude Code's
//! `CLAUDE_CODE_SESSION_ID`, Codex's `CODEX_THREAD_ID`), else the acpmux session
//! (`ACPMUX_SESSION_ID`). A name or id is resolved as `acpmux resolve` does, so a peer's session
//! (`HOST/NAME`) is searched on that peer. A daemon too old to answer is not needed: the search
//! then runs in this process, on this machine's transcripts.

use std::io::IsTerminal as _;

use anyhow::Result;
use clap::Args;
use serde_json::{Value, json};

use crate::cli::output::{age, print_json};
use crate::rpc::method;
use crate::transcript_search::{self as search, Params};

#[derive(Args, Debug, Clone)]
pub struct SearchArgs {
    /// The text to find, as written (any case), anywhere in a prompt, a reply or a tool call.
    #[arg(required = true)]
    pub text: Vec<String>,
    /// Only this session: `self` (the one this shell runs in), a name, `HOST/NAME`, an acpmux
    /// session id, or a Claude Code or Codex session id.
    #[arg(long, short = 's')]
    pub session: Option<String>,
    /// `all`: this machine and every peer; a peer's name: that machine. Default: this machine.
    /// `--host` is the same.
    #[arg(long = "machine", alias = "host", value_name = "MACHINE|all")]
    pub host: Option<String>,
    /// Only prompts (user), replies (assistant) or tool calls and their output (tool).
    #[arg(long, value_parser = ["user", "assistant", "tool"])]
    pub role: Option<String>,
    /// Only what was said this long ago or later: 30m, 6h, 2d.
    #[arg(long, value_name = "DURATION")]
    pub since: Option<String>,
    /// At most this many hits (most 200).
    #[arg(long, short = 'n', default_value_t = search::DEFAULT_LIMIT)]
    pub limit: usize,
    /// About this many characters of text each side of a match.
    #[arg(long, short = 'C', default_value_t = search::DEFAULT_CONTEXT)]
    pub context: usize,
}

/// The harness session `self` names, from this shell's environment.
fn own_harness_session(env: &impl Fn(&str) -> Option<String>) -> Option<String> {
    crate::sender_harness::claude_code(env)
        .or_else(|| crate::sender_harness::codex(env))
        .and_then(|claim| claim.get("sessionId").and_then(Value::as_str).map(str::to_owned))
}

/// What `--session KEY` names: a harness session id and, for a peer's session, its host.
async fn session_target(key: &str) -> Result<(String, Option<String>)> {
    let env = |k: &str| std::env::var(k).ok();
    let key = match key {
        "self" | "@" | "current" => {
            if let Some(id) = own_harness_session(&env) {
                return Ok((id, None));
            }
            crate::cli::orchestrate::expand_session_key("@")?
        }
        other => other.to_owned(),
    };
    let Ok(client) = crate::daemon::connect(false).await else { return Ok((key, None)) };
    let Ok(reply) = client.request(method::MUX_RESOLVE, json!({"query": key})).await else {
        // Not a session acpmux knows: a Claude Code or Codex session id itself.
        return Ok((key, None));
    };
    let matches = reply["matches"].as_array().cloned().unwrap_or_default();
    let live: Vec<&Value> = matches.iter().filter(|s| s["status"] != "closed").collect();
    let Some(found) = live.first().copied().or(matches.first()) else { return Ok((key, None)) };
    let id = found["agentSessionId"].as_str().filter(|s| !s.is_empty()).unwrap_or(&key).to_owned();
    let host = found["peer"].as_str().map(str::to_owned);
    Ok((id, host))
}

pub fn params(args: &SearchArgs) -> Result<Params> {
    let since_ms = args
        .since
        .as_deref()
        .map(crate::cli::run::ls::parse_duration_ms)
        .transpose()?
        .map(|ago| crate::store::now_ms().saturating_sub(ago) as i64);
    Ok(Params {
        query: args.text.join(" "),
        session: None,
        harness_session: None,
        role: args.role.clone(),
        since_ms,
        limit: args.limit.clamp(1, search::MAX_LIMIT),
        context: args.context,
        host: args.host.clone(),
        ..Params::default()
    })
}

pub async fn run(args: SearchArgs, json_out: bool) -> Result<()> {
    let mut p = params(&args)?;
    if let Some(key) = &args.session {
        let (id, host) = session_target(key).await?;
        p.harness_session = Some(id);
        if p.host.is_none() {
            p.host = host;
        }
    }
    let answer = match crate::daemon::connect(true).await {
        Ok(client) => match client.request(method::MUX_TRANSCRIPT_SEARCH, p.to_value()).await {
            Ok(v) => v,
            Err(e) if not_served(&e) => here(&p).await?,
            Err(e) => return Err(e),
        },
        Err(_) => here(&p).await?,
    };
    if json_out {
        print_json(&answer);
    } else {
        print!("{}", text(&answer, std::io::stdout().is_terminal()));
    }
    Ok(())
}

/// Whether the daemon has no `_acpmux/transcript_search` (an older build).
fn not_served(e: &anyhow::Error) -> bool {
    e.downcast_ref::<crate::client::DaemonError>().is_some_and(|e| e.0.code == -32601)
}

/// The search in this process, on this machine only.
async fn here(p: &Params) -> Result<Value> {
    let p2 = p.clone();
    let mut v = tokio::task::spawn_blocking(move || {
        search::search_here(&p2, &search::default_roots(), Some(&crate::pairing::machine_name()))
    })
    .await?
    .map_err(anyhow::Error::msg)?;
    if p.host.as_deref().is_some_and(|h| h != "local" && h != crate::pairing::machine_name()) {
        v["unreached"] = json!([{"host": p.host, "error": "this machine's daemon is older than `acpmux search`: only this machine was searched"}]);
    }
    Ok(v)
}

/// What `acpmux search` prints: each hit's header line, then its snippet indented, newest first.
pub fn text(answer: &Value, color: bool) -> String {
    let hits = answer["hits"].as_array().cloned().unwrap_or_default();
    let mut out = String::new();
    for h in &hits {
        let field = |k: &str| h[k].as_str().unwrap_or_default();
        let session = field("sessionId");
        let short = session.get(..8).unwrap_or(session);
        let host = h["host"].as_str().map(|h| format!("{h}/")).unwrap_or_default();
        let when =
            h["at"].as_u64().map(|at| format!("{} ago", age(at))).unwrap_or_else(|| "-".into());
        let sub = if h["subagent"] == true { " (subagent)" } else { "" };
        out.push_str(&format!(
            "{host}{short}{sub}  turn {}  line {}  {when}  {}\n",
            h["turn"].as_u64().unwrap_or(0),
            h["line"].as_u64().unwrap_or(0),
            field("role"),
        ));
        let snippet = field("snippet");
        let start = (h["matchStart"].as_u64().unwrap_or(0) as usize).min(snippet.len());
        let end = (start + h["matchLen"].as_u64().unwrap_or(0) as usize).min(snippet.len());
        let (before, matched, after) =
            match (snippet.get(..start), snippet.get(start..end), snippet.get(end..)) {
                (Some(b), Some(m), Some(a)) => (b, m, a),
                _ => (snippet, "", ""),
            };
        let mut body = String::new();
        if h["cutBefore"] == true {
            body.push('…');
        }
        body.push_str(before);
        if color {
            body.push_str(&format!("\x1b[1;33m{matched}\x1b[0m"));
        } else {
            body.push_str(matched);
        }
        body.push_str(after);
        if h["cutAfter"] == true {
            body.push('…');
        }
        for line in body.lines() {
            out.push_str("    ");
            out.push_str(line);
            out.push('\n');
        }
        out.push('\n');
    }
    if hits.is_empty() {
        out.push_str("No transcript holds that text.\n");
    }
    out.push_str(&format!(
        "{} hit{} in {} ms ({} transcript{}",
        hits.len(),
        if hits.len() == 1 { "" } else { "s" },
        answer["tookMs"].as_u64().unwrap_or(0),
        answer["files"].as_u64().unwrap_or(0),
        if answer["files"].as_u64() == Some(1) { "" } else { "s" },
    ));
    let read = answer["caughtUpBytes"].as_u64().unwrap_or(0);
    if read > 0 {
        out.push_str(&format!(", {} KB new read first", read.div_ceil(1024)));
    }
    out.push_str(")\n");
    for u in answer["unreached"].as_array().into_iter().flatten() {
        out.push_str(&format!(
            "(not searched: {}: {})\n",
            u["host"].as_str().unwrap_or("?"),
            u["error"].as_str().unwrap_or("")
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn self_is_the_harness_session_this_shell_runs_in() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| pairs.iter().find(|(key, _)| *key == k).map(|(_, v)| (*v).to_owned())
        };
        let claude = env(&[("CLAUDECODE", "1"), ("CLAUDE_CODE_SESSION_ID", "e8f63fd9")]);
        assert_eq!(own_harness_session(&claude).as_deref(), Some("e8f63fd9"));
        let codex = env(&[("CODEX_THREAD_ID", "01a1-thread")]);
        assert_eq!(own_harness_session(&codex).as_deref(), Some("01a1-thread"));
        assert_eq!(own_harness_session(&env(&[])), None);
    }

    #[test]
    fn text_prints_each_hit_with_its_place_and_the_text_around_it() {
        let answer = json!({
            "hits": [{
                "host": "cosmic-gray", "sessionId": "e8f63fd9-94e8-4878-bcd4-704659aba1f2",
                "harness": "claude", "turn": 412, "line": 120034, "at": null, "role": "assistant",
                "subagent": false, "snippet": "Plan:\nthe four agent pages, then", "matchStart": 10,
                "matchLen": 16, "cutBefore": true, "cutAfter": false,
            }],
            "files": 1, "tookMs": 12, "caughtUpBytes": 2048, "unreached": [],
        });
        assert_eq!(
            text(&answer, false),
            "cosmic-gray/e8f63fd9  turn 412  line 120034  -  assistant\n    …Plan:\n    the four agent pages, then\n\n1 hit in 12 ms (1 transcript, 2 KB new read first)\n"
        );
        let none = json!({"hits": [], "files": 3, "tookMs": 4, "unreached": [{"host": "hb", "error": "no answer in 10 s"}]});
        assert_eq!(
            text(&none, false),
            "No transcript holds that text.\n0 hits in 4 ms (3 transcripts)\n(not searched: hb: no answer in 10 s)\n"
        );
    }

    #[test]
    fn params_take_the_flags() {
        let args = SearchArgs {
            text: vec!["four".into(), "agent".into(), "pages".into()],
            session: None,
            host: Some("all".into()),
            role: Some("assistant".into()),
            since: Some("2d".into()),
            limit: 999,
            context: 100,
        };
        let p = params(&args).unwrap();
        assert_eq!(p.query, "four agent pages");
        assert_eq!(p.limit, search::MAX_LIMIT);
        assert_eq!(p.host.as_deref(), Some("all"));
        let since = p.since_ms.unwrap();
        let two_days = 2 * 86_400_000;
        assert!((crate::store::now_ms() as i64 - since - two_days).abs() < 60_000);
    }
}
