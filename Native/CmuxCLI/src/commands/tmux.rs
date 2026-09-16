//! tmux compatibility, local tmux, and SSH terminal commands.
//!
//! Parsing and validation happen here while the app remains owner of layout and
//! remote state through v2 socket methods. Headless commands exec system
//! clients with inherited stdio to preserve normal POSIX terminal semantics.
use crate::{CliError, Context, Result};
use serde_json::{Map, Value, json};
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};

const TMUX_COMMANDS: &[&str] = &[
    "capture-pane",
    "resize-pane",
    "pipe-pane",
    "wait-for",
    "swap-pane",
    "break-pane",
    "join-pane",
    "last-window",
    "last-pane",
    "next-window",
    "previous-window",
    "find-window",
    "clear-history",
    "set-hook",
    "popup",
    "bind-key",
    "unbind-key",
    "copy-mode",
    "set-buffer",
    "paste-buffer",
    "list-buffers",
    "respawn-pane",
    "display-message",
    "new-session",
    "new",
    "new-window",
    "neww",
    "split-window",
    "splitw",
    "list-panes",
    "list-windows",
    "list-sessions",
    "select-layout",
    "select-window",
    "select-pane",
    "kill-session",
    "kill-window",
    "kill-pane",
    "rename-session",
    "rename-window",
    "send-keys",
];

pub fn run(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>> {
    match command {
        "tmux" => local_tmux(ctx, args, true),
        "local-tmux" => local_tmux(ctx, args, false),
        "ssh" | "mosh" => ssh_exec(command, args),
        "ssh-tmux" | "mosh-tmux" => remote_tmux(ctx, command, args),
        "ssh-pty-attach" => ssh_pty_attach(ctx, args),
        "ssh-session-list" | "ssh-session-attach" | "ssh-session-cleanup" | "ssh-session-end" => {
            ssh_session(ctx, command, args)
        }
        "__tmux-compat" => {
            let (c, r) = split_command(args)?;
            tmux_command(ctx, c, r)
        }
        c if TMUX_COMMANDS.contains(&c) => tmux_command(ctx, c, args),
        _ => Ok(None),
    }
}
fn usage(m: impl Into<String>) -> CliError {
    CliError::usage(m)
}
fn value(args: &[String], name: &str) -> Result<Option<String>> {
    let mut out = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == name {
            if out.is_some() {
                return Err(usage(format!("duplicate option {name}")));
            };
            out = Some(
                args.get(i + 1)
                    .ok_or_else(|| usage(format!("{name} requires a value")))?
                    .clone(),
            );
            i += 1;
        } else if let Some(v) = args[i].strip_prefix(&format!("{name}=")) {
            if out.is_some() {
                return Err(usage(format!("duplicate option {name}")));
            };
            out = Some(v.into());
        }
        i += 1;
    }
    Ok(out)
}
fn has(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}
fn split_command(args: &[String]) -> Result<(&str, &[String])> {
    Ok((
        args.first()
            .map(String::as_str)
            .ok_or_else(|| usage("tmux requires a subcommand"))?,
        &args[1..],
    ))
}
fn target(ctx: &Context, args: &[String], allow_focused: bool) -> Result<Map<String, Value>> {
    let mut p = Map::new();
    let w = value(args, "--window")?.or_else(|| ctx.window.clone());
    let ws = value(args, "--workspace")?;
    let sf = value(args, "--surface")?;
    if let Some(v) = w.as_deref() {
        if let Some(id) = ctx.resolve_id("window", Some(v))? {
            p.insert("window_id".into(), json!(id));
        }
    }
    if let Some(v) = ws.as_deref() {
        if let Some(id) = ctx.resolve_id("workspace", Some(v))? {
            p.insert("workspace_id".into(), json!(id));
        }
    } else if w.is_none() {
        if let Some(id) = ctx.resolve_id("workspace", None)? {
            p.insert("workspace_id".into(), json!(id));
        }
    }
    if let Some(v) = sf.as_deref() {
        if let Some(id) = ctx.resolve_id("surface", Some(v))? {
            p.insert("surface_id".into(), json!(id));
        }
    } else if allow_focused || ws.is_none() && w.is_none() {
        if let Some(id) = ctx.resolve_id("surface", None)? {
            p.insert("surface_id".into(), json!(id));
        }
    }
    Ok(p)
}
fn emit(ctx: &Context, payload: Value, text: &str) -> Result<()> {
    if ctx.json {
        ctx.emit(&payload)
    } else {
        ctx.print(
            payload
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or(text),
        )
    }
}
fn tmux_compat(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let (c, r) = split_command(args)?;
    tmux_command(ctx, c, r)
}
fn tmux_command(ctx: &Context, c: &str, args: &[String]) -> Result<Option<i32>> {
    match c {
        "new-session" | "new" => {
            let cwd = value(args, "-c")?.map(|v| expand_path(&v));
            let title = value(args, "-n")?.or(value(args, "-s")?);
            let mut p = Map::new();
            p.insert("focus".into(), json!(!has(args, "-d")));
            if let Some(v) = cwd {
                p.insert("cwd".into(), json!(v));
            }
            let created = ctx.rpc("workspace.create", Value::Object(p))?;
            let ws = created
                .get("workspace_id")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    CliError::new("protocol", "workspace.create did not return workspace_id")
                })?
                .to_string();
            if let Some(t) = title.filter(|x| !x.trim().is_empty()) {
                let _ = ctx.rpc(
                    "workspace.rename",
                    json!({"workspace_id":ws.clone(),"title":t}),
                )?;
            }
            if has(args, "-P") {
                ctx.print(format_tmux(
                    &value(args, "-F")?.unwrap_or_else(|| "#{session_id}".into()),
                    &ws,
                ))?;
            }
            Ok(Some(0))
        }
        "new-window" | "neww" => tmux_command(ctx, "new-session", args),
        "split-window" | "splitw" => {
            let mut p = target(ctx, args, true)?;
            let d = if has(args, "-h") {
                if has(args, "-b") { "left" } else { "right" }
            } else if has(args, "-b") {
                "up"
            } else {
                "down"
            };
            p.insert("direction".into(), json!(d));
            p.insert("focus".into(), json!(!has(args, "-d")));
            if let Some(v) = value(args, "-c")? {
                p.insert("working_directory".into(), json!(expand_path(&v)));
            }
            let payload = ctx.rpc("surface.split", Value::Object(p))?;
            if has(args, "-P") {
                let id = payload
                    .get("surface_id")
                    .and_then(Value::as_str)
                    .or_else(|| payload.get("pane_id").and_then(Value::as_str))
                    .unwrap_or("");
                ctx.print(format_tmux(
                    &value(args, "-F")?.unwrap_or_else(|| "#{pane_id}".into()),
                    id,
                ))?;
            }
            Ok(Some(0))
        }
        "capture-pane" | "display-message" => {
            let mut p = target(ctx, args, false)?;
            if has(args, "--scrollback") {
                p.insert("scrollback".into(), json!(true));
            }
            if let Some(v) = value(args, "--lines")? {
                let n: i64 = v
                    .parse()
                    .map_err(|_| usage("--lines must be greater than 0"))?;
                if n <= 0 {
                    return Err(usage("--lines must be greater than 0"));
                }
                p.insert("lines".into(), json!(n));
                p.insert("scrollback".into(), json!(true));
            }
            let payload = ctx.rpc("surface.read_text", Value::Object(p))?;
            if ctx.json {
                ctx.emit(&payload)?;
            } else {
                ctx.print(payload.get("text").and_then(Value::as_str).unwrap_or(""))?
            }
            Ok(Some(0))
        }
        "resize-pane" => {
            let mut p = target(ctx, args, true)?;
            let d = if has(args, "-L") {
                "left"
            } else if has(args, "-U") {
                "up"
            } else if has(args, "-D") {
                "down"
            } else {
                "right"
            };
            let n: i64 = value(args, "--amount")?
                .unwrap_or_else(|| "1".into())
                .parse()
                .map_err(|_| usage("--amount must be greater than 0"))?;
            if n <= 0 {
                return Err(usage("--amount must be greater than 0"));
            }
            p.insert("direction".into(), json!(d));
            p.insert("amount".into(), json!(n));
            let payload = ctx.rpc("pane.resize", Value::Object(p))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "clear-history" => {
            let payload = ctx.rpc(
                "surface.clear_history",
                Value::Object(target(ctx, args, true)?),
            )?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "send-keys" => {
            let mut p = target(ctx, args, true)?;
            let keys = args
                .iter()
                .filter(|a| !a.starts_with('-'))
                .cloned()
                .collect::<Vec<_>>();
            if keys.is_empty() {
                return Err(usage("send-keys requires keys"));
            }
            let text = keys
                .iter()
                .map(|k| special_key(k).unwrap_or_else(|| k.clone()))
                .collect::<Vec<_>>()
                .join("");
            p.insert("text".into(), json!(text));
            let payload = ctx.rpc("surface.send_text", Value::Object(p))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "respawn-pane" => {
            let payload = ctx.rpc("surface.respawn", Value::Object(target(ctx, args, true)?))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "kill-pane" | "kill-window" => {
            let payload = ctx.rpc("surface.close", Value::Object(target(ctx, args, true)?))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "kill-session" => {
            let mut p = target(ctx, args, false)?;
            let ws = p.remove("workspace_id").unwrap_or(Value::Null);
            let payload = ctx.rpc("workspace.close", json!({"workspace_id":ws}))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "select-window" | "select-pane" => {
            let payload = ctx.rpc(
                if c == "select-window" {
                    "workspace.select"
                } else {
                    "surface.focus"
                },
                Value::Object(target(ctx, args, true)?),
            )?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "list-panes" | "list-windows" | "list-sessions" => {
            let m = if c == "list-panes" {
                "pane.list"
            } else {
                "workspace.list"
            };
            let payload = ctx.rpc(m, Value::Object(target(ctx, args, false)?))?;
            emit(ctx, payload, "")?;
            Ok(Some(0))
        }
        "last-window" | "next-window" | "previous-window" => {
            let m = match c {
                "last-window" => "workspace.last",
                "next-window" => "workspace.next",
                _ => "workspace.previous",
            };
            let payload = ctx.rpc(m, Value::Object(target(ctx, args, false)?))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "last-pane" => {
            let payload = ctx.rpc("pane.last", Value::Object(target(ctx, args, false)?))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "swap-pane" => {
            let mut p = target(ctx, args, true)?;
            if let Some(v) = value(args, "--pane")? {
                p.insert("pane_id".into(), json!(v));
            }
            if let Some(v) = value(args, "--target-pane")? {
                p.insert("target_pane_id".into(), json!(v));
            }
            let payload = ctx.rpc("pane.swap", Value::Object(p))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "break-pane" => {
            let payload = ctx.rpc("pane.break", Value::Object(target(ctx, args, true)?))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "join-pane" => {
            let mut p = target(ctx, args, true)?;
            if let Some(v) = value(args, "--target-pane")? {
                p.insert("target_pane_id".into(), json!(v));
            }
            let payload = ctx.rpc("pane.join", Value::Object(p))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "find-window" => {
            let payload = ctx.rpc("workspace.list", Value::Object(target(ctx, args, false)?))?;
            emit(ctx, payload, "")?;
            Ok(Some(0))
        }
        "rename-session" | "rename-window" => {
            let title = args
                .iter()
                .rev()
                .find(|a| !a.starts_with('-'))
                .cloned()
                .ok_or_else(|| usage(format!("{c} requires a name")))?;
            let mut p = target(ctx, args, false)?;
            p.insert("title".into(), json!(title));
            let payload = ctx.rpc("workspace.rename", Value::Object(p))?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "select-layout" => {
            let payload = ctx.rpc(
                "workspace.equalize_splits",
                Value::Object(target(ctx, args, false)?),
            )?;
            emit(ctx, payload, "OK")?;
            Ok(Some(0))
        }
        "pipe-pane" => pipe_pane(ctx, args),
        "wait-for" => wait_for(args),
        _ => Err(CliError::new(
            "unsupported",
            format!("{c} is not supported by cmux tmux compatibility"),
        )),
    }
}
fn pipe_pane(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let command = value(args, "--command")?
        .or_else(|| {
            let tail = args
                .iter()
                .filter(|a| !a.starts_with('-'))
                .cloned()
                .collect::<Vec<_>>();
            (!tail.is_empty()).then(|| tail.join(" "))
        })
        .ok_or_else(|| usage("pipe-pane requires --command <shell-command>"))?;
    let mut p = target(ctx, args, true)?;
    p.insert("scrollback".into(), json!(true));
    let source = ctx.rpc("surface.read_text", Value::Object(p))?;
    let text = source.get("text").and_then(Value::as_str).unwrap_or("");
    let mut child = Command::new("/bin/sh")
        .arg("-lc")
        .arg(&command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| CliError::new("pipe.exec", e.to_string()))?;
    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        stdin
            .write_all(text.as_bytes())
            .map_err(|e| CliError::new("pipe.write", e.to_string()))?;
    }
    let output = child
        .wait_with_output()
        .map_err(|e| CliError::new("pipe.exec", e.to_string()))?;
    if !output.status.success() {
        return Err(CliError::new(
            "pipe.failed",
            String::from_utf8_lossy(&output.stderr).to_string(),
        ));
    }
    if ctx.json {
        ctx.emit(&json!({"ok":true,"status":0,"stdout":String::from_utf8_lossy(&output.stdout),"stderr":String::from_utf8_lossy(&output.stderr)}))?;
    } else {
        ctx.print(String::from_utf8_lossy(&output.stdout).to_string())?;
    }
    Ok(Some(0))
}

fn expand_path(v: &str) -> String {
    if v == "~" {
        return env::var("HOME").unwrap_or_else(|_| v.into());
    }
    if let Some(x) = v.strip_prefix("~/") {
        return env::var("HOME")
            .map(|h| format!("{h}/{x}"))
            .unwrap_or_else(|_| v.into());
    }
    v.into()
}
fn format_tmux(f: &str, id: &str) -> String {
    f.replace("#{pane_id}", id)
        .replace("#{workspace_id}", id)
        .replace("#{session_id}", id)
}
fn special_key(k: &str) -> Option<String> {
    match k.to_ascii_uppercase().as_str() {
        "ENTER" => Some("\r".into()),
        "TAB" => Some("\t".into()),
        "ESC" => Some("\x1b".into()),
        "SPACE" => Some(" ".into()),
        "BSPACE" => Some("\x08".into()),
        "UP" => Some("\x1b[A".into()),
        "DOWN" => Some("\x1b[B".into()),
        "LEFT" => Some("\x1b[D".into()),
        "RIGHT" => Some("\x1b[C".into()),
        _ => None,
    }
}
fn wait_for(args: &[String]) -> Result<Option<i32>> {
    let n = args
        .iter()
        .find(|a| !a.starts_with('-'))
        .ok_or_else(|| usage("wait-for requires a name"))?;
    let p = env::temp_dir().join(format!("cmux-wait-{}", n.replace('/', "_")));
    if has(args, "-S") || has(args, "--signal") {
        fs::write(&p, [])?;
        return Ok(Some(0));
    }
    let t = std::time::Instant::now()
        + std::time::Duration::from_secs(
            value(args, "--timeout")?
                .and_then(|x| x.parse().ok())
                .unwrap_or(30),
        );
    while std::time::Instant::now() < t {
        if p.exists() {
            let _ = fs::remove_file(&p);
            return Ok(Some(0));
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    Err(CliError::new(
        "timeout",
        format!("wait-for timed out waiting for '{n}'"),
    ))
}
fn local_tmux(ctx: &Context, args: &[String], alias: bool) -> Result<Option<i32>> {
    let a = args.first().map(String::as_str).unwrap_or("attach");
    if alias && a != "attach" && a != "open" {
        return Err(usage(
            "tmux alias only supports attach; use local-tmux for lifecycle operations",
        ));
    }
    let n = args.iter().skip(1).find(|x| !x.starts_with('-')).cloned();
    if has(args, "--headless") || (alias && !has(args, "--workspace") && !has(args, "--surface")) {
        return local_tmux_exec(a, n, args);
    }
    if matches!(a, "attach" | "open") {
        let ws = match value(args, "--workspace")? {
            Some(v) => ctx.resolve_id("workspace", Some(&v))?,
            None => ctx.resolve_id("workspace", None)?,
        }
        .ok_or_else(|| {
            CliError::new(
                "local-tmux.workspace",
                "local-tmux attach requires a workspace target",
            )
        })?;
        let surface = match value(args, "--surface")? {
            Some(v) => ctx.resolve_id("surface", Some(&v))?,
            None => ctx.resolve_id("surface", None)?,
        }
        .ok_or_else(|| {
            CliError::new(
                "local-tmux.surface",
                "local-tmux attach requires a surface target",
            )
        })?;
        let socket = local_tmux_socket();
        let name = n.ok_or_else(|| usage("local-tmux attach requires a session name or --id"))?;
        let command = format!(
            "tmux -S {} attach-session -t {}\r",
            shell_quote(&socket),
            shell_quote(&name)
        );
        let payload = ctx.rpc(
            "surface.send_text",
            json!({"workspace_id":ws,"surface_id":surface,"text":command}),
        )?;
        emit(ctx, payload, "OK")?;
        return Ok(Some(0));
    }
    local_tmux_exec(a, n, args)
}
fn local_tmux_socket() -> String {
    env::var("CMUX_LOCAL_TMUX_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env::var("HOME").unwrap_or_else(|_| ".".into())).join(".cmux/local-tmux")
        })
        .join("server.sock")
        .to_string_lossy()
        .into_owned()
}
fn shell_quote(v: &str) -> String {
    format!("'{}'", v.replace("'", "'\\''"))
}

fn local_tmux_exec(a: &str, n: Option<String>, args: &[String]) -> Result<Option<i32>> {
    let root = env::var("CMUX_LOCAL_TMUX_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env::var("HOME").unwrap_or_else(|_| ".".into())).join(".cmux/local-tmux")
        });
    fs::create_dir_all(&root)?;
    let socket = root.join("server.sock");
    let tmux = env::var("CMUX_TMUX_PATH").unwrap_or_else(|_| "tmux".into());
    let mut c = Command::new(tmux);
    c.arg("-S").arg(socket.to_string_lossy().to_string());
    match a {
        "start" | "create" => {
            let name = n.ok_or_else(|| usage("local-tmux start requires a session name"))?;
            c.args(["new-session", "-A", "-s"]).arg(&name);
            if let Some(v) = value(args, "--cwd")? {
                c.arg("-c").arg(expand_path(&v));
            }
            if let Some(v) = value(args, "--command")? {
                c.args(["/bin/sh", "-lc"]).arg(v);
            }
        }
        "attach" | "open" => {
            c.args(["attach-session", "-t"])
                .arg(n.as_deref().unwrap_or(""));
        }
        "list" | "ls" | "status" | "info" => {
            c.arg("list-sessions");
        }
        "detach" => {
            c.arg("detach-client");
        }
        "close" | "kill" | "delete" => {
            c.args(["kill-session", "-t"])
                .arg(n.as_deref().unwrap_or(""));
        }
        "cleanup" | "prune" => {
            c.arg("list-sessions");
        }
        _ => return Err(usage(format!("unknown local-tmux action `{a}`"))),
    }
    let s = c
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|e| CliError::new("exec", format!("unable to run tmux: {e}")))?;
    Ok(Some(s.code().unwrap_or(1)))
}
fn ssh_exec(command: &str, args: &[String]) -> Result<Option<i32>> {
    let b = if command == "mosh" { "mosh" } else { "ssh" };
    let s = Command::new(b)
        .args(args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|e| CliError::new("ssh.exec", format!("unable to run {b}: {e}")))?;
    Ok(Some(s.code().unwrap_or(1)))
}
fn remote_tmux(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>> {
    let h = args
        .iter()
        .find(|a| !a.starts_with('-'))
        .ok_or_else(|| usage(format!("{command} requires a destination")))?;
    let p = ctx.rpc(
        "remote.tmux.mirror",
        json!({"host":h,"activate":!has(args,"--no-focus"),"new_window":has(args,"--new-window")}),
    )?;
    emit(ctx, p, "OK")?;
    Ok(Some(0))
}
fn ssh_session(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>> {
    let m = match command {
        "ssh-session-list" => "workspace.remote.pty_sessions",
        "ssh-session-cleanup" => "workspace.remote.pty_close",
        "ssh-session-end" => "workspace.remote.terminal_session_end",
        _ => "surface.ssh_session_attach.resolve",
    };
    let mut p = Map::new();
    if let Some(v) = args.first() {
        p.insert("session_id".into(), json!(v));
    }
    let payload = ctx.rpc(m, Value::Object(p))?;
    emit(ctx, payload, "OK")?;
    Ok(Some(0))
}
fn ssh_pty_attach(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let mut p = Map::new();
    if let Some(v) = value(args, "--session-id")? {
        p.insert("session_id".into(), json!(v));
    }
    if let Some(v) = value(args, "--lifecycle-id")? {
        p.insert("lifecycle_id".into(), json!(v));
    }
    let payload = ctx.rpc("workspace.remote.pty_bridge", Value::Object(p))?;
    emit(ctx, payload, "OK")?;
    Ok(Some(0))
}
