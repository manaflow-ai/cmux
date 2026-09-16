//! Rust implementation of cmux workspace/window/pane/surface topology verbs.
use crate::{CliError, Context, Result};
use serde_json::{Map, Value, json};
fn opt(a: &[String], n: &str) -> Option<String> {
    let p = format!("{n}=");
    a.iter().enumerate().find_map(|(i, x)| {
        if x == n {
            a.get(i + 1).filter(|v| !v.starts_with("--")).cloned()
        } else if x.starts_with(&p) {
            Some(x[p.len()..].into())
        } else {
            None
        }
    })
}
fn has(a: &[String], n: &str) -> bool {
    a.iter().any(|x| x == n)
}
fn pos(a: &[String]) -> Vec<String> {
    let mut o = vec![];
    let mut skip = false;
    for x in a {
        if skip {
            skip = false;
            continue;
        }
        if x == "--" {
            break;
        }
        if x.starts_with("--") {
            if !x.contains('=') {
                skip = true
            }
        } else {
            o.push(x.clone())
        }
    }
    o
}
fn b(a: &[String], n: &str) -> Result<Option<bool>> {
    match opt(a, n) {
        None => Ok(None),
        Some(x) => match x.to_ascii_lowercase().as_str() {
            "true" | "1" | "yes" | "on" => Ok(Some(true)),
            "false" | "0" | "no" | "off" => Ok(Some(false)),
            _ => Err(CliError::new(
                "usage.invalid",
                format!("{n} must be true|false"),
            )),
        },
    }
}
fn rid(c: &Context, k: &str, v: Option<String>) -> Result<Option<String>> {
    c.resolve_id(k, v.as_deref())
}
fn ids(
    c: &Context,
    a: &[String],
    p: &mut Map<String, Value>,
    ws: bool,
    pane: bool,
    surf: bool,
) -> Result<()> {
    if let Some(v) = rid(c, "window", opt(a, "--window").or_else(|| c.window.clone()))? {
        p.insert("window_id".into(), json!(v));
    }
    if ws {
        if let Some(v) = rid(c, "workspace", opt(a, "--workspace"))? {
            p.insert("workspace_id".into(), json!(v));
        }
    }
    if pane {
        if let Some(v) = rid(c, "pane", opt(a, "--pane"))? {
            p.insert("pane_id".into(), json!(v));
        }
    }
    if surf {
        if let Some(v) = rid(
            c,
            "surface",
            opt(a, "--surface").or_else(|| opt(a, "--panel")),
        )? {
            p.insert("surface_id".into(), json!(v));
        }
    }
    Ok(())
}
fn emit(c: &Context, v: Value, text: &str) -> Result<Option<i32>> {
    if c.json || c.envelope {
        c.emit(&v)?
    } else {
        c.print(text)?
    }
    Ok(Some(0))
}
fn call(c: &Context, m: &str, p: Map<String, Value>, kind: &str) -> Result<Option<i32>> {
    let v = c.rpc(m, Value::Object(p))?;
    let txt = v
        .get(&format!("{kind}_ref"))
        .or_else(|| v.get(&format!("{kind}_id")))
        .and_then(Value::as_str)
        .map(|x| format!("OK {x}"))
        .unwrap_or_else(|| "OK".into());
    emit(c, v, &txt)
}
fn req(a: &[String], n: &str, u: &str) -> Result<String> {
    opt(a, n).ok_or_else(|| CliError::usage(format!("{u} requires {n}")))
}
fn move_fields(a: &[String], p: &mut Map<String, Value>) -> Result<()> {
    for (n, k) in [
        ("--before", "before_surface_id"),
        ("--after", "after_surface_id"),
        ("--before-surface", "before_surface_id"),
        ("--after-surface", "after_surface_id"),
    ] {
        if let Some(v) = opt(a, n) {
            p.insert(k.into(), json!(v));
        }
    }
    if let Some(v) = opt(a, "--index") {
        if v.parse::<i64>().is_err() {
            return Err(CliError::usage("--index must be an integer"));
        }
        p.insert("index".into(), json!(v.parse::<i64>().unwrap()));
    }
    if let Some(v) = b(a, "--focus")? {
        p.insert("focus".into(), json!(v));
    }
    Ok(())
}
fn ws(c: &Context, s: &str, a: &[String]) -> Result<Option<i32>> {
    let mut p = Map::new();
    match s {
        "list" | "ls" => {
            ids(c, a, &mut p, false, false, false)?;
            call(c, "workspace.list", p, "workspace")
        }
        "create" | "new" => {
            ids(c, a, &mut p, false, false, false)?;
            for (n, k) in [
                ("--name", "title"),
                ("--description", "description"),
                ("--cwd", "cwd"),
                ("--layout", "layout"),
                ("--group", "group_id"),
                ("--group-placement", "group_placement"),
                ("--group-reference", "group_reference_workspace_id"),
            ] {
                if let Some(v) = opt(a, n) {
                    p.insert(k.into(), json!(v));
                }
            }
            if let Some(v) = opt(a, "--command") {
                p.insert("initial_input".into(), json!(format!("{v}\r")));
            }
            if let Some(v) = b(a, "--focus")? {
                p.insert("focus".into(), json!(v));
            }
            call(c, "workspace.create", p, "workspace")
        }
        "close" | "rm" | "delete" => {
            ids(c, a, &mut p, true, false, false)?;
            call(c, "workspace.close", p, "workspace")
        }
        "select" | "focus" => {
            ids(c, a, &mut p, true, false, false)?;
            call(c, "workspace.select", p, "workspace")
        }
        "rename" => {
            ids(c, a, &mut p, true, false, false)?;
            p.insert(
                "name".into(),
                json!(
                    opt(a, "--name")
                        .or_else(|| pos(a).first().cloned())
                        .ok_or_else(|| CliError::usage("workspace rename requires a name"))?
                ),
            );
            call(c, "workspace.rename", p, "workspace")
        }
        "env" => {
            ids(c, a, &mut p, true, false, false)?;
            if has(a, "--mask") {
                p.insert("mask".into(), json!(true));
            }
            call(c, "workspace.env", p, "workspace")
        }
        "status" => {
            ids(c, a, &mut p, true, false, false)?;
            let sub = pos(a).first().cloned().unwrap_or_else(|| "get".into());
            let m = match sub.as_str() {
                "set" => "workspace.status.set",
                "cycle" => "workspace.status.cycle",
                _ => "workspace.status.get",
            };
            call(c, m, p, "workspace")
        }
        "reconnect" | "disconnect" => {
            ids(c, a, &mut p, true, false, false)?;
            call(c, &format!("workspace.remote.{s}"), p, "workspace")
        }
        "group" => group(c, &a[1..]),
        _ => Err(CliError::usage(format!(
            "unknown workspace subcommand: {s}"
        ))),
    }
}
fn group(c: &Context, a: &[String]) -> Result<Option<i32>> {
    let s = pos(a)
        .first()
        .cloned()
        .ok_or_else(|| CliError::usage("workspace group requires a subcommand"))?;
    let mut p = Map::new();
    ids(c, a, &mut p, false, false, false)?;
    let gid = || opt(a, "--group").or_else(|| pos(&a[1..]).first().cloned());
    match s.as_str() {
        "list" | "ls" => call(c, "workspace.group.list", p, "group"),
        "create" => {
            if let Some(v) = opt(a, "--name").or_else(|| pos(&a[1..]).first().cloned()) {
                p.insert("name".into(), json!(v));
            }
            call(c, "workspace.group.create", p, "group")
        }
        "ungroup" | "delete" | "collapse" | "expand" | "pin" | "unpin" => {
            p.insert(
                "group_id".into(),
                json!(gid().ok_or_else(|| CliError::usage("workspace group requires a group id"))?),
            );
            if has(a, "--close-workspaces") {
                p.insert("close_workspaces".into(), json!(true));
            }
            let m = if s == "delete" && has(a, "--close-workspaces") {
                "workspace.group.delete"
            } else {
                Box::leak(format!("workspace.group.{s}").into_boxed_str())
            };
            call(c, m, p, "group")
        }
        "rename" => {
            p.insert(
                "group_id".into(),
                json!(gid().ok_or_else(|| CliError::usage("workspace group requires a group id"))?),
            );
            p.insert(
                "name".into(),
                json!(req(a, "--name", "workspace group rename")?),
            );
            call(c, "workspace.group.rename", p, "group")
        }
        "add" | "set-anchor" => {
            p.insert(
                "group_id".into(),
                json!(req(a, "--group", "workspace group")?),
            );
            p.insert(
                "workspace_id".into(),
                json!(req(a, "--workspace", "workspace group")?),
            );
            call(
                c,
                if s == "add" {
                    "workspace.group.add"
                } else {
                    "workspace.group.set_anchor"
                },
                p,
                "group",
            )
        }
        "remove" => {
            p.insert(
                "workspace_id".into(),
                json!(req(a, "--workspace", "workspace group")?),
            );
            call(c, "workspace.group.remove", p, "group")
        }
        "new-workspace" => {
            p.insert(
                "group_id".into(),
                json!(gid().ok_or_else(|| CliError::usage("workspace group requires a group id"))?),
            );
            call(c, "workspace.group.new_workspace", p, "workspace")
        }
        "set-color" => {
            p.insert(
                "group_id".into(),
                json!(gid().ok_or_else(|| CliError::usage("workspace group requires a group id"))?),
            );
            p.insert("hex".into(), json!(opt(a, "--hex").unwrap_or_default()));
            call(c, "workspace.group.set_color", p, "group")
        }
        "set-icon" => {
            p.insert(
                "group_id".into(),
                json!(gid().ok_or_else(|| CliError::usage("workspace group requires a group id"))?),
            );
            if let Some(v) = opt(a, "--icon") {
                p.insert("icon".into(), json!(v));
            }
            call(c, "workspace.group.set_icon", p, "group")
        }
        _ => Err(CliError::usage(format!(
            "unknown workspace group subcommand: {s}"
        ))),
    }
}
fn window(c: &Context, s: &str, a: &[String]) -> Result<Option<i32>> {
    match s {
        "list" | "ls" => {
            let v = c.rpc("window.list", json!({}))?;
            emit(c, v, "No windows")
        }
        "current" => {
            let v = c.rpc("window.current", json!({}))?;
            emit(c, v, "")
        }
        "create" | "new" => {
            let v = c.raw("new_window")?;
            c.print(v)?;
            Ok(Some(0))
        }
        "focus" | "close" => {
            let w = rid(
                c,
                "window",
                Some(req(a, "--window", &format!("window {s}"))?),
            )?
            .unwrap();
            let v = c.raw(&format!("{s}_window {v}", v = w))?;
            c.print(v)?;
            Ok(Some(0))
        }
        _ => Err(CliError::usage(format!("unknown window subcommand: {s}"))),
    }
}
fn pane(c: &Context, s: &str, a: &[String]) -> Result<Option<i32>> {
    let mut p = Map::new();
    ids(c, a, &mut p, true, s == "surfaces", false)?;
    match s {
        "list" | "ls" => call(c, "pane.list", p, "pane"),
        "surfaces" => call(c, "pane.surfaces", p, "surface"),
        "focus" => call(c, "pane.focus", p, "pane"),
        "create" | "new" => {
            for (n, k) in [
                ("--type", "type"),
                ("--direction", "direction"),
                ("--url", "url"),
                ("--placement", "placement"),
            ] {
                if let Some(v) = opt(a, n) {
                    p.insert(k.into(), json!(v));
                }
            }
            if let Some(v) = opt(a, "--command") {
                p.insert("initial_input".into(), json!(format!("{v}\r")));
            }
            call(c, "pane.create", p, "pane")
        }
        _ => Err(CliError::usage(format!("unknown pane subcommand: {s}"))),
    }
}
fn surface(c: &Context, s: &str, a: &[String]) -> Result<Option<i32>> {
    let mut p = Map::new();
    ids(c, a, &mut p, true, false, true)?;
    match s {
        "list" | "ls" => call(c, "surface.list", p, "surface"),
        "focus" => call(c, "surface.focus", p, "surface"),
        "close" => call(c, "surface.close", p, "surface"),
        "create" | "new" => {
            for (n, k) in [
                ("--type", "type"),
                ("--url", "url"),
                ("--provider", "provider_id"),
                ("--renderer", "renderer_kind"),
                ("--cwd", "working_directory"),
                ("--placement", "placement"),
            ] {
                if let Some(v) = opt(a, n) {
                    p.insert(k.into(), json!(v));
                }
            }
            if let Some(v) = opt(a, "--command") {
                p.insert("initial_input".into(), json!(format!("{v}\r")));
            }
            call(c, "surface.create", p, "surface")
        }
        "split" | "split-off" => {
            if let Some(v) = pos(a).first() {
                p.insert("direction".into(), json!(v));
            }
            if let Some(v) = b(a, "--focus")? {
                p.insert("focus".into(), json!(v));
            }
            if let Some(v) = opt(a, "--command") {
                p.insert("initial_input".into(), json!(format!("{v}\r")));
            }
            call(
                c,
                if s == "split" {
                    "surface.split"
                } else {
                    "surface.split_off"
                },
                p,
                "surface",
            )
        }
        "move" => {
            move_fields(a, &mut p)?;
            call(c, "surface.move", p, "surface")
        }
        "reorder" => {
            move_fields(a, &mut p)?;
            call(c, "surface.reorder", p, "surface")
        }
        "health" => call(c, "surface.health", p, "surface"),
        _ => Err(CliError::usage(format!("unknown surface subcommand: {s}"))),
    }
}
fn todo(c: &Context, a: &[String]) -> Result<Option<i32>> {
    let s = pos(a).first().cloned().unwrap_or_else(|| "list".into());
    let m = match s.as_str() {
        "list" | "ls" => "workspace.todo.list",
        "add" => "workspace.todo.add",
        "check" | "uncheck" | "start" => "workspace.todo.set_state",
        "edit" => "workspace.todo.edit",
        "rm" | "remove" => "workspace.todo.remove",
        "move" | "mv" => "workspace.todo.move",
        "clear" => "workspace.todo.clear",
        "set" => "workspace.todo.set",
        "open" => "workspace.todo.open",
        _ => return Err(CliError::usage(format!("unknown todo subcommand: {s}"))),
    };
    let mut p = Map::new();
    ids(c, a, &mut p, true, false, false)?;
    for (n, k) in [
        ("--text", "text"),
        ("--title", "title"),
        ("--id", "item_id"),
        ("--state", "state"),
        ("--index", "index"),
        ("--to", "to_index"),
    ] {
        if let Some(v) = opt(a, n) {
            p.insert(k.into(), json!(v));
        }
    }
    call(c, m, p, "workspace")
}
pub fn run(c: &Context, cmd: &str, a: &[String]) -> Result<Option<i32>> {
    match cmd {
        "workspace" => {
            let p = pos(a);
            ws(
                c,
                p.first().map(String::as_str).unwrap_or("list"),
                a.get(1..).unwrap_or(&[]),
            )
        }
        "workspace-group" => group(c, a),
        "todo" => todo(c, a),
        "window" => {
            let p = pos(a);
            window(
                c,
                p.first().map(String::as_str).unwrap_or("list"),
                a.get(1..).unwrap_or(&[]),
            )
        }
        "list-workspaces" => ws(c, "list", a),
        "new-workspace" => ws(c, "create", a),
        "list-windows" => {
            let s = c.raw("list_windows")?;
            c.print(s)?;
            Ok(Some(0))
        }
        "current-window" => {
            let s = c.raw("current_window")?;
            c.print(s)?;
            Ok(Some(0))
        }
        "new-window" => window(c, "create", a),
        "focus-window" => window(c, "focus", a),
        "close-window" => window(c, "close", a),
        "move-workspace-to-window" => {
            let mut p = Map::new();
            ids(c, a, &mut p, true, false, false)?;
            call(c, "workspace.move_to_window", p, "workspace")
        }
        "list-panes" => pane(c, "list", a),
        "list-pane-surfaces" => pane(c, "surfaces", a),
        "focus-pane" => pane(c, "focus", a),
        "new-pane" => pane(c, "create", a),
        "list-panels" => surface(c, "list", a),
        "focus-panel" => surface(c, "focus", a),
        "close-surface" => surface(c, "close", a),
        "new-surface" => surface(c, "create", a),
        "new-split" => surface(c, "split", a),
        "split-off" => surface(c, "split-off", a),
        "move-surface" => surface(c, "move", a),
        "reorder-surface" => surface(c, "reorder", a),
        "surface-health" => surface(c, "health", a),
        "close-workspace" => ws(c, "close", a),
        "select-workspace" => ws(c, "select", a),
        "rename-workspace" | "rename-window" => ws(c, "rename", a),
        "current-workspace" => {
            let v = c.rpc("workspace.current", json!({}))?;
            emit(c, v, "")
        }
        "identify" => {
            let v = c.rpc("system.identify", json!({}))?;
            emit(c, v, "")
        }
        "tree" => {
            let v = c.rpc("workspace.list", json!({}))?;
            emit(c, v, "")
        }
        _ => Ok(None),
    }
}
