//! Cloud VM attach and surface navigation commands.
//!
//! This module deliberately keeps the command grammar in Rust while delegating
//! cloud state and placement to the app socket.  The socket methods are the
//! shared boundary used by the Swift UI, so `cmux vm ...` and `cmux surface ...`
//! cannot drift in resource identity or placement semantics.

use serde_json::{Map, Value, json};

use crate::{Context, Result};

fn usage() -> &'static str {
    "Usage: cmux vm tree [<machine>] [--refresh]\n       cmux vm workspace <new|open|rename|close|rm> ...\n       cmux vm terminal <send|read|wait|wait-exit|output|close|rename> ...\n       cmux vm tab rename <machine> <tab-id> <name>\n       cmux vm open <resource> [--workspace <id>] [--focus <bool>] [--print]\n       cmux surface <ls|open|new-terminal> ..."
}

fn text(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or("?").to_owned()
}

fn bool_value(raw: &str) -> Option<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => Some(true),
        "false" | "0" | "no" => Some(false),
        _ => None,
    }
}

fn option(args: &[String], name: &str) -> Option<String> {
    args.iter().enumerate().find_map(|(i, arg)| {
        if arg == name {
            args.get(i + 1).cloned()
        } else {
            arg.strip_prefix(&format!("{name}=")).map(str::to_owned)
        }
    })
}

fn has(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn positional(args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut skip = false;
    for arg in args {
        if skip {
            skip = false;
            continue;
        }
        if arg == "--" {
            break;
        }
        if arg.starts_with("--") {
            if !arg.contains('=') {
                skip = matches!(
                    arg.as_str(),
                    "--workspace"
                        | "--pane"
                        | "--focus"
                        | "--machine"
                        | "--cwd"
                        | "--name"
                        | "--remote-workspace"
                        | "--pattern"
                        | "--timeout"
                        | "--after"
                        | "--max-bytes"
                        | "--keys"
                );
            }
            continue;
        }
        out.push(arg.clone());
    }
    out
}

fn emit(ctx: &Context, value: &Value, plain: Option<String>) -> Result<()> {
    if ctx.json {
        ctx.emit(value)
    } else if let Some(s) = plain {
        ctx.print(s)
    } else {
        ctx.print(value.to_string())
    }
}

fn unknown(ctx: &Context, what: &str) -> Result<Option<i32>> {
    if ctx.non_interactive {
        return Err(crate::CliError::usage(format!("{what}\n\n{}", usage())));
    }
    ctx.print(format!("{what}\n\n{}", usage()))?;
    Ok(Some(0))
}

fn tree(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    if has(args, "--help") || has(args, "-h") {
        return ctx.print(usage()).map(|_| Some(0));
    }
    let p = positional(args);
    if p.len() > 1 {
        return Err(crate::CliError::usage(usage()));
    }
    let mut params = Map::new();
    if let Some(machine) = p.first() {
        params.insert("machine".into(), json!(machine));
    }
    if has(args, "--refresh") {
        params.insert("refresh".into(), json!(true));
    }
    let value = ctx.rpc("surface.catalog", Value::Object(params))?;
    if ctx.json {
        ctx.emit(&value)?;
        return Ok(Some(0));
    }
    let machines = value
        .get("machines")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if machines.is_empty() {
        ctx.print("No cloud machines. Try: cmux vm new")?;
        return Ok(Some(0));
    }
    let resources = value
        .get("resources")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut lines = Vec::new();
    for machine in machines {
        let id = text(&machine, "id");
        let label = machine
            .get("displayName")
            .or_else(|| machine.get("slug"))
            .and_then(Value::as_str)
            .unwrap_or(&id);
        let state = machine
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        lines.push(format!("{label}  {state}"));
        for resource in resources
            .iter()
            .filter(|r| r.get("machine").and_then(Value::as_str) == Some(id.as_str()))
        {
            let kind = resource
                .get("kind")
                .and_then(Value::as_str)
                .unwrap_or("resource");
            let key = resource
                .get("key")
                .or_else(|| resource.get("id"))
                .and_then(Value::as_str)
                .unwrap_or("?");
            lines.push(format!(
                "  {kind}/{key}  (cmux surface open {id}/{kind}/{key})"
            ));
        }
    }
    ctx.print(lines.join("\n"))?;
    Ok(Some(0))
}

fn workspace(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let Some(verb) = args.first() else {
        return Err(crate::CliError::usage(usage()));
    };
    if has(args, "--help") || has(args, "-h") {
        return ctx.print(usage()).map(|_| Some(0));
    }
    let p = positional(&args[1..]);
    let machine = p.first().ok_or_else(|| crate::CliError::usage(usage()))?;
    let mut params = Map::new();
    params.insert("id".into(), json!(machine));
    let method;
    match verb.as_str() {
        "new" => {
            method = "vm.workspace_new";
            if let Some(name) = option(args, "--name") {
                params.insert("name".into(), json!(name));
            }
            if has(args, "--reuse") {
                params.insert("reuse".into(), json!(true));
            }
            if has(args, "--no-open") {
                params.insert("open".into(), json!(false));
            }
        }
        "open" => {
            if p.len() != 2 {
                return Err(crate::CliError::usage(usage()));
            }
            method = "vm.workspace_open";
            params.insert("workspace_id".into(), json!(p[1]));
            if let Some(w) = option(args, "--workspace") {
                params.insert("target_workspace_id".into(), json!(w));
            }
            if let Some(pane) = option(args, "--pane") {
                params.insert("pane_id".into(), json!(pane));
            }
            for (flag, direction) in [
                ("--left", "left"),
                ("--right", "right"),
                ("--up", "up"),
                ("--down", "down"),
            ] {
                if has(args, flag) {
                    params.insert("direction".into(), json!(direction));
                }
            }
            if has(args, "--here") || has(args, "--tabs") || option(args, "--pane").is_some() {
                params.insert("here".into(), json!(true));
            }
            if has(args, "--tabs") {
                params.insert("placement".into(), json!("tab"));
            }
        }
        "rename" => {
            if p.len() != 3 {
                return Err(crate::CliError::usage(usage()));
            }
            method = "vm.workspace_rename";
            params.insert("workspace_id".into(), json!(p[1]));
            params.insert("name".into(), json!(p[2]));
        }
        "close" => {
            if p.len() != 2 {
                return Err(crate::CliError::usage(usage()));
            }
            method = "vm.workspace_close";
            params.insert("workspace_id".into(), json!(p[1]));
        }
        "rm" | "delete" => {
            if p.len() != 2 {
                return Err(crate::CliError::usage(usage()));
            }
            method = "vm.workspace_delete";
            params.insert("workspace_id".into(), json!(p[1]));
        }
        _ => return unknown(ctx, &format!("vm workspace: unknown verb '{verb}'")),
    }
    let value = ctx.rpc(method, Value::Object(params))?;
    let plain = match verb.as_str() {
        "rename" => Some(format!("OK renamed workspace {} on {machine}", p[1])),
        "close" => Some(format!(
            "OK closed workspace {} on {machine} (terminals kept; see Terminals pool)",
            p[1]
        )),
        "rm" | "delete" => Some(format!("OK deleted workspace {} on {machine}", p[1])),
        _ => Some(format!(
            "OK workspace={} machine={machine}",
            text(&value, "workspace_id")
        )),
    };
    emit(ctx, &value, plain).map(|_| Some(0))
}

fn terminal(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let Some(verb) = args.first() else {
        return Err(crate::CliError::usage(usage()));
    };
    let p = positional(&args[1..]);
    if p.len() < 2 {
        return Err(crate::CliError::usage(usage()));
    }
    let machine = &p[0];
    let terminal = &p[1];
    let mut params = Map::new();
    params.insert("id".into(), json!(machine));
    params.insert("terminal_id".into(), json!(terminal));
    let method = match verb.as_str() {
        "close" => "vm.terminal_close",
        "read" | "screen" => "vm.terminal_read",
        "send" | "write" => "vm.terminal_write",
        "wait" => "vm.terminal_wait",
        "wait-exit" => "vm.terminal_wait_exit",
        "output" => "vm.terminal_output",
        "rename" => "vm.terminal_rename",
        _ => return unknown(ctx, &format!("vm terminal: unknown verb '{verb}'")),
    };
    if matches!(verb.as_str(), "send" | "write") {
        let sep = args.iter().position(|a| a == "--");
        let text_args = sep
            .map(|i| args[i + 1..].to_vec())
            .unwrap_or_else(|| p[2..].to_vec());
        if !text_args.is_empty() {
            params.insert("text".into(), json!(text_args.join(" ")));
        }
        if let Some(keys) = option(args, "--keys") {
            params.insert(
                "keys".into(),
                json!(
                    keys.split(',')
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>()
                ),
            );
        }
    } else if verb == "wait" {
        params.insert(
            "pattern".into(),
            json!(
                option(args, "--pattern").ok_or_else(|| crate::CliError::usage(
                    "vm terminal wait: --pattern <regex> is required"
                ))?
            ),
        );
        params.insert(
            "timeout_ms".into(),
            json!(
                option(args, "--timeout")
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(30_000)
            ),
        );
    } else if verb == "wait-exit" {
        params.insert(
            "timeout_ms".into(),
            json!(
                option(args, "--timeout")
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(30_000)
            ),
        );
    } else if verb == "output" {
        if let Some(after) = option(args, "--after") {
            params.insert(
                "after".into(),
                json!(after.parse::<u64>().map_err(|_| crate::CliError::usage(
                    "--after must be a non-negative offset"
                ))?),
            );
        }
        if let Some(max) = option(args, "--max-bytes") {
            params.insert(
                "max_bytes".into(),
                json!(
                    max.parse::<u64>()
                        .map_err(|_| crate::CliError::usage("--max-bytes must be positive"))?
                ),
            );
        }
    } else if verb == "rename" {
        if p.len() != 3 {
            return Err(crate::CliError::usage(usage()));
        }
        params.insert("name".into(), json!(p[2].trim()));
    }
    let value = ctx.rpc(method, Value::Object(params))?;
    let plain = if verb == "read" || verb == "screen" || verb == "output" {
        Some(
            value
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
        )
    } else if verb == "wait-exit" {
        Some(
            if value.get("state").and_then(Value::as_str) == Some("exited") {
                "exited".into()
            } else {
                "pending".into()
            },
        )
    } else {
        Some(format!("OK {verb} terminal {terminal} on {machine}"))
    };
    emit(ctx, &value, plain).map(|_| Some(0))
}

fn tab(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let p = positional(args);
    if p.len() != 4 || p[0] != "rename" {
        return Err(crate::CliError::usage(usage()));
    }
    let value = ctx.rpc(
        "vm.tab_rename",
        json!({"id": p[1], "tab_id": p[2], "name": p[3].trim()}),
    )?;
    emit(
        ctx,
        &value,
        Some(format!("OK renamed tab {} on {}", p[2], p[1])),
    )
    .map(|_| Some(0))
}

fn open(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let p = positional(args);
    let resource = p.first().ok_or_else(|| crate::CliError::usage(usage()))?;
    if p.len() == 1 {
        if let Some(machine) = resource.strip_suffix(":desktop") {
            let mut params = json!({"id": machine});
            if let Some(w) = option(args, "--workspace") {
                params["workspace_id"] = json!(w);
            }
            let value = ctx.rpc("vm.desktop_open", params)?;
            return emit(
                ctx,
                &value,
                Some(format!(
                    "OK desktop={} surface={}",
                    machine,
                    text(&value, "surface_id")
                )),
            )
            .map(|_| Some(0));
        }
        if let Some((machine, raw_port)) = resource.split_once(":port/") {
            let port = raw_port
                .parse::<u16>()
                .map_err(|_| crate::CliError::usage("vm open: port must be 1..65535"))?;
            let value = if has(args, "--print") {
                ctx.rpc("vm.open_port", json!({"id":machine,"port":port}))?
            } else {
                let mut params = json!({"id":machine,"port":port});
                if let Some(w) = option(args, "--workspace") {
                    params["workspace_id"] = json!(w);
                }
                ctx.rpc("vm.port_open", params)?
            };
            return emit(
                ctx,
                &value,
                Some(format!(
                    "{}:{}\n  {}",
                    machine,
                    port,
                    value
                        .get("url")
                        .or_else(|| value.get("open_url"))
                        .and_then(Value::as_str)
                        .unwrap_or("")
                )),
            )
            .map(|_| Some(0));
        }
        // `vm open <machine>` is an alias for `vm shell <machine>`.
        if !resource.contains('/') && !resource.contains(':') {
            return shell(ctx, args);
        }
    }
    // `vm open <machine> <port>` is the legacy spelling for the port resource.
    if p.len() == 2 {
        let port = p[1]
            .parse::<u16>()
            .map_err(|_| crate::CliError::usage("vm open: port must be 1..65535"))?;
        let value = if has(args, "--print") {
            ctx.rpc("vm.open_port", json!({"id": resource, "port": port}))?
        } else {
            let mut params = json!({"id": resource, "port": port});
            if let Some(w) = option(args, "--workspace") {
                params["workspace_id"] = json!(w);
            }
            ctx.rpc("vm.port_open", params)?
        };
        return emit(
            ctx,
            &value,
            Some(format!(
                "{}:{}\n  {}",
                resource,
                port,
                value
                    .get("url")
                    .or_else(|| value.get("open_url"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
            )),
        )
        .map(|_| Some(0));
    }
    let mut params = Map::new();
    params.insert("resource".into(), json!(resource));
    if let Some(w) = option(args, "--workspace") {
        params.insert("workspace_id".into(), json!(w));
    }
    if let Some(pane) = option(args, "--pane") {
        params.insert("pane_id".into(), json!(pane));
    }
    for (flag, direction) in [
        ("--left", "left"),
        ("--right", "right"),
        ("--up", "up"),
        ("--down", "down"),
    ] {
        if has(args, flag) {
            params.insert("direction".into(), json!(direction));
        }
    }
    if has(args, "--tab") {
        params.insert("placement".into(), json!("tab"));
    }
    if has(args, "--new") {
        params.insert("reuse".into(), json!(false));
    }
    if let Some(focus) = option(args, "--focus") {
        params.insert(
            "focus".into(),
            json!(
                bool_value(&focus)
                    .ok_or_else(|| crate::CliError::usage("--focus takes true or false"))?
            ),
        );
    }
    let value = ctx.rpc("surface.project", Value::Object(params))?;
    emit(
        ctx,
        &value,
        Some(format!(
            "OK surface={} workspace={} resource={resource}",
            text(&value, "surface_id"),
            text(&value, "workspace_id")
        )),
    )
    .map(|_| Some(0))
}

fn machine(ctx: &Context, verb: &str, args: &[String]) -> Result<Option<i32>> {
    let p = positional(args);
    match verb {
        "ls" | "list" => {
            let value = ctx.rpc("vm.list", json!({}))?;
            if ctx.json {
                ctx.emit(&value)?;
            } else {
                let rows = value
                    .get("vms")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                if rows.is_empty() {
                    ctx.print("No cloud VMs. Try: cmux vm new")?;
                } else {
                    for row in rows {
                        ctx.print(format!(
                            "{}  {}",
                            text(&row, "id"),
                            row.get("status")
                                .and_then(Value::as_str)
                                .unwrap_or("unknown")
                        ))?;
                    }
                }
            }
        }
        "status" | "info" => {
            let id = p
                .first()
                .ok_or_else(|| crate::CliError::usage("Usage: cmux vm status <id>"))?;
            let value = ctx.rpc("vm.status", json!({"id": id}))?;
            emit(
                ctx,
                &value,
                Some(format!(
                    "{}  [{}] {}",
                    text(&value, "id"),
                    text(&value, "provider"),
                    value
                        .get("status")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown")
                )),
            )?;
        }
        "desktop" | "vnc" => {
            let id = p
                .first()
                .ok_or_else(|| crate::CliError::usage("Usage: cmux vm desktop <id>"))?;
            let mut params = json!({"id": id});
            if let Some(w) = option(args, "--workspace") {
                params["workspace_id"] = json!(w);
            }
            let value = ctx.rpc("vm.desktop_open", params)?;
            emit(
                ctx,
                &value,
                Some(format!(
                    "OK desktop={} surface={}",
                    id,
                    text(&value, "surface_id")
                )),
            )?;
        }
        "tools" | "tool-inspector" => {
            exec_text(
                ctx,
                p.first(),
                "printf 'shell: '; printf '%s\\n' \"$SHELL\"; for tool in zsh git gh htop btop node bun python3; do if command -v \"$tool\" >/dev/null 2>&1; then printf '%-8s %s\\n' \"$tool\" \"$(command -v \"$tool\")\"; else printf '%-8s missing\\n' \"$tool\"; fi; done",
            )?;
        }
        "ports" => {
            exec_text(
                ctx,
                p.first(),
                "if command -v ss >/dev/null 2>&1; then ss -ltnp; elif command -v netstat >/dev/null 2>&1; then netstat -ltnp; else echo 'No port inspector found'; fi",
            )?;
        }
        "handoff" => {
            let id = p
                .first()
                .ok_or_else(|| crate::CliError::usage("Usage: cmux vm handoff <id>"))?;
            let value = ctx.rpc("vm.status", json!({"id": id}))?;
            if ctx.json {
                ctx.emit(&value)?;
            } else {
                ctx.print(format!("cmux Cloud VM handoff\nid:       {id}\nprovider: {}\nstatus:   {}\nattach:   cmux vm ssh {id}\ninspect:  cmux vm tools {id}", text(&value, "provider"), text(&value, "status")))?;
            }
        }
        "ssh-info" => {
            let id = p
                .first()
                .ok_or_else(|| crate::CliError::usage("Usage: cmux vm ssh-info <id>"))?;
            let value = ctx.rpc("vm.ssh_info", json!({"id": id}))?;
            emit(ctx, &value, None)?;
        }
        _ => return Ok(None),
    }
    Ok(Some(0))
}

fn exec_text(ctx: &Context, id: Option<&String>, command: &str) -> Result<Option<i32>> {
    let id = id.ok_or_else(|| crate::CliError::usage("Usage: cmux vm <tools|ports> <id>"))?;
    let value = ctx.rpc(
        "vm.exec",
        json!({"id": id, "command": command, "timeout_ms": 30_000}),
    )?;
    if ctx.json {
        ctx.emit(&value)?;
    } else {
        ctx.print(value.get("stdout").and_then(Value::as_str).unwrap_or(""))?;
    }
    let code = value.get("exit_code").and_then(Value::as_i64).unwrap_or(0);
    Ok(Some(if code == 0 { 0 } else { code as i32 }))
}

fn shell(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let p = positional(args);
    let id = p
        .first()
        .ok_or_else(|| crate::CliError::usage("Usage: cmux vm shell <id>"))?;
    let mut params = json!({"machine": id, "open": true});
    if let Some(w) = option(args, "--workspace") {
        params["workspace_id"] = json!(w);
    }
    let value = ctx.rpc("surface.new_terminal", params)?;
    emit(
        ctx,
        &value,
        Some(format!(
            "OK resource={} terminal={}",
            text(&value, "resource"),
            text(&value, "terminal_id")
        )),
    )
    .map(|_| Some(0))
}

fn new_terminal(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let machine = option(args, "--machine").ok_or_else(|| {
        crate::CliError::usage("surface new-terminal: --machine <id|local> is required")
    })?;
    let mut params = Map::new();
    params.insert("machine".into(), json!(machine));
    params.insert("open".into(), json!(!has(args, "--no-open")));
    for (flag, key) in [
        ("--cwd", "cwd"),
        ("--name", "name"),
        ("--remote-workspace", "remote_workspace_id"),
        ("--workspace", "workspace_id"),
    ] {
        if let Some(v) = option(args, flag) {
            params.insert(key.into(), json!(v));
        }
    }
    if let Some(i) = args.iter().position(|a| a == "--") {
        params.insert("command".into(), json!(&args[i + 1..]));
    }
    let value = ctx.rpc("surface.new_terminal", Value::Object(params))?;
    emit(
        ctx,
        &value,
        Some(format!(
            "OK resource={} terminal={}",
            text(&value, "resource"),
            text(&value, "terminal_id")
        )),
    )
    .map(|_| Some(0))
}

pub fn run(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>> {
    match command {
        "vm" | "cloud" => match args.first().map(String::as_str).unwrap_or("tree") {
            "tree" | "surface" => tree(ctx, &args[1..]),
            "workspace" => workspace(ctx, &args[1..]),
            "terminal" => terminal(ctx, &args[1..]),
            "tab" => tab(ctx, &args[1..]),
            "open" | "port" => open(ctx, &args[1..]),
            "ls" | "list" | "status" | "info" | "desktop" | "vnc" | "tools" | "tool-inspector"
            | "ports" | "handoff" | "ssh-info" => machine(
                ctx,
                args.first().map(String::as_str).unwrap_or("ls"),
                &args[1..],
            ),
            "shell" | "attach" | "ssh" => shell(ctx, &args[1..]),
            _ => Ok(None),
        },
        "surface" => match args.first().map(String::as_str).unwrap_or("ls") {
            "ls" | "list" | "tree" | "catalog" => tree(ctx, &args[1..]),
            "open" | "project" => open(ctx, &args[1..]),
            "new-terminal" | "new" => new_terminal(ctx, &args[1..]),
            _ => Ok(None),
        },
        _ => Ok(None),
    }
}
