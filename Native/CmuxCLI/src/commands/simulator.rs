//! Native Rust owner for iOS Simulator/device CLI commands.
use crate::{CliError, Context, Result, args};
use serde_json::{Map, Value, json};
use std::fs;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const TEXT_LIMIT: usize = 4 * 1024;
const INSPECTOR_LIMIT: usize = 1024 * 1024;
const SCREENSHOT_LIMIT: usize = 8;
const BATCH_TIMEOUT: Duration = Duration::from_secs(600);

pub fn run(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>> {
    if matches!(command, "simulator" | "ios")
        && args
            .iter()
            .take_while(|v| v.as_str() != "--")
            .any(|v| v == "--help" || v == "-h")
    {
        ctx.print(SIMULATOR_HELP)?;
        return Ok(Some(0));
    }
    match command {
        "simulator" => simulator(ctx, args),
        "ios" => ios(ctx, args),
        _ => Ok(None),
    }
}
const SIMULATOR_HELP: &str = "Usage: cmux simulator <subcommand> [args] [--surface <id|ref|index>]\n\n  type [text] [--stdin|--file <path>]\n  tap <x> <y> [x2 y2]\n  gesture|multitouch <json> [--stdin|--file <path>]\n  swipe <x1> <y1> <x2> <y2> [x3 y3 x4 y4] [steps]\n  button <name>\n  rotate <orientation>\n  select <device-udid>\n  ca <diagnostic> <on|off>\n  memory-warning\n  event-log [limit]\n  tools <show|hide|toggle>\n  camera <configure|switch|mirror|status|webcams|stop> ...\n  permissions <list|grant|revoke|reset> ...\n  ui [status|get|set] [option] [value]\n  accessibility\n  foreground\n  targets\n  attach <target-id>\n  send [json] [--stdin|--file <path>]\n  highlight <on|off>\n  release\n\ncmux ios accepts every simulator command and additionally:\n  list [--workspace <ref>]\n  context [--udid] [--surface <ref>]\n  screenshot [--surface <ref>|--workspace <ref>|--all] [--out <path>]\n\nCoordinates are normalized from 0 through 1. Commands wait for their correlated worker result. Screenshot --all captures at most 8 Simulator panes.";
fn usage(s: impl Into<String>) -> CliError {
    CliError::usage(s)
}
fn object(v: Value) -> Map<String, Value> {
    v.as_object().cloned().unwrap_or_default()
}
fn absolute_path(raw: impl AsRef<Path>) -> Result<PathBuf> {
    let path = raw.as_ref();
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut normalized = PathBuf::new();
    for part in absolute.components() {
        match part {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            _ => normalized.push(part.as_os_str()),
        }
    }
    Ok(normalized)
}
fn ca_diagnostic(raw: &str) -> String {
    match raw.to_ascii_lowercase().as_str() {
        "slow-animations" | "slow_animations" | "slowanimations" => "slowAnimations".into(),
        other => other.into(),
    }
}
fn text(v: Option<&Value>) -> String {
    display(v, "?")
}
fn display(v: Option<&Value>, fallback: &str) -> String {
    sanitize(
        &v.and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| v.filter(|x| !x.is_null()).map(ToString::to_string))
            .unwrap_or_else(|| fallback.into()),
    )
}
fn sanitize(value: &str) -> String {
    value.chars().map(|c| {
        if c.is_control() || matches!(c, '\u{00ad}' | '\u{061c}' | '\u{06dd}' | '\u{070f}' | '\u{08e2}' | '\u{180e}' | '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{206f}' | '\u{feff}' | '\u{fff9}'..='\u{fffb}' | '\u{110bd}' | '\u{110cd}' | '\u{13430}'..='\u{13455}' | '\u{1bca0}'..='\u{1bca3}' | '\u{1d173}'..='\u{1d17a}' | '\u{e0001}' | '\u{e0020}'..='\u{e007f}') { '\u{fffd}' } else { c }
    }).collect()
}
fn print_accessibility(ctx: &Context, p: &Value) -> Result<()> {
    let mut stack: Vec<(&Value, usize)> = p
        .get("roots")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .rev()
        .map(|v| (v, 0))
        .collect();
    let mut emitted = 0;
    while let Some((node, depth)) = stack.pop() {
        if emitted >= 500 {
            stack.push((node, depth));
            break;
        }
        emitted += 1;
        ctx.print(format!(
            "{}{}\t{}\t{}\t{}",
            "  ".repeat(depth.min(16)),
            text(node.get("type")),
            display(node.get("AXLabel"), ""),
            display(node.get("AXValue"), ""),
            display(node.get("AXUniqueId"), "")
        ))?;
        for child in node
            .get("children")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .rev()
        {
            stack.push((child, depth + 1));
        }
    }
    if p.get("truncated").and_then(Value::as_bool) == Some(true) || !stack.is_empty() {
        ctx.print("Accessibility results reached the 500-element limit")?;
    }
    Ok(())
}

#[derive(Default)]
struct Parsed {
    surface: Option<String>,
    stdin: bool,
    file: Option<String>,
    value: Option<String>,
    positionals: Vec<String>,
}
fn parse_args(values: &[String]) -> Result<Parsed> {
    let mut p = Parsed::default();
    let mut after = false;
    let mut i = 0;
    while i < values.len() {
        let a = &values[i];
        if after {
            p.positionals.push(a.clone());
            i += 1;
            continue;
        }
        match a.as_str() {
            "--" => after = true,
            "--stdin" => p.stdin = true,
            "--surface" | "--file" | "--value" => {
                i += 1;
                let v = values
                    .get(i)
                    .ok_or_else(|| usage(format!("{a} requires a value")))?
                    .clone();
                match a.as_str() {
                    "--surface" => p.surface = Some(v),
                    "--file" => p.file = Some(v),
                    _ => p.value = Some(v),
                }
            }
            x if x.starts_with("--value=") => {
                let v = x[8..].to_string();
                if v.is_empty() {
                    return Err(usage("--value requires a value"));
                }
                p.value = Some(v);
            }
            x if x.starts_with("--") => {
                return Err(usage(format!("simulator: unknown flag '{x}'")));
            }
            _ => p.positionals.push(a.clone()),
        }
        i += 1;
    }
    Ok(p)
}
fn read_bounded<R: Read>(r: R, limit: usize) -> Result<Vec<u8>> {
    let mut b = Vec::new();
    r.take((limit + 1) as u64).read_to_end(&mut b)?;
    if b.len() > limit {
        Err(CliError::new(
            "input_too_large",
            format!("simulator input exceeds the {limit}-byte UTF-8 limit"),
        ))
    } else {
        Ok(b)
    }
}
fn source(p: &Parsed, limit: usize) -> Result<String> {
    if p.value.is_some() {
        return Err(usage("--value is not valid for this simulator command"));
    }
    let count =
        (!p.positionals.is_empty() as usize) + (p.stdin as usize) + (p.file.is_some() as usize);
    if count == 0 {
        return Err(usage(
            "simulator input requires a positional value, --stdin, or --file",
        ));
    }
    if count != 1 || p.positionals.len() > 1 {
        return Err(usage("simulator input sources are mutually exclusive"));
    }
    let b = if let Some(v) = p.positionals.first() {
        if v.len() > limit {
            return Err(CliError::new(
                "input_too_large",
                format!("simulator input exceeds the {limit}-byte UTF-8 limit"),
            ));
        }
        return Ok(v.clone());
    } else if p.stdin {
        read_bounded(std::io::stdin().lock(), limit)?
    } else {
        read_bounded(fs::File::open(p.file.as_ref().unwrap())?, limit)?
    };
    String::from_utf8(b)
        .map_err(|_| CliError::new("invalid_utf8", "simulator input must be valid UTF-8"))
}
fn no_source(p: &Parsed, sub: &str) -> Result<()> {
    if !p.positionals.is_empty() || p.stdin || p.file.is_some() || p.value.is_some() {
        Err(usage(format!("simulator {sub} does not accept input")))
    } else {
        Ok(())
    }
}
fn coord(s: &str) -> Result<f64> {
    let x = s
        .parse::<f64>()
        .map_err(|_| usage("Simulator coordinates must be numbers from 0 through 1"))?;
    if x.is_finite() && (0.0..=1.0).contains(&x) {
        Ok(x)
    } else {
        Err(usage(
            "Simulator coordinates must be numbers from 0 through 1",
        ))
    }
}
fn on_off(s: &str) -> Option<bool> {
    match s.to_ascii_lowercase().as_str() {
        "on" | "true" | "1" => Some(true),
        "off" | "false" | "0" => Some(false),
        _ => None,
    }
}
fn button(s: &str) -> String {
    match s.to_ascii_lowercase().replace('_', "-").as_str() {
        "swipe-home" | "swipehome" => "swipeHome",
        "app-switcher" | "appswitcher" => "appSwitcher",
        "side-button" | "sidebutton" => "sideButton",
        "volume-up" | "volumeup" => "volumeUp",
        "volume-down" | "volumedown" => "volumeDown",
        "watch-side-button" | "watchsidebutton" => "watchSideButton",
        x => x,
    }
    .into()
}

fn routing(ctx: &Context, surface: Option<&str>) -> Result<Map<String, Value>> {
    let mut p = Map::new();
    if let Some(w) = ctx.window.as_deref() {
        if let Some(id) = ctx.resolve_id("window", Some(w))? {
            p.insert("window_id".into(), json!(id));
        }
    }
    if ctx.window.is_none()
        && surface
            .map(|s| s.trim().is_empty() || s.trim().parse::<i64>().is_ok())
            .unwrap_or(true)
    {
        if let Ok(workspace) = std::env::var("CMUX_WORKSPACE_ID") {
            if !workspace.trim().is_empty() {
                if let Some(id) = ctx.resolve_id("workspace", Some(workspace.trim()))? {
                    p.insert("workspace_id".into(), json!(id));
                }
            }
        }
    }
    if let Some(s) = surface {
        if let Some(id) = ctx.resolve_id("surface", Some(s))? {
            p.insert("surface_id".into(), json!(id));
        }
    }
    Ok(p)
}
#[derive(Clone)]
enum Output {
    Completed,
    Typed,
    Targets,
    Send,
    Events,
    Camera,
    Permissions,
    PermissionsUpdated {
        action: String,
        service: String,
        bundle: String,
    },
    UIStatus,
    UIValue(String),
    UIUpdated(String),
    Accessibility,
    Foreground,
}
fn print_agent(ctx: &Context, p: &Value, o: Output) -> Result<()> {
    if ctx.json || matches!(o, Output::Camera) {
        return ctx.emit(p);
    }
    match o {
        Output::Completed => ctx.print("Completed"),
        Output::Typed => ctx.print(format!(
            "Typed {} character(s)",
            p.get("character_count")
                .and_then(Value::as_u64)
                .unwrap_or(0)
        )),
        Output::Send => ctx.print(p.get("response_json").and_then(Value::as_str).unwrap_or("")),
        Output::Targets => {
            if p.get("targets")
                .and_then(Value::as_array)
                .map(Vec::is_empty)
                .unwrap_or(true)
            {
                return ctx.print("No Web Inspector targets");
            }
            for t in p
                .get("targets")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                ctx.print(format!(
                    "{}\t{}\t{}\t{}",
                    text(t.get("id")),
                    text(t.get("application_name")),
                    display(t.get("title"), ""),
                    display(t.get("url"), "")
                ))?;
            }
            Ok(())
        }
        Output::Events => {
            for e in p
                .get("events")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                ctx.print(format!(
                    "{}\t{}\t{}",
                    display(e.get("timestamp"), ""),
                    display(e.get("action"), ""),
                    display(e.get("summary"), "")
                ))?;
            }
            Ok(())
        }
        Output::Permissions => {
            if let Some(applications) = p.get("applications").and_then(Value::as_array) {
                if applications.is_empty() {
                    return ctx.print("No permission values");
                }
                let mut apps: Vec<_> = applications.iter().collect();
                apps.sort_by_key(|a| a.get("bundle_id").and_then(Value::as_str).unwrap_or(""));
                for app in apps {
                    for (k, v) in app
                        .get("permissions")
                        .and_then(Value::as_object)
                        .into_iter()
                        .flatten()
                    {
                        ctx.print(format!(
                            "{}\t{}\t{}",
                            text(app.get("bundle_id")),
                            sanitize(k),
                            display(Some(v), "unknown")
                        ))?;
                    }
                }
                if p.get("truncated").and_then(Value::as_bool) == Some(true) {
                    ctx.print("Permission results were truncated at 256 applications")?;
                }
                return Ok(());
            }
            if p.get("permissions")
                .and_then(Value::as_object)
                .map(Map::is_empty)
                .unwrap_or(true)
            {
                return ctx.print("No permission values");
            }
            if let Some(m) = p.get("permissions").and_then(Value::as_object) {
                for (k, v) in m {
                    ctx.print(format!("{k}\t{}", text(Some(v))))?;
                }
            }
            for a in p
                .get("applications")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let id = text(a.get("bundle_id"));
                if let Some(m) = a.get("permissions").and_then(Value::as_object) {
                    for (k, v) in m {
                        ctx.print(format!("{id}\t{k}\t{}", text(Some(v))))?;
                    }
                }
            }
            Ok(())
        }
        Output::PermissionsUpdated {
            action,
            service,
            bundle,
        } => ctx.print(format!(
            "{} {} for {}",
            sanitize(&action),
            sanitize(&service),
            sanitize(&bundle)
        )),
        Output::UIStatus => {
            if p.get("settings")
                .and_then(Value::as_object)
                .map(Map::is_empty)
                .unwrap_or(true)
            {
                return ctx.print("No interface settings");
            }
            for (k, v) in p
                .get("settings")
                .and_then(Value::as_object)
                .into_iter()
                .flatten()
            {
                ctx.print(format!("{k}\t{}", text(Some(v))))?;
            }
            Ok(())
        }
        Output::UIValue(option) => {
            ctx.print(display(p.get("settings").and_then(|x| x.get(&option)), ""))
        }
        Output::UIUpdated(option) => ctx.print(format!(
            "Set {} to {}",
            sanitize(&option),
            display(p.get("settings").and_then(|x| x.get(&option)), "")
        )),
        Output::Accessibility => print_accessibility(ctx, p),
        Output::Foreground => {
            if let Some(a) = p.get("application") {
                ctx.print(format!(
                    "{}\t{}\t{}\t{}\t{}",
                    display(a.get("name").or_else(|| a.get("bundle_id")), "?"),
                    text(a.get("bundle_id")),
                    display(a.get("pid"), ""),
                    display(a.get("executable"), ""),
                    display(a.get("bundle_path"), "")
                ))
            } else {
                ctx.print("No foreground application")
            }
        }
        Output::Camera => unreachable!(),
    }
}

fn simulator(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let sub = args
        .first()
        .map(|s| s.to_ascii_lowercase())
        .ok_or_else(|| usage("cmux simulator <subcommand>"))?;
    let p = parse_args(&args[1..])?;
    if let Some((method, extra, out)) = agent_request(&sub, &p)? {
        if ctx.dry_run {
            return preview(ctx, &method, &p, Value::Object(extra));
        }
        let mut params = routing(ctx, p.surface.as_deref())?;
        params.extend(extra);
        let value = rpc(ctx, &method, Value::Object(params), None)?;
        print_agent(ctx, &value, out)?;
        return Ok(Some(0));
    }
    let (method, extra, out) = match sub.as_str() {
        "type" => (
            "simulator.type",
            json!({"text":source(&p,TEXT_LIMIT)?}),
            Output::Typed,
        ),
        "targets" => {
            no_source(&p, &sub)?;
            (
                "simulator.web_inspector.targets",
                json!({}),
                Output::Targets,
            )
        }
        "attach" => {
            if p.positionals.len() != 1 || p.file.is_some() || p.stdin {
                return Err(usage("simulator attach <target-id>"));
            }
            (
                "simulator.web_inspector.attach",
                json!({"target_id":p.positionals[0]}),
                Output::Completed,
            )
        }
        "send" => (
            "simulator.web_inspector.send",
            json!({"json":source(&p,INSPECTOR_LIMIT)?}),
            Output::Send,
        ),
        "highlight" => {
            if p.positionals.len() != 1 || p.file.is_some() || p.stdin {
                return Err(usage("simulator highlight <on|off>"));
            }
            let e = on_off(&p.positionals[0])
                .ok_or_else(|| usage("simulator highlight requires on or off"))?;
            (
                "simulator.web_inspector.highlight",
                json!({"enabled":e}),
                Output::Completed,
            )
        }
        "release" => {
            no_source(&p, &sub)?;
            (
                "simulator.web_inspector.release",
                json!({}),
                Output::Completed,
            )
        }
        _ => {
            return Err(CliError::new(
                "unknown_subcommand",
                format!("Unknown simulator subcommand: {sub}"),
            ));
        }
    };
    if ctx.dry_run {
        return preview(ctx, method, &p, extra);
    }
    let mut params = routing(ctx, p.surface.as_deref())?;
    params.extend(object(extra));
    let value = rpc(ctx, method, Value::Object(params), None)?;
    print_agent(ctx, &value, out)?;
    Ok(Some(0))
}
fn preview(ctx: &Context, method: &str, parsed: &Parsed, params: Value) -> Result<Option<i32>> {
    ctx.emit(&json!({"dry_run":true,"method":method,"params":params,"surface":parsed.surface,"window":ctx.window}))?;
    Ok(Some(0))
}

fn rpc(ctx: &Context, method: &str, params: Value, deadline: Option<Instant>) -> Result<Value> {
    let seconds = match method {
        "simulator.select_device" | "simulator.context" | "simulator.prepare_screenshot" => 560,
        "simulator.type" => 680,
        "simulator.web_inspector.send" => 580,
        m if m.starts_with("simulator.web_inspector.") => 575,
        "simulator.ui.status" => 140,
        "simulator.ui.set" => 260,
        "simulator.permissions.set"
            if params.get("service").and_then(Value::as_str) == Some("all") =>
        {
            200
        }
        "simulator.permissions.set" => 80,
        "simulator.camera.configure" | "simulator.camera.switch" => 170,
        _ => 45,
    };
    let mut request = ctx.clone();
    request.timeout = if method == "simulator.type" {
        Duration::from_secs_f64(
            560.0 + text_delivery_timeout(params.get("text").and_then(Value::as_str).unwrap_or("")),
        )
    } else {
        Duration::from_secs(seconds)
    };
    if let Some(deadline) = deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(batch_timeout());
        }
        request.timeout = request.timeout.min(remaining);
    }
    request.rpc(method, params)
}
fn text_delivery_timeout(text: &str) -> f64 {
    if text.is_empty() {
        return 120.0;
    }
    let mut chars = text.chars().peekable();
    let mut events = 0;
    while let Some(c) = chars.next() {
        if c == '\r' {
            events += 2;
            if chars.peek() == Some(&'\n') {
                chars.next();
            }
        } else if c.is_ascii_uppercase() || "_+{}|:\"~<>?!@#$%^&*()".contains(c) {
            events += 4;
        } else if c.is_ascii_lowercase() || c.is_ascii_digit() || "\n\t -=[]\\;'`,./".contains(c) {
            events += 2;
        } else {
            return 120.0;
        }
    }
    (10.0 + events as f64 * 0.012).clamp(10.0, 120.0)
}
fn batch_timeout() -> CliError {
    CliError::new(
        "timeout",
        "The iOS Simulator screenshot batch exceeded its 10-minute deadline",
    )
}

fn agent_request(sub: &str, p: &Parsed) -> Result<Option<(String, Map<String, Value>, Output)>> {
    let v = &p.positionals;
    if sub != "permissions" && sub != "ui" && p.value.is_some() {
        return Err(usage(format!("invalid arguments for simulator {sub}")));
    }
    let req = |m: &str, x: Value, o: Output| Ok(Some((m.into(), object(x), o)));
    match sub {
        "select" | "select-device" => {
            if v.len() != 1 || p.stdin || p.file.is_some() {
                return Err(usage(format!("simulator {sub} <device-id>")));
            }
            req(
                "simulator.select_device",
                json!({"device_id":v[0]}),
                Output::Completed,
            )
        }
        "tap" => {
            if p.stdin || p.file.is_some() || !(v.len() == 2 || v.len() == 4) {
                return Err(usage("simulator tap <x> <y> [x2 y2]"));
            }
            let mut x = json!({"x":coord(&v[0])?,"y":coord(&v[1])?});
            if v.len() == 4 {
                x["x2"] = json!(coord(&v[2])?);
                x["y2"] = json!(coord(&v[3])?)
            }
            req("simulator.tap", x, Output::Completed)
        }
        "gesture" | "multitouch" | "multi-touch" => {
            let raw = source(p, 64 * 1024)?;
            let d: Value = serde_json::from_str(&raw).map_err(|_| {
                CliError::new(
                    "invalid_gesture_json",
                    "simulator gesture requires a JSON touch object or array",
                )
            })?;
            let events = if d.is_array() { d } else { json!([d]) };
            let ok = events
                .as_array()
                .map(|a| !a.is_empty() && a.len() <= 256 && a.iter().all(Value::is_object))
                .unwrap_or(false);
            if !ok {
                return Err(CliError::new(
                    "invalid_gesture_json",
                    "simulator gesture requires a JSON touch object or array",
                ));
            }
            req(
                if sub == "gesture" {
                    "simulator.gesture"
                } else {
                    "simulator.multi_touch"
                },
                json!({"events":events}),
                Output::Completed,
            )
        }
        "swipe" => {
            if p.stdin || p.file.is_some() || ![4, 5, 8, 9].contains(&v.len()) {
                return Err(usage("simulator swipe <x1> <y1> <x2> <y2> [steps]"));
            }
            let mut x = json!({"from_x":coord(&v[0])?,"from_y":coord(&v[1])?,"to_x":coord(&v[2])?,"to_y":coord(&v[3])?});
            let off = if v.len() >= 8 {
                x["from_x2"] = json!(coord(&v[4])?);
                x["from_y2"] = json!(coord(&v[5])?);
                x["to_x2"] = json!(coord(&v[6])?);
                x["to_y2"] = json!(coord(&v[7])?);
                8
            } else {
                4
            };
            if v.len() == 5 || v.len() == 9 {
                let n = v[off]
                    .parse::<u64>()
                    .map_err(|_| usage("swipe steps must be 2 through 64"))?;
                if !(2..=64).contains(&n) {
                    return Err(usage("swipe steps must be 2 through 64"));
                }
                x["steps"] = json!(n)
            }
            req("simulator.swipe", x, Output::Completed)
        }
        "button" => {
            if v.len() != 1 || p.stdin || p.file.is_some() {
                return Err(usage("simulator button <name>"));
            }
            req(
                "simulator.button",
                json!({"button":button(&v[0])}),
                Output::Completed,
            )
        }
        "rotate" => {
            if v.len() != 1 || p.stdin || p.file.is_some() {
                return Err(usage("simulator rotate <orientation>"));
            }
            req(
                "simulator.rotate",
                json!({"orientation":v[0].replace('-', "_")}),
                Output::Completed,
            )
        }
        "ca" => {
            if v.len() != 2 || p.stdin || p.file.is_some() {
                return Err(usage("simulator ca <diagnostic> <on|off>"));
            }
            let e = on_off(&v[1]).ok_or_else(|| usage("simulator ca requires on or off"))?;
            req(
                "simulator.core_animation",
                json!({"diagnostic":ca_diagnostic(&v[0]),"enabled":e}),
                Output::Completed,
            )
        }
        "memory-warning" | "memory_warning" => {
            no_source(p, sub)?;
            req("simulator.memory_warning", json!({}), Output::Completed)
        }
        "event-log" | "events" => {
            if p.stdin || p.file.is_some() || v.len() > 1 {
                return Err(usage("simulator event-log [limit]"));
            }
            let mut x = json!({});
            if let Some(r) = v.first() {
                let n = r
                    .parse::<u64>()
                    .map_err(|_| usage("event-log limit must be 1 through 500"))?;
                if !(1..=500).contains(&n) {
                    return Err(usage("event-log limit must be 1 through 500"));
                }
                x["limit"] = json!(n)
            }
            req("simulator.event_log", x, Output::Events)
        }
        "tools" => {
            if p.stdin
                || p.file.is_some()
                || v.len() != 1
                || !["show", "hide", "toggle"].contains(&v[0].to_ascii_lowercase().as_str())
            {
                return Err(usage("simulator tools <show|hide|toggle>"));
            }
            req(
                "simulator.tools",
                json!({"action":v[0].to_ascii_lowercase()}),
                Output::Completed,
            )
        }
        "permissions" => permissions(v, p),
        "ui" => ui(v, p),
        "accessibility" | "ax" => {
            no_source(p, sub)?;
            req("simulator.accessibility", json!({}), Output::Accessibility)
        }
        "foreground" => {
            no_source(p, sub)?;
            req("simulator.foreground", json!({}), Output::Foreground)
        }
        "camera" => camera(v, p),
        _ => Ok(None),
    }
}
fn camera(v: &[String], p: &Parsed) -> Result<Option<(String, Map<String, Value>, Output)>> {
    if p.stdin || p.file.is_some() || v.is_empty() {
        return Err(usage(
            "simulator camera <configure|switch|mirror|status|stop> ...",
        ));
    }
    let a = v[0].to_ascii_lowercase();
    match a.as_str() {
        "status" | "webcams" if v.len() == 1 => Ok(Some((
            "simulator.camera.status".into(),
            Map::new(),
            Output::Camera,
        ))),
        "stop" if v.len() == 1 => Ok(Some((
            "simulator.camera.configure".into(),
            object(json!({"source":"off"})),
            Output::Camera,
        ))),
        "mirror" if v.len() == 2 && ["auto", "on", "off"].contains(&v[1].as_str()) => Ok(Some((
            "simulator.camera.mirror".into(),
            object(json!({"mode":v[1]})),
            Output::Camera,
        ))),
        "configure" => {
            if v.len() < 2 {
                return Err(usage("camera configure <bundle-id> [source ...]"));
            }
            let mut x = if v.len() == 2 {
                object(json!({"source":"placeholder"}))
            } else {
                camera_source(&v[2..])?
            };
            x.insert("bundle_id".into(), json!(v[1]));
            Ok(Some((
                "simulator.camera.configure".into(),
                x,
                Output::Camera,
            )))
        }
        "switch" => {
            if v.len() < 2 || ["off", "disabled"].contains(&v[1].to_ascii_lowercase().as_str()) {
                return Err(usage("camera switch <source> ..."));
            }
            Ok(Some((
                "simulator.camera.switch".into(),
                camera_source(&v[1..])?,
                Output::Camera,
            )))
        }
        _ => Err(usage("unknown camera subcommand")),
    }
}
fn camera_source(v: &[String]) -> Result<Map<String, Value>> {
    if v.is_empty() {
        return Err(usage("camera source is required"));
    }
    let s = v[0].to_ascii_lowercase();
    if ![
        "off",
        "placeholder",
        "image",
        "file",
        "video",
        "host",
        "webcam",
    ]
    .contains(&s.as_str())
    {
        return Err(usage("unknown camera source"));
    }
    let mut x = object(json!({"source":s}));
    let mut i = 1;
    if ["image", "file", "video"].contains(&s.as_str()) {
        let path = v
            .get(i)
            .ok_or_else(|| usage("camera source path is required"))?;
        x.insert("path".into(), json!(absolute_path(path)?));
        i += 1;
        if s == "file" || s == "video" {
            x.insert("loops".into(), json!(true));
        }
    } else if ["host", "webcam"].contains(&s.as_str()) {
        if let Some(id) = v.get(i) {
            x.insert("device_id".into(), json!(id));
            i += 1
        }
    }
    if v.get(i)
        .map(|z| z.eq_ignore_ascii_case("loop"))
        .unwrap_or(false)
    {
        x.insert("loops".into(), json!(true));
        i += 1
    }
    if i != v.len() {
        return Err(usage("invalid camera arguments"));
    }
    Ok(x)
}
fn validate_bundle(v: &str) -> Result<()> {
    let b = v.as_bytes();
    if b.is_empty()
        || b.len() > 255
        || !b[0].is_ascii_alphanumeric()
        || !b
            .iter()
            .all(|c| c.is_ascii_alphanumeric() || *c == b'-' || *c == b'.')
    {
        return Err(CliError::new(
            "invalid_bundle_identifier",
            format!("Invalid Simulator application bundle identifier: {v}"),
        ));
    }
    Ok(())
}
fn permissions(v: &[String], p: &Parsed) -> Result<Option<(String, Map<String, Value>, Output)>> {
    if p.stdin || p.file.is_some() || v.is_empty() {
        return Err(usage("simulator permissions list|grant|revoke|reset ..."));
    }
    let a = v[0].to_ascii_lowercase();
    if a == "list" || a == "read" {
        if v.len() > 2 || p.value.is_some() {
            return Err(usage("permissions list [bundle-id]"));
        }
        let mut x = Map::new();
        if let Some(id) = v.get(1) {
            validate_bundle(id)?;
            x.insert("bundle_id".into(), json!(id));
        }
        return Ok(Some((
            "simulator.permissions.read".into(),
            x,
            Output::Permissions,
        )));
    }
    if !["grant", "revoke", "deny", "reset"].contains(&a.as_str()) || v.len() < 3 || v.len() > 4 {
        return Err(usage(
            "permissions grant|revoke|reset <permission> <bundle-id> [value]",
        ));
    }
    validate_bundle(&v[2])?;
    if p.value.is_some() && v.len() == 4 {
        return Err(usage(
            "permissions accepts either --value or a positional value",
        ));
    }
    let (action, service) =
        normalize_permission(&a, &v[1], p.value.clone().or_else(|| v.get(3).cloned()))?;
    Ok(Some((
        "simulator.permissions.set".into(),
        object(json!({"action":action,"service":service,"bundle_id":v[2]})),
        Output::PermissionsUpdated {
            action,
            service,
            bundle: v[2].clone(),
        },
    )))
}
fn normalize_permission(
    action: &str,
    raw: &str,
    value: Option<String>,
) -> Result<(String, String)> {
    let action = if action == "deny" { "revoke" } else { action };
    let mut p = raw.to_ascii_lowercase().replace('_', "-");
    let mut val = value.map(|x| x.to_ascii_lowercase());
    match p.as_str() {
        "push" | "notification" => p = "notifications".into(),
        "photo-library" | "photo" => p = "photos".into(),
        "location-always" => {
            p = "location".into();
            if val.is_none() {
                val = Some("always".into());
            }
        }
        "location-in-use" | "location-inuse" => {
            p = "location".into();
            if val.is_none() {
                val = Some("inuse".into());
            }
        }
        "mic" => p = "microphone".into(),
        "critical-notifications" => p = "notifications-critical".into(),
        "face-id" => p = "faceid".into(),
        "home-kit" => p = "homekit".into(),
        _ => {}
    }
    let ok = [
        "all",
        "calendar",
        "contacts-limited",
        "contacts",
        "location",
        "location-always",
        "location-inuse",
        "photos-add",
        "photos",
        "photos-limited",
        "media-library",
        "microphone",
        "motion",
        "reminders",
        "siri",
        "camera",
        "notifications",
        "notifications-critical",
        "speech",
        "faceid",
        "user-tracking",
        "homekit",
    ]
    .contains(&p.as_str());
    if !ok || (p == "all" && action != "reset") {
        return Err(CliError::new(
            "unknown_permission",
            format!("Unknown or unsupported Simulator permission: {raw}"),
        ));
    }
    if let Some(v) = val {
        let s = match (p.as_str(), v.as_str()) {
            ("photos", "limited") => "photos-limited",
            ("notifications", "critical") => "notifications-critical",
            ("location", "always") => "location-always",
            ("location", "inuse") | ("location", "in-use") => "location-inuse",
            ("location", "never") => return Ok(("revoke".into(), "location".into())),
            _ => {
                return Err(CliError::new(
                    "invalid_permission_value",
                    format!("Invalid value '{v}' for Simulator permission {p}"),
                ));
            }
        };
        Ok((action.into(), s.into()))
    } else {
        Ok((action.into(), p))
    }
}
fn normalize_ui(raw: &str) -> Result<String> {
    let x = raw.to_ascii_lowercase().replace('_', "-");
    let x = match x.as_str() {
        "content-size" => "text-size",
        "button-shapes" => "show-borders",
        "voice-over" => "voiceover",
        _ => x.as_str(),
    };
    if [
        "appearance",
        "liquid-glass",
        "color-filter",
        "text-size",
        "reduce-motion",
        "increase-contrast",
        "show-borders",
        "reduce-transparency",
        "voiceover",
    ]
    .contains(&x)
    {
        Ok(x.into())
    } else {
        Err(CliError::new(
            "unknown_ui_option",
            format!("Unknown Simulator interface option: {raw}"),
        ))
    }
}
fn normalize_ui_value(op: &str, raw: &str) -> Result<String> {
    let v = raw.to_ascii_lowercase().replace('_', "-");
    let ok = match op {
        "appearance" => ["light", "dark"].contains(&v.as_str()),
        "liquid-glass" => ["clear", "tinted"].contains(&v.as_str()),
        "color-filter" => [
            "none",
            "grayscale",
            "red-green",
            "green-red",
            "blue-yellow",
            "protanopia",
            "deuteranopia",
            "tritanopia",
        ]
        .contains(&v.as_str()),
        "text-size" => [
            "extra-small",
            "small",
            "medium",
            "large",
            "extra-large",
            "extra-extra-large",
            "extra-extra-extra-large",
            "accessibility-medium",
            "accessibility-large",
            "accessibility-extra-large",
            "accessibility-extra-extra-large",
            "accessibility-extra-extra-extra-large",
            "increment",
            "decrement",
        ]
        .contains(&v.as_str()),
        _ => [
            "on", "true", "enabled", "1", "yes", "off", "false", "disabled", "0", "no",
        ]
        .contains(&v.as_str()),
    };
    if !ok {
        return Err(CliError::new(
            "invalid_ui_value",
            format!("Invalid value '{raw}' for Simulator interface option {op}"),
        ));
    }
    Ok(match (op, v.as_str()) {
        ("color-filter", "protanopia") => "red-green",
        ("color-filter", "deuteranopia") => "green-red",
        ("color-filter", "tritanopia") => "blue-yellow",
        (_, "true") | (_, "enabled") | (_, "1") | (_, "yes") => "on",
        (_, "false") | (_, "disabled") | (_, "0") | (_, "no") => "off",
        _ => v.as_str(),
    }
    .into())
}
fn ui(v: &[String], p: &Parsed) -> Result<Option<(String, Map<String, Value>, Output)>> {
    if p.stdin || p.file.is_some() || p.value.is_some() {
        return Err(usage("invalid simulator ui arguments"));
    }
    if v.is_empty() || (v.len() == 1 && v[0].eq_ignore_ascii_case("status")) {
        return Ok(Some((
            "simulator.ui.status".into(),
            Map::new(),
            Output::UIStatus,
        )));
    }
    let (raw, val) = if v[0].eq_ignore_ascii_case("get") {
        if v.len() != 2 {
            return Err(usage("ui get <option>"));
        }
        (v[1].clone(), None)
    } else if v[0].eq_ignore_ascii_case("set") {
        if v.len() != 3 {
            return Err(usage("ui set <option> <value>"));
        }
        (v[1].clone(), Some(v[2].clone()))
    } else if v.len() == 1 {
        (v[0].clone(), None)
    } else if v.len() == 2 {
        (v[0].clone(), Some(v[1].clone()))
    } else {
        return Err(usage("invalid simulator ui arguments"));
    };
    let op = normalize_ui(&raw)?;
    if let Some(raw) = val {
        Ok(Some((
            "simulator.ui.set".into(),
            object(json!({"option":op,"value":normalize_ui_value(&op,&raw)?})),
            Output::UIUpdated(op),
        )))
    } else {
        Ok(Some((
            "simulator.ui.status".into(),
            Map::new(),
            Output::UIValue(op),
        )))
    }
}

fn ios(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let sub = args
        .first()
        .map(|s| s.to_ascii_lowercase())
        .ok_or_else(|| usage("cmux ios <list|context|screenshot>"))?;
    match sub.as_str() {
        "list" => {
            let mut v = args[1..].to_vec();
            let ws = args::take_option(&mut v, "--workspace")?;
            if !v.is_empty() {
                return Err(usage("ios list [--workspace <ref>]"));
            }
            let ts = targets(ctx, ws.as_deref())?;
            if ctx.json {
                ctx.emit(&json!({"targets": ts}))?;
            } else if ts.is_empty() {
                ctx.print("No iOS Simulator panes")?;
            } else {
                for t in ts {
                    ctx.print(format!(
                        "{}\t{}\t{}\t{}",
                        text(t.get("surface_ref")),
                        text(t.get("device_name")),
                        text(t.get("simulator_id")),
                        text(t.get("state"))
                    ))?;
                }
            }
        }
        "context" => {
            let mut v = args[1..].to_vec();
            let udid = args::take_flag(&mut v, "--udid");
            let surface = args::take_option(&mut v, "--surface")?;
            if !v.is_empty() {
                return Err(usage("ios context [--udid] [--surface <ref>]"));
            }
            let p = context(ctx, surface.as_deref())?;
            if udid {
                let id = p
                    .get("simulator_id")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        CliError::new(
                            "missing_simulator_id",
                            "The selected iOS pane has no Simulator identifier",
                        )
                    })?;
                ctx.print(id)?;
            } else if ctx.json {
                ctx.emit(&p)?;
            } else {
                for k in [
                    "simulator_id",
                    "device_name",
                    "runtime_id",
                    "state",
                    "orientation",
                    "surface_ref",
                ] {
                    if let Some(v) = p.get(k).filter(|x| !x.is_null()) {
                        ctx.print(format!("{k}={}", text(Some(v))))?;
                    }
                }
            }
        }
        "screenshot" => screenshot(ctx, &args[1..])?,
        _ => return simulator(ctx, args),
    }
    Ok(Some(0))
}
fn targets(ctx: &Context, ws: Option<&str>) -> Result<Vec<Value>> {
    let id = ctx
        .resolve_id("workspace", ws)?
        .ok_or_else(|| CliError::new("not_found", "No workspace selected"))?;
    let mut params = json!({"workspace_id": id});
    if let Some(w) = ctx.window.as_deref() {
        if let Some(id) = ctx.resolve_id("window", Some(w))? {
            params["window_id"] = json!(id);
        }
    }
    let listed = ctx.rpc("surface.list", params)?;
    Ok(listed.get("surfaces").and_then(Value::as_array).into_iter().flatten()
        .filter(|s| s.get("type").and_then(Value::as_str) == Some("simulator"))
        .map(|s| json!({
            "surface_id": s.get("id"), "surface_ref": s.get("ref").or_else(|| s.get("id")),
            "simulator_id": s.get("simulator_id"), "runtime_id": s.get("runtime_id"),
            "device_type_id": s.get("device_type_id"), "device_name": s.get("device_name"), "state": s.get("state"),
            "workspace_id": listed.get("workspace_id").cloned().unwrap_or(json!(id)),
            "workspace_ref": listed.get("workspace_ref")
        })).collect())
}
fn context(ctx: &Context, surface: Option<&str>) -> Result<Value> {
    rpc(
        ctx,
        "simulator.context",
        Value::Object(routing(ctx, surface)?),
        None,
    )
}
fn prepare_screenshot(
    ctx: &Context,
    surface: Option<&str>,
    deadline: Option<Instant>,
) -> Result<Value> {
    rpc(
        ctx,
        "simulator.prepare_screenshot",
        Value::Object(routing(ctx, surface)?),
        deadline,
    )
}
fn missing_simulator_id() -> CliError {
    CliError::new(
        "missing_simulator_id",
        "The selected iOS pane has no Simulator identifier",
    )
}
fn missing_surface_ref() -> CliError {
    CliError::new(
        "missing_surface_ref",
        "The selected iOS pane has no surface reference",
    )
}
fn screenshot(ctx: &Context, raw: &[String]) -> Result<()> {
    let mut values = raw.to_vec();
    let surfaces = take_all(&mut values, "--surface")?;
    let workspace = args::take_option(&mut values, "--workspace")?;
    let output = args::take_option(&mut values, "--out")?
        .map(absolute_path)
        .transpose()?;
    let all = args::take_flag(&mut values, "--all");
    if !values.is_empty()
        || (!all && surfaces.len() > 1)
        || (all && !surfaces.is_empty())
        || (!surfaces.is_empty() && workspace.is_some())
    {
        return Err(usage(
            "ios screenshot [--surface <ref>] [--workspace <ref>] [--all] [--out <path>]",
        ));
    }
    if ctx.dry_run {
        ctx.emit(&json!({"dry_run":true,"method":"simulator.prepare_screenshot","surfaces":surfaces,"workspace":workspace,"all":all,"output":output,"max_targets":SCREENSHOT_LIMIT,"command":["xcrun","simctl","io","<resolved-simulator-udid>","screenshot","<resolved-output-path>"]}))?;
        return Ok(());
    }
    let (mut targets, resolve) = if all {
        (targets(ctx, workspace.as_deref())?, true)
    } else if let Some(surface) = surfaces.first() {
        (vec![prepare_screenshot(ctx, Some(surface), None)?], false)
    } else if workspace.is_none() {
        (vec![prepare_screenshot(ctx, None, None)?], false)
    } else {
        let candidates = targets(ctx, workspace.as_deref())?;
        if candidates.len() != 1 {
            return Err(usage(format!(
                "Found {} iOS Simulator panes; pass --surface <ref> or --all",
                candidates.len()
            )));
        }
        (candidates, true)
    };
    if targets.is_empty() {
        return Err(CliError::new(
            "no_targets",
            "No matching iOS Simulator panes were found",
        ));
    }
    if all && targets.len() > SCREENSHOT_LIMIT {
        return Err(CliError::new(
            "too_many_targets",
            format!(
                "Found {} iOS Simulator panes; screenshot --all supports at most 8",
                targets.len()
            ),
        ));
    }
    let deadline = all.then(|| Instant::now() + BATCH_TIMEOUT);
    if resolve {
        let mut resolved = Vec::with_capacity(targets.len());
        for mut target in targets {
            let surface = target
                .get("surface_ref")
                .and_then(Value::as_str)
                .ok_or_else(missing_surface_ref)?;
            match prepare_screenshot(ctx, Some(surface), deadline) {
                Ok(value) => resolved.push(value),
                Err(e) if all => {
                    target["error"] = json!(e.message);
                    resolved.push(target);
                }
                Err(e) => return Err(e),
            }
        }
        targets = resolved;
    }
    if let Some(path) = &output {
        if all && !path.is_dir() {
            return Err(usage(
                "--out must name an existing directory when capturing multiple Simulators",
            ));
        }
        if !all && path.is_dir() {
            return Err(usage("--out must name a file when capturing one Simulator"));
        }
    }
    let mut captures = Vec::with_capacity(targets.len());
    for target in targets {
        if all && target.get("error").is_some() {
            captures.push(
                json!({"surface_ref":target.get("surface_ref"), "error":target.get("error")}),
            );
            continue;
        }
        let identity = target
            .get("simulator_id")
            .and_then(Value::as_str)
            .ok_or_else(missing_simulator_id)
            .and_then(|id| {
                target
                    .get("surface_ref")
                    .and_then(Value::as_str)
                    .ok_or_else(missing_surface_ref)
                    .map(|surface| (id, surface))
            });
        let (id, surface) = match identity {
            Ok(pair) => pair,
            Err(e) if all => {
                captures.push(json!({"surface_ref":target.get("surface_ref"), "error":e.message}));
                continue;
            }
            Err(e) => return Err(e),
        };
        let destination = if !all && output.is_some() {
            output.clone().unwrap()
        } else {
            output
                .clone()
                .unwrap_or(std::env::current_dir()?)
                .join(format!("ios-{}.png", surface.replace(':', "-")))
        };
        let result = if let Some(deadline) = deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                Err(batch_timeout())
            } else {
                simctl(id, &destination, remaining.min(Duration::from_secs(30)))
            }
        } else {
            simctl(id, &destination, Duration::from_secs(30))
        };
        match result {
            Ok(()) => {
                captures.push(json!({"path":destination,"simulator_id":id,"surface_ref":surface}))
            }
            Err(e) if all => {
                captures.push(json!({"simulator_id":id,"surface_ref":surface,"error":e.message}))
            }
            Err(e) => return Err(e),
        }
    }
    if ctx.json {
        ctx.emit(&json!({"captures":captures}))?;
    } else {
        for capture in &captures {
            if let Some(path) = capture.get("path").and_then(Value::as_str) {
                ctx.print(sanitize(path))?;
            } else if let Some(error) = capture.get("error").and_then(Value::as_str) {
                eprintln!("{}: {}", text(capture.get("surface_ref")), sanitize(error));
            }
        }
    }
    if captures.iter().any(|c| c.get("error").is_some()) {
        return Err(CliError::new(
            "screenshot_failed",
            "One or more iOS Simulator screenshots failed",
        ));
    }
    Ok(())
}
fn take_all(v: &mut Vec<String>, n: &str) -> Result<Vec<String>> {
    let mut o = Vec::new();
    let mut i = 0;
    while i < v.len() {
        if v[i] == n {
            let value = v
                .get(i + 1)
                .ok_or_else(|| usage(format!("{n} requires a value")))?
                .clone();
            v.drain(i..=i + 1);
            o.push(value);
        } else if let Some(value) = v[i].strip_prefix(&format!("{n}=")) {
            if value.is_empty() {
                return Err(usage(format!("{n} requires a value")));
            }
            o.push(value.to_string());
            v.remove(i);
        } else {
            i += 1;
        }
    }
    Ok(o)
}
fn simctl(id: &str, dest: &Path, timeout: Duration) -> Result<()> {
    let mut child = Command::new("/usr/bin/xcrun")
        .args(["simctl", "io", id, "screenshot"])
        .arg(dest)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|e| CliError::new("simctl", e.to_string()))?;
    let stderr = child.stderr.take().expect("piped stderr");
    let (sender, receiver) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let mut input = stderr;
        let mut retained = Vec::new();
        let mut buffer = [0_u8; 8192];
        loop {
            match input.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    let keep = n.min((64 * 1024_usize).saturating_sub(retained.len()));
                    retained.extend_from_slice(&buffer[..keep]);
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
        let _ = sender.send(String::from_utf8_lossy(&retained).into_owned());
    });
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let stderr = receiver
                    .recv_timeout(Duration::from_secs(1))
                    .unwrap_or_default();
                if status.success() {
                    return Ok(());
                }
                return Err(CliError::new(
                    "simctl",
                    if stderr.trim().is_empty() {
                        format!("simctl exited with {status}")
                    } else {
                        stderr.trim().to_string()
                    },
                ));
            }
            Ok(None) => {}
            Err(e) => {
                unsafe {
                    libc::kill(-(child.id() as i32), libc::SIGKILL);
                }
                let _ = child.kill();
                let _ = child.wait();
                return Err(CliError::new("simctl", e.to_string()));
            }
        }
        if start.elapsed() >= timeout {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.kill();
            let _ = child.wait();
            return Err(CliError::new("timeout", "The Simulator command timed out."));
        }
        thread::sleep(Duration::from_millis(20));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| (*v).to_string()).collect()
    }
    fn request(sub: &str, values: &[&str]) -> (String, Map<String, Value>, Output) {
        agent_request(sub, &parse_args(&strings(values)).unwrap())
            .unwrap()
            .unwrap()
    }
    #[test]
    fn touch_requests_preserve_two_finger_contract() {
        let (method, p, _) = request("tap", &["0.1", "0.2", "0.8", "0.9"]);
        assert_eq!(method, "simulator.tap");
        assert_eq!(p, object(json!({"x":0.1,"y":0.2,"x2":0.8,"y2":0.9})));
        let (method, p, _) = request("swipe", &["0", "0", "1", "1", "1", "0", "0", "1", "64"]);
        assert_eq!(method, "simulator.swipe");
        assert_eq!(p["from_x2"], 1.0);
        assert_eq!(p["to_x2"], 0.0);
        assert_eq!(p["steps"], 64);
        for coord in ["NaN", "inf", "-0.01", "1.01"] {
            assert!(super::coord(coord).is_err());
        }
    }
    #[test]
    fn gesture_bounds_and_aliases_are_validated_before_transport() {
        let (method, p, _) = request("multi-touch", &[r#"{"x":0.5,"y":0.6}"#]);
        assert_eq!(method, "simulator.multi_touch");
        assert_eq!(p["events"].as_array().unwrap().len(), 1);
        for raw in ["[]", "[0]", "null", "invalid"] {
            assert!(agent_request("gesture", &parse_args(&strings(&[raw])).unwrap()).is_err());
        }
        let too_many = serde_json::to_string(&vec![json!({}); 257]).unwrap();
        assert!(agent_request("gesture", &parse_args(&vec![too_many]).unwrap()).is_err());
    }
    #[test]
    fn bounded_input_rejects_ambiguous_or_large_sources() {
        assert!(source(&parse_args(&strings(&["text", "--stdin"])).unwrap(), 4).is_err());
        assert!(source(&parse_args(&strings(&["ééé"])).unwrap(), 4).is_err());
        assert_eq!(
            source(&parse_args(&strings(&["--", "--text"])).unwrap(), 100).unwrap(),
            "--text"
        );
        assert!(read_bounded(&b"12345"[..], 4).is_err());
    }
    #[test]
    fn permission_aliases_values_and_bundle_ids_match_swift() {
        let (m, p, _) = request("permissions", &["deny", "mic", "com.example.app"]);
        assert_eq!(m, "simulator.permissions.set");
        assert_eq!(
            p,
            object(json!({"action":"revoke","service":"microphone","bundle_id":"com.example.app"}))
        );
        assert_eq!(
            normalize_permission("grant", "location-always", Some("never".into())).unwrap(),
            ("revoke".into(), "location".into())
        );
        assert_eq!(
            normalize_permission("grant", "photo", Some("limited".into()))
                .unwrap()
                .1,
            "photos-limited"
        );
        assert!(normalize_permission("grant", "all", None).is_err());
        assert!(validate_bundle("-bad").is_err());
        assert!(validate_bundle("com.example\napp").is_err());
        assert!(
            agent_request(
                "permissions",
                &parse_args(&strings(&[
                    "grant",
                    "photos",
                    "com.example",
                    "limited",
                    "--value",
                    "limited"
                ]))
                .unwrap()
            )
            .is_err()
        );
    }
    #[test]
    fn ui_camera_and_diagnostic_contracts_are_preserved() {
        let (m, p, _) = request("ui", &["set", "button_shapes", "enabled"]);
        assert_eq!(m, "simulator.ui.set");
        assert_eq!(p, object(json!({"option":"show-borders","value":"on"})));
        let (_, _, out) = request("ui", &["get", "content-size"]);
        assert!(matches!(out,Output::UIValue(ref key) if key=="text-size"));
        let (_, p, _) = request("camera", &["configure", "com.example"]);
        assert_eq!(p["source"], "placeholder");
        assert!(
            agent_request("camera", &parse_args(&strings(&["switch", "off"])).unwrap()).is_err()
        );
        let (_, p, _) = request("ca", &["slow_animations", "on"]);
        assert_eq!(p["diagnostic"], "slowAnimations");
        for sub in ["button", "rotate", "tools"] {
            assert!(
                agent_request(sub, &parse_args(&strings(&["home", "--stdin"])).unwrap()).is_err()
            );
        }
    }
    #[test]
    fn repeated_surface_selectors_do_not_disappear() {
        let mut args = strings(&["--surface", "surface:1", "--surface=surface:2", "--all"]);
        assert_eq!(
            take_all(&mut args, "--surface").unwrap(),
            strings(&["surface:1", "surface:2"])
        );
        assert_eq!(args, strings(&["--all"]));
        assert_eq!(sanitize("hi\u{1b}[31m\u{202e}"), "hi�[31m�");
    }
    #[test]
    fn simulator_rpc_uses_native_method_and_caller_routing() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixListener;
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("simulator.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut reader = BufReader::new(socket.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert_eq!(line.trim(), "auth simulator-test");
            writeln!(socket, "OK").unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "simulator.tap");
            assert_eq!(
                request["params"]["surface_id"],
                "00000000-0000-0000-0000-000000000001"
            );
            assert!(request["params"].get("workspace_id").is_none());
            writeln!(socket, "{}", json!({"ok":true,"result":{"accepted":true}})).unwrap();
        });
        let ctx = Context {
            socket: Some(path.to_string_lossy().into()),
            password: Some("simulator-test".into()),
            json: true,
            ..Context::default()
        };
        assert_eq!(
            run(
                &ctx,
                "simulator",
                &strings(&[
                    "tap",
                    "0.2",
                    "0.3",
                    "--surface",
                    "00000000-0000-0000-0000-000000000001"
                ])
            )
            .unwrap(),
            Some(0)
        );
        server.join().unwrap();
    }
}
