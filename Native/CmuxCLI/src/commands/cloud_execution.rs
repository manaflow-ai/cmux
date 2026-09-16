//! Cloud execution and file/environment transfer commands.
//!
//! This module deliberately contains only the command-to-RPC translation.  The
//! app remains the authority for machine credentials and the private link; the
//! Rust CLI never invents a backend method and never puts a secret in a shell
//! command.  Keeping the transport here small also lets `cmux vm exec` and
//! `cmux vm wait` behave identically when invoked from scripts and agents.

use crate::{CliError, Context, Result};
use base64::Engine;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const DEFAULT_EXEC_TIMEOUT: u64 = 100;
const DEFAULT_WAIT_TIMEOUT: u64 = 180;
const MAX_TRANSFER_BYTES: u64 = 256 * 1024 * 1024;
const SECRET_TRANSFER_BYTES: u64 = 256 * 1024;
const CHUNK_BYTES: usize = 512 * 1024;

pub fn run(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>> {
    let mut argv = args.to_vec();
    let verb = if command == "vm" {
        argv.first().cloned().unwrap_or_default()
    } else if let Some(rest) = command.strip_prefix("vm ") {
        // A dispatcher may pass `vm exec` as the command and the tail as args.
        let words: Vec<String> = rest.split_whitespace().map(str::to_owned).collect();
        argv.splice(0..0, words.clone());
        words.first().cloned().unwrap_or_default()
    } else {
        command.to_owned()
    };
    let verb = verb.as_str();
    if command == "vm" && !argv.is_empty() {
        argv.remove(0);
    } else if command.starts_with("vm ") {
        let count = command
            .strip_prefix("vm ")
            .unwrap()
            .split_whitespace()
            .count();
        argv.drain(0..count.min(argv.len()));
    }
    match verb {
        "exec" => vm_exec(ctx, &argv),
        "run" => vm_run(ctx, &argv),
        "route" => vm_route(ctx, &argv),
        "agent" => vm_agent(ctx, &argv),
        "push" | "upload" => vm_push(ctx, &argv),
        "pull" | "download" => vm_pull(ctx, &argv),
        "wait" => vm_wait(ctx, &argv),
        "env" => vm_env(ctx, &argv),
        "layout" => vm_layout(ctx, &argv),
        _ => Ok(None),
    }
}

fn usage(text: &str) -> CliError {
    CliError::usage(text)
}

fn parse_timeout(args: &mut Vec<String>, default: u64, max: u64) -> Result<u64> {
    let mut timeout = default;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--timeout" {
            if i + 1 >= args.len() {
                return Err(usage("--timeout requires seconds"));
            }
            timeout = args[i + 1]
                .parse()
                .map_err(|_| usage("--timeout must be a positive number"))?;
            if timeout == 0 || timeout > max {
                return Err(usage("--timeout is outside the supported range"));
            }
            args.drain(i..=i + 1);
        } else {
            i += 1;
        }
    }
    Ok(timeout)
}

fn command_string(argv: &[String]) -> Result<String> {
    let mut args = argv;
    if args.first().map(String::as_str) == Some("--") {
        args = &args[1..];
    }
    if args.is_empty() {
        return Err(usage(
            "Usage: cmux vm exec [--timeout <seconds>] <machine> -- <command...>",
        ));
    }
    Ok(args
        .iter()
        .map(|s| shell_quote(s))
        .collect::<Vec<_>>()
        .join(" "))
}

fn vm_exec(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let mut args = input.to_vec();
    let timeout = parse_timeout(&mut args, DEFAULT_EXEC_TIMEOUT, 900)?;
    let sep = args.iter().position(|a| a == "--");
    let (head, tail) = sep
        .map(|i| (&args[..i], &args[i + 1..]))
        .unwrap_or((&args[..], &[][..]));
    let machine = head.first().ok_or_else(|| {
        usage("Usage: cmux vm exec [--timeout <seconds>] <machine> -- <command...>")
    })?;
    let command = if sep.is_some() {
        command_string(tail)?
    } else {
        command_string(&head[1..])?
    };
    let response = ctx.rpc(
        "vm.exec",
        json!({"id": machine, "command": command, "timeout_ms": timeout * 1000}),
    )?;
    let exit_code = response
        .get("exit_code")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if ctx.json {
        ctx.emit(&response)?;
    } else {
        if let Some(s) = response.get("stdout").and_then(Value::as_str) {
            ctx.print(s)?;
            if !s.ends_with('\n') && !s.is_empty() {
                ctx.print("\n")?;
            }
        }
        if let Some(s) = response.get("stderr").and_then(Value::as_str) {
            eprint!("{}{}", s, if s.ends_with('\n') { "" } else { "\n" });
        }
    }
    Ok(Some(if exit_code < 0 { 1 } else { exit_code as i32 }))
}

fn vm_wait(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let mut args = input.to_vec();
    let timeout = parse_timeout(&mut args, DEFAULT_WAIT_TIMEOUT, 3600)?;
    let wake = take_flag(&mut args, "--wake");
    let machine = args
        .first()
        .ok_or_else(|| usage("Usage: cmux vm wait <machine> [--timeout <seconds>] [--wake]"))?;
    let started = Instant::now();
    loop {
        let value = ctx.rpc("vm.status", json!({"id": machine}))?;
        let status = value
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_ascii_lowercase();
        if ["running", "ready", "standby", "paused"].contains(&status.as_str()) {
            if wake {
                let _ = ctx.rpc(
                    "vm.exec",
                    json!({"id": machine, "command": "true", "timeout_ms": 30_000}),
                )?;
            }
            let mut out = value;
            if let Value::Object(ref mut map) = out {
                map.insert("waited_seconds".into(), json!(started.elapsed().as_secs()));
                map.insert("woke".into(), json!(wake));
            }
            if ctx.json {
                ctx.emit(&out)?;
            } else {
                ctx.print(&format!(
                    "{} is ready ({}) after {}s\n",
                    machine,
                    status,
                    started.elapsed().as_secs()
                ))?;
            }
            return Ok(Some(0));
        }
        if !["creating", "starting", "pending", "resuming", "unknown"].contains(&status.as_str()) {
            return Err(CliError::new(
                "vm_not_ready",
                format!("{} reached status \"{}\"", machine, status),
            ));
        }
        if started.elapsed() >= Duration::from_secs(timeout) {
            return Err(CliError::new(
                "timeout",
                format!("Timed out after {}s waiting for {}", timeout, machine),
            ));
        }
        thread::sleep(Duration::from_secs(3));
    }
}

fn vm_run(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let mut args = input.to_vec();
    let timeout = parse_timeout(&mut args, 600, 900)?;
    let machine = take_value(&mut args, "--machine")?;
    let sync = take_flag(&mut args, "--sync");
    let new_machine = take_flag(&mut args, "--new");
    let _size = take_value(&mut args, "--size")?;
    let pull = take_value(&mut args, "--pull")?;
    let sep = args
        .iter()
        .position(|a| a == "--")
        .ok_or_else(|| usage("Usage: cmux vm run [options] -- <command...>"))?;
    let command_args = &args[sep + 1..];
    if command_args.is_empty() {
        return Err(usage("Usage: cmux vm run [options] -- <command...>"));
    }
    let id = match machine {
        Some(id) => id,
        None => select_machine(ctx, new_machine)?,
    };
    let mut prefix = String::new();
    if sync {
        let cwd = std::env::current_dir().map_err(io_err)?;
        let name = cwd.file_name().and_then(|s| s.to_str()).unwrap_or("app");
        let remote = format!("work/{}", name);
        vm_push(
            ctx,
            &[id.clone(), cwd.display().to_string(), remote.clone()],
        )?;
        prefix = format!("cd {} && ", shell_quote(&remote));
    }
    let command = format!(
        "{}{}",
        prefix,
        command_args
            .iter()
            .map(|s| shell_quote(s))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let response = ctx.rpc(
        "vm.exec",
        json!({"id": id, "command": command, "timeout_ms": timeout * 1000}),
    )?;
    if let Some(path) = pull {
        let _ = vm_pull(ctx, &[id.clone(), path])?;
    }
    let code = response
        .get("exit_code")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if ctx.json {
        let mut out = response;
        if let Value::Object(ref mut map) = out {
            map.insert("machine".into(), json!(id));
        }
        ctx.emit(&out)?;
    } else {
        if let Some(s) = response.get("stdout").and_then(Value::as_str) {
            ctx.print(s)?;
        }
        if let Some(s) = response.get("stderr").and_then(Value::as_str) {
            eprint!("{}", s);
        }
    }
    Ok(Some(code.max(0) as i32))
}

fn vm_route(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let mut args = input.to_vec();
    let mut params = Map::new();
    if take_flag(&mut args, "--new") {
        params.insert("force_new".into(), json!(true));
    }
    let value = if params
        .get("force_new")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        let created = ctx.rpc(
            "vm.create",
            json!({"kind":"base","idempotency_key":uuid::Uuid::new_v4().to_string()}),
        )?;
        json!({"machine":created.get("id").cloned().unwrap_or(Value::Null),"created":true,"reason":"provisioned"})
    } else {
        select_machine(ctx, false)
            .map(|id| json!({"machine":id,"created":false,"reason":"first ready machine"}))?
    };
    if ctx.json {
        ctx.emit(&value)?;
    } else {
        let id = value
            .get("machine")
            .or_else(|| value.get("id"))
            .and_then(Value::as_str)
            .unwrap_or("(would provision)");
        ctx.print(id)?;
    }
    Ok(Some(0))
}

fn select_machine(ctx: &Context, force_new: bool) -> Result<String> {
    if !force_new {
        let list = ctx.rpc("vm.list", json!({}))?;
        if let Some(vms) = list.get("vms").and_then(Value::as_array) {
            if let Some(id) = vms.iter().find_map(|v| {
                let status = v
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if ["running", "ready", "standby", "paused"].contains(&status.as_str()) {
                    v.get("id").and_then(Value::as_str).map(str::to_owned)
                } else {
                    None
                }
            }) {
                return Ok(id);
            }
        }
    }
    let created = ctx.rpc(
        "vm.create",
        json!({"kind":"base","idempotency_key":uuid::Uuid::new_v4().to_string()}),
    )?;
    created
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| CliError::new("route_failed", "vm.create returned no machine id"))
}

fn vm_agent(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let mut args = input.to_vec();
    let timeout = parse_timeout(&mut args, 900, 3600)?;
    let _wait = take_flag(&mut args, "--wait");
    let output = take_flag(&mut args, "--output");
    let _no_open = take_flag(&mut args, "--no-open");
    let agent = take_value(&mut args, "--agent")?
        .or_else(|| args.first().cloned())
        .ok_or_else(|| {
            usage("Usage: cmux vm agent --agent <claude|codex|opencode|pi> -- <prompt or args...>")
        })?;
    if args.first().map(String::as_str) == Some(agent.as_str()) {
        args.remove(0);
    }
    let machine = take_value(&mut args, "--machine")?;
    let sep = args
        .iter()
        .position(|a| a == "--")
        .ok_or_else(|| usage("vm agent requires -- before agent arguments"))?;
    let tail = &args[sep + 1..];
    if tail.is_empty() {
        return Err(usage("vm agent requires a prompt or agent arguments"));
    }
    let id = match machine {
        Some(id) => id,
        None => select_machine(ctx, false)?,
    };
    let command = format!(
        "{} {}",
        agent,
        tail.iter()
            .map(|s| shell_quote(s))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let value = ctx.rpc(
        "vm.exec",
        json!({"id": id, "command": command, "timeout_ms": timeout * 1000}),
    )?;
    if ctx.json {
        ctx.emit(&value)?;
    } else if output {
        if let Some(s) = value.get("stdout").and_then(Value::as_str) {
            ctx.print(s)?;
        }
    } else if let Some(s) = value.get("stdout").and_then(Value::as_str) {
        ctx.print(s)?;
    }
    Ok(Some(
        value
            .get("exit_code")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .max(0) as i32,
    ))
}

fn vm_push(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let mut args = input.to_vec();
    if args.iter().any(|a| a == "--watch") {
        return Err(CliError::new(
            "unsupported",
            "vm push --watch is not available in the Rust CLI yet; run a one-shot push or keep using the Swift cmux command",
        ));
    }
    let secret = take_flag(&mut args, "--secret");
    let mode = take_value(&mut args, "--mode")?.unwrap_or_else(|| "600".into());
    let excludes = take_multi_value(&mut args, "--exclude");
    args.retain(|a| a != "--no-default-excludes" && a != "--watch");
    if args.len() < 2 || args.len() > 3 {
        return Err(usage(
            "Usage: cmux vm push [--secret] <machine> <local-path> [remote-path]",
        ));
    }
    let machine = args.remove(0);
    let local = expand_tilde(&args.remove(0));
    let remote = args.first().cloned().unwrap_or_else(|| {
        Path::new(&local)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("payload")
            .into()
    });
    if fs::metadata(&local).map_err(io_err)?.is_dir() {
        return Err(CliError::new(
            "unsupported",
            "directory push is not available in this first Rust slice; use vm push on individual files",
        ));
    }
    let data = fs::read(&local)
        .map_err(|e| CliError::new("io", format!("cannot read {}: {}", local, e)))?;
    if data.is_empty() {
        return Err(CliError::new(
            "empty_file",
            "refusing to transfer an empty file",
        ));
    }
    let cap = if secret {
        SECRET_TRANSFER_BYTES
    } else {
        MAX_TRANSFER_BYTES
    };
    if data.len() as u64 > cap {
        return Err(CliError::new(
            "too_large",
            format!("{} exceeds the {} byte transfer limit", local, cap),
        ));
    }
    if secret {
        let value = ctx.rpc("vm.file_put", json!({"id": machine, "path": remote, "mode": mode, "data_base64": base64::engine::general_purpose::STANDARD.encode(&data)}))?;
        if ctx.json {
            ctx.emit(&value)?;
        } else {
            ctx.print(&format!(
                "OK {} ({} bytes, mode {}) delivered over the link\n",
                remote,
                data.len(),
                mode
            ))?;
        }
        return Ok(Some(0));
    }
    // Keep ordinary transfers off the control plane.  The app grants an
    // ephemeral localhost SSH endpoint and an ed25519 host key.
    let temp = tempfile_dir("cmux-scp")?;
    let cleanup_temp = temp.clone();
    struct TempCleanup(PathBuf);
    impl Drop for TempCleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = TempCleanup(cleanup_temp);
    let key = temp.join("identity");
    let status = Command::new("/usr/bin/ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-C", "cmux-scp", "-f"])
        .arg(&key)
        .status()
        .map_err(io_err)?;
    if !status.success() {
        let _ = fs::remove_dir_all(&temp);
        return Err(CliError::new(
            "transfer_key",
            "could not create transfer key",
        ));
    }
    let public_key = fs::read_to_string(key.with_extension("pub")).map_err(io_err)?;
    let endpoint = ctx.rpc(
        "vm.scp_info",
        json!({"id": machine, "public_key": public_key}),
    )?;
    let host = endpoint.get("host").and_then(Value::as_str).unwrap_or("");
    let port = endpoint.get("port").and_then(Value::as_u64).unwrap_or(0);
    let user = endpoint
        .get("username")
        .and_then(Value::as_str)
        .unwrap_or("");
    let host_key = endpoint
        .get("host_public_key")
        .and_then(Value::as_str)
        .unwrap_or("");
    if host != "127.0.0.1" || !(1..=65535).contains(&port) || user.is_empty() || host_key.is_empty()
    {
        return Err(CliError::new(
            "transfer_unavailable",
            "cloud file transfer requires a private verified SSH endpoint",
        ));
    }
    fs::write(temp.join("known_hosts"), format!("cmux-scp {}\n", host_key)).map_err(io_err)?;
    let target = format!("{}@{}:{}", user, host, remote);
    let opts = ssh_opts(&temp, port, &key);
    let child = Command::new("/usr/bin/scp")
        .args(&opts)
        .arg(&local)
        .arg(target)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(io_err)?;
    let out = child.wait_with_output().map_err(io_err)?;
    if !out.status.success() {
        return Err(CliError::new(
            "transfer_failed",
            String::from_utf8_lossy(&out.stderr).trim().to_owned(),
        ));
    }
    let digest = hex_digest(&data);
    let out = json!({"ok":true,"direction":"push","vm":machine,"local":local,"remote":remote,"bytes":data.len(),"sha256":digest,"excluded":excludes});
    if ctx.json {
        ctx.emit(&out)?;
    } else {
        ctx.print(&format!(
            "Pushed {} to {}:{} ({} bytes)\n",
            local,
            machine,
            remote,
            data.len()
        ))?;
    }
    Ok(Some(0))
}

fn vm_pull(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    if input.len() < 2 || input.len() > 3 {
        return Err(usage(
            "Usage: cmux vm pull <machine> <remote-path> [local-path]",
        ));
    }
    let machine = &input[0];
    let remote = &input[1];
    let local = input.get(2).cloned().unwrap_or_else(|| {
        Path::new(remote)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("payload")
            .into()
    });
    // Pull uses the authenticated exec channel in the legacy implementation.
    let quoted = shell_quote(remote);
    let pre = ctx.rpc(
        "vm.exec",
        json!({"id":machine,"command":format!("wc -c < {}",quoted),"timeout_ms":100_000}),
    )?;
    let total = pre
        .get("stdout")
        .and_then(Value::as_str)
        .and_then(|s| s.trim().parse::<usize>().ok())
        .ok_or_else(|| CliError::new("transfer_size", "could not determine remote file size"))?;
    if total > MAX_TRANSFER_BYTES as usize {
        return Err(CliError::new(
            "too_large",
            "remote file exceeds the pull limit",
        ));
    }
    let mut data = Vec::with_capacity(total);
    for offset in (0..total).step_by(CHUNK_BYTES) {
        let count = (total - offset).min(CHUNK_BYTES);
        let command = format!(
            "dd if={} bs=1 skip={} count={} 2>/dev/null | base64",
            quoted, offset, count
        );
        let value = ctx.rpc(
            "vm.exec",
            json!({"id":machine,"command":command,"timeout_ms":100_000}),
        )?;
        let encoded = value
            .get("stdout")
            .and_then(Value::as_str)
            .unwrap_or("")
            .split_whitespace()
            .collect::<String>();
        let chunk = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| CliError::new("transfer_corrupt", "invalid base64 chunk from machine"))?;
        data.extend_from_slice(&chunk);
    }
    if data.len() != total {
        return Err(CliError::new(
            "transfer_short",
            "remote file changed during pull",
        ));
    }
    let path = expand_tilde(&local);
    if let Some(parent) = Path::new(&path).parent() {
        fs::create_dir_all(parent).map_err(io_err)?;
    }
    fs::write(&path, &data).map_err(io_err)?;
    let out = json!({"ok":true,"direction":"pull","vm":machine,"remote":remote,"local":path,"bytes":data.len(),"sha256":hex_digest(&data)});
    if ctx.json {
        ctx.emit(&out)?;
    } else {
        ctx.print(&format!(
            "Pulled {}:{} to {} ({} bytes)\n",
            machine,
            remote,
            path,
            data.len()
        ))?;
    }
    Ok(Some(0))
}

fn vm_env(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let verb = input.first().map(String::as_str).unwrap_or("");
    let args = &input[1..];
    let machine = args
        .first()
        .ok_or_else(|| usage("Usage: cmux vm env <set|ls|rm> <machine> ..."))?;
    match verb {
        "set" => {
            let mut entries = Vec::new();
            let mut i = 1;
            while i < args.len() {
                let raw = &args[i];
                if raw == "--from-file" {
                    i += 1;
                    let p = args
                        .get(i)
                        .ok_or_else(|| usage("--from-file requires a path"))?;
                    let text = fs::read_to_string(expand_tilde(p)).map_err(io_err)?;
                    entries.extend(parse_env(&text)?);
                } else if raw == "-" {
                    let mut text = String::new();
                    io::stdin().read_to_string(&mut text).map_err(io_err)?;
                    entries.extend(parse_env(&text)?);
                } else {
                    entries.push(parse_assignment(raw)?);
                }
                i += 1;
            }
            if entries.is_empty() {
                return Err(usage("vm env set requires KEY=VALUE"));
            }
            let value = ctx.rpc("vm.env_set", json!({"id":machine,"entries":entries}))?;
            if ctx.json {
                ctx.emit(&value)?;
            } else {
                ctx.print("OK environment updated\n")?;
            }
        }
        "ls" => {
            let show = args.iter().any(|a| a == "--show");
            let cmd = format!("cmux env ls{} --json", if show { " --show" } else { "" });
            let value = exec_shim(ctx, machine, &cmd)?;
            if ctx.json {
                ctx.emit(&value)?;
            } else {
                ctx.print(value.get("stdout").and_then(Value::as_str).unwrap_or(""))?;
            }
        }
        "rm" => {
            let keys = args[1..].to_vec();
            if keys.is_empty() {
                return Err(usage("vm env rm requires KEY"));
            }
            let cmd = format!(
                "cmux env rm {}",
                keys.iter()
                    .map(|s| shell_quote(s))
                    .collect::<Vec<_>>()
                    .join(" ")
            );
            let value = exec_shim(ctx, machine, &cmd)?;
            if ctx.json {
                ctx.emit(&value)?;
            } else {
                ctx.print("OK environment updated\n")?;
            }
        }
        _ => return Err(usage("Usage: cmux vm env <set|ls|rm> <machine> ...")),
    }
    Ok(Some(0))
}

fn vm_layout(ctx: &Context, input: &[String]) -> Result<Option<i32>> {
    let verb = input.first().map(String::as_str).unwrap_or("");
    let args = &input[1..];
    let machine = args
        .first()
        .ok_or_else(|| usage("Usage: cmux vm layout <export|apply> <machine> ..."))?;
    let cmd = match verb {
        "export" | "get" | "show" => format!(
            "cmux layout export --json{}",
            if args.iter().any(|a| a == "--raw") {
                " --raw"
            } else {
                ""
            }
        ),
        "apply" | "set" => {
            let source = args
                .get(1)
                .ok_or_else(|| usage("vm layout apply requires a layout file or -"))?;
            let data = if source == "-" {
                let mut s = String::new();
                io::stdin().read_to_string(&mut s).map_err(io_err)?;
                s.into_bytes()
            } else {
                fs::read(expand_tilde(source)).map_err(io_err)?
            };
            format!(
                "printf %s {} | base64 -d | cmux layout apply --json -",
                shell_quote(&base64::engine::general_purpose::STANDARD.encode(data))
            )
        }
        _ => return Err(usage("Usage: cmux vm layout <export|apply> <machine> ...")),
    };
    let value = exec_shim(ctx, machine, &cmd)?;
    if ctx.json {
        ctx.emit(&value)?;
    } else {
        ctx.print(value.get("stdout").and_then(Value::as_str).unwrap_or(""))?;
    }
    Ok(Some(0))
}

fn exec_shim(ctx: &Context, machine: &str, command: &str) -> Result<Value> {
    let value = ctx.rpc(
        "vm.exec",
        json!({"id":machine,"command":command,"timeout_ms":120_000}),
    )?;
    if value.get("exit_code").and_then(Value::as_i64).unwrap_or(1) != 0 {
        return Err(CliError::new(
            "vm_exec_failed",
            value
                .get("stderr")
                .and_then(Value::as_str)
                .unwrap_or("machine command failed"),
        ));
    }
    Ok(value)
}
fn take_flag(args: &mut Vec<String>, flag: &str) -> bool {
    if let Some(i) = args.iter().position(|a| a == flag) {
        args.remove(i);
        true
    } else {
        false
    }
}
fn take_value(args: &mut Vec<String>, flag: &str) -> Result<Option<String>> {
    if let Some(i) = args.iter().position(|a| a == flag) {
        if i + 1 >= args.len() {
            return Err(usage(&format!("{} requires a value", flag)));
        }
        let v = args.remove(i + 1);
        args.remove(i);
        Ok(Some(v))
    } else {
        Ok(None)
    }
}
fn take_multi_value(args: &mut Vec<String>, flag: &str) -> Vec<String> {
    let mut out = Vec::new();
    while let Some(i) = args.iter().position(|a| a == flag) {
        if i + 1 >= args.len() {
            break;
        }
        out.push(args.remove(i + 1));
        args.remove(i);
    }
    out
}
fn parse_assignment(raw: &str) -> Result<Value> {
    let (key, value) = raw
        .split_once('=')
        .ok_or_else(|| usage("expected KEY=VALUE"))?;
    if !regex::Regex::new(r"^[A-Za-z_][A-Za-z0-9_]*$")
        .unwrap()
        .is_match(key)
        || value.contains(['\n', '\r'])
    {
        return Err(usage("invalid environment assignment"));
    }
    Ok(json!({"key":key,"value":value}))
}
fn parse_env(text: &str) -> Result<Vec<Value>> {
    text.lines()
        .filter_map(|line| {
            let mut l = line.trim();
            if l.is_empty() || l.starts_with('#') {
                return None;
            }
            if let Some(rest) = l.strip_prefix("export ") {
                l = rest.trim();
            }
            Some(parse_assignment(l))
        })
        .collect()
}
fn shell_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".into();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}
fn expand_tilde(s: &str) -> String {
    if let Some(rest) = s.strip_prefix("~/") {
        std::env::var("HOME").unwrap_or_default() + "/" + rest
    } else {
        s.to_owned()
    }
}
fn io_err(e: impl std::fmt::Display) -> CliError {
    CliError::new("io", e.to_string())
}
fn hex_digest(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    h.finalize().iter().map(|b| format!("{:02x}", b)).collect()
}
fn tempfile_dir(prefix: &str) -> Result<PathBuf> {
    let p = std::env::temp_dir().join(format!("{}-{}", prefix, uuid::Uuid::new_v4()));
    fs::create_dir(&p).map_err(io_err)?;
    Ok(p)
}
fn ssh_opts(dir: &Path, port: u64, key: &Path) -> Vec<String> {
    vec![
        "-F".into(),
        "/dev/null".into(),
        "-o".into(),
        "StrictHostKeyChecking=yes".into(),
        "-o".into(),
        "HostKeyAlias=cmux-scp".into(),
        "-o".into(),
        format!("UserKnownHostsFile={}", dir.join("known_hosts").display()),
        "-o".into(),
        "GlobalKnownHostsFile=/dev/null".into(),
        "-o".into(),
        format!("ConnectTimeout=15"),
        "-o".into(),
        "IdentitiesOnly=yes".into(),
        "-i".into(),
        key.display().to_string(),
        "-p".into(),
        port.to_string(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quote_handles_spaces_and_quotes() {
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("a'b"), "'a'\\''b'");
        assert_eq!(shell_quote(""), "''");
    }

    #[test]
    fn dotenv_parser_accepts_comments_export_and_empty_values() {
        let parsed = parse_env("# comment\nexport TOKEN=abc\nEMPTY=\n").unwrap();
        assert_eq!(parsed[0], json!({"key":"TOKEN","value":"abc"}));
        assert_eq!(parsed[1], json!({"key":"EMPTY","value":""}));
    }

    #[test]
    fn assignment_rejects_invalid_keys_and_newlines() {
        assert!(parse_assignment("bad-key=value").is_err());
        assert!(parse_assignment("OK=multi\nline").is_err());
    }
}
