//! Handle-to-ID resolution shared by Rust command modules.

use crate::{CliError, Context, Result};
use serde_json::{Value, json};
use std::env;

/// Resolve a window, workspace, pane, or surface selector to the app's UUID.
///
/// Selectors intentionally follow the Swift CLI contract: UUIDs pass through,
/// `kind:N` references and numeric indexes are looked up, and omitted values
/// use caller context before focused app state. An explicit blank selector is
/// rejected so shell expansion cannot silently target another workspace.
pub fn resolve(ctx: &Context, kind: &str, value: Option<&str>) -> Result<Option<String>> {
    let kind = kind.trim().to_ascii_lowercase();
    if !matches!(kind.as_str(), "window" | "workspace" | "pane" | "surface") {
        return Err(CliError::new(
            "invalid_kind",
            format!("Unknown ID kind: {kind}"),
        ));
    }
    resolve_kind(
        ctx,
        &kind,
        value.map(str::trim).filter(|v| !v.is_empty()),
        value.is_some(),
    )
}

fn resolve_kind(
    ctx: &Context,
    kind: &str,
    raw: Option<&str>,
    explicitly_supplied: bool,
) -> Result<Option<String>> {
    if let Some(raw) = raw {
        if looks_like_uuid(raw) {
            return Ok(Some(raw.to_string()));
        }
        if let Some((prefix, index)) = parse_ref(raw) {
            if prefix != kind {
                return Err(CliError::new(
                    "invalid_handle",
                    format!("Invalid {kind} handle: {raw}"),
                ));
            }
            return lookup(ctx, kind, None, Some(index), Some(raw));
        }
        if let Ok(index) = raw.parse::<i64>() {
            return lookup(ctx, kind, None, Some(index), None);
        }
        return Err(CliError::new(
            "not_found",
            format!("{kind} not found: {raw}"),
        ));
    }
    if explicitly_supplied {
        return Err(CliError::new(
            "invalid_handle",
            format!("{kind} handle is blank"),
        ));
    }
    match kind {
        "window" => {
            let current = ctx.rpc("window.current", json!({}))?;
            Ok(current
                .get("window_id")
                .or_else(|| current.get("id"))
                .and_then(Value::as_str)
                .map(str::to_owned))
        }
        "workspace" => {
            if ctx.window.is_none() {
                if let Ok(caller) = env::var("CMUX_WORKSPACE_ID") {
                    if looks_like_uuid(caller.trim()) {
                        return Ok(Some(caller.trim().to_string()));
                    }
                }
            }
            let mut params = json!({});
            if let Some(window) = ctx.window.as_deref() {
                if let Some(window_id) = resolve_kind(ctx, "window", Some(window), true)? {
                    params["window_id"] = Value::String(window_id);
                }
            }
            let current = ctx.rpc("workspace.current", params)?;
            Ok(current
                .get("workspace_id")
                .or_else(|| current.get("id"))
                .and_then(Value::as_str)
                .map(str::to_owned))
        }
        "pane" | "surface" => {
            let workspace = resolve_kind(ctx, "workspace", None, false)?
                .ok_or_else(|| CliError::new("not_found", "No workspace selected"))?;
            lookup(ctx, kind, Some(&workspace), None, None)
        }
        _ => unreachable!(),
    }
}

fn lookup(
    ctx: &Context,
    kind: &str,
    workspace: Option<&str>,
    index: Option<i64>,
    wanted_ref: Option<&str>,
) -> Result<Option<String>> {
    let (method, list_key) = match kind {
        "window" => ("window.list", "windows"),
        "workspace" => ("workspace.list", "workspaces"),
        "pane" => ("pane.list", "panes"),
        "surface" => ("surface.list", "surfaces"),
        _ => unreachable!(),
    };
    let mut params = json!({});
    if let Some(workspace) = workspace {
        params["workspace_id"] = Value::String(workspace.to_string());
    }
    if kind == "workspace" {
        if let Some(window) = ctx.window.as_deref() {
            if let Some(window_id) = resolve_kind(ctx, "window", Some(window), true)? {
                params["window_id"] = Value::String(window_id);
            }
        }
    }
    let payload = ctx.rpc(method, params)?;
    let items = payload
        .get(list_key)
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if let Some(wanted_ref) = wanted_ref {
        if let Some(id) = items
            .iter()
            .find(|item| item.get("ref").and_then(Value::as_str) == Some(wanted_ref))
            .and_then(item_id)
        {
            return Ok(Some(id));
        }
        return Err(CliError::new(
            "not_found",
            format!("{kind} ref not found: {wanted_ref}"),
        ));
    }
    if let Some(index) = index {
        if let Some(id) = items
            .iter()
            .find(|item| item_index(item) == Some(index))
            .and_then(item_id)
        {
            return Ok(Some(id));
        }
        return Err(CliError::new(
            "not_found",
            format!("{kind} index not found"),
        ));
    }
    let selected = items
        .iter()
        .find(|item| item.get("focused").and_then(Value::as_bool) == Some(true))
        .and_then(item_id)
        .or_else(|| items.first().and_then(item_id));
    selected
        .map(Some)
        .ok_or_else(|| CliError::new("not_found", format!("No {kind} selected")))
}

fn item_id(item: &Value) -> Option<String> {
    item.get("id")
        .or_else(|| item.get("uuid"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}
fn item_index(item: &Value) -> Option<i64> {
    item.get("index")
        .and_then(|v| v.as_i64().or_else(|| v.as_str()?.parse().ok()))
}
fn parse_ref(raw: &str) -> Option<(&str, i64)> {
    let (kind, index) = raw.split_once(':')?;
    if !matches!(kind, "window" | "workspace" | "pane" | "surface") {
        return None;
    }
    Some((kind, index.parse().ok()?))
}
fn looks_like_uuid(value: &str) -> bool {
    value.len() == 36
        && value.as_bytes().iter().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                *c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
