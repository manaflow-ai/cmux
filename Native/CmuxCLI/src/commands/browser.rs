//! Native implementation of `cmux browser`.
//!
//! The browser command is deliberately kept as a small, boring adapter: parsing and
//! validation live here, while the application remains the owner of browser state and
//! automation.  Keeping the method names and parameter spelling in one place makes the
//! Rust and Swift entry points observable-equivalent and avoids a generic RPC passthrough.

use std::fs;
use std::path::PathBuf;

use base64::Engine;
use serde_json::{Map, Value, json};

use crate::{Context, Result};

fn usage(message: impl Into<String>) -> crate::CliError {
    crate::CliError::usage(message.into())
}

fn non_flags(args: &[String]) -> Vec<String> {
    args.iter()
        .filter(|s| !s.starts_with('-'))
        .cloned()
        .collect()
}

fn take(args: &mut Vec<String>, names: &[&str]) -> Result<Option<String>> {
    let mut found = None;
    let mut i = 0;
    while i < args.len() {
        if names.iter().any(|n| args[i] == *n) {
            if found.is_some() {
                return Err(usage(format!("{} may only be specified once", args[i])));
            }
            if i + 1 >= args.len() || args[i + 1].starts_with('-') {
                return Err(usage(format!("{} requires a value", args[i])));
            }
            found = Some(args.remove(i + 1));
            args.remove(i);
            continue;
        }
        if let Some((name, value)) = args[i].split_once('=') {
            if names.iter().any(|n| name == *n) {
                if found.is_some() {
                    return Err(usage(format!("{} may only be specified once", name)));
                }
                if value.is_empty() {
                    return Err(usage(format!("{} requires a value", name)));
                }
                found = Some(value.to_string());
                args.remove(i);
                continue;
            }
        }
        i += 1;
    }
    Ok(found)
}

fn flag(args: &mut Vec<String>, names: &[&str]) -> bool {
    let mut found = false;
    args.retain(|a| {
        let matches = names.iter().any(|n| a == *n);
        found |= matches;
        !matches
    });
    found
}

fn surface(ctx: &Context, raw: Option<&str>, command: &str) -> Result<String> {
    ctx.resolve_id("surface", raw).map(|v| v.ok_or_else(|| usage(format!("browser {command} requires a surface handle (use: browser <surface> {command} ... or --surface)"))))?
}

fn print_payload(ctx: &Context, payload: &Value, fallback: &str) -> Result<()> {
    if ctx.json {
        ctx.emit(payload)
    } else {
        ctx.print(fallback)?;
        if let Some(s) = payload.get("post_action_snapshot").and_then(Value::as_str) {
            if !s.trim().is_empty() {
                ctx.print(s)?;
            }
        }
        Ok(())
    }
}

fn text_value(v: &Value) -> String {
    match v {
        Value::Null => "null".into(),
        Value::Bool(v) => v.to_string(),
        Value::String(v) => v.clone(),
        Value::Number(v) => v.to_string(),
        Value::Array(_) | Value::Object(_) => {
            serde_json::to_string_pretty(v).unwrap_or_else(|_| v.to_string())
        }
    }
}

fn browser_log_text(value: Option<&Value>, empty: &str) -> String {
    let Some(items) = value.and_then(Value::as_array) else {
        return empty.into();
    };
    if items.is_empty() {
        return empty.into();
    }
    items
        .iter()
        .map(|item| {
            if let Value::Object(m) = item {
                let level = m
                    .get("level")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .unwrap_or("log");
                if let Some(text) = m
                    .get("text")
                    .and_then(Value::as_str)
                    .filter(|s| !s.trim().is_empty())
                {
                    return format!("[{level}] {text}");
                }
                if let Some(message) = m
                    .get("message")
                    .and_then(Value::as_str)
                    .filter(|s| !s.trim().is_empty())
                {
                    return format!("[error] {message}");
                }
            }
            text_value(item)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn bool_value(v: Option<&Value>) -> bool {
    v.and_then(Value::as_bool).unwrap_or(false)
}

fn parse_bool(raw: &str) -> Option<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn resolve_path(raw: &str) -> PathBuf {
    if let Some(rest) = raw.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(raw)
}

fn require_url(args: &[String], command: &str) -> Result<String> {
    let value = args
        .iter()
        .filter(|a| !a.starts_with('-'))
        .cloned()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string();
    if value.is_empty() {
        Err(usage(format!("browser {command} requires a URL")))
    } else {
        Ok(value)
    }
}

fn help(ctx: &Context, subcommand: Option<&str>) -> Result<Option<i32>> {
    let text = match subcommand.map(str::to_ascii_lowercase).as_deref() {
        None | Some("--help") | Some("-h") => "Usage: cmux browser [surface] <subcommand> [options]\n\nNavigation: open, goto, back, forward, reload, url, tab\nAutomation: snapshot, eval, wait, click, dblclick, hover, focus, type, fill, press, select, scroll\nInspection: get, is, find, frame, dialog, screenshot, console, errors\nState: cookies, storage, download, profile, import, viewport, geolocation, offline, trace, network, screencast\nUse `cmux browser <subcommand> --help` for command-specific syntax.".to_string(),
        Some("snapshot") => "Usage: cmux browser <surface> snapshot [--selector CSS] [--interactive] [--cursor] [--compact] [--max-depth N]".into(),
        Some("screenshot") => "Usage: cmux browser <surface> screenshot [--out PATH]\nCapture the browser surface as PNG.".into(),
        Some("wait") => "Usage: cmux browser <surface> wait [--selector CSS|--text TEXT|--url URL] [--timeout-ms N|--timeout SEC]".into(),
        Some("download") => "Usage: cmux browser <surface> download [list [--limit 1..25]|wait [PATH] [--timeout-ms N]]".into(),
        Some("viewport") => "Usage: cmux browser <surface> viewport <width> <height> | reset".into(),
        Some("cookies") => "Usage: cmux browser <surface> cookies [get|set|clear] [--name NAME] [--value VALUE]".into(),
        Some("storage") => "Usage: cmux browser <surface> storage <local|session> [get [KEY]|set KEY VALUE|clear]".into(),
        Some(other) => format!("Usage: cmux browser <surface> {other} [options]"),
    };
    ctx.print(text)?;
    Ok(Some(0))
}

fn routing_params(
    ctx: &Context,
    mut args: Vec<String>,
    explicit_surface: Option<&str>,
) -> Result<Map<String, Value>> {
    let workspace = take(&mut args, &["--workspace"])?;
    let window = take(&mut args, &["--window"])?;
    let return_to = take(&mut args, &["--return-to"])?;
    let mut p = Map::new();
    if let Some(raw) = explicit_surface {
        p.insert(
            "surface_id".into(),
            Value::String(surface(ctx, Some(raw), "command")?),
        );
    }
    if let Some(raw) = workspace {
        if let Some(id) = ctx.resolve_id("workspace", Some(&raw))? {
            p.insert("workspace_id".into(), Value::String(id));
        }
    }
    if let Some(raw) = window {
        if let Some(id) = ctx.resolve_id("window", Some(&raw))? {
            p.insert("window_id".into(), Value::String(id));
        }
    }
    if let Some(raw) = return_to {
        if let Some(id) = ctx.resolve_id("surface", Some(&raw))? {
            p.insert("return_to".into(), Value::String(id));
        }
    }
    Ok(p)
}

fn download(ctx: &Context, surface_raw: Option<&str>, mut args: Vec<String>) -> Result<()> {
    let sid = surface(ctx, surface_raw, "download")?;
    let verb = args.first().map(|s| s.to_ascii_lowercase());
    if matches!(verb.as_deref(), Some("list") | Some("ls")) {
        args.remove(0);
        let limit = take(&mut args, &["--limit"])?;
        if !args.is_empty() {
            return Err(usage("Unexpected browser download list argument"));
        }
        let mut p = Map::new();
        p.insert("surface_id".into(), sid.into());
        if let Some(v) = limit {
            let n: i64 = v
                .parse()
                .map_err(|_| usage("--limit must be an integer between 1 and 25"))?;
            if !(1..=25).contains(&n) {
                return Err(usage("--limit must be an integer between 1 and 25"));
            }
            p.insert("limit".into(), n.into());
        }
        let out = ctx.rpc("browser.download.list", Value::Object(p))?;
        if ctx.json {
            return ctx.emit(&out);
        }
        let list = out.get("downloads").and_then(Value::as_array);
        if list.is_none_or(|x| x.is_empty()) {
            return ctx.print("No recent downloads.");
        }
        for (i, d) in list.unwrap().iter().enumerate() {
            let val = |k| {
                d.get(k)
                    .map(text_value)
                    .unwrap_or_else(|| "<unavailable>".into())
            };
            ctx.print(format!(
                "{}. {} {}\n   id: {}\n   path: {}\n   bytes: {}\n   path_exists: {}",
                i + 1,
                val("status"),
                val("filename"),
                val("download_id"),
                val("path"),
                val("bytes"),
                val("path_exists")
            ))?;
        }
        return Ok(());
    }
    if verb.as_deref() == Some("wait") {
        args.remove(0);
    }
    let path = take(&mut args, &["--path"])?;
    let timeout_ms = if let Some(v) = take(&mut args, &["--timeout-ms"])? {
        Some(
            v.parse::<i64>()
                .map_err(|_| usage("--timeout-ms must be an integer"))?,
        )
    } else if let Some(v) = take(&mut args, &["--timeout"])? {
        let n = v
            .parse::<f64>()
            .map_err(|_| usage("--timeout must be a finite number"))?;
        if !n.is_finite() {
            return Err(usage("--timeout must be a finite number"));
        }
        Some((n * 1000.0).max(1.0) as i64)
    } else {
        None
    };
    let positional = non_flags(&args);
    if path.is_some() && !positional.is_empty() || positional.len() > 1 {
        return Err(usage("browser download wait accepts one destination path"));
    }
    let mut p = Map::new();
    p.insert("surface_id".into(), sid.into());
    if let Some(v) = path.or_else(|| positional.first().cloned()) {
        p.insert("path".into(), v.into());
    }
    if let Some(v) = timeout_ms {
        p.insert("timeout_ms".into(), v.into());
    }
    let out = ctx.rpc("browser.download.wait", Value::Object(p))?;
    print_payload(ctx, &out, "OK")
}

pub fn run(ctx: &Context, command: &str, raw_args: &[String]) -> Result<Option<i32>> {
    if command != "browser" {
        return Ok(None);
    }
    if raw_args.is_empty() {
        return Err(usage("browser requires a subcommand"));
    }
    let mut all = raw_args.to_vec();
    let json_flag = flag(&mut all, &["--json"]);
    // Browser skill examples put display flags at the end. The global parser owns the
    // effective format; consume the local spelling here so it never leaks into a URL
    // or selector.
    let _ = take(&mut all, &["--id-format"])?;
    let _ = json_flag; // root Context owns the global JSON switch; trailing --json is accepted for parity.
    let surface_opt = take(&mut all, &["--surface"])?;
    let verbs_without_surface = [
        "open",
        "open-split",
        "new",
        "identify",
        "import",
        "profile",
        "profiles",
        "react-grab",
        "reactgrab",
        "devtools",
        "dev-tools",
        "focus-mode",
        "design-mode",
        "zoom",
        "history",
    ];
    let mut surface_raw = surface_opt;
    if surface_raw.is_none()
        && all.first().is_some_and(|s| {
            !s.starts_with('-') && !verbs_without_surface.contains(&s.to_ascii_lowercase().as_str())
        })
    {
        surface_raw = Some(all.remove(0));
    }
    let sub = all
        .first()
        .map(|s| s.to_ascii_lowercase())
        .ok_or_else(|| usage("browser requires a subcommand"))?;
    let mut args = all.into_iter().skip(1).collect::<Vec<_>>();
    if sub == "--help" || sub == "-h" {
        return help(ctx, None);
    }
    if args.iter().any(|a| a == "--help" || a == "-h") {
        args.retain(|a| a != "--help" && a != "-h");
        if args.is_empty() {
            return help(ctx, Some(&sub));
        }
    }

    if sub == "identify" {
        let mut out = ctx.rpc("system.identify", Value::Object(Map::new()))?;
        if let Some(raw) = surface_raw.as_deref() {
            let sid = surface(ctx, Some(raw), "identify")?;
            let url = ctx.rpc("browser.url.get", json!({"surface_id": sid}))?;
            let title = ctx.rpc("browser.get.title", json!({"surface_id": sid}))?;
            let mut b = Map::new();
            b.insert("surface".into(), sid.into());
            b.insert(
                "url".into(),
                url.get("url")
                    .cloned()
                    .unwrap_or(Value::String(String::new())),
            );
            b.insert(
                "title".into(),
                title
                    .get("title")
                    .cloned()
                    .unwrap_or(Value::String(String::new())),
            );
            if let Value::Object(ref mut m) = out {
                m.insert("browser".into(), Value::Object(b));
            }
        }
        print_payload(ctx, &out, "OK")?;
        return Ok(Some(0));
    }
    if sub == "profile" || sub == "profiles" {
        let verb = args
            .first()
            .map(|x| match x.as_str() {
                "ls" => "list",
                "add" | "new" => "create",
                "rm" | "remove" => "delete",
                x => x,
            })
            .unwrap_or("list")
            .to_string();
        if !args.is_empty() {
            args.remove(0);
        }
        let (method, params) = match verb.as_str() {
            "list" => ("browser.profiles.list", json!({})),
            "create" => {
                let name = take(&mut args, &["--name"])?
                    .or_else(|| {
                        let v = non_flags(&args);
                        if v.is_empty() {
                            None
                        } else {
                            Some(v.join(" "))
                        }
                    })
                    .ok_or_else(|| usage(format!("browser profiles {verb} requires a name")))?;
                ("browser.profiles.create", json!({"name":name}))
            }
            "rename" => {
                let profile = take(&mut args, &["--profile"])?
                    .or_else(|| non_flags(&args).first().cloned())
                    .ok_or_else(|| usage("browser profiles rename requires a profile"))?;
                let name = take(&mut args, &["--name"])?
                    .or_else(|| {
                        let v = non_flags(&args);
                        if v.len() > 1 {
                            Some(v[1..].join(" "))
                        } else {
                            None
                        }
                    })
                    .ok_or_else(|| usage("browser profiles rename requires a new name"))?;
                (
                    "browser.profiles.rename",
                    json!({"profile":profile,"new_name":name}),
                )
            }
            "clear" => {
                let all_flag = flag(&mut args, &["--all"]);
                let profile =
                    take(&mut args, &["--profile"])?.or_else(|| non_flags(&args).first().cloned());
                if !all_flag && profile.is_none() {
                    return Err(usage("browser profiles clear requires a profile or --all"));
                }
                let mut p = Map::new();
                if all_flag {
                    p.insert("all".into(), true.into());
                }
                if let Some(v) = profile {
                    p.insert("profile".into(), v.into());
                }
                if flag(&mut args, &["--force"]) {
                    p.insert("force".into(), true.into());
                }
                ("browser.profiles.clear", Value::Object(p))
            }
            "delete" => {
                let profile = take(&mut args, &["--profile"])?
                    .or_else(|| non_flags(&args).first().cloned())
                    .ok_or_else(|| usage("browser profiles delete requires a profile"))?;
                ("browser.profiles.delete", json!({"profile":profile}))
            }
            _ => {
                return Err(usage(format!(
                    "Unsupported browser profiles subcommand: {verb}"
                )));
            }
        };
        let out = ctx.rpc(method, params)?;
        if ctx.json {
            ctx.emit(&out)?
        } else if verb == "list" {
            if let Some(ps) = out.get("profiles").and_then(Value::as_array) {
                for p in ps {
                    let n = p.get("name").and_then(Value::as_str).unwrap_or("");
                    let s = p.get("slug").and_then(Value::as_str).unwrap_or("");
                    let id = p.get("id").and_then(Value::as_str).unwrap_or("");
                    ctx.print(format!("{s}\t{n}\t{id}"))?
                }
            } else {
                ctx.print("No browser profiles")?
            }
        } else {
            ctx.print("OK")?
        };
        return Ok(Some(0));
    }
    if sub == "download" {
        download(ctx, surface_raw.as_deref(), args)?;
        return Ok(Some(0));
    }
    if sub == "import" {
        if !non_flags(&args).is_empty() {
            return Err(usage("browser import does not accept positional arguments"));
        }
        let interactive = flag(&mut args, &["--interactive"]);
        let noninteractive = flag(
            &mut args,
            &["--non-interactive", "--noninteractive", "--yes", "-y"],
        );
        if interactive && noninteractive {
            return Err(usage(
                "browser import cannot use both --interactive and --non-interactive",
            ));
        }
        let mut p = Map::new();
        if noninteractive {
            p.insert("scope".into(), "cookiesOnly".into());
        }
        if let Some(v) = take(&mut args, &["--from", "--browser", "--source"])? {
            p.insert("browser".into(), v.into());
        }
        if let Some(v) = take(
            &mut args,
            &["--to", "--to-profile", "--destination-profile"],
        )? {
            p.insert("destination_profile".into(), v.into());
        }
        let profiles = args
            .iter()
            .filter_map(|a| {
                a.strip_prefix("--profile=")
                    .or_else(|| a.strip_prefix("--source-profile="))
                    .map(str::to_string)
            })
            .collect::<Vec<_>>();
        if !profiles.is_empty() {
            p.insert("source_profiles".into(), json!(profiles));
        }
        if flag(&mut args, &["--all-profiles"]) {
            p.insert("all_profiles".into(), true.into());
        }
        if flag(
            &mut args,
            &["--create-profile", "--create-destination-profile"],
        ) {
            p.insert("create_destination_profile".into(), true.into());
        }
        let out = ctx.rpc(
            if noninteractive {
                "browser.import.cookies"
            } else {
                "browser.import.dialog"
            },
            Value::Object(p),
        )?;
        print_payload(ctx, &out, "OK")?;
        return Ok(Some(0));
    }
    if matches!(sub.as_str(), "open" | "open-split" | "new") {
        let workspace = take(&mut args, &["--workspace"])?;
        let window = take(&mut args, &["--window"])?;
        let focus = take(&mut args, &["--focus"])?;
        let profile = take(&mut args, &["--profile"])?;
        if args.iter().any(|a| a.starts_with("--")) {
            return Err(usage(format!(
                "browser {sub} does not support an unknown option"
            )));
        }
        if surface_raw.is_some() && sub == "open" {
            let sid = surface(ctx, surface_raw.as_deref(), &sub)?;
            let url = require_url(&args, &sub)?;
            let out = ctx.rpc("browser.navigate", json!({"surface_id":sid,"url":url}))?;
            print_payload(ctx, &out, "OK")?;
            return Ok(Some(0));
        }
        let mut p = Map::new();
        let url = args.join(" ").trim().to_string();
        if !url.is_empty() {
            p.insert("url".into(), url.into());
        }
        if let Some(v) = profile {
            p.insert("profile".into(), v.into());
        }
        if let Some(v) = surface_raw {
            p.insert("surface_id".into(), surface(ctx, Some(&v), &sub)?.into());
        }
        if let Some(v) = workspace {
            if let Some(id) = ctx.resolve_id("workspace", Some(&v))? {
                p.insert("workspace_id".into(), id.into());
            }
        }
        if let Some(v) = window {
            if let Some(id) = ctx.resolve_id("window", Some(&v))? {
                p.insert("window_id".into(), id.into());
            }
        }
        if let Some(v) = focus {
            p.insert(
                "focus".into(),
                parse_bool(&v)
                    .ok_or_else(|| usage("--focus must be true or false"))?
                    .into(),
            );
        }
        let out = ctx.rpc("browser.open_split", Value::Object(p))?;
        print_payload(ctx, &out, "OK")?;
        return Ok(Some(0));
    }

    let sid = || surface(ctx, surface_raw.as_deref(), &sub);
    let automation = |ctx: &Context, method: &str, p: Value| -> Result<()> {
        let out = ctx.rpc(method, p)?;
        print_payload(ctx, &out, "OK")
    };
    match sub.as_str() {
        "goto" | "navigate" => {
            let id = sid()?;
            let snap = flag(&mut args, &["--snapshot-after"]);
            let url = require_url(&args, &sub)?;
            let mut p = json!({"surface_id":id,"url":url});
            if snap {
                p["snapshot_after"] = true.into();
            }
            automation(ctx, "browser.navigate", p)?;
        }
        "back" | "forward" | "reload" => {
            let id = sid()?;
            let snap = flag(&mut args, &["--snapshot-after"]);
            let mut p = json!({"surface_id":id});
            if snap {
                p["snapshot_after"] = true.into();
            }
            automation(ctx, &format!("browser.{sub}"), p)?;
        }
        "url" | "get-url" => {
            let out = ctx.rpc("browser.url.get", json!({"surface_id":sid()?}))?;
            if ctx.json {
                ctx.emit(&out)?
            } else {
                ctx.print(out.get("url").and_then(Value::as_str).unwrap_or(""))?;
            }
        }
        "focus-webview" | "focus_webview" => {
            automation(ctx, "browser.focus_webview", json!({"surface_id":sid()?}))?
        }
        "is-webview-focused" | "is_webview_focused" => {
            let out = ctx.rpc("browser.is_webview_focused", json!({"surface_id":sid()?}))?;
            if ctx.json {
                ctx.emit(&out)?
            } else {
                ctx.print(if bool_value(out.get("focused")) {
                    "true"
                } else {
                    "false"
                })?;
            }
        }
        "snapshot" => {
            let id = sid()?;
            let selector = take(&mut args, &["--selector"])?;
            let depth = take(&mut args, ["--max-depth"].as_ref())?;
            let mut p = json!({"surface_id":id});
            if let Some(v) = selector {
                p["selector"] = v.into();
            }
            if flag(&mut args, &["--interactive", "-i"]) {
                p["interactive"] = true.into();
            }
            if flag(&mut args, &["--cursor"]) {
                p["cursor"] = true.into();
            }
            if flag(&mut args, &["--compact"]) {
                p["compact"] = true.into();
            }
            if let Some(v) = depth {
                let n: i64 = v
                    .parse()
                    .map_err(|_| usage("--max-depth must be a non-negative integer"))?;
                if n < 0 {
                    return Err(usage("--max-depth must be a non-negative integer"));
                }
                p["max_depth"] = n.into();
            }
            let out = ctx.rpc("browser.snapshot", p)?;
            if ctx.json {
                ctx.emit(&out)?
            } else {
                ctx.print(
                    out.get("snapshot")
                        .and_then(Value::as_str)
                        .unwrap_or("Empty page"),
                )?;
            }
        }
        "eval" => {
            let id = sid()?;
            let script = take(&mut args, &["--script"])?.unwrap_or_else(|| args.join(" "));
            if script.trim().is_empty() {
                return Err(usage("browser eval requires a script"));
            }
            let out = ctx.rpc(
                "browser.eval",
                json!({"surface_id":id,"script":script.trim()}),
            )?;
            if ctx.json {
                ctx.emit(&out)?
            } else {
                ctx.print(
                    out.get("value")
                        .map(text_value)
                        .unwrap_or_else(|| "OK".into()),
                )?;
            }
        }
        "wait" => {
            let id = sid()?;
            let selector = take(&mut args, &["--selector"])?;
            let text = take(&mut args, &["--text"])?;
            let url = take(&mut args, &["--url-contains", "--url"])?;
            let state = take(&mut args, &["--load-state"])?;
            let fun = take(&mut args, &["--function"])?;
            let ms = if let Some(v) = take(&mut args, &["--timeout-ms"])? {
                Some(
                    v.parse::<i64>()
                        .map_err(|_| usage("--timeout-ms must be an integer"))?,
                )
            } else if let Some(v) = take(&mut args, &["--timeout"])? {
                Some(
                    (v.parse::<f64>()
                        .map_err(|_| usage("--timeout must be a number"))?
                        * 1000.0)
                        .max(1.0) as i64,
                )
            } else {
                None
            };
            let mut p = json!({"surface_id":id});
            if let Some(v) = selector {
                p["selector"] = v.into();
            }
            if let Some(v) = text {
                p["text_contains"] = v.into();
            }
            if let Some(v) = url {
                p["url_contains"] = v.into();
            }
            if let Some(v) = state {
                p["load_state"] = v.into();
            }
            if let Some(v) = fun {
                p["function"] = v.into();
            }
            if let Some(v) = ms {
                p["timeout_ms"] = v.into();
            }
            automation(ctx, "browser.wait", p)?;
        }
        "click" | "dblclick" | "hover" | "focus" | "check" | "uncheck" | "scrollintoview"
        | "scrollinto" | "scroll-into-view" => {
            let id = sid()?;
            let selector = take(&mut args, &["--selector"])?
                .or_else(|| non_flags(&args).first().cloned())
                .ok_or_else(|| usage(format!("browser {sub} requires a selector")))?;
            let method = match sub.as_str() {
                "scrollintoview" | "scrollinto" | "scroll-into-view" => "browser.scroll_into_view",
                x => {
                    return automation(
                        ctx,
                        &format!("browser.{x}"),
                        json!({"surface_id":id,"selector":selector,"snapshot_after":flag(&mut args,&["--snapshot-after"])}),
                    ).map(|_| Some(0));
                }
            };
            automation(
                ctx,
                method,
                json!({"surface_id":id,"selector":selector,"snapshot_after":flag(&mut args,&["--snapshot-after"])}),
            )?;
        }
        "type" | "fill" => {
            let id = sid()?;
            let selector = take(&mut args, &["--selector"])?
                .or_else(|| non_flags(&args).first().cloned())
                .ok_or_else(|| usage(format!("browser {sub} requires a selector")))?;
            let text = take(&mut args, &["--text"])?.unwrap_or_else(|| {
                non_flags(&args)
                    .into_iter()
                    .skip(if args.iter().any(|x| x == &selector) {
                        1
                    } else {
                        0
                    })
                    .collect::<Vec<_>>()
                    .join(" ")
            });
            if sub == "type" && text.is_empty() {
                return Err(usage("browser type requires text"));
            }
            automation(
                ctx,
                if sub == "type" {
                    "browser.type"
                } else {
                    "browser.fill"
                },
                json!({"surface_id":id,"selector":selector,"text":text,"snapshot_after":flag(&mut args,&["--snapshot-after"])}),
            )?;
        }
        "press" | "key" | "keydown" | "keyup" => {
            let id = sid()?;
            let key = take(&mut args, &["--key"])?
                .or_else(|| non_flags(&args).first().cloned())
                .ok_or_else(|| usage(format!("browser {sub} requires a key")))?;
            let method = if sub == "key" {
                "browser.press".to_string()
            } else {
                format!("browser.{sub}")
            };
            automation(
                ctx,
                &method,
                json!({"surface_id":id,"key":key,"snapshot_after":flag(&mut args,&["--snapshot-after"])}),
            )?;
        }
        "select" => {
            let id = sid()?;
            let selector = take(&mut args, &["--selector"])?
                .or_else(|| non_flags(&args).first().cloned())
                .ok_or_else(|| usage("browser select requires a selector"))?;
            let value = take(&mut args, &["--value"])?
                .or_else(|| non_flags(&args).into_iter().nth(1))
                .ok_or_else(|| usage("browser select requires a value"))?;
            automation(
                ctx,
                "browser.select",
                json!({"surface_id":id,"selector":selector,"value":value,"snapshot_after":flag(&mut args,&["--snapshot-after"])}),
            )?;
        }
        "scroll" => {
            let id = sid()?;
            let selector = take(&mut args, &["--selector"])?;
            let dx = take(&mut args, &["--dx"])?;
            let dy = take(&mut args, &["--dy"])?;
            let mut p = json!({"surface_id":id});
            if let Some(v) = selector {
                p["selector"] = v.into();
            }
            if let Some(v) = dx {
                p["dx"] = v
                    .parse::<i64>()
                    .map_err(|_| usage("--dx must be an integer"))?
                    .into();
            }
            if let Some(v) = dy {
                p["dy"] = v
                    .parse::<i64>()
                    .map_err(|_| usage("--dy must be an integer"))?
                    .into();
            }
            if flag(&mut args, &["--snapshot-after"]) {
                p["snapshot_after"] = true.into();
            }
            automation(ctx, "browser.scroll", p)?;
        }
        "screenshot" => {
            let id = sid()?;
            let out_path = take(&mut args, &["--out"])?;
            let mut out = ctx.rpc("browser.screenshot", json!({"surface_id": id}))?;
            if let Some(path) = out_path.as_deref() {
                let destination = resolve_path(path);
                let encoded = out
                    .get("png_base64")
                    .and_then(Value::as_str)
                    .ok_or_else(|| usage("browser screenshot missing image data"))?;
                let bytes =
                    base64::Engine::decode(&base64::engine::general_purpose::STANDARD, encoded)
                        .map_err(|_| usage("browser screenshot returned invalid image data"))?;
                if let Some(parent) = destination.parent() {
                    fs::create_dir_all(parent)?;
                }
                fs::write(&destination, bytes)?;
                if let Value::Object(ref mut m) = out {
                    m.insert(
                        "path".into(),
                        Value::String(destination.to_string_lossy().into_owned()),
                    );
                    m.insert(
                        "url".into(),
                        Value::String(format!("file://{}", destination.to_string_lossy())),
                    );
                    m.remove("png_base64");
                }
                if ctx.json {
                    ctx.emit(&out)?
                } else {
                    ctx.print(format!("OK {path}"))?;
                }
            } else if ctx.json {
                ctx.emit(&out)?;
            } else {
                let location = out
                    .get("url")
                    .or_else(|| out.get("path"))
                    .and_then(Value::as_str)
                    .unwrap_or("OK");
                ctx.print(format!("OK {location}"))?;
            }
        }
        "get" => {
            let id = sid()?;
            let verb = args
                .first()
                .cloned()
                .ok_or_else(|| usage("browser get requires a subcommand"))?;
            args.remove(0);
            let method = match verb.as_str() {
                "url" => "browser.url.get",
                "title" => "browser.get.title",
                "text" => "browser.get.text",
                "html" => "browser.get.html",
                "value" => "browser.get.value",
                "attr" => "browser.get.attr",
                "count" => "browser.get.count",
                "box" => "browser.get.box",
                "styles" => "browser.get.styles",
                _ => return Err(usage(format!("Unsupported browser get subcommand: {verb}"))),
            };
            let selector = take(&mut args, &["--selector"])?;
            if !matches!(verb.as_str(), "url" | "title") && selector.is_none() {
                return Err(usage(format!("browser get {verb} requires a selector")));
            }
            let mut p = json!({"surface_id":id});
            if let Some(v) = selector {
                p["selector"] = v.into();
            }
            if let Some(v) = take(&mut args, &["--attr"])? {
                p["attr"] = v.into();
            }
            if let Some(v) = take(&mut args, &["--property"])? {
                p["property"] = v.into();
            }
            let out = ctx.rpc(method, p)?;
            if ctx.json {
                ctx.emit(&out)?
            } else {
                ctx.print(
                    out.get("value")
                        .map(text_value)
                        .or_else(|| out.get("count").map(text_value))
                        .unwrap_or_else(|| "OK".into()),
                )?;
            }
        }
        "is" => {
            let id = sid()?;
            let verb = args
                .first()
                .cloned()
                .ok_or_else(|| usage("browser is requires a subcommand"))?;
            args.remove(0);
            let selector = take(&mut args, &["--selector"])?
                .or_else(|| non_flags(&args).first().cloned())
                .ok_or_else(|| usage(format!("browser is {verb} requires a selector")))?;
            let method = match verb.as_str() {
                "visible" => "browser.is.visible",
                "enabled" => "browser.is.enabled",
                "checked" => "browser.is.checked",
                _ => return Err(usage(format!("Unsupported browser is subcommand: {verb}"))),
            };
            let out = ctx.rpc(method, json!({"surface_id":id,"selector":selector}))?;
            if ctx.json {
                ctx.emit(&out)?
            } else {
                ctx.print(&text_value(out.get("value").unwrap_or(&Value::Bool(false))))?;
            }
        }
        "find" => {
            let id = sid()?;
            let loc = args
                .first()
                .cloned()
                .ok_or_else(|| usage("browser find requires a locator"))?;
            args.remove(0);
            let mut p = json!({"surface_id":id});
            let method = match loc.as_str() {
                "role" => {
                    let v = take(&mut args, &["--name"])?;
                    let role = non_flags(&args)
                        .first()
                        .cloned()
                        .ok_or_else(|| usage("browser find role requires <role>"))?;
                    p["role"] = role.into();
                    if let Some(v) = v {
                        p["name"] = v.into();
                    }
                    if flag(&mut args, &["--exact"]) {
                        p["exact"] = true.into();
                    }
                    "browser.find.role".to_string()
                }
                "text" | "label" | "placeholder" | "alt" | "title" | "testid" => {
                    let v = non_flags(&args)
                        .first()
                        .cloned()
                        .ok_or_else(|| usage(format!("browser find {loc} requires a value")))?;
                    p[loc.as_str()] = v.into();
                    if flag(&mut args, &["--exact"]) {
                        p["exact"] = true.into();
                    }
                    format!("browser.find.{loc}")
                }
                "first" | "last" => {
                    let v = take(&mut args, &["--selector"])?
                        .or_else(|| non_flags(&args).first().cloned())
                        .ok_or_else(|| usage(format!("browser find {loc} requires a selector")))?;
                    p["selector"] = v.into();
                    format!("browser.find.{loc}")
                }
                "nth" => {
                    let idx = take(&mut args, &["--index"])?
                        .or_else(|| non_flags(&args).first().cloned())
                        .ok_or_else(|| usage("browser find nth requires an integer index"))?;
                    p["index"] = idx
                        .parse::<i64>()
                        .map_err(|_| usage("browser find nth requires an integer index"))?
                        .into();
                    let v = take(&mut args, &["--selector"])?
                        .or_else(|| non_flags(&args).get(1).cloned())
                        .ok_or_else(|| usage("browser find nth requires a selector"))?;
                    p["selector"] = v.into();
                    "browser.find.nth".to_string()
                }
                _ => return Err(usage(format!("Unsupported browser find locator: {loc}"))),
            };
            automation(ctx, &method, p)?;
        }
        "frame" => {
            let id = sid()?;
            let v = args
                .first()
                .cloned()
                .ok_or_else(|| usage("browser frame requires <selector|main>"))?;
            if v == "main" {
                automation(ctx, "browser.frame.main", json!({"surface_id":id}))?
            } else {
                automation(
                    ctx,
                    "browser.frame.select",
                    json!({"surface_id":id,"selector":v}),
                )?
            }
        }
        "dialog" => {
            let id = sid()?;
            let v = args
                .first()
                .cloned()
                .ok_or_else(|| usage("browser dialog requires <accept|dismiss> [text]"))?;
            match v.as_str() {
                "accept" => automation(
                    ctx,
                    "browser.dialog.accept",
                    json!({"surface_id":id,"text":args.iter().skip(1).cloned().collect::<Vec<_>>().join(" ")}),
                )?,
                "dismiss" => automation(ctx, "browser.dialog.dismiss", json!({"surface_id":id}))?,
                _ => return Err(usage(format!("Unsupported browser dialog subcommand: {v}"))),
            }
        }
        "cookies" => {
            let id = sid()?;
            let verb = args.first().cloned().unwrap_or_else(|| "get".into());
            if !args.is_empty() {
                args.remove(0);
            }
            let mut p = json!({"surface_id":id});
            for (n, k) in [
                ("--name", "name"),
                ("--value", "value"),
                ("--url", "url"),
                ("--domain", "domain"),
                ("--path", "path"),
                ("--expires", "expires"),
            ] {
                if let Some(v) = take(&mut args, &[n])? {
                    p[k] = if k == "expires" {
                        v.parse::<i64>()
                            .map_err(|_| usage("--expires must be an integer Unix timestamp"))?
                            .into()
                    } else {
                        v.into()
                    };
                }
            }
            if flag(&mut args, &["--secure"]) {
                p["secure"] = true.into();
            }
            if flag(&mut args, &["--all"]) {
                p["all"] = true.into();
            }
            let method = match verb.as_str() {
                "get" => "browser.cookies.get",
                "set" => {
                    if p.get("name").is_none() {
                        if let Some(v) = non_flags(&args).first() {
                            p["name"] = v.clone().into();
                        }
                    }
                    if p.get("value").is_none() {
                        if let Some(v) = non_flags(&args).get(1) {
                            p["value"] = v.clone().into();
                        }
                    }
                    if p.get("name").is_none() || p.get("value").is_none() {
                        return Err(usage(
                            "browser cookies set requires <name> <value> (or --name/--value)",
                        ));
                    }
                    if flag(&mut args, &["--http-only"]) {
                        p["httpOnly"] = true.into();
                    }
                    "browser.cookies.set"
                }
                "clear" => "browser.cookies.clear",
                _ => {
                    return Err(usage(format!(
                        "Unsupported browser cookies subcommand: {verb}"
                    )));
                }
            };
            automation(ctx, method, p)?;
        }
        "storage" => {
            let id = sid()?;
            let typ = args.first().cloned().unwrap_or_else(|| "local".into());
            if !["local", "session"].contains(&typ.as_str()) {
                return Err(usage("browser storage requires type: local|session"));
            }
            let op = args.get(1).cloned().unwrap_or_else(|| "get".into());
            let vals = args
                .iter()
                .skip(2)
                .filter(|a| !a.starts_with('-'))
                .cloned()
                .collect::<Vec<_>>();
            let mut p = json!({"surface_id":id,"type":typ});
            let method = match op.as_str() {
                "get" => {
                    if let Some(v) = vals.first() {
                        p["key"] = v.clone().into();
                    }
                    "browser.storage.get"
                }
                "set" => {
                    if vals.len() < 2 {
                        return Err(usage(format!(
                            "browser storage {typ} set requires <key> <value>"
                        )));
                    }
                    p["key"] = vals[0].clone().into();
                    p["value"] = vals[1].clone().into();
                    "browser.storage.set"
                }
                "clear" => "browser.storage.clear",
                _ => {
                    return Err(usage(format!(
                        "Unsupported browser storage subcommand: {op}"
                    )));
                }
            };
            automation(ctx, method, p)?;
        }
        "tab" => {
            let id = sid()?;
            let verb = args.first().map(String::as_str).unwrap_or("list");
            let (verb, vals) = if ["new", "list", "close", "switch"].contains(&verb) {
                (verb, args.iter().skip(1).cloned().collect::<Vec<_>>())
            } else if verb.parse::<i64>().is_ok() {
                ("switch", args.clone())
            } else {
                ("list", args.clone())
            };
            let mut p = json!({"surface_id":id});
            let method = match verb {
                "list" => "browser.tab.list",
                "new" => {
                    if !vals.is_empty() {
                        p["url"] = vals.join(" ").into();
                    }
                    "browser.tab.new"
                }
                "switch" | "close" => {
                    if let Some(v) = vals.first() {
                        if let Ok(i) = v.parse::<i64>() {
                            p["index"] = i.into();
                        } else {
                            p["target_surface_id"] = v.clone().into();
                        }
                    }
                    if verb == "switch" {
                        "browser.tab.switch"
                    } else {
                        "browser.tab.close"
                    }
                }
                _ => unreachable!(),
            };
            automation(ctx, method, p)?;
        }
        "viewport" => {
            let id = sid()?;
            let mut p = json!({"surface_id":id});
            if args.first().is_some_and(|x| x == "reset") {
                if args.len() != 1 {
                    return Err(usage(
                        "browser viewport reset does not accept additional arguments",
                    ));
                }
                p["reset"] = true.into();
            } else {
                if args.len() != 2 {
                    return Err(usage("browser viewport requires: <width> <height> | reset"));
                }
                p["width"] = args[0]
                    .parse::<i64>()
                    .map_err(|_| usage("browser viewport requires: <width> <height> | reset"))?
                    .into();
                p["height"] = args[1]
                    .parse::<i64>()
                    .map_err(|_| usage("browser viewport requires: <width> <height> | reset"))?
                    .into();
            }
            automation(ctx, "browser.viewport.set", p)?;
        }
        "geolocation" | "geo" => {
            let id = sid()?;
            if args.len() < 2 {
                return Err(usage(
                    "browser geolocation requires: <latitude> <longitude>",
                ));
            }
            automation(
                ctx,
                "browser.geolocation.set",
                json!({"surface_id":id,"latitude":args[0].parse::<f64>().map_err(|_|usage("browser geolocation requires: <latitude> <longitude>"))?,"longitude":args[1].parse::<f64>().map_err(|_|usage("browser geolocation requires: <latitude> <longitude>"))?}),
            )?;
        }
        "offline" => {
            let id = sid()?;
            let raw = args
                .first()
                .ok_or_else(|| usage("browser offline requires true|false"))?;
            let v = parse_bool(raw).ok_or_else(|| usage("browser offline requires true|false"))?;
            automation(
                ctx,
                "browser.offline.set",
                json!({"surface_id":id,"enabled":v}),
            )?;
        }
        "trace" | "screencast" => {
            let id = sid()?;
            let v = args
                .first()
                .ok_or_else(|| usage(format!("browser {sub} requires start|stop")))?;
            if v != "start" && v != "stop" {
                return Err(usage(format!("Unsupported browser {sub} subcommand: {v}")));
            }
            let mut p = json!({"surface_id":id});
            if sub == "trace" {
                if let Some(v) = args.get(1) {
                    p["path"] = v.clone().into();
                }
            }
            automation(ctx, &format!("browser.{sub}.{}", v), p)?;
        }
        "network" => {
            let id = sid()?;
            let v = args
                .first()
                .ok_or_else(|| usage("browser network requires route|unroute|requests"))?;
            let mut p = json!({"surface_id":id});
            let method = match v.as_str() {
                "route" => {
                    let pat = args
                        .get(1)
                        .ok_or_else(|| usage("browser network route requires a URL/pattern"))?;
                    p["url"] = pat.clone().into();
                    if flag(&mut args, &["--abort"]) {
                        p["abort"] = true.into();
                    }
                    if let Some(b) = take(&mut args, &["--body"])? {
                        p["body"] = b.into();
                    }
                    "browser.network.route"
                }
                "unroute" => {
                    let pat = args
                        .get(1)
                        .ok_or_else(|| usage("browser network unroute requires a URL/pattern"))?;
                    p["url"] = pat.clone().into();
                    "browser.network.unroute"
                }
                "requests" => "browser.network.requests",
                _ => {
                    return Err(usage(format!(
                        "Unsupported browser network subcommand: {v}"
                    )));
                }
            };
            automation(ctx, method, p)?;
        }
        "input" | "input_mouse" | "input_keyboard" | "input_touch" => {
            let id = sid()?;
            let (method, rest) = if sub == "input" {
                let v = args
                    .first()
                    .ok_or_else(|| usage("browser input requires mouse|keyboard|touch"))?;
                (
                    format!("browser.input_{v}"),
                    args.iter().skip(1).cloned().collect::<Vec<_>>(),
                )
            } else {
                (format!("browser.{sub}"), args.clone())
            };
            let mut p = json!({"surface_id":id});
            if !rest.is_empty() {
                p["args"] = json!(rest);
            }
            automation(ctx, &method, p)?;
        }
        "react-grab" | "reactgrab" => automation(
            ctx,
            "browser.react_grab.toggle",
            routing_params(ctx, args, surface_raw.as_deref()).map(Value::Object)?,
        )?,
        "devtools" | "dev-tools" => {
            let v = args.first().map(String::as_str).unwrap_or("toggle");
            let method = match v {
                "toggle" => "browser.devtools.toggle",
                "console" => "browser.console.show",
                _ => return Err(usage("browser devtools requires toggle|console")),
            };
            automation(
                ctx,
                method,
                routing_params(ctx, args, surface_raw.as_deref()).map(Value::Object)?,
            )?;
        }
        "focus-mode" | "design-mode" => {
            let design = sub == "design-mode";
            let mode = args.first().cloned().unwrap_or_else(|| {
                if design {
                    "status".into()
                } else {
                    "toggle".into()
                }
            });
            let method = if design && mode == "status" {
                "browser.design_mode.status"
            } else if design {
                "browser.design_mode.set"
            } else {
                "browser.focus_mode.set"
            };
            let mut p = routing_params(ctx, args.clone(), surface_raw.as_deref())?;
            p.insert("mode".into(), mode.clone().into());
            automation(ctx, method, Value::Object(p))?;
        }
        "zoom" => {
            let v = args.first().cloned().ok_or_else(|| {
                usage("browser zoom requires in, out, reset, or a numeric factor")
            })?;
            let mut p = routing_params(ctx, args.clone(), surface_raw.as_deref())?;
            if ["in", "out", "reset"].contains(&v.as_str()) {
                p.insert("direction".into(), v.clone().into());
            } else {
                p.insert(
                    "zoom".into(),
                    v.parse::<f64>()
                        .map_err(|_| {
                            usage("browser zoom requires in, out, reset, or a numeric factor")
                        })?
                        .into(),
                );
            }
            automation(ctx, "browser.zoom.set", Value::Object(p))?;
        }
        "history" => {
            if !flag(&mut args, &["--force", "--yes"]) {
                return Err(usage("browser history clear requires --force or --yes"));
            }
            automation(ctx, "browser.history.clear", json!({"force":true}))?;
        }
        "console" | "errors" => {
            let id = sid()?;
            let verb = args.first().map(String::as_str).unwrap_or("list");
            let mut p = json!({"surface_id":id});
            let method = if sub == "console" {
                match verb {
                    "list" => "browser.console.list",
                    "clear" => "browser.console.clear",
                    _ => return Err(usage("Unsupported browser console subcommand")),
                }
            } else {
                match verb {
                    "list" => "browser.errors.list",
                    "clear" => {
                        p["clear"] = true.into();
                        "browser.errors.list"
                    }
                    _ => return Err(usage("Unsupported browser errors subcommand")),
                }
            };
            let out = ctx.rpc(method, p)?;
            if ctx.json {
                ctx.emit(&out)?
            } else {
                let key = if sub == "console" {
                    "entries"
                } else {
                    "errors"
                };
                ctx.print(browser_log_text(
                    out.get(key),
                    if sub == "console" {
                        "No console entries"
                    } else {
                        "No browser errors"
                    },
                ))?;
            }
        }
        "highlight" => {
            let id = sid()?;
            let s = take(&mut args, &["--selector"])?
                .or_else(|| non_flags(&args).first().cloned())
                .ok_or_else(|| usage("browser highlight requires a selector"))?;
            automation(
                ctx,
                "browser.highlight",
                json!({"surface_id":id,"selector":s}),
            )?;
        }
        "state" => {
            let id = sid()?;
            let v = args
                .first()
                .ok_or_else(|| usage("browser state requires save|load <path>"))?;
            let path = args
                .get(1)
                .ok_or_else(|| usage(format!("browser state {v} requires a file path")))?;
            let method = match v.as_str() {
                "save" => "browser.state.save",
                "load" => "browser.state.load",
                _ => return Err(usage(format!("Unsupported browser state subcommand: {v}"))),
            };
            automation(ctx, method, json!({"surface_id":id,"path":path}))?;
        }
        "addinitscript" | "addscript" | "addstyle" => {
            let id = sid()?;
            let (field, opt) = if sub == "addstyle" {
                ("css", "--css")
            } else {
                ("script", "--script")
            };
            let content = take(&mut args, &[opt])?.unwrap_or_else(|| args.join(" "));
            if content.trim().is_empty() {
                return Err(usage(format!("browser {sub} requires content")));
            }
            let mut p = Map::new();
            p.insert("surface_id".into(), id.into());
            p.insert(field.into(), content.trim().into());
            automation(ctx, &format!("browser.{sub}"), Value::Object(p))?;
        }
        _ => return Err(usage(format!("Unsupported browser subcommand: {sub}"))),
    }
    Ok(Some(0))
}
