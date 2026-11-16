//! Model races use the daemon's guarded sub-session lifecycle. The CLI only submits an
//! intent or reads its durable result; exiting this command never ends the race.
//! CLI callers must run inside an authenticated agent session. Ordinary terminals use
//! the app's Race models control; naming a parent does not authenticate the caller.

use anyhow::Result;
use clap::{Args, Subcommand};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::errors::AppError;
use super::orchestrate::{expand_session_key, split_target};
use super::output::{arg_or_stdin, print_json};

const AUTH_HELP: &str = "Run race commands inside an authenticated acpmux agent session. \
    --parent may name that session or a descendant it can manage. \
    From an ordinary terminal, use the chat's menu → Tools → Race models in cmux NEXT.";

#[derive(Subcommand)]
pub enum RaceCmd {
    /// From an authenticated agent session, start candidates and let a reviewer choose.
    #[command(after_help = AUTH_HELP)]
    New(NewRace),
    /// Read a race and the reviewer's result.
    #[command(after_help = AUTH_HELP)]
    Show(RaceKey),
    /// Stop this race's agents; keep its recorded results.
    #[command(after_help = AUTH_HELP)]
    Stop(RaceKey),
    /// List this chat's races.
    #[command(alias = "list", after_help = AUTH_HELP)]
    Ls(Parent),
    /// Wins and completed races for each model in this chat.
    #[command(after_help = AUTH_HELP)]
    Stats(Parent),
}

#[derive(Args)]
pub struct Parent {
    /// Your authenticated agent session or a descendant it can manage, by name or id.
    /// Defaults to the calling agent's own chat; this flag does not authenticate a terminal.
    #[arg(long)]
    parent: Option<String>,
}

#[derive(Args)]
pub struct RaceKey {
    /// Race id returned by `race new` or `race ls`.
    race_id: String,
    #[command(flatten)]
    scope: Parent,
}

#[derive(Args)]
pub struct NewRace {
    #[command(flatten)]
    scope: Parent,
    /// HARNESS[/MODEL] for each candidate; repeat for every model to race.
    #[arg(long = "model", short = 'm', required = true)]
    models: Vec<String>,
    /// HARNESS[/MODEL] for the independent reviewer.
    #[arg(long)]
    reviewer: String,
    /// Thinking effort for the candidates; omitted uses each harness's default.
    #[arg(long, short = 'e')]
    effort: Option<String>,
    /// Thinking effort for the reviewer; omitted uses its harness's default.
    #[arg(long)]
    reviewer_effort: Option<String>,
    /// Read the task from a UTF-8 file. `-` reads stdin.
    #[arg(long, conflicts_with = "prompt")]
    prompt_file: Option<std::path::PathBuf>,
    /// The task for every candidate. `-` reads stdin.
    prompt: Vec<String>,
}

fn target(spec: &str, effort: Option<&str>) -> Result<Value> {
    let (harness, model) = split_target(spec);
    if harness.trim().is_empty()
        || spec.split_once('/').is_some_and(|(_, model)| model.trim().is_empty())
    {
        return Err(AppError::usage("a model needs HARNESS or HARNESS/MODEL").into());
    }
    let mut value = json!({"harness": harness});
    if let Some(model) = model {
        value.set("model", json!(model));
    }
    if let Some(effort) = effort {
        value.set("effort", json!(effort));
    }
    Ok(value)
}

fn scoped(scope: Parent) -> Result<Value> {
    let mut params = json!({});
    if let Some(parent) = scope.parent {
        params.set("parent", json!(expand_session_key(&parent)?));
    }
    // No parent field lets the daemon derive the caller from the proven token.
    Ok(params)
}

fn request(cmd: RaceCmd) -> Result<(&'static str, Value)> {
    match cmd {
        RaceCmd::New(args) => {
            if args.models.len() < 2 {
                return Err(AppError::usage("a race needs at least two -m candidates").into());
            }
            let prompt = match args.prompt_file {
                Some(path) if path == std::path::Path::new("-") => arg_or_stdin(&["-".into()])?,
                Some(path) => std::fs::read_to_string(path)?,
                None => arg_or_stdin(&args.prompt)?,
            };
            if prompt.trim().is_empty() {
                return Err(AppError::usage("a race needs a task or --prompt-file").into());
            }
            let candidates: Result<Vec<_>> =
                args.models.iter().map(|m| target(m, args.effort.as_deref())).collect();
            let mut params = scoped(args.scope)?;
            params.set("prompt", json!(prompt));
            params.set("candidates", json!(candidates?));
            params.set("reviewer", target(&args.reviewer, args.reviewer_effort.as_deref())?);
            Ok(("_acpmux/race/start", params))
        }
        RaceCmd::Show(key) => keyed("_acpmux/race/get", key),
        RaceCmd::Stop(key) => keyed("_acpmux/race/cancel", key),
        RaceCmd::Ls(scope) => Ok(("_acpmux/race/list", scoped(scope)?)),
        RaceCmd::Stats(scope) => Ok(("_acpmux/race/stats", scoped(scope)?)),
    }
}

fn keyed(method: &'static str, key: RaceKey) -> Result<(&'static str, Value)> {
    let mut params = scoped(key.scope)?;
    params.set("raceId", json!(key.race_id));
    Ok((method, params))
}

pub async fn run(cmd: RaceCmd, json_out: bool) -> Result<()> {
    // Validate inputs before connecting, so malformed commands create nothing.
    let (method, params) = request(cmd)?;
    let client = crate::daemon::connect(true).await?;
    let result = client.request(method, params).await?;
    if json_out {
        print_json(&result);
    } else if let Some(races) = result.get("races").and_then(Value::as_array) {
        for race in races {
            print_race(race);
        }
    } else if let Some(models) = result.get("models").and_then(Value::as_array) {
        for model in models {
            let rate = model.get("winRate").and_then(Value::as_f64);
            println!(
                "{}  {} / {}  {}",
                target_name(model),
                model.get("wins").and_then(Value::as_u64).unwrap_or(0),
                model.get("races").and_then(Value::as_u64).unwrap_or(0),
                rate.map(|r| format!("{:.1}%", r * 100.0)).unwrap_or_else(|| "—".into()),
            );
        }
    } else {
        print_race(&result);
    }
    Ok(())
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("")
}

fn target_name(value: &Value) -> String {
    let harness = text(value, "harness");
    match value.get("model").and_then(Value::as_str) {
        Some(model) => format!("{harness}/{model}"),
        None => harness.to_owned(),
    }
}

fn print_race(race: &Value) {
    println!("{}  {}", text(race, "id"), text(race, "state"));
    let winner = race.get("winnerId").and_then(Value::as_str);
    for candidate in race.get("candidates").and_then(Value::as_array).into_iter().flatten() {
        let name = candidate.get("target").map(target_name).unwrap_or_default();
        let mark = if winner == candidate.get("id").and_then(Value::as_str) && winner.is_some() {
            " *"
        } else {
            ""
        };
        println!("  {name}  {}{mark}", text(candidate, "state"));
        for key in ["cwd", "reply", "error"] {
            if let Some(value) = candidate.get(key).and_then(Value::as_str) {
                println!("    {value}");
            }
        }
    }
    if let Some(reason) = race.get("reason").and_then(Value::as_str) {
        println!("{reason}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::command::{Cli, Command};
    use clap::Parser;

    fn parse(args: &[&str]) -> Result<(&'static str, Value)> {
        let cli = Cli::try_parse_from(args)?;
        match cli.command {
            Some(Command::Race(command)) => request(command),
            _ => anyhow::bail!("expected race command"),
        }
    }

    #[test]
    fn race_cli_keeps_models_task_and_review_effort_separate() {
        let (method, value) = parse(&[
            "acpmux",
            "race",
            "new",
            "--parent",
            "source-chat",
            "-m",
            "codex/sol",
            "-m",
            "opencode/provider/model",
            "--reviewer",
            "claude/opus",
            "--reviewer-effort",
            "medium",
            "fix this\nwithout dropping this line",
        ])
        .unwrap();
        assert_eq!(method, "_acpmux/race/start");
        assert_eq!(value.get("parent"), Some(&json!("source-chat")));
        assert_eq!(value.get("prompt"), Some(&json!("fix this\nwithout dropping this line")));
        assert_eq!(value.pointer("/candidates/1/model"), Some(&json!("provider/model")));
        assert_eq!(value.pointer("/reviewer/effort"), Some(&json!("medium")));
        assert!(value.pointer("/candidates/0/effort").is_none());
    }

    #[test]
    fn race_cli_rejects_missing_task_and_single_candidate_before_connecting() {
        assert!(
            parse(&["acpmux", "race", "new", "-m", "codex", "--reviewer", "claude", "task"])
                .is_err()
        );
        assert!(
            parse(&[
                "acpmux",
                "race",
                "new",
                "-m",
                "codex",
                "-m",
                "claude",
                "--reviewer",
                "codex",
                " "
            ])
            .is_err()
        );
    }

    #[test]
    fn race_cli_reads_and_stops_only_the_named_race_under_the_named_parent() {
        for (verb, method) in [("show", "get"), ("stop", "cancel")] {
            let (actual, params) =
                parse(&["acpmux", "race", verb, "race-a", "--parent", "chat-a"]).unwrap();
            assert_eq!(actual, format!("_acpmux/race/{method}"));
            assert_eq!(params, json!({"raceId": "race-a", "parent": "chat-a"}));
        }
        let (_, params) = parse(&["acpmux", "race", "ls"]).unwrap();
        assert!(params.get("parent").is_none());
    }

    #[test]
    fn race_cli_rejects_empty_harness_or_explicit_model() {
        for spec in ["", "/model", "codex/", "codex/ "] {
            assert!(target(spec, None).is_err(), "accepted {spec:?}");
        }
    }
}
