//! Terminal I/O and process diagnostics commands.
//!
//! These commands intentionally keep the socket method names and parameter
//! shapes used by the Swift CLI.  The Rust CLI is only a transport/parser
//! owner; rendering remains a thin compatibility layer around the response.

use std::env;
use std::io::Write;
use std::process::{Command, Stdio};

use serde_json::{Map, Value, json};

use crate::{CliError, Context, Result};

pub fn run(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>> {
    match command {
        "read-selection" => {
            read_selection(ctx, args, true)?;
        }
        "read-screen" => {
            read_screen(ctx, args)?;
        }
        "send" => {
            send(ctx, args, false)?;
        }
        "send-key" => {
            send_key(ctx, args, false)?;
        }
        "send-panel" => {
            send(ctx, args, true)?;
        }
        "send-key-panel" => {
            send_key(ctx, args, true)?;
        }
        "capture-pane" => {
            read_screen(ctx, args)?;
        }
        "clear-history" => {
            clear_history(ctx, args)?;
        }
        "pipe-pane" => {
            pipe_pane(ctx, args)?;
        }
        "surface-health" => {
            surface_health(ctx, args)?;
        }
        "debug-terminals" => {
            debug_terminals(ctx, args)?;
        }
        "top" => {
            top(ctx, args)?;
        }
        "memory" => {
            memory(ctx, args)?;
        }
        _ => return Ok(None),
    }
    Ok(Some(0))
}

fn usage(msg: impl Into<String>) -> CliError {
    CliError::usage(msg.into())
}

fn option(args: &[String], name: &str) -> Result<(Option<String>, Vec<String>)> {
    let mut result = None;
    let mut rest = Vec::with_capacity(args.len());
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if arg == name {
            if result.is_some() {
                return Err(usage(format!("duplicate option {name}")));
            }
            let value = args
                .get(i + 1)
                .ok_or_else(|| usage(format!("{name} requires a value")))?;
            if value.starts_with('-') && value != "-" {
                return Err(usage(format!("{name} requires a value")));
            }
            result = Some(value.clone());
            i += 2;
        } else if let Some(value) = arg.strip_prefix(&format!("{name}=")) {
            if result.is_some() {
                return Err(usage(format!("duplicate option {name}")));
            }
            result = Some(value.to_string());
            i += 1;
        } else {
            rest.push(arg.clone());
            i += 1;
        }
    }
    Ok((result, rest))
}

fn flag(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn target(
    ctx: &Context,
    args: &[String],
    panel: bool,
    allow_focused_surface: bool,
) -> Result<(Map<String, Value>, Vec<String>)> {
    let (workspace, rem) = option(args, "--workspace")?;
    let (surface, rem) = if panel {
        option(&rem, "--panel")?
    } else {
        option(&rem, "--surface")?
    };
    let (window, rem) = option(&rem, "--window")?;
    let mut params = Map::new();
    if let Some(raw) = window.as_deref().or(ctx.window.as_deref()) {
        if let Some(id) = ctx.resolve_id("window", Some(raw))? {
            params.insert("window_id".into(), json!(id));
        }
    }
    if let Some(raw) = workspace.as_deref() {
        if let Some(id) = ctx.resolve_id("workspace", Some(raw))? {
            params.insert("workspace_id".into(), json!(id));
        }
    } else if window.is_none() && ctx.window.is_none() {
        if let Some(id) = ctx.resolve_id("workspace", None)? {
            params.insert("workspace_id".into(), json!(id));
        }
    }
    if let Some(raw) = surface.as_deref() {
        if let Some(id) = ctx.resolve_id("surface", Some(raw))? {
            params.insert("surface_id".into(), json!(id));
        }
    } else if allow_focused_surface {
        if let Some(id) = ctx.resolve_id("surface", None)? {
            params.insert("surface_id".into(), json!(id));
        }
    } else if workspace.is_none() && window.is_none() && ctx.window.is_none() {
        if let Some(id) = ctx.resolve_id("surface", None)? {
            params.insert("surface_id".into(), json!(id));
        }
    }
    Ok((params, rem))
}

fn emit_or_text(ctx: &Context, payload: Value, text: impl FnOnce(&Value) -> String) -> Result<()> {
    if ctx.json {
        ctx.emit(&payload)
    } else {
        ctx.print(text(&payload))
    }
}

fn read_selection(ctx: &Context, args: &[String], include_context: bool) -> Result<()> {
    let (mut params, rem) = target(ctx, args, false, false)?;
    if !rem.is_empty() {
        return Err(usage(format!(
            "read-selection: unexpected arguments: {}",
            rem.join(" ")
        )));
    }
    let payload = ctx.rpc(
        "surface.read_selection",
        Value::Object(std::mem::take(&mut params)),
    )?;
    if ctx.json {
        return ctx.emit(&payload);
    }
    let has = payload
        .get("has_selection")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !has {
        if include_context {
            let mut lines = Vec::new();
            if let Some(v) = payload
                .get("kind")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                lines.push(format!("Kind: {v}"));
            }
            if let Some(v) = payload
                .get("file_path")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                lines.push(format!("File: {v}"));
            }
            if !lines.is_empty() {
                ctx.print(format!("{}\n", lines.join("\n")))?;
            }
        }
        return ctx.print("Has selection: false");
    }
    if include_context {
        let mut lines = Vec::new();
        if let Some(v) = payload
            .get("kind")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            lines.push(format!("Kind: {v}"));
        }
        if let Some(v) = payload
            .get("file_path")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            lines.push(format!("File: {v}"));
        }
        if let Some(range) = payload.get("line_range").and_then(Value::as_object) {
            if let (Some(a), Some(b)) = (
                range.get("start").and_then(Value::as_i64),
                range.get("end").and_then(Value::as_i64),
            ) {
                lines.push(if a == b {
                    format!("Line: {a}")
                } else {
                    format!("Lines: {a}-{b}")
                });
            }
        }
        if let Some(v) = payload
            .get("url")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            lines.push(format!("URL: {v}"));
        }
        if !lines.is_empty() {
            ctx.print(format!("{}\n\n", lines.join("\n")))?;
        }
    }
    ctx.print(payload.get("text").and_then(Value::as_str).unwrap_or(""))
}

fn read_screen(ctx: &Context, args: &[String]) -> Result<()> {
    if flag(args, "--selection") {
        if flag(args, "--scrollback")
            || args
                .iter()
                .any(|a| a == "--lines" || a.starts_with("--lines="))
        {
            return Err(usage(
                "read-screen: --selection cannot be combined with --scrollback or --lines",
            ));
        }
        let filtered: Vec<String> = args
            .iter()
            .filter(|a| a.as_str() != "--selection")
            .cloned()
            .collect();
        return read_selection(ctx, &filtered, false);
    }
    let (mut params, rem0) = target(ctx, args, false, false)?;
    let (lines, rem) = option(&rem0, "--lines")?;
    let scrollback = flag(&rem, "--scrollback");
    let trailing: Vec<_> = rem.into_iter().filter(|a| a != "--scrollback").collect();
    if !trailing.is_empty() {
        return Err(usage(format!(
            "read-screen: unexpected arguments: {}",
            trailing.join(" ")
        )));
    }
    if scrollback {
        params.insert("scrollback".into(), json!(true));
    }
    if let Some(raw) = lines {
        let n: i64 = raw
            .parse()
            .map_err(|_| usage("--lines must be greater than 0"))?;
        if n <= 0 {
            return Err(usage("--lines must be greater than 0"));
        }
        params.insert("lines".into(), json!(n));
        params.insert("scrollback".into(), json!(true));
    }
    let payload = ctx.rpc("surface.read_text", Value::Object(params))?;
    emit_or_text(ctx, payload, |v| {
        v.get("text")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    })
}

fn unescape(text: &str) -> String {
    text.replace("\\n", "\r")
        .replace("\\r", "\r")
        .replace("\\t", "\t")
}

fn send(ctx: &Context, args: &[String], panel: bool) -> Result<()> {
    let (mut params, rem) = target(ctx, args, panel, false)?;
    let mut rem = rem;
    if rem.first().map(String::as_str) == Some("--") {
        rem.remove(0);
    }
    if rem.is_empty() {
        return Err(usage(if panel {
            "send-panel requires text"
        } else {
            "send requires text"
        }));
    }
    params.insert("text".into(), json!(unescape(&rem.join(" "))));
    let payload = ctx.rpc("surface.send_text", Value::Object(params))?;
    emit_or_text(ctx, payload, |_| "OK".to_string())
}

fn send_key(ctx: &Context, args: &[String], panel: bool) -> Result<()> {
    let (mut params, rem) = target(ctx, args, panel, false)?;
    let mut rem = rem;
    if rem.first().map(String::as_str) == Some("--") {
        rem.remove(0);
    }
    let key = rem.first().ok_or_else(|| {
        usage(if panel {
            "send-key-panel requires a key"
        } else {
            "send-key requires a key"
        })
    })?;
    params.insert("key".into(), json!(key));
    let payload = ctx.rpc("surface.send_key", Value::Object(params))?;
    emit_or_text(ctx, payload, |_| "OK".to_string())
}

fn clear_history(ctx: &Context, args: &[String]) -> Result<()> {
    let (params, rem) = target(ctx, args, false, true)?;
    if !rem.is_empty() {
        return Err(usage(format!(
            "clear-history: unexpected arguments: {}",
            rem.join(" ")
        )));
    }
    let payload = ctx.rpc("surface.clear_history", Value::Object(params))?;
    emit_or_text(ctx, payload, |_| "OK".to_string())
}

fn pipe_pane(ctx: &Context, args: &[String]) -> Result<()> {
    let (params, rem0) = target(ctx, args, false, true)?;
    let (command, rem) = option(&rem0, "--command")?;
    let command = command
        .or_else(|| {
            let mut r = rem.clone();
            if r.first().map(String::as_str) == Some("--") {
                r.remove(0);
            }
            let s = r.join(" ").trim().to_string();
            if s.is_empty() { None } else { Some(s) }
        })
        .ok_or_else(|| usage("pipe-pane requires --command <shell-command>"))?;
    let payload = ctx.rpc(
        "surface.read_text",
        Value::Object({
            let mut p = params.clone();
            p.insert("scrollback".into(), json!(true));
            p
        }),
    )?;
    let input = payload.get("text").and_then(Value::as_str).unwrap_or("");
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(&command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child.stdin.take().unwrap().write_all(input.as_bytes())?;
    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(CliError::new(
            "command_failed",
            format!(
                "pipe-pane command failed ({}): {}",
                output.status.code().unwrap_or(1),
                String::from_utf8_lossy(&output.stderr)
            ),
        ));
    }
    if ctx.json {
        ctx.emit(&json!({"ok":true,"status":output.status.code().unwrap_or(0),"stdout":String::from_utf8_lossy(&output.stdout),"stderr":String::from_utf8_lossy(&output.stderr)}))
    } else {
        let out = String::from_utf8_lossy(&output.stdout);
        if !out.is_empty() {
            ctx.print(out.as_ref())?;
        }
        ctx.print("OK")
    }
}

fn surface_health(ctx: &Context, args: &[String]) -> Result<()> {
    let (params, rem) = target(ctx, args, false, false)?;
    if !rem.is_empty() {
        return Err(usage(format!(
            "surface-health: unexpected arguments: {}",
            rem.join(" ")
        )));
    }
    let payload = ctx.rpc("surface.health", Value::Object(params))?;
    if ctx.json {
        return ctx.emit(&payload);
    }
    let surfaces = payload
        .get("surfaces")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if surfaces.is_empty() {
        return ctx.print("No surfaces");
    }
    let mut lines = Vec::new();
    for s in surfaces {
        let handle = s
            .get("ref")
            .or_else(|| s.get("id"))
            .and_then(Value::as_str)
            .unwrap_or("?");
        let ty = s.get("type").and_then(Value::as_str).unwrap_or("");
        let in_window = s
            .get("in_window")
            .map(|v| format!(" in_window={v}"))
            .unwrap_or_default();
        let socket = s
            .get("socket_binding")
            .and_then(Value::as_str)
            .map(|v| format!(" socket_binding={v}"))
            .unwrap_or_default();
        lines.push(format!("{handle}  type={ty}{in_window}{socket}"));
    }
    ctx.print(lines.join("\n"))
}

fn debug_terminals(ctx: &Context, args: &[String]) -> Result<()> {
    if args.iter().any(|a| a != "--") {
        return Err(usage(format!(
            "debug-terminals: unexpected argument '{}'",
            args.iter().find(|a| a.as_str() != "--").unwrap()
        )));
    }
    let payload = ctx.rpc("debug.terminals", json!({}))?;
    if ctx.json {
        return ctx.emit(&payload);
    }
    let terms = payload
        .get("terminals")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if terms.is_empty() {
        return ctx.print("No terminal surfaces");
    }
    let mut lines = Vec::new();
    for item in terms {
        let i = item.get("index").and_then(Value::as_i64).unwrap_or(0);
        let surface = item
            .get("surface_ref")
            .or_else(|| item.get("surface_id"))
            .and_then(Value::as_str)
            .unwrap_or("?");
        let title = item
            .get("surface_title")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(|s| format!(" \"{}\"", s.replace('"', "\\\"")))
            .unwrap_or_default();
        lines.push(format!("[{i}] {surface}{title}"));
        lines.push(format!(
            "    mapped={} tree={} window={} workspace={} pane={}",
            dbg(&item, "mapped"),
            dbg(&item, "tree_visible"),
            dbgstr(&item, "window_ref"),
            dbgstr(&item, "workspace_ref"),
            dbgstr(&item, "pane_ref")
        ));
        lines.push(format!(
            "    runtime={} focused={} selected={} tty={} cwd={}",
            dbg(&item, "runtime_surface_ready"),
            dbg(&item, "surface_focused"),
            dbg(&item, "surface_selected_in_pane"),
            dbgstr(&item, "tty"),
            dbgstr(&item, "current_directory")
        ));
    }
    ctx.print(lines.join("\n"))
}

fn dbg(v: &Value, k: &str) -> String {
    v.get(k)
        .map(|x| x.to_string())
        .unwrap_or_else(|| "nil".into())
}
fn dbgstr(v: &Value, k: &str) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or("nil").into()
}

fn caller_context() -> Option<Value> {
    let mut caller = Map::new();
    if let Ok(v) = env::var("CMUX_WORKSPACE_ID") {
        if !v.trim().is_empty() {
            caller.insert("workspace_id".into(), json!(v));
        }
    }
    if let Ok(v) = env::var("CMUX_SURFACE_ID") {
        if !v.trim().is_empty() {
            caller.insert("surface_id".into(), json!(v));
        }
    }
    (!caller.is_empty()).then_some(Value::Object(caller))
}

fn top(ctx: &Context, args: &[String]) -> Result<()> {
    let (workspace, rem0) = option(args, "--workspace")?;
    let (window, rem1) = option(&rem0, "--window")?;
    let (sort, rem2) = option(&rem1, "--sort")?;
    let (format, rem3) = option(&rem2, "--format")?;
    let all = flag(&rem3, "--all");
    let processes = flag(&rem3, "--processes");
    let flat = flag(&rem3, "--flat");
    let local_json = flag(&rem3, "--json");
    let rest: Vec<_> = rem3
        .into_iter()
        .filter(|a| !matches!(a.as_str(), "--all" | "--processes" | "--flat" | "--json"))
        .collect();
    if !rest.is_empty() {
        return Err(usage(format!("top: unexpected argument '{}'", rest[0])));
    }
    if all && window.is_some() {
        return Err(usage("top: --window cannot be combined with --all"));
    }
    if (ctx.json || local_json) && (sort.is_some() || flat || format.is_some()) {
        return Err(usage(
            "top: text-only options cannot be combined with --json",
        ));
    }
    let mut params = Map::new();
    params.insert("all_windows".into(), json!(all));
    params.insert("include_processes".into(), json!(processes));
    if let Some(raw) = window.as_deref() {
        if let Some(id) = ctx.resolve_id("window", Some(raw))? {
            params.insert("window_id".into(), json!(id));
        }
    }
    if let Some(raw) = workspace.as_deref() {
        if let Some(id) = ctx.resolve_id("workspace", Some(raw))? {
            params.insert("workspace_id".into(), json!(id));
        } else {
            return Err(usage(format!("top: invalid workspace handle '{raw}'")));
        }
    }
    if let Some(caller) = caller_context() {
        params.insert("caller".into(), caller);
    }
    let payload = ctx.rpc("system.top", Value::Object(params))?;
    if ctx.json || local_json {
        return ctx.emit(&payload);
    }
    if flat || format.as_deref() == Some("tsv") {
        return render_top_tsv(ctx, &payload);
    }
    render_top_tree(ctx, &payload)
}

fn render_top_tree(ctx: &Context, payload: &Value) -> Result<()> {
    let windows = payload
        .get("windows")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if windows.is_empty() {
        return ctx.print("No windows");
    }
    let mut lines = vec!["  CPU%    MEMORY  PROC  NODE".into()];
    for w in windows {
        lines.push(format!(
            "{}  window {}",
            resource(w.get("resources")),
            handle(w)
        ));
        for ws in w
            .get("workspaces")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            lines.push(format!(
                "└── {} workspace {}",
                resource(ws.get("resources")),
                handle(ws)
            ));
        }
    }
    ctx.print(lines.join("\n"))
}
fn render_top_tsv(ctx: &Context, payload: &Value) -> Result<()> {
    let windows = payload
        .get("windows")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut lines =
        vec!["cpu_percent\tmemory_bytes\tprocess_count\tkind\tref\tparent_ref\ttitle".into()];
    for w in windows {
        let r = w.get("resources").cloned().unwrap_or(json!({}));
        lines.push(format!(
            "{}\t{}\t{}\twindow\t{}\ttotal\t",
            num(&r, "cpu_percent"),
            num(&r, "memory_bytes"),
            num(&r, "process_count"),
            handle(w)
        ));
    }
    ctx.print(lines.join("\n"))
}
fn resource(r: Option<&Value>) -> String {
    let r = r.and_then(Value::as_object);
    format!(
        "{:>6} {:>9} {:>5}",
        r.and_then(|x| x.get("cpu_percent"))
            .map(|x| x.to_string())
            .unwrap_or("0".into()),
        r.and_then(|x| x.get("memory_bytes"))
            .map(|x| x.to_string())
            .unwrap_or("0".into()),
        r.and_then(|x| x.get("process_count"))
            .map(|x| x.to_string())
            .unwrap_or("0".into())
    )
}
fn num(v: &Value, k: &str) -> String {
    v.get(k)
        .map(|x| x.to_string())
        .unwrap_or_else(|| "0".into())
}
fn handle(v: &Value) -> String {
    v.get("ref")
        .or_else(|| v.get("id"))
        .and_then(Value::as_str)
        .unwrap_or("?")
        .into()
}

fn memory(ctx: &Context, args: &[String]) -> Result<()> {
    let (workspace, rem) = option(args, "--workspace")?;
    let (groups, rem) = option(&rem, "--groups")?;
    let all = flag(&rem, "--all");
    let local_json = flag(&rem, "--json");
    let rest: Vec<_> = rem
        .into_iter()
        .filter(|a| !matches!(a.as_str(), "--all" | "--json"))
        .collect();
    if !rest.is_empty() {
        return Err(usage(format!("memory: unexpected argument '{}'", rest[0])));
    }
    let limit: i64 = groups
        .as_deref()
        .unwrap_or("12")
        .parse()
        .map_err(|_| usage("memory: invalid --groups value"))?;
    if !(1..=100).contains(&limit) {
        return Err(usage("memory: invalid --groups value"));
    }
    let mut p = Map::new();
    p.insert("all_windows".into(), json!(all));
    p.insert("top_group_limit".into(), json!(limit));
    if let Some(raw) = workspace.as_deref() {
        if let Some(id) = ctx.resolve_id("workspace", Some(raw))? {
            p.insert("workspace_id".into(), json!(id));
        } else {
            return Err(usage(format!("memory: invalid workspace handle '{raw}'")));
        }
    }
    if let Some(caller) = caller_context() {
        p.insert("caller".into(), caller);
    }
    let payload = ctx.rpc("system.memory", Value::Object(p))?;
    if ctx.json || local_json {
        return ctx.emit(&payload);
    }
    render_memory(ctx, &payload)
}
fn render_memory(ctx: &Context, p: &Value) -> Result<()> {
    let d = p.get("memory_diagnostic").and_then(Value::as_object);
    let Some(d) = d else {
        return ctx.print("No memory diagnostic available");
    };
    let app = d.get("app").and_then(Value::as_object);
    let child = d.get("children").and_then(Value::as_object);
    let mut l = Vec::new();
    if let Some(s) = d
        .get("summary")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        l.push(s.into());
        l.push(String::new());
    }
    l.push("APP".into());
    l.push(format!(
        "  {} pid={}",
        app.and_then(|x| x.get("name"))
            .and_then(Value::as_str)
            .unwrap_or("cmux"),
        app.and_then(|x| x.get("pid"))
            .map(|x| x.to_string())
            .unwrap_or("?".into())
    ));
    l.push(format!(
        "  footprint {}",
        app.and_then(|x| x.get("physical_footprint_bytes"))
            .map(|x| x.to_string())
            .unwrap_or("?".into())
    ));
    l.push(format!(
        "  rss       {}",
        app.and_then(|x| x.get("resident_bytes"))
            .map(|x| x.to_string())
            .unwrap_or("?".into())
    ));
    l.push(String::new());
    l.push("CHILD PROCESSES".into());
    l.push(format!(
        "  recursive RSS {} across {} processes",
        child
            .and_then(|x| x.get("recursive_rss_bytes"))
            .map(|x| x.to_string())
            .unwrap_or("?".into()),
        child
            .and_then(|x| x.get("process_count"))
            .map(|x| x.to_string())
            .unwrap_or("0".into())
    ));
    ctx.print(l.join("\n"))
}
