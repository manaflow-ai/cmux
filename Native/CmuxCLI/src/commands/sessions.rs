//! Saved agent sessions, continuation, and managed-agent launch commands.
//!
//! The app remains the authority for live surface state.  This module owns the
//! local, deterministic parts of the old Swift CLI: session-store inspection,
//! continuation selector parsing, structured record validation, and process
//! replacement.  It deliberately never invents a restore record when the
//! socket or persisted state is unavailable.

use crate::{args, CliError, Context, Result};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn run(ctx: &Context, command: &str, raw_args: &[String]) -> Result<Option<i32>> {
    match command {
        "sessions" | "session-debug" => {
            sessions_list(ctx, raw_args)?;
            Ok(Some(0))
        }
        "restore" => {
            continuation(ctx, raw_args, false)?;
            Ok(Some(0))
        }
        "fork" => {
            continuation(ctx, raw_args, true)?;
            Ok(Some(0))
        }
        "claude-teams" => {
            launch_managed(ctx, "claude", raw_args, ManagedKind::ClaudeTeams)?;
            Ok(Some(0))
        }
        "codex-teams" => {
            launch_managed(ctx, "codex", raw_args, ManagedKind::CodexTeams)?;
            Ok(Some(0))
        }
        "omo" => {
            launch_managed(ctx, "opencode", raw_args, ManagedKind::Omo)?;
            Ok(Some(0))
        }
        "omx" => {
            launch_managed(ctx, "omx", raw_args, ManagedKind::Omx)?;
            Ok(Some(0))
        }
        "omc" => {
            launch_managed(ctx, "omc", raw_args, ManagedKind::Omc)?;
            Ok(Some(0))
        }
        "__codex-teams-watch" => {
            // This private verb is intentionally accepted so old persisted
            // launch records can fail with a useful provider error instead of
            // being mistaken for an unknown cmux command.
            return Err(CliError::new(
                "codex_teams_watcher_unavailable",
                "Codex Teams watcher is not available in this Rust CLI build",
            ));
        }
        _ => Ok(None),
    }
}

fn sessions_list(ctx: &Context, raw: &[String]) -> Result<()> {
    let mut args = raw.to_vec();
    if matches!(args.first().map(String::as_str), Some("list" | "debug")) {
        args.remove(0);
    } else if matches!(
        args.first().map(String::as_str),
        Some("help" | "--help" | "-h")
    ) {
        ctx.print(sessions_usage())?;
        return Ok(());
    } else if args.first().is_some_and(|v| !v.starts_with('-')) {
        return Err(CliError::usage(format!(
            "Unknown sessions subcommand: {}. Usage: cmux sessions list [options]",
            args[0]
        )));
    }

    let agent = args::take_option(&mut args, "--agent")?;
    let session = args::take_option(&mut args, "--session")?;
    let workspace = args::take_option(&mut args, "--workspace")?;
    let surface = args::take_option(&mut args, "--surface")?;
    let cwd = args::take_option(&mut args, "--cwd")?;
    let state_dir = args::take_option(&mut args, "--state-dir")?;
    let codex_home = args::take_option(&mut args, "--codex-home")?;
    let limit_raw = args::take_option(&mut args, "--limit")?;
    let include_all = args::take_flag(&mut args, "--all");
    let local_json = args::take_flag(&mut args, "--json") || ctx.json || ctx.envelope;
    args::reject_remaining(&args, "sessions list")?;

    let limit = if include_all {
        usize::MAX
    } else if let Some(raw) = limit_raw {
        raw.parse::<usize>()
            .ok()
            .filter(|v| *v > 0)
            .ok_or_else(|| CliError::usage("sessions list: --limit must be a positive integer"))?
    } else {
        100
    };
    let home = env::var("HOME").unwrap_or_else(|_| "/".into());
    let state_dir = expand_path(state_dir.as_deref().unwrap_or_else(|| {
        // Keep this as a leaked-free owned value by using the normal default
        // branch below.  The closure is only used for the common environment
        // override path.
        ""
    }));
    let state_dir = if state_dir == PathBuf::from(".") || state_dir.as_os_str().is_empty() {
        expand_path(
            env::var("CMUX_AGENT_HOOK_STATE_DIR")
                .ok()
                .as_deref()
                .unwrap_or(&format!("{home}/.cmuxterm")),
        )
    } else {
        state_dir
    };
    let codex_default = env::var("CODEX_HOME").unwrap_or_else(|_| format!("{home}/.codex"));
    let default_codex_home = expand_path(codex_home.as_deref().unwrap_or(&codex_default));
    let requested_agent = agent.as_deref().map(normalize);

    let mut stores = Vec::new();
    let mut entries = Vec::new();
    let names = discover_store_files(&state_dir)?;
    for (agent_name, path) in names {
        if let Some(wanted) = requested_agent.as_deref() {
            let canonical = canonical_agent(wanted);
            if canonical != agent_name {
                continue;
            }
        }
        let exists = path.is_file();
        let mut store_payload = json!({
            "agent": agent_name,
            "path": path.to_string_lossy(),
            "exists": exists,
            "session_count": 0,
        });
        if !exists {
            stores.push(store_payload);
            continue;
        }
        let value: Value = serde_json::from_slice(&fs::read(&path)?).map_err(|e| {
            CliError::new("session_store_invalid", format!("{}: {e}", path.display()))
        })?;
        let sessions = value
            .get("sessions")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        store_payload["session_count"] = json!(sessions.len());
        stores.push(store_payload);
        let active_ws = value
            .get("activeSessionsByWorkspace")
            .or_else(|| value.get("active_sessions_by_workspace"));
        let active_surface = value
            .get("activeSessionsBySurface")
            .or_else(|| value.get("active_sessions_by_surface"));
        for record in sessions.values() {
            let Some(object) = record.as_object() else {
                continue;
            };
            let raw_id = string(object, &["sessionId", "session_id"]);
            let session_id = raw_id.clone().unwrap_or_default();
            let workspace_id = string(object, &["workspaceId", "workspace_id"]).unwrap_or_default();
            let surface_id = string(object, &["surfaceId", "surface_id"]).unwrap_or_default();
            let saved_cwd = string(object, &["cwd"]);
            if let Some(wanted) = session.as_deref().map(normalize) {
                if normalize(&session_id) != wanted {
                    continue;
                }
            }
            if let Some(wanted) = workspace.as_deref().map(normalize_id) {
                if normalize_id(&workspace_id) != wanted {
                    continue;
                }
            }
            if let Some(wanted) = surface.as_deref().map(normalize_id) {
                if normalize_id(&surface_id) != wanted {
                    continue;
                }
            }
            if let Some(wanted) = cwd.as_deref().map(normalize) {
                let launch_cwd = object
                    .get("launchCommand")
                    .or_else(|| object.get("launch_command"))
                    .and_then(|v| {
                        v.get("workingDirectory")
                            .or_else(|| v.get("working_directory"))
                    })
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if !normalize(saved_cwd.as_deref().unwrap_or("")).contains(&wanted)
                    && !normalize(launch_cwd).contains(&wanted)
                {
                    continue;
                }
            }
            let updated = object
                .get("updatedAt")
                .or_else(|| object.get("updated_at"))
                .and_then(Value::as_f64)
                .unwrap_or(0.0);
            let started = object
                .get("startedAt")
                .or_else(|| object.get("started_at"))
                .and_then(Value::as_f64)
                .unwrap_or(0.0);
            let launch = object
                .get("launchCommand")
                .or_else(|| object.get("launch_command"));
            let launch_args = launch
                .and_then(|v| v.get("arguments"))
                .cloned()
                .unwrap_or_else(|| json!([]));
            let transcript = string(object, &["transcriptPath", "transcript_path"]);
            let transcript_backed = transcript
                .as_deref()
                .is_some_and(|p| expand_path(p).is_file());
            let restorable = object
                .get("isRestorable")
                .or_else(|| object.get("is_restorable"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let active_for_workspace = active_record_matches(active_ws, &workspace_id, &session_id);
            let active_for_surface =
                active_record_matches(active_surface, &surface_id, &session_id);
            let launch_backed = launch_args.as_array().is_some_and(|a| !a.is_empty());
            let visible = include_all
                || session.is_some()
                || workspace.is_some()
                || surface.is_some()
                || cwd.is_some()
                || restorable
                || transcript_backed
                || launch_backed
                || active_for_workspace
                || active_for_surface;
            if !visible {
                continue;
            }
            let mut payload = object.clone();
            payload.insert("agent".into(), json!(agent_name));
            payload.insert("store_path".into(), json!(path.to_string_lossy()));
            payload.insert("session_id".into(), json!(session_id));
            payload.insert("workspace_id".into(), json!(workspace_id));
            payload.insert("surface_id".into(), json!(surface_id));
            payload.insert("started_at_unix".into(), json!(started));
            payload.insert("updated_at_unix".into(), json!(updated));
            payload.insert("started_at".into(), json!(iso8601(started)));
            payload.insert("updated_at".into(), json!(iso8601(updated)));
            payload.insert("transcript_backed".into(), json!(transcript_backed));
            payload.insert("launch_backed".into(), json!(launch_backed));
            payload.insert("active_for_workspace".into(), json!(active_for_workspace));
            payload.insert("active_for_surface".into(), json!(active_for_surface));
            payload.insert("default_visible".into(), json!(visible));
            entries.push((updated, payload));
        }
    }
    entries.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                string(a.1, &["session_id"])
                    .cmp(&string(b.1, &["session_id"]))
            })
    });
    let total = entries.len();
    entries.truncate(limit);
    if local_json {
        let data = json!({
            "state_dir": state_dir,
            "default_codex_home": default_codex_home,
            "total_matches": total,
            "limit": if limit == usize::MAX { Value::Null } else { json!(limit) },
            "stores": stores,
            "sessions": entries.into_iter().map(|(_, v)| Value::Object(v)).collect::<Vec<_>>(),
        });
        ctx.emit(&data)?;
    } else if entries.is_empty() {
        ctx.print(format!(
            "No saved agent sessions matched.\nstate_dir={}",
            state_dir.display()
        ))?;
    } else {
        for (_, p) in &entries {
            ctx.print(render_line(p))?;
        }
        if total > entries.len() {
            ctx.print(format!(
                "... {} more. Pass --all or --limit <n>.",
                total - entries.len()
            ))?;
        }
    }
    Ok(())
}

fn continuation(ctx: &Context, raw: &[String], fork: bool) -> Result<()> {
    let selector = parse_selector(raw, fork)?;
    let surface_id = if let Some(s) = selector.surface.as_deref() {
        ctx.resolve_id("surface", Some(s))?
            .ok_or_else(|| surface_error(fork, "requested surface was not found"))?
    } else {
        ctx.resolve_id("surface", None)?
            .ok_or_else(|| surface_error(fork, "current cmux surface could not be identified"))?
    };
    let payload = ctx.rpc("surface.resume.get", json!({"surface_id": surface_id}))?;
    let raw_record = payload
        .get("restore_record")
        .ok_or_else(|| surface_error(fork, "this session has nothing to restore"))?;
    let record = raw_record
        .as_object()
        .ok_or_else(|| surface_error(fork, "saved restore data is not compatible"))?;
    let kind = string(record, &["kind"])
        .ok_or_else(|| surface_error(fork, "saved restore data is not compatible"))?;
    if let Some(expected) = selector.kind.as_deref() {
        if expected != kind {
            return Err(surface_error(
                fork,
                "this command no longer matches the session",
            ));
        }
    }
    let checkpoint = string(record, &["checkpoint_id", "checkpointID"]);
    if let Some(expected) = selector.checkpoint.as_deref() {
        if Some(expected) != checkpoint.as_deref() {
            return Err(surface_error(
                fork,
                "this command no longer matches the session",
            ));
        }
    }
    let mode = string(record, &["mode", "modeRawValue"]).unwrap_or_default();
    if fork && (mode == "direct" || mode == "relaunchAgent") {
        return Err(surface_error(
            true,
            "this session's saved fork data is not compatible",
        ));
    }
    let args = if fork {
        record
            .get("fork_arguments")
            .or_else(|| record.get("forkArguments"))
            .and_then(Value::as_array)
            .map(strings)
            .or_else(|| build_fork_argv(kind.as_str(), checkpoint.as_deref(), record))
    } else {
        record
            .get("prepared_arguments")
            .or_else(|| record.get("preparedArguments"))
            .and_then(Value::as_array)
            .map(strings)
            .or_else(|| launch_args(record))
    };
    let cwd =
        string(record, &["working_directory", "workingDirectory"]).or_else(|| launch_cwd(record));
    let mut environment: BTreeMap<String, String> = env::vars().collect();
    if let Some(saved) = record.get("environment").and_then(Value::as_object) {
        for (k, v) in saved {
            if let Some(v) = v.as_str() {
                environment.insert(k.clone(), v.into());
            }
        }
    }
    if let Some(launch) = record
        .get("launch_command")
        .or_else(|| record.get("launchCommand"))
    {
        if let Some(saved) = launch.get("environment").and_then(Value::as_object) {
            for (k, v) in saved {
                if let Some(v) = v.as_str() {
                    environment.insert(k.clone(), v.into());
                }
            }
        }
    }
    if let Some(argv) = args.filter(|v| !v.is_empty()) {
        let executable = argv[0].clone();
        let mut command = Command::new(resolve_executable(&executable, &environment["PATH"]));
        command
            .args(argv.iter().skip(1))
            .env_clear()
            .envs(&environment);
        if let Some(cwd) = cwd.as_deref().filter(|v| !v.trim().is_empty()) {
            if Path::new(cwd).is_dir() {
                command.current_dir(cwd);
            }
        }
        let err = command.exec();
        return Err(surface_error(
            fork,
            format!("saved process could not be started: {err}"),
        ));
    }
    if let Some(command_text) = legacy_command(record, fork) {
        let shell = environment
            .get("SHELL")
            .filter(|p| Path::new(p).is_file())
            .cloned()
            .unwrap_or_else(|| "/bin/sh".into());
        let mut command = Command::new(shell);
        command
            .args(["-lc", &command_text])
            .env_clear()
            .envs(&environment);
        if let Some(cwd) = cwd.as_deref().filter(|v| Path::new(v).is_dir()) {
            command.current_dir(cwd);
        }
        let err = command.exec();
        return Err(surface_error(
            fork,
            format!("saved process could not be started: {err}"),
        ));
    }
    Err(surface_error(
        fork,
        if fork {
            "this agent does not support forking"
        } else {
            "saved restore data is not compatible"
        },
    ))
}

#[derive(Debug)]
struct Selector {
    surface: Option<String>,
    kind: Option<String>,
    checkpoint: Option<String>,
}
fn parse_selector(raw: &[String], fork: bool) -> Result<Selector> {
    let mut args = raw.to_vec();
    let surface_count = args
        .iter()
        .filter(|v| *v == "--surface" || v.starts_with("--surface="))
        .count();
    if surface_count > 1 {
        return Err(surface_usage(fork));
    }
    let surface = args::take_option(&mut args, "--surface")?;
    if args.len() == 0 && surface.is_some() {
        return Ok(Selector {
            surface,
            kind: None,
            checkpoint: None,
        });
    }
    if args.len() != 2 || args.iter().any(|v| v.trim().is_empty()) {
        return Err(surface_usage(fork));
    }
    Ok(Selector {
        surface,
        kind: Some(args[0].clone()),
        checkpoint: Some(args[1].clone()),
    })
}
fn surface_usage(fork: bool) -> CliError {
    CliError::usage(if fork {
        "Usage: cmux fork [--surface <id|ref>] <kind> <checkpoint-id>"
    } else {
        "Usage: cmux restore [--surface <id|ref>] <kind> <checkpoint-id>"
    })
}
fn surface_error(fork: bool, message: impl Into<String>) -> CliError {
    CliError::new(
        if fork { "fork_error" } else { "restore_error" },
        format!(
            "{}: {}",
            if fork { "fork" } else { "restore" },
            message.into()
        ),
    )
}

#[derive(Clone, Copy)]
enum ManagedKind {
    ClaudeTeams,
    CodexTeams,
    Omo,
    Omx,
    Omc,
}
fn launch_managed(
    _ctx: &Context,
    executable: &str,
    raw: &[String],
    kind: ManagedKind,
) -> Result<()> {
    let mut envs: BTreeMap<String, String> = env::vars().collect();
    let path =
        find_executable(executable, envs.get("PATH").map(String::as_str)).ok_or_else(|| {
            CliError::new(
                "provider_missing",
                format!(
                    "{} was not found. Install it and make sure it can be run from your terminal.",
                    executable
                ),
            )
        })?;
    let mut argv = raw.to_vec();
    let launch_path = path.clone();
    match kind {
        ManagedKind::ClaudeTeams => {
            if !has_option(&argv, "--teammate-mode") {
                argv.splice(0..0, ["--teammate-mode".into(), "auto".into()]);
            }
            envs.insert("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS".into(), "1".into());
        }
        ManagedKind::CodexTeams => {
            envs.insert("CMUX_CODEX_TEAMS".into(), "1".into());
        }
        ManagedKind::Omo => {
            envs.insert("CMUX_OMO".into(), "1".into());
        }
        ManagedKind::Omx => {
            envs.insert("CMUX_OMX".into(), "1".into());
        }
        ManagedKind::Omc => {
            envs.insert("CMUX_OMC".into(), "1".into());
        }
    }
    let mut command = Command::new(launch_path);
    command.args(argv).env_clear().envs(envs);
    let err = command.exec();
    Err(CliError::new(
        "provider_exec_failed",
        format!("Failed to launch {executable}: {err}"),
    ))
}
fn has_option(args: &[String], name: &str) -> bool {
    args.iter()
        .any(|v| v == name || v.starts_with(&format!("{name}=")))
}

fn discover_store_files(dir: &Path) -> Result<Vec<(String, PathBuf)>> {
    let mut out = Vec::new();
    if !dir.is_dir() {
        return Ok(out);
    }
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.extension().and_then(|v| v.to_str()) != Some("json") {
            continue;
        }
        let Some(name) = path.file_name().and_then(|v| v.to_str()) else {
            continue;
        };
        let Some(agent) = name.strip_suffix("-hook-sessions.json") else {
            continue;
        };
        out.push((canonical_agent(agent), path));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}
fn canonical_agent(v: &str) -> String {
    match normalize(v).as_str() {
        "claude-code" | "claude_code" => "claude".into(),
        "agy" => "antigravity".into(),
        "rovo" => "rovodev".into(),
        x => x.into(),
    }
}
fn normalize(v: &str) -> String {
    v.trim().to_lowercase()
}
fn normalize_id(v: &str) -> String {
    normalize(v).rsplit('/').next().unwrap_or(v).to_string()
}
fn expand_path(v: &str) -> PathBuf {
    let v = v.trim();
    if v == "~" {
        return PathBuf::from(env::var("HOME").unwrap_or_else(|_| "/".into()));
    }
    if let Some(rest) = v.strip_prefix("~/") {
        return PathBuf::from(env::var("HOME").unwrap_or_else(|_| "/".into())).join(rest);
    }
    PathBuf::from(v)
}
fn string(obj: &Map<String, Value>, names: &[&str]) -> Option<String> {
    names
        .iter()
        .find_map(|k| obj.get(*k).and_then(Value::as_str).map(ToOwned::to_owned))
}
fn strings(v: &Vec<Value>) -> Vec<String> {
    v.iter()
        .filter_map(Value::as_str)
        .map(ToOwned::to_owned)
        .collect()
}
fn launch_args(obj: &Map<String, Value>) -> Option<Vec<String>> {
    obj.get("launch_command")
        .or_else(|| obj.get("launchCommand"))
        .and_then(|v| v.get("arguments"))
        .and_then(Value::as_array)
        .map(strings)
}
fn launch_cwd(obj: &Map<String, Value>) -> Option<String> {
    obj.get("launch_command")
        .or_else(|| obj.get("launchCommand"))
        .and_then(|v| string(v.as_object()?, &["working_directory", "workingDirectory"]))
}
fn legacy_command(obj: &Map<String, Value>, fork: bool) -> Option<String> {
    let names: &[&str] = if fork {
        &["fork_command", "legacy_fork_command", "legacyForkCommand"]
    } else {
        &["legacy_command", "legacyCommand"]
    };
    names.iter().find_map(|k| {
        if k.is_empty() {
            None
        } else {
            obj.get(*k)
                .and_then(Value::as_str)
                .filter(|v| !v.trim().is_empty())
                .map(ToOwned::to_owned)
        }
    })
}
fn build_fork_argv(kind: &str, id: Option<&str>, obj: &Map<String, Value>) -> Option<Vec<String>> {
    let id = id?;
    let launch = launch_args(obj)?;
    let exe = launch.first()?.clone();
    let preserved = preserved_launch_tail(&launch[1..]);
    match kind {
        "claude" => Some(
            [
                vec![exe, "--resume".into(), id.into(), "--fork-session".into()],
                preserved,
            ]
            .concat(),
        ),
        "codex" => Some([vec![exe, "fork".into(), id.into()], preserved].concat()),
        "opencode" => Some(
            [
                vec![exe, "--session".into(), id.into(), "--fork".into()],
                preserved,
            ]
            .concat(),
        ),
        "pi" | "omp" => Some([vec![exe, "--fork".into(), id.into()], preserved].concat()),
        _ => None,
    }
}

/// Remove identity-bearing continuation options from a captured launch. The
/// old `--resume <id>` pair must not be replayed after we substitute a new id.
fn preserved_launch_tail(args: &[String]) -> Vec<String> {
    let mut out = Vec::with_capacity(args.len());
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if arg == "--fork-session" {
            i += 1;
            continue;
        }
        if arg == "--resume" || arg == "-r" || arg == "--resume-id" {
            i += 1;
            if i < args.len() {
                i += 1;
            }
            continue;
        }
        if arg.starts_with("--resume=") || arg.starts_with("--resume-id=") {
            i += 1;
            continue;
        }
        out.push(arg.clone());
        i += 1;
    }
    out
}
fn resolve_executable(exe: &str, path: &str) -> String {
    if exe.contains('/') {
        exe.into()
    } else {
        find_executable(exe, Some(path)).unwrap_or_else(|| exe.into())
    }
}
fn find_executable(name: &str, search: Option<&str>) -> Option<String> {
    let entries = search.unwrap_or("").split(':').chain([
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]);
    entries
        .filter(|v| !v.is_empty())
        .map(|d| Path::new(d).join(name))
        .find(|p| p.is_file() && is_executable(p))
        .map(|p| p.to_string_lossy().into())
}
#[cfg(unix)]
fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(p)
        .map(|m| m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}
#[cfg(not(unix))]
fn is_executable(p: &Path) -> bool {
    p.is_file()
}
fn active_record_matches(value: Option<&Value>, owner: &str, session: &str) -> bool {
    value
        .and_then(Value::as_object)
        .and_then(|m| m.get(owner))
        .and_then(Value::as_object)
        .and_then(|m| string(m, &["sessionId", "session_id"]))
        .is_some_and(|v| v == session)
}
fn iso8601(seconds: f64) -> String {
    if seconds <= 0.0 {
        return "".into();
    }
    // Howard Hinnant's civil-from-days conversion, kept inline to avoid
    // pulling a date crate into the embedded CLI. Swift uses fractional
    // ISO-8601 output, so retain milliseconds here.
    let millis = (seconds * 1000.0).round() as i64;
    let whole = millis.div_euclid(1000);
    let ms = millis.rem_euclid(1000);
    let days = whole.div_euclid(86_400);
    let day_seconds = whole.rem_euclid(86_400);
    let z = days + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }).div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe.div_euclid(1_460) + doe.div_euclid(36_524) - doe.div_euclid(146_096)).div_euclid(365);
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe.div_euclid(4) - yoe.div_euclid(100));
    let mp = (5 * doy + 2).div_euclid(153);
    let d = doy - (153 * mp + 2).div_euclid(5) + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    let hour = day_seconds.div_euclid(3_600);
    let minute = day_seconds.rem_euclid(3_600).div_euclid(60);
    let second = day_seconds.rem_euclid(60);
    format!("{year:04}-{m:02}-{d:02}T{hour:02}:{minute:02}:{second:02}.{ms:03}Z")
}
fn render_line(v: &Map<String, Value>) -> String {
    let agent = string(v, &["agent"]).unwrap_or_else(|| "unknown".into());
    let id = string(v, &["session_id", "sessionId"]).unwrap_or_else(|| "unknown".into());
    let ws = string(v, &["workspace_id", "workspaceId"]).unwrap_or_else(|| "-".into());
    let surface = string(v, &["surface_id", "surfaceId"]).unwrap_or_else(|| "-".into());
    let cwd = string(v, &["cwd"]).unwrap_or_else(|| "-".into());
    let updated = string(v, &["updated_at"]).unwrap_or_else(|| "-".into());
    format!("{agent} {id}  workspace={ws}  surface={surface}  cwd={cwd}  active_ws={}  active_surface={}  updated={updated}", if v.get("active_for_workspace").and_then(Value::as_bool)==Some(true){"yes"}else{"no"}, if v.get("active_for_surface").and_then(Value::as_bool)==Some(true){"yes"}else{"no"})
}
fn sessions_usage() -> &'static str {
    "Usage: cmux sessions list [options]\n\nPrint saved agent session records from ~/.cmuxterm/*-hook-sessions.json.\nOptions: --agent --session --workspace --surface --cwd --state-dir --codex-home --limit --all --json"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selector_accepts_surface_after_positionals() {
        let parsed = parse_selector(
            &[
                "claude".into(),
                "sid".into(),
                "--surface".into(),
                "surface:1".into(),
            ],
            false,
        )
        .unwrap();
        assert_eq!(parsed.kind.as_deref(), Some("claude"));
        assert_eq!(parsed.checkpoint.as_deref(), Some("sid"));
        assert_eq!(parsed.surface.as_deref(), Some("surface:1"));
    }

    #[test]
    fn selector_surface_only_uses_current_target() {
        let parsed = parse_selector(&["--surface".into()], true).unwrap();
        assert!(parsed.kind.is_none());
        assert!(parsed.checkpoint.is_none());
        assert!(parsed.surface.is_none());
    }

    #[test]
    fn fork_argv_preserves_launch_tail() {
        let record = serde_json::from_value::<Value>(json!({
            "launch_command": {"arguments": ["claude", "--model", "sonnet", "--resume", "old"]}
        }))
        .unwrap();
        let argv = build_fork_argv("claude", Some("new"), record.as_object().unwrap()).unwrap();
        assert_eq!(
            argv,
            vec![
                "claude",
                "--resume",
                "new",
                "--fork-session",
                "--model",
                "sonnet"
            ]
        );
    }

    #[test]
    fn legacy_command_only_records_are_supported() {
        let object = serde_json::Map::from_iter([(
            String::from("legacy_command"),
            json!("exec agent --resume sid"),
        )]);
        assert_eq!(
            legacy_command(&object, false).as_deref(),
            Some("exec agent --resume sid")
        );
        assert!(legacy_command(&object, true).is_none());
    }
}
