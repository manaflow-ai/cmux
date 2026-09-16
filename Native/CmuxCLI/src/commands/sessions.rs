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
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

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
            let captured_args = launch
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
            let launch_backed = captured_args.as_array().is_some_and(|a| !a.is_empty());
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
            payload.insert(
                "agent_display_name".into(),
                json!(display_agent_name(&agent_name)),
            );
            payload.insert(
                "launch_arguments".into(),
                crate::commands::sessions::launch_args(object)
                    .map_or_else(|| json!([]), |v| json!(v)),
            );
            payload.insert(
                "transcript_path".into(),
                transcript.clone().map_or(Value::Null, Value::String),
            );
            payload.insert(
                "pid".into(),
                object.get("pid").cloned().unwrap_or(Value::Null),
            );
            payload.insert(
                "is_restorable".into(),
                object
                    .get("isRestorable")
                    .or_else(|| object.get("is_restorable"))
                    .cloned()
                    .unwrap_or(Value::Null),
            );
            let fork_available = launch_backed
                || object
                    .get("fork_command")
                    .or_else(|| object.get("legacy_fork_command"))
                    .and_then(Value::as_str)
                    .is_some_and(|v| !v.trim().is_empty());
            payload.insert("fork_command_available".into(), json!(fork_available));
            payload.insert(
                "fork_supported".into(),
                json!(
                    fork_available
                        && matches!(
                            agent_name.as_str(),
                            "claude" | "codex" | "opencode" | "pi" | "omp"
                        )
                ),
            );
            if agent_name == "codex" {
                let indexed = default_codex_home.join("session_index.jsonl");
                let found = fs::read_to_string(indexed).ok().is_some_and(|body| {
                    body.lines()
                        .any(|line| line.contains(&format!("\"id\":\"{session_id}\"")))
                });
                payload.insert("session_home".into(), json!(default_codex_home));
                payload.insert(
                    "session_dir".into(),
                    json!(default_codex_home.join("sessions")),
                );
                payload.insert("codex_indexed".into(), json!(found));
                payload.insert("codex_transcript_found".into(), json!(transcript_backed));
                payload.insert(
                    "codex_transcript_path".into(),
                    transcript.clone().map_or(Value::Null, Value::String),
                );
            }
            payload.insert("default_visible".into(), json!(visible));
            entries.push((updated, payload));
        }
    }
    entries.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| string(&a.1, &["session_id"]).cmp(&string(&b.1, &["session_id"])))
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
    if ctx.dry_run {
        let argv = if fork {
            record
                .get("fork_arguments")
                .or_else(|| record.get("forkArguments"))
                .and_then(Value::as_array)
                .map(strings)
                .or_else(|| build_fork_argv(&kind, checkpoint.as_deref(), record))
        } else {
            build_restore_argv(&mode, &kind, checkpoint.as_deref(), record)
        };
        ctx.emit(&json!({
            "dry_run": true,
            "command": if fork { "fork" } else { "restore" },
            "surface_id": surface_id,
            "kind": kind,
            "checkpoint_id": checkpoint,
            "arguments": argv,
            "working_directory": string(record, &["working_directory", "workingDirectory"]).or_else(|| launch_cwd(record)),
        }))?;
        return Ok(());
    }
    let admission = if !fork
        && (mode == "resumeAgent" || mode == "relaunchAgent")
        && payload
            .get("agent_restore_admission_supported")
            .and_then(Value::as_bool)
            == Some(true)
    {
        let session_id = checkpoint
            .as_deref()
            .ok_or_else(|| surface_error(fork, "session identity is missing"))?;
        let workspace_id = payload
            .get("workspace_id")
            .and_then(Value::as_str)
            .ok_or_else(|| surface_error(fork, "workspace identity is missing"))?;
        let response = ctx.rpc(
            "agent.restore.admit",
            json!({
                "workspace_id": workspace_id,
                "surface_id": surface_id,
                "kind": kind,
                "session_id": session_id,
                "record_session_id": session_id,
            }),
        )?;
        if response.get("admitted").and_then(Value::as_bool) != Some(true) {
            return Err(surface_error(
                fork,
                "this agent session is already running or another launch is starting",
            ));
        }
        Some(json!({
            "workspace_id": workspace_id,
            "surface_id": surface_id,
            "kind": kind,
            "session_id": session_id,
            "claim_id": response.get("claim_id").cloned().unwrap_or(Value::Null),
        }))
    } else {
        None
    };
    if mode == "resumeAgent"
        && kind == "codex"
        && string(record, &["source"]).as_deref() == Some("agent-hook")
    {
        let binding = payload
            .get("resume_binding")
            .and_then(Value::as_object)
            .ok_or_else(|| surface_error(fork, "current resume binding is missing"))?;
        let bound_checkpoint = string(binding, &["checkpoint_id", "checkpointId"]);
        if bound_checkpoint.as_deref() != checkpoint.as_deref() {
            release_admission(ctx, admission.as_ref());
            return Err(surface_error(
                fork,
                "this command no longer matches the session",
            ));
        }
        if let Err(error) = verify_codex_owner(record, checkpoint.as_deref().unwrap_or("")) {
            release_admission(ctx, admission.as_ref());
            return Err(error);
        }
        let response = ctx.rpc(
            "surface.resume.get",
            json!({
                "surface_id": surface_id,
                "claim_checkpoint_id": checkpoint,
                "claim_source": binding.get("source").cloned().unwrap_or(Value::Null),
                "claim_updated_at": binding.get("updated_at").cloned().unwrap_or(Value::Null),
            }),
        )?;
        if response.get("resume_claimed").and_then(Value::as_bool) != Some(true) {
            release_admission(ctx, admission.as_ref());
            return Err(surface_error(
                fork,
                "this command no longer matches the session",
            ));
        }
    }
    let args = if fork {
        record
            .get("fork_arguments")
            .or_else(|| record.get("forkArguments"))
            .and_then(Value::as_array)
            .map(strings)
            .or_else(|| build_fork_argv(kind.as_str(), checkpoint.as_deref(), record))
    } else {
        build_restore_argv(&mode, &kind, checkpoint.as_deref(), record)
    };
    let cwd =
        string(record, &["working_directory", "workingDirectory"]).or_else(|| launch_cwd(record));
    let mut environment: BTreeMap<String, String> = env::vars().collect();
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
    if let Some(saved) = record.get("environment").and_then(Value::as_object) {
        for (k, v) in saved {
            if let Some(v) = v.as_str() {
                environment.insert(k.clone(), v.into());
            }
        }
    }
    if let Some(argv) = args.filter(|v| !v.is_empty()) {
        let executable = argv[0].clone();
        let mut command = Command::new(resolve_executable(
            &executable,
            environment.get("PATH").map(String::as_str).unwrap_or(""),
        ));
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
        release_admission(ctx, admission.as_ref());
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
        release_admission(ctx, admission.as_ref());
        return Err(surface_error(
            fork,
            format!("saved process could not be started: {err}"),
        ));
    }
    release_admission(ctx, admission.as_ref());
    Err(surface_error(
        fork,
        if fork {
            "this agent does not support forking"
        } else {
            "saved restore data is not compatible"
        },
    ))
}
fn release_admission(ctx: &Context, claim: Option<&Value>) {
    if let Some(claim) = claim {
        let _ = ctx.rpc("agent.restore.release", claim.clone());
    }
}

fn verify_codex_owner(record: &Map<String, Value>, session_id: &str) -> Result<()> {
    let captured = record
        .get("launch_command")
        .or_else(|| record.get("launchCommand"));
    let home = record
        .get("environment")
        .and_then(|v| v.get("CODEX_HOME"))
        .and_then(Value::as_str)
        .or_else(|| {
            captured
                .and_then(|v| v.get("environment"))
                .and_then(|v| v.get("CODEX_HOME"))
                .and_then(Value::as_str)
        })
        .map(str::to_owned)
        .or_else(|| env::var("CODEX_HOME").ok())
        .unwrap_or_else(|| format!("{}/.codex", env::var("HOME").unwrap_or_default()));
    let mut home = expand_path(&home);
    if home.is_relative() {
        if let Some(cwd) = launch_cwd(record)
            .or_else(|| string(record, &["working_directory", "workingDirectory"]))
        {
            home = Path::new(&cwd).join(home);
        }
    }
    let database = home.join("state_5.sqlite");
    let mut indexed_source = Value::Null;
    let indexed_path = if database.is_file() {
        let safe_id = session_id.replace('\'', "''");
        let mut decoded = None;
        for columns in [
            "rollout_path, source, thread_source",
            "rollout_path, source",
            "rollout_path",
        ] {
            let output = Command::new("/usr/bin/sqlite3")
                .args(["-readonly", "-json", "-cmd", ".timeout 500"])
                .arg(&database)
                .arg(format!(
                    "SELECT {columns} FROM threads WHERE id = '{safe_id}' LIMIT 1;"
                ))
                .output()
                .map_err(|_| {
                    CliError::new(
                        "codex_checkpoint_unavailable",
                        "restore: the saved Codex session could not be verified",
                    )
                })?;
            if output.status.success() {
                decoded = Some(if output.stdout.is_empty() {
                    json!([])
                } else {
                    serde_json::from_slice(&output.stdout)?
                });
                break;
            }
        }
        let rows = decoded.ok_or_else(|| {
            CliError::new(
                "codex_checkpoint_unavailable",
                "restore: the saved Codex session could not be verified",
            )
        })?;
        if let Some(row) = rows.as_array().and_then(|v| v.first()) {
            indexed_source = json!([row.get("source"), row.get("thread_source")]);
            Some(
                row.get("rollout_path")
                    .and_then(Value::as_str)
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| {
                        CliError::new(
                            "codex_checkpoint_unavailable",
                            "restore: the saved Codex session has no rollout",
                        )
                    })?
                    .to_owned(),
            )
        } else {
            None
        }
    } else {
        None
    };
    let paths = if let Some(path) = indexed_path {
        let path = PathBuf::from(path);
        vec![if path.is_absolute() {
            path
        } else {
            home.join(path)
        }]
    } else {
        let mut candidates = Vec::new();
        let mut remaining = 8192;
        collect_rollouts(
            &home.join("sessions"),
            session_id,
            &mut remaining,
            &mut candidates,
        );
        candidates
    };
    for path in paths {
        use std::io::{BufRead, BufReader, Read};
        let Ok(file) = fs::File::open(&path) else {
            continue;
        };
        let reader = BufReader::new(file.take(4 * 1024 * 1024));
        for line in reader.lines().take(2048) {
            let Ok(line) = line else {
                break;
            };
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if value.get("type").and_then(Value::as_str) != Some("session_meta") {
                continue;
            }
            let payload = &value["payload"];
            if payload.get("id").and_then(Value::as_str) != Some(session_id) {
                break;
            }
            let source = json!([payload.get("source"), indexed_source]);
            let origin = payload
                .get("originator")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let thread_source = payload
                .get("thread_source")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            if source_marker(&source, "exec")
                || source_marker(&source, "review")
                || source_marker(&source, "automation")
                || source_marker(&source, "subagent")
                || origin.contains("codex_exec")
                || origin.contains("review")
                || thread_source == "subagent"
            {
                return Err(CliError::new(
                    "codex_checkpoint_rejected",
                    "restore: a child or automation session cannot own this terminal",
                ));
            }
            if ["cli", "tui", "vscode"]
                .iter()
                .any(|m| source_marker(&source, m))
            {
                return Ok(());
            }
            return Err(CliError::new(
                "codex_checkpoint_rejected",
                "restore: the saved Codex session's ownership could not be verified",
            ));
        }
    }
    Err(CliError::new("codex_checkpoint_unavailable", "restore: the saved Codex session is unavailable. Retry later or start a new agent session."))
}

fn source_marker(source: &Value, marker: &str) -> bool {
    match source {
        Value::String(s) => {
            s.eq_ignore_ascii_case(marker)
                || serde_json::from_str::<Value>(s)
                    .ok()
                    .filter(|v| !v.is_string())
                    .is_some_and(|v| source_marker(&v, marker))
        }
        Value::Array(a) => a.iter().any(|v| source_marker(v, marker)),
        Value::Object(o) => o
            .iter()
            .any(|(k, v)| k.eq_ignore_ascii_case(marker) || source_marker(v, marker)),
        _ => false,
    }
}

fn collect_rollouts(
    root: &Path,
    session_id: &str,
    remaining: &mut usize,
    matches: &mut Vec<PathBuf>,
) {
    if *remaining == 0 || matches.len() >= 32 {
        return;
    }
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        if *remaining == 0 || matches.len() >= 32 {
            return;
        }
        *remaining -= 1;
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            collect_rollouts(&entry.path(), session_id, remaining, matches);
        } else if file_type.is_file()
            && entry.file_name().to_string_lossy().contains(session_id)
            && entry.path().extension().is_some_and(|v| v == "jsonl")
        {
            matches.push(entry.path());
        }
    }
}

#[derive(Debug)]
struct Selector {
    surface: Option<String>,
    kind: Option<String>,
    checkpoint: Option<String>,
}
fn parse_selector(raw: &[String], fork: bool) -> Result<Selector> {
    if raw == ["--surface"] {
        return Ok(Selector {
            surface: None,
            kind: None,
            checkpoint: None,
        });
    }
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
    ctx: &Context,
    executable: &str,
    raw: &[String],
    kind: ManagedKind,
) -> Result<()> {
    let informational = if matches!(kind, ManagedKind::ClaudeTeams) {
        ["--help", "-h", "--version", "-v"]
            .iter()
            .any(|option| claude_has_real_option(raw, option))
    } else {
        raw.first().is_some_and(|v| v == "help")
            || raw
                .iter()
                .take_while(|v| v.as_str() != "--")
                .any(|v| matches!(v.as_str(), "--help" | "-h" | "--version" | "-V"))
    };
    if !informational
        && ctx.socket.is_none()
        && env::var("CMUX_SOCKET_PATH")
            .ok()
            .filter(|v| !v.is_empty())
            .is_none()
        && env::var("CMUX_SOCKET")
            .ok()
            .filter(|v| !v.is_empty())
            .is_none()
    {
        return Err(CliError::new(
            "managed_terminal_required",
            format!(
                "{} must be launched from a cmux-managed terminal surface",
                executable
            ),
        ));
    }
    let mut envs: BTreeMap<String, String> = env::vars().collect();
    if let Some(socket) = ctx.socket.as_deref() {
        envs.insert("CMUX_SOCKET_PATH".into(), socket.into());
        envs.remove("CMUX_SOCKET");
    }
    if let Some(password) = ctx.password.as_deref().filter(|v| !v.trim().is_empty()) {
        envs.insert("CMUX_SOCKET_PASSWORD".into(), password.into());
    }
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
    if ctx.dry_run {
        ctx.emit(&json!({"dry_run": true, "executable": launch_path, "arguments": argv}))?;
        return Ok(());
    }
    let mut shim_root = None;
    match kind {
        ManagedKind::ClaudeTeams => {
            if !has_option(&argv, "--teammate-mode") {
                argv.splice(0..0, ["--teammate-mode".into(), "auto".into()]);
            }
            envs.insert("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS".into(), "1".into());
            envs.remove("CLAUDE_CODE_SANDBOXED");
            envs.remove("CMUX_CLAUDE_TEAMS_SANDBOXED");
            if claude_has_real_option(raw, "--dangerously-skip-permissions") {
                envs.insert("CLAUDE_CODE_SANDBOXED".into(), "1".into());
                envs.insert("CMUX_CLAUDE_TEAMS_SANDBOXED".into(), "1".into());
            }
        }
        ManagedKind::CodexTeams => {
            envs.insert("CMUX_CODEX_TEAMS".into(), "1".into());
        }
        ManagedKind::Omo => {
            envs.insert("CMUX_OMO".into(), "1".into());
            shim_root = Some(write_managed_shims("omo")?);
        }
        ManagedKind::Omx => {
            envs.insert("CMUX_OMX".into(), "1".into());
            shim_root = Some(write_managed_shims("omx")?);
        }
        ManagedKind::Omc => {
            envs.insert("CMUX_OMC".into(), "1".into());
            shim_root = Some(write_managed_shims("omc")?);
        }
    }
    if let Some(root) = shim_root {
        let old_path = envs.get("PATH").cloned().unwrap_or_default();
        envs.insert(
            "CMUX_AGENT_COMMAND_SHIM_ROOT".into(),
            root.display().to_string(),
        );
        envs.insert(
            "CMUX_OMO_CMUX_BIN".into(),
            env::args().next().unwrap_or_else(|| "cmux".into()),
        );
        envs.insert("PATH".into(), format!("{}:{old_path}", root.display()));
    }
    if matches!(kind, ManagedKind::CodexTeams) && !informational {
        return launch_codex_teams(&launch_path, &argv, &mut envs);
    }
    let mut command = Command::new(launch_path);
    command.args(argv).env_clear().envs(envs);
    let err = command.exec();
    Err(CliError::new(
        "provider_exec_failed",
        format!("Failed to launch {executable}: {err}"),
    ))
}

/// Start Codex's localhost app-server and run the root TUI against it. The
/// Swift implementation also runs a websocket watcher that mirrors spawned
/// threads into cmux panes. Keeping the server/root lifecycle here preserves
/// resume/fork routing and guarantees the server is reaped when the root exits;
/// the watcher remains an explicit follow-up migration.
fn launch_codex_teams(
    executable: &str,
    args: &[String],
    environment: &mut BTreeMap<String, String>,
) -> Result<()> {
    use std::net::TcpListener;
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(|e| {
        CliError::new(
            "codex_teams_port",
            format!("Failed to allocate a localhost port: {e}"),
        )
    })?;
    let port = listener
        .local_addr()
        .map_err(|e| CliError::new("codex_teams_port", e.to_string()))?
        .port();
    drop(listener);
    let url = format!("ws://127.0.0.1:{port}");
    let mut server = Command::new(executable);
    server
        .args(["app-server", "--listen", &url])
        .env_clear()
        .envs(environment.iter())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut server = server.spawn().map_err(|e| {
        CliError::new(
            "codex_teams_server",
            format!("Failed to start Codex app-server: {e}"),
        )
    })?;
    thread::sleep(Duration::from_millis(100));
    environment.insert("CMUX_CODEX_TEAMS_APP_SERVER_URL".into(), url.clone());
    environment.insert("CMUX_CODEX_TEAMS_MAX_AUTO_DEPTH".into(), "2".into());
    environment.insert("CMUX_AGENT_LAUNCH_KIND".into(), "codexTeams".into());
    environment.insert("CMUX_AGENT_LAUNCH_EXECUTABLE".into(), executable.into());
    let mut root_args = Vec::with_capacity(args.len() + 2);
    if matches!(args.first().map(String::as_str), Some("resume" | "fork")) {
        root_args.push(args[0].clone());
        root_args.push("--remote".into());
        root_args.push(url);
        root_args.extend_from_slice(&args[1..]);
    } else {
        root_args.extend(["--remote".into(), url]);
        root_args.extend_from_slice(args);
    }
    let status = Command::new(executable)
        .args(root_args)
        .env_clear()
        .envs(environment.iter())
        .status()
        .map_err(|e| CliError::new("codex_teams_exec", format!("Failed to launch codex: {e}")))?;
    let _ = server.kill();
    let _ = server.wait();
    if status.success() {
        Ok(())
    } else {
        Err(
            CliError::new("codex_teams_exit", "Codex exited with a non-zero status")
                .exit(status.code().unwrap_or(1)),
        )
    }
}

/// Create provider shims that delegate layout work to the canonical
/// `cmux __tmux-compat` command.
fn write_managed_shims(name: &str) -> Result<PathBuf> {
    let root = env::temp_dir().join(format!("cmux-cli-shims-{}-{}", name, std::process::id()));
    fs::create_dir_all(&root)?;
    let cmux = env::args().next().unwrap_or_else(|| "cmux".into());
    let tmux = format!(
        "#!/bin/sh\ncase \"${{1:-}}\" in -V|-v) echo 'tmux 3.4'; exit 0;; esac\nexec {} __tmux-compat \"$@\"\n",
        shell_quote(&cmux)
    );
    write_executable(&root.join("tmux"), &tmux)?;
    if name == "omo" {
        let notifier = format!(
            "#!/bin/sh\ntitle='' body=''\nwhile [ $# -gt 0 ]; do case \"$1\" in -title) title=\"$2\"; shift 2;; -message) body=\"$2\"; shift 2;; *) shift;; esac; done\nexec {} notify --title \"${{title:-OpenCode}}\" --body \"${{body:-}}\"\n",
            shell_quote(&cmux)
        );
        write_executable(&root.join("terminal-notifier"), &notifier)?;
    }
    Ok(root)
}

fn write_executable(path: &Path, content: &str) -> Result<()> {
    fs::write(path, content)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(path)?.permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn has_option(args: &[String], name: &str) -> bool {
    args.iter()
        .any(|v| v == name || v.starts_with(&format!("{name}=")))
}

/// Claude accepts a prompt at several boundaries. Only an option token counts
/// as a permission opt-in; prompt text or another option's value never does.
fn claude_has_real_option(args: &[String], target: &str) -> bool {
    let value_options = [
        "--model",
        "--fallback-model",
        "--effort",
        "--permission-mode",
        "--settings",
        "--system-prompt",
        "--append-system-prompt",
        "--system-prompt-file",
        "--append-system-prompt-file",
        "--resume",
        "-r",
        "--session-id",
        "--agent",
        "--agents",
        "--teammate-mode",
        "--allowedTools",
        "--disallowedTools",
        "--tools",
        "--mcp-config",
        "--output-format",
        "--input-format",
        "--max-turns",
        "--max-budget-usd",
    ];
    let mut i = 0;
    while i < args.len() {
        let argument = args[i].as_str();
        if argument == "--" || argument == "--tmux" || argument.starts_with("--tmux=") {
            return false;
        }
        if argument == target
            || argument
                .strip_prefix(target)
                .is_some_and(|tail| tail.starts_with('='))
        {
            return true;
        }
        if value_options.contains(&argument) {
            i += 2;
        } else {
            i += 1;
        }
    }
    false
}

fn discover_store_files(dir: &Path) -> Result<Vec<(String, PathBuf)>> {
    let known = [
        "claude",
        "codex",
        "grok",
        "opencode",
        "pi",
        "omp",
        "campfire",
        "amp",
        "cursor",
        "gemini",
        "kiro",
        "antigravity",
        "rovodev",
        "hermes-agent",
        "copilot",
        "codebuddy",
        "factory",
        "qoder",
        "kimi",
    ];
    let mut out: Vec<(String, PathBuf)> = known
        .iter()
        .map(|agent| {
            (
                (*agent).into(),
                dir.join(format!("{agent}-hook-sessions.json")),
            )
        })
        .collect();
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
        let canonical = canonical_agent(agent);
        if !out.iter().any(|(known, _)| known == &canonical) {
            out.push((canonical, path));
        }
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
fn display_agent_name(agent: &str) -> &'static str {
    match agent {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "opencode" => "OpenCode",
        "hermes-agent" => "Hermes Agent",
        "rovodev" => "Rovo Dev",
        "antigravity" => "Antigravity",
        _ => "Agent",
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

fn build_restore_argv(
    mode: &str,
    kind: &str,
    id: Option<&str>,
    object: &Map<String, Value>,
) -> Option<Vec<String>> {
    let prepared = object
        .get("prepared_arguments")
        .or_else(|| object.get("preparedArguments"))
        .and_then(Value::as_array)
        .map(strings)
        .filter(|v| !v.is_empty());
    let captured = launch_args(object).filter(|v| !v.is_empty());
    if mode == "direct" || mode == "relaunchAgent" {
        return prepared.or(captured);
    }
    if mode == "forkAgent" {
        return prepared.or_else(|| build_fork_argv(kind, id, object));
    }
    if mode != "resumeAgent" {
        return None;
    }
    let id = id?;
    let launch = captured.unwrap_or_default();
    let fallback = match kind {
        "factory" => "droid",
        "qoder" => "qodercli",
        "cursor" => "cursor-agent",
        "hermes-agent" => "hermes",
        "kiro" => "kiro-cli",
        "rovodev" => "acli",
        _ => kind,
    };
    let executable = launch.first().cloned().unwrap_or_else(|| fallback.into());
    let mut tail = if launch.len() > 1 {
        preserved_launch_tail(&launch[1..])
    } else {
        vec![]
    };
    let launch_object = object
        .get("launch_command")
        .or_else(|| object.get("launchCommand"));
    let launcher = launch_object
        .and_then(|v| v.get("launcher"))
        .and_then(Value::as_str);
    if let Some(wrapper) = launcher {
        let subcommand = match wrapper {
            "claudeTeams" => Some("claude-teams"),
            "codexTeams" => Some("codex-teams"),
            "omo" => Some("omo"),
            "omx" => Some("omx"),
            "omc" => Some("omc"),
            _ => None,
        };
        if let Some(subcommand) = subcommand {
            if tail.first().is_some_and(|v| v == subcommand) {
                tail.remove(0);
            }
            let mut result = vec![executable, subcommand.into()];
            match wrapper {
                "claudeTeams" => result.extend(["--resume".into(), id.into()]),
                "codexTeams" => result.extend(["resume".into(), id.into()]),
                "omo" => result.extend(["--session".into(), id.into()]),
                _ => return prepared,
            }
            result.extend(tail);
            return Some(result);
        }
    }
    let prefix = match kind {
        "claude" => vec!["claude".into(), "--resume".into(), id.into()],
        "codex" => vec![executable, "resume".into(), id.into()],
        "opencode" => vec![executable, "--session".into(), id.into()],
        "amp" => vec![executable, "threads".into(), "continue".into(), id.into()],
        "kiro" => vec![executable, "chat".into(), "--resume-id".into(), id.into()],
        "rovodev" => vec![
            executable,
            "rovodev".into(),
            "run".into(),
            "--restore".into(),
            id.into(),
        ],
        "pi" | "omp" | "campfire" => vec![executable, "--session".into(), id.into()],
        "grok" | "cursor" | "gemini" | "hermes-agent" | "copilot" | "codebuddy" | "factory"
        | "qoder" | "kimi" => vec![executable, "--resume".into(), id.into()],
        _ => return prepared,
    };
    Some([prefix, tail].concat())
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
    let mut directories = search
        .unwrap_or("")
        .split(':')
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if let Ok(home) = env::var("HOME") {
        for suffix in [
            ".local/bin",
            ".bun/bin",
            ".nvm/current/bin",
            ".volta/bin",
            ".fnm/current/bin",
            ".local/share/mise/shims",
            ".asdf/shims",
            "bin",
        ] {
            directories.push(format!("{home}/{suffix}"));
        }
    }
    directories.extend(
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .iter()
            .map(|v| v.to_string()),
    );
    let entries = directories.iter().map(String::as_str);
    entries
        .filter(|v| !v.is_empty())
        .map(|d| Path::new(d).join(name))
        .find(|p| p.is_file() && is_executable(p) && !is_managed_provider_shim(p))
        .map(|p| p.to_string_lossy().into())
}
fn is_managed_provider_shim(path: &Path) -> bool {
    let text = path.to_string_lossy();
    if text.contains(".app/Contents/Resources/bin/")
        || text.contains("/cmux-cli-shims/")
        || text.contains("/cmux-cli-shims-")
    {
        return true;
    }
    if let Ok(mut file) = fs::File::open(path) {
        use std::io::Read;
        let mut prefix = [0u8; 512];
        if let Ok(size) = file.read(&mut prefix) {
            return String::from_utf8_lossy(&prefix[..size])
                .contains("cmux claude wrapper - injects hooks and session tracking");
        }
    }
    false
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
    let yoe = (doe - doe.div_euclid(1_460) + doe.div_euclid(36_524) - doe.div_euclid(146_096))
        .div_euclid(365);
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
    format!(
        "{agent} {id}  workspace={ws}  surface={surface}  cwd={cwd}  active_ws={}  active_surface={}  updated={updated}",
        if v.get("active_for_workspace").and_then(Value::as_bool) == Some(true) {
            "yes"
        } else {
            "no"
        },
        if v.get("active_for_surface").and_then(Value::as_bool) == Some(true) {
            "yes"
        } else {
            "no"
        }
    )
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

    #[test]
    fn iso8601_matches_swift_shape() {
        assert_eq!(iso8601(0.0), "");
        assert_eq!(iso8601(1_700_000_000.123), "2023-11-14T22:13:20.123Z");
    }

    #[test]
    fn continuation_identity_options_are_removed_as_pairs() {
        let tail = preserved_launch_tail(&[
            "--model".into(),
            "sonnet".into(),
            "--resume".into(),
            "old".into(),
            "--fork-session".into(),
            "--verbose".into(),
        ]);
        assert_eq!(tail, vec!["--model", "sonnet", "--verbose"]);
    }

    #[test]
    fn dangerous_permission_opt_in_is_not_prompt_or_option_value() {
        let target = "--dangerously-skip-permissions";
        assert!(claude_has_real_option(
            &[target.into(), "--version".into()],
            target
        ));
        assert!(!claude_has_real_option(
            &["--".into(), target.into()],
            target
        ));
        assert!(!claude_has_real_option(
            &["--model".into(), target.into()],
            target
        ));
        assert!(!claude_has_real_option(
            &["--tmux".into(), target.into()],
            target
        ));
    }
}
