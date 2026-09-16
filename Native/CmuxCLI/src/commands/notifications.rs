//! Notification, feed, sidebar metadata, comments, and Vault commands.
//!
//! The app remains the authority for state. This module parses arguments,
//! resolves caller handles, and forwards one socket request per operation.

use crate::{CliError, Context, Result, args};
use serde_json::{Map, Value, json};
use std::env;
use std::fs;
use std::io::{self, IsTerminal};
use std::process::Command;

mod feed;

pub fn run(ctx: &Context, command: &str, input: &[String]) -> Result<Option<i32>> {
    match command {
        "notify"
        | "list-notifications"
        | "dismiss-notification"
        | "mark-notification-read"
        | "open-notification"
        | "jump-to-unread"
        | "clear-notifications"
        | "set-status"
        | "clear-status"
        | "list-status"
        | "set-progress"
        | "clear-progress"
        | "log"
        | "clear-log"
        | "list-log"
        | "sidebar-state"
        | "right-sidebar"
        | "sidebar"
        | "feed"
        | "comments"
        | "vault" => execute(ctx, command, input),
        _ => Ok(None),
    }
}

fn execute(ctx: &Context, command: &str, input: &[String]) -> Result<Option<i32>> {
    if input
        .iter()
        .take_while(|v| v.as_str() != "--")
        .any(|v| matches!(v.as_str(), "--help" | "-h"))
    {
        ctx.print(usage(command))?;
        return Ok(Some(0));
    }
    if command == "feed" {
        return feed::run(ctx, input).map(Some);
    }
    let value = match command {
        "notify" => notify(ctx, input)?,
        "list-notifications" => {
            args::reject_remaining(input, "list-notifications")?;
            return list_notifications(ctx).map(|_| Some(0));
        }
        "dismiss-notification" => notification_dismiss(ctx, input)?,
        "mark-notification-read" => notification_mark_read(ctx, input)?,
        "open-notification" => notification_open(ctx, input)?,
        "jump-to-unread" => {
            args::reject_remaining(input, "jump-to-unread")?;
            ctx.rpc("notification.jump_to_unread", json!({}))?
        }
        "clear-notifications" => clear_notifications(ctx, input)?,
        "set-status" | "clear-status" | "list-status" | "set-progress" | "clear-progress"
        | "log" | "clear-log" | "list-log" | "sidebar-state" => {
            sidebar_metadata(ctx, command, input)?
        }
        "right-sidebar" => right_sidebar(ctx, input)?,
        "sidebar" => sidebar(ctx, input)?,
        "comments" => comments(ctx, input)?,
        "vault" => vault(ctx, input)?,
        _ => unreachable!(),
    };
    if let Value::String(text) = &value {
        if ctx.envelope {
            ctx.emit(&value)?;
        } else {
            ctx.print(text)?;
        }
    } else if !value.is_null() {
        if ctx.json || ctx.envelope {
            ctx.emit(&value)?;
        } else {
            render(ctx, command, input, &value)?;
        }
    }
    Ok(Some(
        if command == "sidebar" && integer(&value["error_count"]) > 0 {
            1
        } else {
            0
        },
    ))
}

fn text<'a>(value: &'a Value, key: &str, fallback: &'a str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or(fallback)
}
fn integer(value: &Value) -> i64 {
    value
        .as_i64()
        .or_else(|| value.as_str()?.parse().ok())
        .unwrap_or(0)
}
fn rows<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

fn render(ctx: &Context, command: &str, input: &[String], value: &Value) -> Result<()> {
    match command {
        "notify" if !has(input, "--clear") => {
            let id = text(value, "id", "");
            if id.is_empty() {
                return ctx.print("OK");
            }
            let fallback = format!("notification:{id}");
            let handle = text(value, "notification_ref", &fallback);
            let display = match ctx.id_format.as_str() {
                "uuids" => id.to_owned(),
                "both" => format!("{handle} ({id})"),
                _ => handle.to_owned(),
            };
            ctx.print(format!("OK {display}"))
        }
        "notify" | "dismiss-notification" | "mark-notification-read" => ctx.print("OK"),
        "open-notification" | "jump-to-unread" => {
            let mut parts = vec!["OK".to_owned()];
            for kind in ["surface", "workspace"] {
                let id = value.get(format!("{kind}_id")).and_then(Value::as_str);
                let reference = value.get(format!("{kind}_ref")).and_then(Value::as_str);
                let handle = match ctx.id_format.as_str() {
                    "uuids" => id.or(reference).map(str::to_owned),
                    "both" => reference.or(id).map(|v| {
                        if let (Some(r), Some(i)) = (reference, id) {
                            format!("{r} ({i})")
                        } else {
                            v.to_owned()
                        }
                    }),
                    _ => reference.or(id).map(str::to_owned),
                };
                if let Some(handle) = handle {
                    parts.push(handle);
                }
            }
            ctx.print(parts.join(" "))
        }
        "comments" => {
            let comments = rows(value, "comments");
            let root = text(value, "repo_root", "");
            if comments.is_empty() {
                return ctx.print(format!("No review comments. (repo: {root})"));
            }
            ctx.print(format!(
                "{} review comment{} (repo: {root})",
                comments.len(),
                if comments.len() == 1 { "" } else { "s" }
            ))?;
            for comment in comments {
                let start = integer(&comment["startLine"]);
                let end = comment.get("endLine").map(integer).unwrap_or(start);
                let range = if end > start {
                    format!("{start}-{end}")
                } else {
                    start.to_string()
                };
                let state = if comment.get("consumedAt").is_none() {
                    "pending"
                } else {
                    "consumed"
                };
                ctx.print(format!(
                    "- {}:{range} [{state}]",
                    text(comment, "filePath", "?")
                ))?;
                if let Some(anchor) = comment["lineText"].as_str().filter(|v| !v.is_empty()) {
                    ctx.print(format!("    anchor: {anchor}"))?;
                }
                if let Some(message) = comment["message"].as_str().filter(|v| !v.is_empty()) {
                    ctx.print(format!("    {message}"))?;
                }
            }
            Ok(())
        }
        "vault" => render_vault(ctx, input.first().map(String::as_str).unwrap_or(""), value),
        "sidebar" => render_sidebar(ctx, input.first().map(String::as_str).unwrap_or(""), value),
        _ => ctx.emit(value),
    }
}

fn render_vault(ctx: &Context, sub: &str, value: &Value) -> Result<()> {
    match sub {
        "sessions" | "ls" | "search" => {
            for error in rows(value, "errors") {
                if let Some(message) = error.as_str() {
                    eprintln!("warning: {message}");
                }
            }
            let sessions = rows(value, "sessions");
            if sessions.is_empty() {
                return ctx.print("No sessions.");
            }
            for session in sessions {
                ctx.print(format!(
                    "{}\t{}\t{}\t{}\t{}\t{}",
                    text(session, "agent", "-"),
                    text(session, "session_id", "-"),
                    text(session, "status", "-"),
                    text(session, "modified", ""),
                    text(session, "title", ""),
                    text(session, "cwd", "")
                ))?;
            }
        }
        "checkpoints" => {
            if value["supports_fork"].as_bool() == Some(false) {
                ctx.print("note: this agent's checkpoints are view-only (fork not supported yet)")?;
            }
            let checkpoints = rows(value, "checkpoints");
            if checkpoints.is_empty() {
                return ctx.print("No checkpoints.");
            }
            for checkpoint in checkpoints {
                ctx.print(checkpoint_line(checkpoint))?;
            }
        }
        "checkpoint" => {
            if let Some(checkpoint) = value.get("checkpoint") {
                ctx.print(checkpoint_line(checkpoint))?;
            }
        }
        "fork" => {
            if let Some(id) = value["session_id"].as_str() {
                ctx.print(format!("Forked session {id}"))?;
            }
            if let Some(resume) = value["resume_command"].as_str() {
                ctx.print(format!("Resume with: {resume}"))?;
            }
            if value["opened"].as_bool() == Some(true) {
                ctx.print("Opened in a new workspace.")?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn checkpoint_line(checkpoint: &Value) -> String {
    let turn = checkpoint["turn"]
        .as_i64()
        .map(|v| v.to_string())
        .unwrap_or_else(|| "-".into());
    let label = checkpoint["name"]
        .as_str()
        .or_else(|| checkpoint["prompt"].as_str())
        .unwrap_or("");
    let sha: String = text(checkpoint, "git_sha", "").chars().take(7).collect();
    format!(
        "{}\t{}\tturn={turn}\t{sha}\t{label}",
        text(checkpoint, "id", "-"),
        text(checkpoint, "source", "-")
    )
}

fn render_sidebar(ctx: &Context, action: &str, value: &Value) -> Result<()> {
    let sidebars = rows(value, "sidebars");
    if sidebars.is_empty() {
        ctx.print("No custom sidebars found.")?;
    }
    for sidebar in sidebars {
        let prefix = format!(
            "{} [{}] {}",
            text(sidebar, "name", "(unknown)"),
            text(sidebar, "kind", ""),
            text(sidebar, "path", "")
        );
        if sidebar["ok"].as_bool() == Some(true) {
            ctx.print(format!("OK {prefix}"))?;
        } else {
            ctx.print(format!(
                "ERROR {prefix}: {}",
                text(sidebar, "error", "Unknown error")
            ))?;
        }
    }
    let valid = integer(&value["valid_count"]);
    let invalid = integer(&value["error_count"]);
    match action {
        "reload" => ctx.print(format!(
            "Reloaded {} valid sidebars. {valid} valid, {invalid} invalid.",
            integer(&value["reloaded_count"])
        )),
        "select" if value["selected_name"].is_string() => {
            ctx.print(format!("Selected {}.", text(value, "selected_name", "")))
        }
        "open" if value["opened_name"].is_string() => ctx.print(format!(
            "Opened {} as pane {}.",
            text(value, "opened_name", ""),
            value["surface_ref"]
                .as_str()
                .or_else(|| value["surface_id"].as_str())
                .unwrap_or("")
        )),
        _ => ctx.print(format!("{valid} valid, {invalid} invalid.")),
    }
}

fn usage(command: &str) -> String {
    let body = match command {
        "notify" => {
            "[--title <text>] [--subtitle <text>] [--body <text>] [--workspace <id|ref>] [--surface <id|ref>] [--reply] [--clear]"
        }
        "dismiss-notification" => "--id <notification:id|uuid> | --all-read",
        "mark-notification-read" => "--id <id> | --workspace <id|ref> [--surface <id|ref>] | --all",
        "open-notification" => "--id <notification:id|uuid>",
        "clear-notifications" => "[--workspace <id|ref>] [--surface <id|ref>]",
        "vault" => {
            "sessions [--agent <id>] [--folder <path>] [--limit <n>]\n       cmux vault search <query> [--limit <n>]\n       cmux vault checkpoints --agent <id> --session <id>\n       cmux vault checkpoint --agent <id> --session <id> [--name <text>]\n       cmux vault fork --agent <id> --session <id> (--checkpoint <id> | --turn <n>) [--open]"
        }
        "comments" => "list [--repo <path>] [--all] [--json]",
        "sidebar" => {
            "validate|reload [name|--all]\n       cmux sidebar select <name>\n       cmux sidebar open <name> [--workspace <id|ref>] [--window <id|ref>]"
        }
        "right-sidebar" => {
            "toggle|show|hide|focus|mode\n       cmux right-sidebar set <files|find|vault|sessions|feed|dock|cloud|custom> [sidebar-name] [--no-focus]"
        }
        "feed" => {
            "tui [--opentui|--legacy]\n       cmux feed clear [--yes]\n       cmux feed history [--limit <n>]"
        }
        "set-status" => "<key> <value> [--icon <icon>] [--color <color>] [--workspace <id|ref>]",
        "clear-status" => "<key> [--workspace <id|ref>]",
        "set-progress" => "<0..1> [--label <text>] [--workspace <id|ref>]",
        "log" => "[--level <level>] [--source <source>] [--workspace <id|ref>] <message>",
        _ => "[--workspace <id|ref>]",
    };
    format!("Usage: cmux {command} {body}")
}

fn option(args: &[String], name: &str) -> Result<Option<String>> {
    let mut copy = args.to_vec();
    args::take_option(&mut copy, name)
}
fn has(args: &[String], flag: &str) -> bool {
    args.iter().any(|v| v == flag)
}

fn normalize_notification_id(value: &str) -> String {
    if value
        .get(..13)
        .is_some_and(|v| v.eq_ignore_ascii_case("notification:"))
    {
        value[13..].to_owned()
    } else {
        value.to_owned()
    }
}

fn uuid(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok()
}
fn nonempty_env(name: &str) -> Option<String> {
    env::var(name).ok().filter(|v| !v.trim().is_empty())
}
fn window_id(ctx: &Context, raw: Option<&str>) -> Result<Option<String>> {
    raw.map(|r| ctx.resolve_id("window", Some(r)))
        .transpose()
        .map(Option::flatten)
}
fn workspace_id(ctx: &Context, raw: Option<&str>, window: Option<&str>) -> Result<String> {
    let mut scoped = ctx.clone();
    scoped.window = window.map(str::to_owned);
    scoped
        .resolve_id("workspace", raw)?
        .ok_or_else(|| CliError::new("workspace_missing", "No workspace selected"))
}
fn current_workspace(ctx: &Context, window: &str, command: &str) -> Result<String> {
    let current = ctx.rpc("workspace.current", json!({"window_id": window}))?;
    current["workspace_id"].as_str().filter(|v| !v.trim().is_empty()).map(str::to_owned).ok_or_else(|| CliError::new("workspace_missing", format!("{command}: targeted window has no current workspace. Select a workspace in that window or pass --workspace <id|ref|index>.")))
}
fn surface_in_workspace(
    ctx: &Context,
    raw: &str,
    workspace: &str,
    window: Option<&str>,
) -> Result<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(CliError::usage("Surface handle is blank"));
    }
    let mut params = json!({"workspace_id": workspace});
    if let Some(window) = window {
        params["window_id"] = json!(window);
    }
    let result = ctx.rpc("surface.list", params)?;
    for surface in rows(&result, "surfaces") {
        if surface["id"]
            .as_str()
            .is_some_and(|v| v.eq_ignore_ascii_case(raw))
            || surface["ref"].as_str() == Some(raw)
            || raw
                .parse::<i64>()
                .ok()
                .is_some_and(|n| surface.get("index").is_some_and(|i| integer(i) == n))
        {
            if let Some(id) = surface["id"].as_str() {
                return Ok(id.to_owned());
            }
        }
    }
    Err(CliError::new(
        "surface_missing",
        format!("Surface not found: {raw}"),
    ))
}
fn surface_in_window(ctx: &Context, raw: &str, window: &str) -> Result<(String, String)> {
    if raw.parse::<i64>().is_ok() {
        let workspace = current_workspace(ctx, window, "notify")?;
        let surface = surface_in_workspace(ctx, raw, &workspace, Some(window))?;
        return Ok((workspace, surface));
    }
    let result = ctx.rpc("workspace.list", json!({"window_id": window}))?;
    for workspace in rows(&result, "workspaces") {
        if let Some(id) = workspace["id"].as_str() {
            match surface_in_workspace(ctx, raw, id, Some(window)) {
                Ok(surface) => return Ok((id.to_owned(), surface)),
                Err(error) if error.code == "surface_missing" => {}
                Err(error) => return Err(error),
            }
        }
    }
    Err(CliError::new(
        "surface_missing",
        "Surface not found in window",
    ))
}

fn caller_tty() -> Option<String> {
    for name in ["CMUX_CLI_TTY_NAME", "CMUX_TTY_NAME", "TTY", "SSH_TTY"] {
        if let Some(tty) = nonempty_env(name) {
            let tty = tty.trim();
            return Some(tty.strip_prefix("/dev/").unwrap_or(tty).to_owned());
        }
    }
    for fd in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
        let mut buffer = [0i8; 1024];
        if unsafe { libc::ttyname_r(fd, buffer.as_mut_ptr(), buffer.len()) } == 0 {
            let raw = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) }.to_string_lossy();
            return Some(raw.strip_prefix("/dev/").unwrap_or(&raw).to_owned());
        }
    }
    None
}

fn notify(ctx: &Context, input: &[String]) -> Result<Value> {
    let mut rest = input.to_vec();
    let title = args::take_option(&mut rest, "--title")?.unwrap_or_else(|| "Notification".into());
    let subtitle = args::take_option(&mut rest, "--subtitle")?.unwrap_or_default();
    let body = args::take_option(&mut rest, "--body")?.unwrap_or_default();
    let ws = args::take_option(&mut rest, "--workspace")?;
    let sf = args::take_option(&mut rest, "--surface")?;
    let win = args::take_option(&mut rest, "--window")?.or_else(|| ctx.window.clone());
    let reply = args::take_flag(&mut rest, "--reply");
    let clear = args::take_flag(&mut rest, "--clear");
    args::reject_remaining(&rest, "notify")?;
    if clear && sf.is_some() && ws.is_none() && win.is_none() {
        return Err(CliError::usage(
            "notify --clear --surface requires workspace or window context; specify --workspace or --window",
        ));
    }
    let win_id = window_id(ctx, win.as_deref())?;
    let has_handle = ws
        .as_deref()
        .into_iter()
        .chain(sf.as_deref())
        .any(|v| !uuid(v));
    let mut params = Map::new();
    let method;
    if let Some(surface_raw) = sf.as_deref() {
        let explicit_ws = ws
            .as_deref()
            .map(|raw| workspace_id(ctx, Some(raw), win_id.as_deref()))
            .transpose()?;
        if clear || has_handle {
            let (workspace, surface) =
                if let Some(window) = win_id.as_deref().filter(|_| ws.is_none()) {
                    surface_in_window(ctx, surface_raw, window)?
                } else {
                    let ambient = if win.is_none() {
                        nonempty_env("CMUX_WORKSPACE_ID")
                    } else {
                        None
                    };
                    let workspace = if let Some(ws) = explicit_ws {
                        ws
                    } else {
                        workspace_id(ctx, ambient.as_deref(), win_id.as_deref())?
                    };
                    let surface =
                        surface_in_workspace(ctx, surface_raw, &workspace, win_id.as_deref())?;
                    (workspace, surface)
                };
            params.insert("workspace_id".into(), json!(workspace));
            params.insert("surface_id".into(), json!(surface));
            method = if clear {
                "notification.clear"
            } else if has_handle {
                "notification.create_for_target"
            } else {
                "notification.create"
            };
            if !clear && !has_handle {
                if let Some(window) = win_id {
                    params.insert("window_id".into(), json!(window));
                }
            }
        } else {
            params.insert("surface_id".into(), json!(surface_raw));
            if let Some(workspace) = explicit_ws {
                params.insert("workspace_id".into(), json!(workspace));
            }
            if let Some(window) = win_id {
                params.insert("window_id".into(), json!(window));
            }
            method = "notification.create";
        }
    } else if let Some(window) = win_id.as_deref() {
        let workspace = if let Some(raw) = ws.as_deref() {
            workspace_id(ctx, Some(raw), Some(window))?
        } else {
            current_workspace(ctx, window, "notify")?
        };
        params.insert("workspace_id".into(), json!(workspace));
        if !clear {
            params.insert("window_id".into(), json!(window));
        }
        method = if clear {
            "notification.clear"
        } else {
            "notification.create"
        };
    } else {
        params.insert("caller".into(), json!(true));
        params.insert(
            "prefer_tty".into(),
            json!(env::var_os("TMUX").is_some() && ws.is_none()),
        );
        let ambient = nonempty_env("CMUX_WORKSPACE_ID");
        if let Some(raw) = ws
            .as_deref()
            .or(ambient.as_deref())
            .filter(|raw| uuid(raw) || ws.is_some())
        {
            params.insert(
                "preferred_workspace_id".into(),
                json!(if uuid(raw) {
                    raw.to_owned()
                } else {
                    workspace_id(ctx, Some(raw), None)?
                }),
            );
        }
        if let Some(surface) = nonempty_env("CMUX_SURFACE_ID").filter(|v| uuid(v)) {
            params.insert("preferred_surface_id".into(), json!(surface));
        }
        if let Some(tty) = caller_tty() {
            params.insert("caller_tty".into(), json!(tty));
        }
        method = if clear {
            "notification.clear"
        } else {
            "notification.create_for_caller"
        };
    }
    if !clear {
        params.insert("title".into(), json!(title));
        params.insert("subtitle".into(), json!(subtitle));
        params.insert("body".into(), json!(body));
        if reply {
            params.insert("reply_shape".into(), json!("text"));
        }
    }
    ctx.rpc(method, Value::Object(params))
}

fn parse_notifications(response: &str) -> Value {
    if response == "No notifications" {
        return json!([]);
    }
    let items: Vec<Value> = response.lines().filter_map(|line| {
        let (_, payload) = line.split_once(':')?; let fields: Vec<_> = payload.split('|').collect();
        if fields.len() < 7 { return None; }
        let mut body_end = fields.len(); let mut created = Value::Null; let mut tab = Value::Null;
        if fields.len() >= 9 && fields[fields.len()-1].starts_with("pct:") {
            let date = fields[fields.len()-2];
            if regex::Regex::new(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:?\d{2})$").unwrap().is_match(date) {
                body_end -= 2; created = json!(date);
                let title = fields[fields.len()-1][4..].replace("%0D", "\r").replace("%0A", "\n").replace("%7C", "|").replace("%25", "%");
                if !title.is_empty() { tab = json!(title); }
            }
        }
        Some(json!({"id":fields[0],"workspace_id":fields[1],"surface_id":if fields[2]=="none" { Value::Null } else { json!(fields[2]) },"is_read":fields[3]=="read","title":fields[4],"subtitle":fields[5],"body":fields[6..body_end].join("|"),"created_at":created,"tab_title":tab}))
    }).collect();
    json!(items)
}
fn list_notifications(ctx: &Context) -> Result<()> {
    let response = ctx.raw("list_notifications")?;
    if ctx.json || ctx.envelope {
        ctx.emit(&parse_notifications(&response))
    } else {
        ctx.print(response)
    }
}
fn notification_dismiss(ctx: &Context, input: &[String]) -> Result<Value> {
    let mut rest = input.to_vec();
    let id = args::take_option(&mut rest, "--id")?;
    let all = args::take_flag(&mut rest, "--all-read");
    if id.is_some() == all {
        return Err(CliError::usage(
            "dismiss-notification requires exactly one of --id or --all-read",
        ));
    }
    args::reject_remaining(&rest, "dismiss-notification")?;
    ctx.rpc(
        "notification.dismiss",
        id.map(|v| json!({"id":normalize_notification_id(&v)}))
            .unwrap_or_else(|| json!({"all_read":true})),
    )
}
fn notification_mark_read(ctx: &Context, input: &[String]) -> Result<Value> {
    let mut rest = input.to_vec();
    let id = args::take_option(&mut rest, "--id")?;
    let ws = args::take_option(&mut rest, "--workspace")?;
    let sf = args::take_option(&mut rest, "--surface")?;
    let win = args::take_option(&mut rest, "--window")?.or_else(|| ctx.window.clone());
    let all = args::take_flag(&mut rest, "--all");
    if id.is_some() as u8 + ws.is_some() as u8 + all as u8 != 1 {
        return Err(CliError::usage(
            "mark-notification-read requires exactly one selector: --id, --workspace, or --all",
        ));
    }
    if sf.is_some() && ws.is_none() {
        return Err(CliError::usage("--surface requires --workspace"));
    }
    args::reject_remaining(&rest, "mark-notification-read")?;
    let params = if let Some(id) = id {
        json!({"id":normalize_notification_id(&id)})
    } else if let Some(ws) = ws {
        let win = window_id(ctx, win.as_deref())?;
        let ws = workspace_id(ctx, Some(&ws), win.as_deref())?;
        let mut p = json!({"tab_id":ws});
        if let Some(surface) = sf {
            p["surface_id"] = json!(surface_in_workspace(ctx, &surface, &ws, None)?);
        }
        p
    } else {
        json!({"all":true})
    };
    ctx.rpc("notification.mark_read", params)
}
fn notification_open(ctx: &Context, input: &[String]) -> Result<Value> {
    let mut rest = input.to_vec();
    let id = args::take_option(&mut rest, "--id")?
        .ok_or_else(|| CliError::usage("open-notification requires --id"))?;
    args::reject_remaining(&rest, "open-notification")?;
    ctx.rpc(
        "notification.open",
        json!({"id":normalize_notification_id(&id)}),
    )
}
fn clear_notifications(ctx: &Context, input: &[String]) -> Result<Value> {
    let mut rest = input.to_vec();
    let ws = args::take_option(&mut rest, "--workspace")?;
    let sf = args::take_option(&mut rest, "--surface")?;
    let win = args::take_option(&mut rest, "--window")?.or_else(|| ctx.window.clone());
    args::reject_remaining(&rest, "clear-notifications")?;
    let window = window_id(ctx, win.as_deref())?;
    let workspace = if let Some(ws) = ws {
        Some(workspace_id(ctx, Some(&ws), window.as_deref())?)
    } else if let Some(window) = window.as_deref() {
        Some(current_workspace(ctx, window, "clear-notifications")?)
    } else {
        nonempty_env("CMUX_WORKSPACE_ID").and_then(|ws| workspace_id(ctx, Some(&ws), None).ok())
    };
    let mut parts = vec!["clear_notifications".to_owned()];
    if let Some(ws) = workspace.as_deref() {
        parts.push(format!("--tab={ws}"));
    }
    if let Some(sf) = sf {
        let ws = workspace.as_deref().ok_or_else(|| {
            CliError::usage("clear-notifications --surface requires a workspace or window context")
        })?;
        parts.push(format!(
            "--panel={}",
            surface_in_workspace(ctx, &sf, ws, None)?
        ));
    }
    Ok(json!(ctx.raw(&parts.join(" "))?))
}

fn sidebar_metadata(ctx: &Context, command: &str, input: &[String]) -> Result<Value> {
    let socket_command = match command {
        "set-status" => "set_status",
        "clear-status" => "clear_status",
        "list-status" => "list_status",
        "set-progress" => "set_progress",
        "clear-progress" => "clear_progress",
        "log" => "log",
        "clear-log" => "clear_log",
        "list-log" => "list_log",
        "sidebar-state" => "sidebar_state",
        _ => unreachable!(),
    };
    // Options after -- are literal log/status text. Never consume a workspace
    // string there or move the injected target past the delimiter.
    let separator = input.iter().position(|v| v == "--").unwrap_or(input.len());
    let mut options = input[..separator].to_vec();
    let tail = &input[separator..];
    let ws = args::take_option(&mut options, "--workspace")?;
    let win = args::take_option(&mut options, "--window")?.or_else(|| ctx.window.clone());
    let window = window_id(ctx, win.as_deref())?;
    let workspace = if let Some(ws) = ws {
        Some(workspace_id(ctx, Some(&ws), window.as_deref())?)
    } else if let Some(window) = window.as_deref() {
        Some(current_workspace(ctx, window, command)?)
    } else {
        nonempty_env("CMUX_WORKSPACE_ID")
            .map(|ws| workspace_id(ctx, Some(&ws), None))
            .transpose()?
    };
    if let Some(workspace) = workspace {
        options.push(format!("--tab={workspace}"));
    }
    let mut parts = vec![socket_command.to_owned()];
    parts.extend(options);
    parts.extend_from_slice(tail);
    let line = parts
        .iter()
        .map(|v| shell_quote(v))
        .collect::<Vec<_>>()
        .join(" ");
    Ok(json!(ctx.raw(&line)?))
}
fn right_sidebar_arguments(
    input: &[String],
) -> Result<(Vec<String>, Option<String>, Option<String>, bool)> {
    let mut rest = input.to_vec();
    let workspace = args::take_option(&mut rest, "--workspace")?;
    let window = args::take_option(&mut rest, "--window")?;
    let no_focus = args::take_flag(&mut rest, "--no-focus");
    if let Some(flag) = rest.iter().find(|v| v.starts_with("--")) {
        return Err(CliError::usage(format!(
            "right-sidebar: unknown flag '{flag}'"
        )));
    }
    let action = rest
        .first()
        .map(|v| v.to_lowercase())
        .ok_or_else(|| CliError::usage("right-sidebar requires a subcommand"))?;
    let mut result = match action.as_str() {
        "toggle" | "show" | "hide" | "focus" | "mode" => {
            if rest.len() != 1 {
                return Err(CliError::usage(format!(
                    "right-sidebar {action} received unexpected arguments"
                )));
            }
            if no_focus {
                return Err(CliError::usage(
                    "right-sidebar: --no-focus is only valid with set",
                ));
            }
            vec![action.clone()]
        }
        "set" => {
            if !(2..=3).contains(&rest.len()) {
                return Err(CliError::usage(
                    "right-sidebar set requires a mode: files, find, vault, sessions, feed, dock, cloud, or custom [sidebar-name]",
                ));
            }
            let mode = right_sidebar_mode(&rest[1]).ok_or_else(|| {
                CliError::usage(format!("Unknown right-sidebar mode '{}'", rest[1]))
            })?;
            if rest.len() == 3 && !matches!(mode.as_str(), "custom" | "custom-sidebar") {
                return Err(CliError::usage(
                    "right-sidebar set received unexpected arguments",
                ));
            }
            let mut r = vec!["set".into(), mode];
            if rest.len() == 3 {
                r.push(rest[2].clone());
            }
            r
        }
        _ => {
            if rest.len() != 1 {
                return Err(CliError::usage(format!(
                    "Unknown right-sidebar command '{action}'"
                )));
            }
            let mode = right_sidebar_mode(&action).ok_or_else(|| {
                CliError::usage(format!("Unknown right-sidebar command '{action}'"))
            })?;
            if no_focus {
                return Err(CliError::usage(
                    "right-sidebar: --no-focus is only valid with set",
                ));
            }
            // The documented `cloud` alias is forwarded unchanged, while `set
            // cloud` and the vms alias canonicalize to machines.
            vec![
                "set".into(),
                if action == "cloud" {
                    "cloud".into()
                } else {
                    mode
                },
            ]
        }
    };
    if no_focus {
        result.push("--no-focus".into());
    }
    Ok((result, workspace, window, action == "mode"))
}
fn right_sidebar_mode(raw: &str) -> Option<String> {
    let value = raw.trim().to_lowercase();
    match value.as_str() {
        "files" | "find" | "vault" | "sessions" | "feed" | "dock" | "machines" | "custom"
        | "custom-sidebar" => Some(value),
        "cloud" | "vms" => Some("machines".into()),
        _ => None,
    }
}
fn right_sidebar(ctx: &Context, input: &[String]) -> Result<Value> {
    let (mut parts, workspace, window, show_response) = right_sidebar_arguments(input)?;
    let window = window_id(ctx, window.as_deref().or(ctx.window.as_deref()))?;
    if let Some(raw) = workspace.as_deref() {
        parts.push(format!(
            "--tab={}",
            workspace_id(ctx, Some(raw), window.as_deref())?
        ));
    }
    if let Some(window) = window {
        parts.push(format!("--window={window}"));
    }
    parts.insert(0, "right_sidebar".into());
    let response = ctx.raw(
        &parts
            .iter()
            .map(|v| shell_quote(v))
            .collect::<Vec<_>>()
            .join(" "),
    )?;
    if show_response {
        Ok(json!(response))
    } else {
        Ok(Value::Null)
    }
}

fn sidebar(ctx: &Context, input: &[String]) -> Result<Value> {
    let mut args = input.to_vec();
    let all = args::take_flag(&mut args, "--all");
    let _ = args::take_flag(&mut args, "--json");
    let action = args.first().map(String::as_str).ok_or_else(|| {
        CliError::usage("sidebar requires a subcommand: validate, reload, select, or open")
    })?;
    let mut params = Map::new();
    match action {
        "validate" | "reload" => {
            if all && args.len() > 1 {
                return Err(CliError::usage(format!(
                    "sidebar {action}: use either --all or a sidebar name, not both"
                )));
            }
            if !all {
                if let Some(name) = args.get(1) {
                    params.insert("name".into(), json!(name));
                }
            }
            if args.len() > 2 {
                return Err(CliError::usage(format!(
                    "sidebar {action} accepts at most one sidebar name"
                )));
            }
        }
        "select" | "open" => {
            if all {
                return Err(CliError::usage(format!(
                    "sidebar {action} does not support --all"
                )));
            }
            let mut rest = args[1..].to_vec();
            let workspace = if action == "open" {
                args::take_option(&mut rest, "--workspace")?
            } else {
                None
            };
            let window = if action == "open" {
                args::take_option(&mut rest, "--window")?
            } else {
                None
            };
            if rest.len() != 1 {
                return Err(CliError::usage(format!(
                    "sidebar {action} requires one sidebar name"
                )));
            }
            params.insert("name".into(), json!(rest[0]));
            if action == "open" {
                params.insert("focus".into(), json!(true));
                if let Some(raw) = window.as_deref().or(ctx.window.as_deref()) {
                    if let Some(id) = ctx.resolve_id("window", Some(raw))? {
                        params.insert("window_id".into(), json!(id));
                    }
                }
                let workspace_raw = workspace.or_else(|| {
                    if window.is_none() && ctx.window.is_none() {
                        nonempty_env("CMUX_WORKSPACE_ID")
                    } else {
                        None
                    }
                });
                if let Some(raw) = workspace_raw.as_deref() {
                    if let Some(id) = ctx.resolve_id("workspace", Some(raw))? {
                        params.insert("workspace_id".into(), json!(id));
                    }
                }
            }
        }
        _ => {
            return Err(CliError::usage(format!(
                "Unknown sidebar command '{action}'"
            )));
        }
    }
    let method = match action {
        "validate" => "sidebar.custom.validate",
        "reload" => "sidebar.custom.reload",
        "select" => "sidebar.custom.select",
        _ => "sidebar.custom.open",
    };
    ctx.rpc(method, Value::Object(params))
}

fn comments(ctx: &Context, input: &[String]) -> Result<Value> {
    let sub = input
        .first()
        .map(String::as_str)
        .ok_or_else(|| CliError::usage("comments requires a subcommand. Try: list"))?;
    if !matches!(sub, "list" | "ls") {
        return Err(CliError::usage(format!(
            "Unknown comments subcommand '{sub}'. Try: list"
        )));
    }
    let mut rest = input[1..].to_vec();
    let repo = args::take_option(&mut rest, "--repo")?.unwrap_or_else(|| ".".into());
    let include = args::take_flag(&mut rest, "--all");
    if repo.starts_with("--") {
        return Err(CliError::usage(
            "--repo requires a path. For a path starting with a dash, pass it as ./-name",
        ));
    }
    args::reject_remaining(
        &rest,
        "cmux comments list. Supported: --repo <path>, --all, --json",
    )?;
    let output = Command::new("git")
        .args(["-C", &repo, "rev-parse", "--show-toplevel"])
        .output()?;
    let root = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if !output.status.success() || root.is_empty() {
        return Err(CliError::new(
            "not_repository",
            format!("cmux comments requires a git repository: {repo}"),
        ));
    }
    let mut params = json!({"repo_root":root});
    if include {
        params["include_consumed"] = json!(true);
    }
    ctx.rpc("comments.list", params)
}
fn vault_request(input: &[String]) -> Result<(&'static str, Value)> {
    let sub = input.first().map(String::as_str).ok_or_else(|| {
        CliError::usage(
            "vault requires a subcommand. Try: sessions, search, checkpoints, checkpoint, fork",
        )
    })?;
    let mut rest = input[1..].to_vec();
    let mut p = Map::new();
    let method = match sub {
        "sessions" | "ls" => {
            if let Some(v) = args::take_option(&mut rest, "--agent")? {
                p.insert("agent".into(), json!(v));
            }
            if let Some(v) = args::take_option(&mut rest, "--folder")? {
                p.insert("folder".into(), json!(v));
            }
            if let Some(v) = args::take_option(&mut rest, "--limit")? {
                p.insert("limit".into(), json!(parse_positive(&v, "--limit")?));
            }
            "vault.sessions"
        }
        "search" => {
            if let Some(v) = args::take_option(&mut rest, "--limit")? {
                p.insert("limit".into(), json!(parse_positive(&v, "--limit")?));
            }
            if let Some(flag) = rest.iter().find(|v| v.starts_with("--")) {
                return Err(CliError::usage(format!(
                    "Unexpected argument '{flag}' for cmux vault search"
                )));
            }
            if rest.is_empty() {
                return Err(CliError::usage(
                    "vault search requires a query. Operators: agent:, repo:, ws:, before:/after:",
                ));
            }
            p.insert("query".into(), json!(rest.join(" ")));
            rest.clear();
            "vault.search"
        }
        "checkpoints" | "checkpoint" | "fork" => {
            for key in ["agent", "session"] {
                let value=args::take_option(&mut rest,&format!("--{key}"))?.filter(|v|!v.starts_with("--")).ok_or_else(||CliError::usage("This subcommand requires --agent <id> --session <id> (see cmux vault sessions)"))?;
                p.insert(key.into(), json!(value));
            }
            match sub {
                "checkpoints" => "vault.checkpoints",
                "checkpoint" => {
                    if let Some(name) = args::take_option(&mut rest, "--name")? {
                        p.insert("name".into(), json!(name));
                    }
                    "vault.checkpoint"
                }
                _ => {
                    let checkpoint = args::take_option(&mut rest, "--checkpoint")?;
                    let turn = args::take_option(&mut rest, "--turn")?;
                    let open = args::take_flag(&mut rest, "--open");
                    if checkpoint.is_none() && turn.is_none() {
                        return Err(CliError::usage(
                            "vault fork requires --checkpoint <id> or --turn <n> (see cmux vault checkpoints)",
                        ));
                    }
                    if let Some(id) = checkpoint {
                        p.insert("checkpoint".into(), json!(id));
                    }
                    if let Some(n) = turn {
                        p.insert("turn".into(), json!(parse_positive(&n, "--turn")?));
                    }
                    if open {
                        p.insert("open".into(), json!(true));
                        p.insert("focus".into(), json!(true));
                    }
                    "vault.fork"
                }
            }
        }
        _ => {
            return Err(CliError::usage(format!(
                "Unknown vault subcommand '{sub}'. Try: sessions, search, checkpoints, checkpoint, fork"
            )));
        }
    };
    args::reject_remaining(&rest, &format!("cmux vault {sub}"))?;
    Ok((method, Value::Object(p)))
}
fn vault(ctx: &Context, input: &[String]) -> Result<Value> {
    let (method, params) = vault_request(input)?;
    ctx.rpc(method, params)
}

fn parse_positive(raw: &str, name: &str) -> Result<i64> {
    raw.parse::<i64>()
        .ok()
        .filter(|v| *v > 0)
        .ok_or_else(|| CliError::usage(format!("{name} requires a positive number")))
}
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn notification_refs_strip_prefix() {
        assert_eq!(normalize_notification_id("notification:abc"), "abc");
        assert_eq!(normalize_notification_id("abc"), "abc");
    }
    #[test]
    fn shell_quotes_single_quotes() {
        assert_eq!(shell_quote("a'b"), "'a'\\''b'");
    }
}
