//! CodeRouter commands.
//!
//! `cmux coderouter status|machines|claude|agent` is the cmux model-plane
//! adapter. The app remains the authority for Stack authentication and team
//! state; this module owns argument parsing and presentation. `cmux cr` and
//! unknown `coderouter` verbs pass through to the standalone CodeRouter CLI,
//! with cmux control-plane variables removed.

use crate::{CliError, Context, Result, args};
use serde_json::{Map, Value, json};
use std::env;
use std::fs;
use std::io::{self, IsTerminal, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const INSTALL_COMMAND: &str = "curl -fsSL https://cmux.com/coderouter/install.sh | sh";
const USAGE: &str = "Usage: cmux coderouter <status|machines|claude|agent|capabilities> [options]\n       cmux cr [coderouter-args...]\n\nTeam model-plane commands use the cmux app socket. Other coderouter verbs pass through to the standalone CodeRouter CLI.";

/// Handle both aliases. `cr` is always the standalone CLI, matching the
/// existing Swift contract. `coderouter` owns only explicit model-plane verbs.
pub fn run(ctx: &Context, command: &str, input: &[String]) -> Result<Option<i32>> {
    if command == "cr" {
        return passthrough(input);
    }
    if command != "coderouter" {
        return Ok(None);
    }
    let sub = input.first().map(|s| s.to_ascii_lowercase());
    match sub.as_deref() {
        Some("status") => status(ctx, &input[1..]),
        Some("machines") | Some("machine") => machines(ctx, &input[1..]),
        Some("claude") => claude(ctx, &input[1..]),
        Some("agent") => agent(ctx, &input[1..]),
        Some("capabilities") | Some("catalog") => capabilities(ctx, &input[1..]),
        Some("help") | Some("--help") | Some("-h") | None => {
            ctx.print(USAGE)?;
            Ok(Some(0))
        }
        _ => passthrough(input),
    }
}

fn team_args(args: &[String]) -> Result<(Option<String>, Vec<String>)> {
    let mut rest = args.to_vec();
    let team = crate::args::take_option(&mut rest, "--team")?;
    Ok((team.filter(|s| !s.trim().is_empty()), rest))
}
fn team_params(team: Option<&str>) -> Value {
    let mut map = Map::new();
    if let Some(team) = team.filter(|s| !s.is_empty()) {
        map.insert("teamId".into(), json!(team));
    }
    Value::Object(map)
}

fn status(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let (team, rest) = team_args(input)?;
    args::reject_remaining(&rest, "Usage: cmux coderouter status [--team <id>]")?;
    let auth = ctx.rpc("auth.status", json!({}))?;
    let signed_in = auth
        .get("signed_in")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let upstream = if signed_in {
        Some(ctx.rpc(
            "coderouter.claude_upstream.get",
            team_params(team.as_deref()),
        ))
    } else {
        None
    };

    if ctx.json {
        let mut result = Map::new();
        result.insert("signed_in".into(), json!(signed_in));
        if let Some(user) = auth.get("user") {
            result.insert("user".into(), user.clone());
        }
        if let Some(id) = auth.get("selected_team_id") {
            result.insert("selected_team_id".into(), id.clone());
        }
        match upstream {
            Some(Ok(value)) => {
                result.insert(
                    "team_id".into(),
                    value.get("teamId").cloned().unwrap_or(Value::Null),
                );
                result.insert(
                    "claude_accounts".into(),
                    value.get("accounts").cloned().unwrap_or_else(|| json!([])),
                );
            }
            Some(Err(error)) => {
                result.insert("claude_accounts_error".into(), json!(error.message));
            }
            None => {}
        }
        let mut value = Value::Object(result);
        explain(ctx, &mut value, "coderouter.status", "account + upstream");
        ctx.emit(&value)?;
        return Ok(Some(0));
    }
    if !signed_in {
        ctx.print("Not signed in. Run `cmux auth login`, then retry.")?;
        return Ok(Some(0));
    }
    let email = auth
        .get("user")
        .and_then(|v| v.get("email"))
        .and_then(Value::as_str)
        .map(safe)
        .unwrap_or_else(|| "unknown account".into());
    ctx.print(format!("Signed in as {email}"))?;
    let team_id = upstream
        .as_ref()
        .and_then(|r| r.as_ref().ok())
        .and_then(|v| v.get("teamId"))
        .and_then(Value::as_str)
        .or_else(|| auth.get("selected_team_id").and_then(Value::as_str));
    if let Some(team_id) = team_id.filter(|v| !v.is_empty()) {
        ctx.print(format!("Team: {}", safe(team_id)))?;
    }
    match upstream {
        Some(Ok(value)) => print_accounts(ctx, &value)?,
        Some(Err(error)) => ctx.print(format!(
            "Claude upstream accounts: unavailable ({})",
            safe(&error.message)
        ))?,
        None => {}
    }
    if ctx.explain {
        eprintln!(
            "explain: command=coderouter.status resource=account+upstream transport=cmux-socket"
        );
    }
    Ok(Some(0))
}

fn machines(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let (team, rest) = team_args(input)?;
    args::reject_remaining(&rest, "Usage: cmux coderouter machines [--team <id>]")?;
    let mut value = ctx.rpc("coderouter.machines", team_params(team.as_deref()))?;
    explain(ctx, &mut value, "coderouter.machines", "machine");
    if ctx.json {
        ctx.emit(&value)?;
    } else {
        print_machine_usage(ctx, &value)?;
        if ctx.explain {
            eprintln!(
                "explain: command=coderouter.machines resource=machine transport=cmux-socket"
            );
        }
    }
    Ok(Some(0))
}

fn claude(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let sub = input
        .first()
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_else(|| "list".into());
    let rest = &input[1..];
    match sub.as_str() {
        "help" | "--help" | "-h" => {
            ctx.print(USAGE)?;
            Ok(Some(0))
        }
        "list" | "ls" | "show" | "get" | "status" => claude_list(ctx, rest),
        "add" | "set" => claude_add(ctx, rest),
        "remove" | "rm" | "delete" => claude_remove(ctx, rest),
        "disable" | "enable" => claude_state(ctx, &sub, rest),
        "clear" | "remove-all" | "unset" => claude_clear(ctx, rest),
        _ => Err(CliError::usage(format!(
            "Unknown coderouter claude subcommand: {sub}\n\n{USAGE}"
        ))),
    }
}
fn claude_list(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let (team, rest) = team_args(input)?;
    args::reject_remaining(&rest, "Usage: cmux coderouter claude list [--team <id>]")?;
    let mut value = ctx.rpc(
        "coderouter.claude_upstream.get",
        team_params(team.as_deref()),
    )?;
    explain(ctx, &mut value, "coderouter.claude.list", "upstream");
    if ctx.json {
        ctx.emit(&value)?;
    } else {
        print_accounts(ctx, &value)?;
    }
    Ok(Some(0))
}

fn claude_add(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let kind = input.first().filter(|s| !s.starts_with('-')).map(|s| s.to_ascii_lowercase()).ok_or_else(|| CliError::usage("coderouter claude add requires a credential kind: oauth-token, api-key, or bedrock"))?;
    let (team, mut rest) = team_args(&input[1..])?;
    let label = args::take_option(&mut rest, "--label")?.filter(|s| !s.trim().is_empty());
    let force_stdin = args::take_flag(&mut rest, "--stdin");
    if kind == "bedrock" && force_stdin {
        return Err(CliError::usage(
            "coderouter claude add bedrock does not accept --stdin; use AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.",
        ));
    }
    let mut params = match kind.as_str() {
        "oauth-token" | "oauth" | "claude-code" => {
            args::reject_remaining(
                &rest,
                "Usage: cmux coderouter claude add oauth-token [--label <s>] [--stdin]",
            )?;
            let token = secret(
                force_stdin,
                "CLAUDE_CODE_OAUTH_TOKEN",
                "Claude Code OAuth token",
                "Run `claude setup-token` to mint one.",
            )?;
            if !token.starts_with("sk-ant-oat01-") {
                return Err(CliError::new(
                    "invalid_credential",
                    "That is not a Claude Code OAuth token (expected sk-ant-oat01-...). For an Anthropic API key use `cmux coderouter claude add api-key`.",
                ));
            }
            json!({"kind":"anthropic_oauth", "token":token})
        }
        "api-key" | "apikey" | "anthropic-key" => {
            args::reject_remaining(
                &rest,
                "Usage: cmux coderouter claude add api-key [--label <s>] [--stdin]",
            )?;
            let key = secret(
                force_stdin,
                "ANTHROPIC_API_KEY",
                "Anthropic API key",
                "Create one in the Anthropic console.",
            )?;
            if !key.starts_with("sk-ant-") || key.starts_with("sk-ant-oat") {
                return Err(CliError::new(
                    "invalid_credential",
                    "That is not an Anthropic API key (expected sk-ant-...). For a Claude Code OAuth token use `cmux coderouter claude add oauth-token`.",
                ));
            }
            json!({"kind":"anthropic_api_key", "apiKey":key})
        }
        "bedrock" => {
            let region = args::take_option(&mut rest, "--region")?.or_else(|| env::var("AWS_REGION").ok()).or_else(|| env::var("AWS_DEFAULT_REGION").ok()).filter(|s| !s.trim().is_empty()).ok_or_else(|| CliError::usage("coderouter claude add bedrock requires --region <r> or AWS_REGION / AWS_DEFAULT_REGION."))?;
            let mut model_ids = Map::new();
            let mut remaining = Vec::new();
            let mut i = 0;
            while i < rest.len() {
                if rest[i] == "--model" {
                    let pair = rest.get(i + 1).ok_or_else(|| CliError::usage("coderouter claude add bedrock: --model requires <claude-model-id>=<bedrock-model-id>."))?;
                    let (left, right) = pair.split_once('=').filter(|(a,b)| !a.is_empty() && !b.is_empty()).ok_or_else(|| CliError::usage(format!("coderouter claude add bedrock: --model expects <claude-model-id>=<bedrock-model-id>, got '{}'.", safe(pair))))?;
                    model_ids.insert(left.into(), json!(right));
                    i += 2;
                } else {
                    remaining.push(rest[i].clone());
                    i += 1;
                }
            }
            args::reject_remaining(
                &remaining,
                "Usage: cmux coderouter claude add bedrock [--region <r>] [--model <claude-id>=<bedrock-id>]",
            )?;
            let access = env::var("AWS_ACCESS_KEY_ID").ok().filter(|s| !s.is_empty()).ok_or_else(|| CliError::usage("coderouter claude add bedrock reads AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from your shell environment; export both, then retry."))?;
            let secret_key = env::var("AWS_SECRET_ACCESS_KEY").ok().filter(|s| !s.is_empty()).ok_or_else(|| CliError::usage("coderouter claude add bedrock reads AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from your shell environment; export both, then retry."))?;
            let mut value = json!({"kind":"bedrock", "region":region, "accessKeyId":access, "secretAccessKey":secret_key});
            if let Some(token) = env::var("AWS_SESSION_TOKEN").ok().filter(|s| !s.is_empty()) {
                value["sessionToken"] = json!(token);
            }
            if !model_ids.is_empty() {
                value["modelIds"] = Value::Object(model_ids);
            }
            value
        }
        _ => {
            return Err(CliError::usage(format!(
                "coderouter claude add: unsupported credential kind '{}'. Use oauth-token, api-key, or bedrock.",
                safe(&kind)
            )));
        }
    };
    if let Some(label) = label {
        params["label"] = json!(label);
    }
    if let Some(team) = team {
        params["teamId"] = json!(team);
    }
    let mut response = ctx.rpc("coderouter.claude_upstream.add", params)?;
    explain(ctx, &mut response, "coderouter.claude.add", "upstream");
    if ctx.json {
        ctx.emit(&response)?;
        return Ok(Some(0));
    }
    let account = response.get("account").or_else(|| response.get("upstream"));
    let kind = account
        .and_then(|v| v.get("kind"))
        .and_then(Value::as_str)
        .unwrap_or("?");
    let identifier = account
        .and_then(|v| v.get("identifier"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let label = account
        .and_then(|v| v.get("label"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let suffix = if identifier.is_empty() {
        String::new()
    } else {
        format!(" {}", safe(identifier))
    };
    let label_suffix = if label.is_empty() {
        String::new()
    } else {
        format!(" ({})", safe(label))
    };
    ctx.print(format!(
        "OK added Claude upstream account: {}{}{}",
        safe(kind),
        suffix,
        label_suffix
    ))?;
    if let Some(id) = account.and_then(|v| v.get("id")).and_then(Value::as_str) {
        ctx.print(format!("  id: {}", safe(id)))?;
    }
    if let Some(team) = response.get("teamId").and_then(Value::as_str) {
        ctx.print(format!("  team: {}", safe(team)))?;
    }
    if let Some(region) = account
        .and_then(|v| v.get("region"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        ctx.print(format!("  region: {}", safe(region)))?;
    }
    if let Some(total) = response.get("accountsTotal").and_then(Value::as_i64) {
        ctx.print(format!(
            "Cloud machines now route `claude` across {total} account{}.",
            if total == 1 { "" } else { "s" }
        ))?;
    }
    Ok(Some(0))
}
fn claude_remove(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let (team, rest) = team_args(input)?;
    let selector = one_selector(&rest, "coderouter claude remove")?;
    let account = resolve_account(ctx, selector, team.as_deref())?;
    let mut params = team_params(team.as_deref());
    params["accountId"] = json!(account.0);
    let mut response = ctx.rpc("coderouter.claude_upstream.remove", params)?;
    explain(ctx, &mut response, "coderouter.claude.remove", "upstream");
    if ctx.json {
        ctx.emit(&response)?;
    } else if response.get("removed").and_then(Value::as_bool) == Some(true) {
        ctx.print(format!("OK removed {}", account.1))?;
    } else {
        ctx.print(format!("No Claude upstream account {} exists.", account.1))?;
    }
    Ok(Some(0))
}
fn claude_state(ctx: &Context, state: &str, input: &[String]) -> Result<Option<i32>> {
    let (team, rest) = team_args(input)?;
    let selector = one_selector(&rest, &format!("coderouter claude {state}"))?;
    let account = resolve_account(ctx, selector, team.as_deref())?;
    let mut params = team_params(team.as_deref());
    params["accountId"] = json!(account.0);
    params["state"] = json!(if state == "disable" {
        "disabled"
    } else {
        "active"
    });
    let mut response = ctx.rpc("coderouter.claude_upstream.update", params)?;
    explain(ctx, &mut response, "coderouter.claude.state", "upstream");
    if ctx.json {
        ctx.emit(&response)?;
    } else {
        ctx.print(format!(
            "OK {} {}",
            if state == "disable" {
                "disabled"
            } else {
                "enabled"
            },
            account.1
        ))?;
    }
    Ok(Some(0))
}
fn claude_clear(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let (team, rest) = team_args(input)?;
    args::reject_remaining(&rest, "Usage: cmux coderouter claude clear [--team <id>]")?;
    let mut response = ctx.rpc(
        "coderouter.claude_upstream.clear",
        team_params(team.as_deref()),
    )?;
    explain(ctx, &mut response, "coderouter.claude.clear", "upstream");
    if ctx.json {
        ctx.emit(&response)?;
    } else if response.get("removed").and_then(Value::as_bool) == Some(true) {
        let count = response.get("count").and_then(Value::as_i64).unwrap_or(0);
        ctx.print(format!(
            "OK removed {count} Claude upstream account{}.",
            if count == 1 { "" } else { "s" }
        ))?;
    } else {
        ctx.print("No Claude upstream accounts were set.")?;
    }
    Ok(Some(0))
}

fn agent(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    if input.iter().any(|v| v == "--help" || v == "-h") {
        ctx.print("Usage: cmux coderouter agent <claude|codex|opencode|pi> [vm-agent-options] -- <prompt or args...>")?;
        return Ok(Some(0));
    }
    let mut args = input.to_vec();
    let provider = args.first().filter(|v| !v.starts_with('-')).cloned().or_else(|| args::take_option(&mut args, "--agent").ok().flatten()).ok_or_else(|| CliError::usage("Usage: cmux coderouter agent <claude|codex|opencode|pi> [vm-agent-options] -- <prompt or args...>"))?;
    if args.first() == Some(&provider) {
        args.remove(0);
    }
    let mut forwarded = vec!["agent".to_string(), provider];
    forwarded.extend(args);
    crate::commands::cloud_execution::run(ctx, "vm", &forwarded)
}

fn capabilities(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    if !input.is_empty() {
        return Err(CliError::usage(
            "Usage: cmux coderouter capabilities [--json]",
        ));
    }
    let value = json!({
        "schema_version": 1,
        "command": "coderouter",
        "transport": {"owned": "cmux-socket", "passthrough": "standalone-coderouter"},
        "resources": {
            "account": {"scope":"personal", "commands":["cr accounts", "cr add"]},
            "upstream": {"scope":"team", "commands":["cmux coderouter claude list", "cmux coderouter claude add", "cmux coderouter claude remove", "cmux coderouter claude enable", "cmux coderouter claude disable", "cmux coderouter claude clear"]},
            "machine": {"scope":"cloud", "commands":["cmux coderouter machines", "cmux coderouter agent"]}
        },
        "commands": ["status", "machines", "claude list", "claude add", "claude remove", "claude enable", "claude disable", "claude clear", "agent"],
        "global_options": ["--output text|json|jsonl", "--non-interactive", "--timeout <seconds>", "--dry-run", "--explain"]
    });
    if ctx.json {
        ctx.emit(&value)?;
    } else {
        ctx.print("CodeRouter command capabilities are available as JSON: cmux coderouter capabilities --json")?;
    }
    Ok(Some(0))
}

fn resolve_account(ctx: &Context, selector: &str, team: Option<&str>) -> Result<(String, String)> {
    if looks_like_uuid(selector) {
        return Ok((selector.to_ascii_lowercase(), safe(selector)));
    }
    let response = ctx.rpc("coderouter.claude_upstream.get", team_params(team))?;
    let accounts = response
        .get("accounts")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let needle = selector.to_ascii_lowercase();
    let matches: Vec<&Value> = accounts
        .iter()
        .filter(|account| {
            ["label", "identifier", "id"]
                .iter()
                .filter_map(|key| account.get(*key).and_then(Value::as_str))
                .any(|value| value.to_ascii_lowercase() == needle)
        })
        .collect();
    match matches.as_slice() {
        [account] => {
            let id = account.get("id").and_then(Value::as_str).ok_or_else(|| {
                CliError::new("invalid_response", "Claude upstream account has no id")
            })?;
            Ok((id.into(), account_summary(account)))
        }
        [] => Err(CliError::usage(format!(
            "No Claude upstream account matches '{}'. Run `cmux coderouter claude list` and use the id, label, or identifier.",
            safe(selector)
        ))),
        many => Err(CliError::usage(format!(
            "'{}' matches {} Claude upstream accounts. Use the id from `cmux coderouter claude list`.",
            safe(selector),
            many.len()
        ))),
    }
}
fn one_selector<'a>(args: &'a [String], command: &str) -> Result<&'a str> {
    if args.iter().any(|v| v.starts_with('-')) {
        return Err(CliError::usage(format!("{command}: unknown flag")));
    }
    match args {
        [selector] if !selector.is_empty() => Ok(selector),
        [] => Err(CliError::usage(format!(
            "{command} requires an account id, label, or identifier"
        ))),
        _ => Err(CliError::usage(format!("{command}: unexpected argument"))),
    }
}
fn secret(force_stdin: bool, variable: &str, label: &str, hint: &str) -> Result<String> {
    if !force_stdin {
        if let Ok(value) = env::var(variable) {
            if !value.trim().is_empty() {
                return Ok(value);
            }
        }
    }
    if force_stdin || !io::stdin().is_terminal() {
        let mut data = String::new();
        io::stdin().read_to_string(&mut data)?;
        return data
            .lines()
            .map(str::trim)
            .find(|line| !line.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| CliError::usage(format!("No {label} on stdin. {hint}")));
    }
    Err(CliError::new(
        "secret_required",
        format!("No {label} supplied. Set {variable} or use --stdin. {hint}"),
    ))
}

fn print_accounts(ctx: &Context, value: &Value) -> Result<()> {
    let accounts = value
        .get("accounts")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if accounts.is_empty() {
        ctx.print("Claude upstream accounts: none. Cloud machines cannot run `claude` until one is added:\n  claude setup-token && cmux coderouter claude add oauth-token")?;
        return Ok(());
    }
    ctx.print(format!("Claude upstream accounts ({}):", accounts.len()))?;
    for account in &accounts {
        let id = account.get("id").and_then(Value::as_str).unwrap_or("?");
        ctx.print(format!(
            "  {}  {}  {}",
            safe(id),
            account_summary(account),
            account_health(account)
        ))?;
        if let Some(region) = account
            .get("region")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            ctx.print(format!("    region: {}", safe(region)))?;
        }
        if let Some(models) = account.get("modelIds").and_then(Value::as_object) {
            let mut keys: Vec<_> = models.keys().collect();
            keys.sort();
            for key in keys {
                if let Some(value) = models.get(key).and_then(Value::as_str) {
                    ctx.print(format!("    model: {} -> {}", safe(key), safe(value)))?;
                }
            }
        }
    }
    Ok(())
}
fn print_machine_usage(ctx: &Context, value: &Value) -> Result<()> {
    if value.get("kind").and_then(Value::as_str) != Some("ready") {
        ctx.print("Machine usage is unavailable right now (the coderouter usage ledger did not answer). Retry in a moment.")?;
        return Ok(());
    }
    let machines = value
        .get("machines")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let days = value
        .get("periodDays")
        .and_then(Value::as_i64)
        .unwrap_or(30);
    if machines.is_empty() {
        ctx.print(format!(
            "No coderouter usage from Cloud machines in the last {days} days."
        ))?;
        return Ok(());
    }
    let mut total_tokens = 0i64;
    let mut total_usd = 0f64;
    for machine in &machines {
        let id = machine.get("vmId").and_then(Value::as_str).unwrap_or("?");
        let name = machine
            .get("displayName")
            .and_then(Value::as_str)
            .unwrap_or("");
        let totals = machine.get("totals").unwrap_or(&Value::Null);
        let tokens = totals
            .get("totalTokens")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let usd = totals
            .get("apiEquivalentUsd")
            .and_then(Value::as_f64)
            .unwrap_or(0.0);
        total_tokens += tokens;
        total_usd += usd;
        ctx.print(format!(
            "{}{}  tokens={}  ${usd:.2}",
            safe(id),
            if name.is_empty() {
                "".into()
            } else {
                format!("  {}", safe(name))
            },
            tokens
        ))?;
    }
    ctx.print(format!(
        "Total ({days}d): {} machine{}, tokens={total_tokens}, ${total_usd:.2} API-equivalent",
        machines.len(),
        if machines.len() == 1 { "" } else { "s" }
    ))?;
    Ok(())
}
fn account_summary(account: &Value) -> String {
    let kind = account.get("kind").and_then(Value::as_str).unwrap_or("?");
    let identifier = account
        .get("identifier")
        .and_then(Value::as_str)
        .unwrap_or("");
    let label = account.get("label").and_then(Value::as_str).unwrap_or("");
    format!(
        "{}{}{}",
        safe(kind),
        if identifier.is_empty() {
            "".into()
        } else {
            format!(" {}", safe(identifier))
        },
        if label.is_empty() {
            "".into()
        } else {
            format!(" ({})", safe(label))
        }
    )
}
fn account_health(account: &Value) -> String {
    if account.get("state").and_then(Value::as_str) == Some("disabled") {
        return "disabled".into();
    }
    "active".into()
}
fn looks_like_uuid(value: &str) -> bool {
    value.len() == 36
        && value.as_bytes().iter().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                *b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn safe(value: &str) -> String {
    value
        .chars()
        .map(|c| if c.is_control() { '�' } else { c })
        .collect()
}
fn explain(ctx: &Context, value: &mut Value, command: &str, resource: &str) {
    if !ctx.explain {
        return;
    }
    if let Value::Object(map) = value {
        map.insert("_explain".into(), json!({"command":command,"resource":resource,"transport":"cmux-socket","schema_version":1}));
    }
}

fn passthrough(input: &[String]) -> Result<Option<i32>> {
    let environment: Vec<(String, String)> = env::vars()
        .filter(|(key, _)| !key.starts_with("CMUX_") && !key.starts_with("CMUXD_"))
        .collect();
    let executable = match resolve_executable(&environment, "coderouter")
        .or_else(|| resolve_executable(&environment, "cr"))
    {
        Some(path) => Some(path),
        None => bootstrap(&environment)?,
    };
    let Some(executable) = executable else {
        return Err(CliError::new(
            "coderouter.not_installed",
            format!(
                "CodeRouter CLI is not installed. Install it, then retry:\n  {INSTALL_COMMAND}"
            ),
        )
        .exit(127)
        .next(INSTALL_COMMAND));
    };
    let mut command = Command::new(&executable);
    command
        .args(input)
        .env_clear()
        .envs(environment.iter().map(|(key, value)| (key, value)));
    let error = command.exec();
    Err(CliError::new(
        "coderouter.exec_failed",
        format!("Could not start CodeRouter CLI at {executable}: {error}"),
    )
    .exit(127))
}

/// Preserve the Swift adapter's first-use behavior without putting cmux
/// variables into the installer or child process. A non-TTY never prompts and
/// receives the exact install command in the structured error instead.
fn bootstrap(environment: &[(String, String)]) -> Result<Option<String>> {
    if !io::stdin().is_terminal() || !io::stderr().is_terminal() {
        return Ok(None);
    }
    let install_root = environment
        .iter()
        .find(|(key, _)| key == "CODEROUTER_INSTALL")
        .map(|(_, value)| PathBuf::from(value))
        .or_else(|| {
            environment
                .iter()
                .find(|(key, _)| key == "HOME")
                .map(|(_, value)| PathBuf::from(value).join(".coderouter"))
        })
        .unwrap_or_else(|| PathBuf::from(".coderouter"));
    eprintln!(
        "CodeRouter CLI is not installed. cmux can install it now by running the official installer:\n  {INSTALL_COMMAND}\nThis downloads the checksum-verified CodeRouter binary into {} and adds that directory to your shell PATH.",
        install_root.join("bin").display()
    );
    eprint!("Install CodeRouter now? [y/N] ");
    let _ = io::stderr().flush();
    let mut answer = String::new();
    io::stdin().read_line(&mut answer)?;
    if !answer.trim().to_ascii_lowercase().starts_with('y') {
        return Ok(None);
    }

    eprintln!("Installing CodeRouter...");
    let tmp_root = env::var_os("TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(format!("cmux-coderouter-install-{}", std::process::id()));
    fs::create_dir_all(&tmp_root)?;
    let script = tmp_root.join("install.sh");
    let mut download = Command::new("/usr/bin/curl");
    download
        .args([
            "--proto",
            "=https",
            "--tlsv1.2",
            "-fsSL",
            "--max-time",
            "60",
            "https://cmux.com/coderouter/install.sh",
            "-o",
        ])
        .arg(&script)
        .env_clear()
        .envs(environment.iter().map(|(key, value)| (key, value)));
    let status = download
        .status()
        .map_err(|error| CliError::new("coderouter.bootstrap_download", error.to_string()))?;
    if !status.success() {
        let _ = fs::remove_dir_all(&tmp_root);
        return Err(CliError::new("coderouter.bootstrap_download", format!("Could not download the CodeRouter installer (curl exited with status {}). Retry, or install it with:\n  {INSTALL_COMMAND}", status.code().unwrap_or(1))).exit(127));
    }
    let mut installer = Command::new("/bin/sh");
    installer
        .arg(&script)
        .env_clear()
        .envs(environment.iter().map(|(key, value)| (key, value)));
    let status = installer
        .status()
        .map_err(|error| CliError::new("coderouter.bootstrap_install", error.to_string()))?;
    let _ = fs::remove_dir_all(&tmp_root);
    if !status.success() {
        return Err(CliError::new("coderouter.bootstrap_install", format!("The CodeRouter installer exited with status {}. Retry, or install it with:\n  {INSTALL_COMMAND}", status.code().unwrap_or(1))).exit(127));
    }
    Ok(resolve_executable(environment, "coderouter")
        .or_else(|| resolve_executable(environment, "cr")))
}

fn resolve_executable(environment: &[(String, String)], name: &str) -> Option<String> {
    let path = environment
        .iter()
        .find(|(key, _)| key == "PATH")
        .map(|(_, value)| value.as_str())
        .unwrap_or("");
    for directory in path.split(':').filter(|v| !v.is_empty()) {
        let candidate = Path::new(directory).join(name);
        if is_executable(&candidate) {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    let home = environment
        .iter()
        .find(|(key, _)| key == "HOME")
        .map(|(_, value)| value)
        .cloned()
        .or_else(|| env::var("HOME").ok());
    let install = environment
        .iter()
        .find(|(key, _)| key == "CODEROUTER_INSTALL")
        .map(|(_, value)| PathBuf::from(value))
        .or_else(|| home.map(|h| PathBuf::from(h).join(".coderouter")));
    install
        .map(|root| root.join("bin").join(name))
        .filter(|candidate| is_executable(candidate))
        .map(|p| p.to_string_lossy().into_owned())
}
fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|meta| meta.is_file())
        .unwrap_or(false)
}
