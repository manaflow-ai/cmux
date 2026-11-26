//! The `acpmux` MCP server's race tools: `race_start` and `race_show`, the agent-callable form of
//! `acpmux race new` and `race show` (`cli/race.rs`). A race runs N attempts of a task as this
//! chat's sub-sessions, each in its own worktree, and an independent reviewer picks one
//! (`hub/races.rs`): best-of-N with a judge (RFD 0167 row 14). The requests are the CLI's, over
//! this server's connection, which carries the chat's caller token, so the race's parent is this
//! chat and the daemon refuses nothing here it would not refuse the CLI.

use super::{arg, error_result, ok, refusal};
use crate::cli::race::{MAX_ATTEMPTS, attempts, race_text, target, with_hints};
use crate::client::Client;
use crate::rpc::method;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const TOOLS: &[&str] = &["race_start", "race_show"];

pub(super) fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "race_start",
            "description": "Best-of-N: run one task as several attempts, each a sub-session of this chat in its own git worktree of this chat's folder, then an independent reviewer reads every attempt and picks one. Give one model with attempts (4 attempts of codex) or several models. Returns the race id at once; race_show reads its state and pick. Losing worktrees are kept.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompt": {"type": "string", "description": "The task every attempt works on."},
                    "models": {"type": "array", "items": {"type": "string"}, "minItems": 1, "description": "HARNESS[/MODEL] per candidate, e.g. [\"codex\"] or [\"claude/opus\", \"codex/gpt-5.5\"]."},
                    "attempts": {"type": "integer", "minimum": 1, "maximum": MAX_ATTEMPTS, "description": "Attempts of each model (default 1; one model needs 2 or more)."},
                    "reviewer": {"type": "string", "description": "HARNESS[/MODEL] of the reviewer that picks the winner."},
                    "effort": {"type": "string", "description": "Thinking effort of the attempts (default: each harness's)."},
                    "hints": {"type": "array", "items": {"type": "string"}, "description": "A plan hint per candidate, in candidate order (each model's attempts together), put before the task so attempts diverge; \"\" or none leaves the task alone."},
                    "reviewer_effort": {"type": "string", "description": "Thinking effort of the reviewer."}
                },
                "required": ["prompt", "models", "reviewer"]
            }
        }),
        json!({
            "name": "race_show",
            "description": "Read a race this chat started: its state (running, reviewing, completed, failed, cancelled), each attempt's state, worktree and summary, and the reviewer's pick and reason. Without race_id, lists this chat's races.",
            "inputSchema": {
                "type": "object",
                "properties": {"race_id": {"type": "string", "description": "The id race_start returned."}}
            }
        }),
    ]
}

/// The request for a call, or the refusal the agent reads.
pub(super) fn request(name: &str, args: &Value) -> Result<(&'static str, Value), String> {
    if name == "race_show" {
        return Ok(match arg(args, "race_id") {
            Some(id) => (method::MUX_RACE_GET, json!({"raceId": id})),
            None => (method::MUX_RACE_LIST, json!({})),
        });
    }
    let prompt = arg(args, "prompt").ok_or("prompt is required: the task")?;
    let reviewer = arg(args, "reviewer").ok_or("reviewer is required: HARNESS[/MODEL]")?;
    let models: Vec<String> = match args.get("models") {
        Some(Value::Array(items)) => items
            .iter()
            .map(|v| v.as_str().map(str::to_owned).ok_or("models must be strings"))
            .collect::<Result<_, _>>()?,
        Some(Value::String(one)) => vec![one.clone()],
        _ => return Err("models is required: HARNESS[/MODEL] per candidate".to_owned()),
    };
    let n = match args.get("attempts") {
        None | Some(Value::Null) => 1,
        Some(v) => v
            .as_u64()
            .filter(|n| (1..=u64::from(MAX_ATTEMPTS)).contains(n))
            .ok_or(format!("attempts must be 1 to {MAX_ATTEMPTS}"))? as u32,
    };
    if models.len() * (n as usize) < 2 {
        return Err(
            "a race needs at least two candidates: two models, or attempts of 2 or more".to_owned()
        );
    }
    let hints: Vec<String> = match args.get("hints") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => items
            .iter()
            .map(|v| v.as_str().map(str::to_owned).ok_or("hints must be strings"))
            .collect::<Result<_, _>>()?,
        Some(_) => return Err("hints must be an array of strings".to_owned()),
    };
    let candidates = attempts(&models, n, arg(args, "effort"))
        .and_then(|c| with_hints(c, &hints))
        .map_err(|e| e.to_string())?;
    let mut params = json!({"prompt": prompt, "candidates": candidates});
    params.set(
        "reviewer",
        target(reviewer, arg(args, "reviewer_effort")).map_err(|e| e.to_string())?,
    );
    Ok((method::MUX_RACE_START, params))
}

pub(super) async fn call(daemon: &Arc<Client>, name: &str, args: &Value) -> Value {
    let (m, params) = match request(name, args) {
        Ok(r) => r,
        Err(e) => return error_result(e),
    };
    match daemon.request(m, params).await {
        Ok(reply) => {
            let text = match reply.get("races").and_then(Value::as_array) {
                Some(races) if races.is_empty() => "This chat has no races.".to_owned(),
                Some(races) => races.iter().map(race_text).collect::<Vec<_>>().join("\n"),
                None => race_text(&reply),
            };
            ok(text, reply)
        }
        Err(e) => refusal(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn race_start_puts_each_hint_on_its_candidate() {
        let (_, params) = request(
            "race_start",
            &json!({"prompt": "fix it", "models": ["claude/haiku", "codex"], "attempts": 2,
                    "reviewer": "claude", "hints": ["", "test first", "read first"]}),
        )
        .unwrap();
        let hints: Vec<_> = params["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c.get("hint").cloned())
            .collect();
        assert_eq!(hints, [None, Some(json!("test first")), Some(json!("read first")), None]);
        let too_many =
            json!({"prompt": "p", "models": ["a", "b"], "reviewer": "c", "hints": ["x", "y", "z"]});
        assert!(request("race_start", &too_many).is_err());
    }

    #[test]
    fn race_start_repeats_one_model_for_its_attempts() {
        let (m, params) = request(
            "race_start",
            &json!({"prompt": "fix it", "models": ["codex"], "attempts": 4, "reviewer": "claude/opus"}),
        )
        .unwrap();
        assert_eq!(m, method::MUX_RACE_START);
        assert_eq!(params["candidates"].as_array().unwrap().len(), 4);
        assert_eq!(params["reviewer"], json!({"harness": "claude", "model": "opus"}));
        assert!(params.get("parent").is_none(), "the daemon derives the parent from the token");
    }

    #[test]
    fn race_start_refuses_one_candidate_and_bad_attempts() {
        for args in [
            json!({"prompt": "t", "models": ["codex"], "reviewer": "claude"}),
            json!({"prompt": "t", "models": ["codex"], "attempts": 0, "reviewer": "claude"}),
            json!({"prompt": "t", "models": ["codex"], "attempts": 99, "reviewer": "claude"}),
            json!({"prompt": " ", "models": ["codex", "claude"], "reviewer": "claude"}),
            json!({"prompt": "t", "models": ["codex", "claude"]}),
        ] {
            assert!(request("race_start", &args).is_err(), "accepted {args}");
        }
    }

    #[test]
    fn race_show_reads_one_race_or_lists() {
        assert_eq!(
            request("race_show", &json!({"race_id": "r1"})).unwrap(),
            (method::MUX_RACE_GET, json!({"raceId": "r1"}))
        );
        assert_eq!(request("race_show", &json!({})).unwrap().0, method::MUX_RACE_LIST);
    }
}
