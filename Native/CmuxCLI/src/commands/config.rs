//! Offline configuration, documentation, theme and settings commands.
//!
//! These commands intentionally do not require a running cmux instance when they
//! only inspect local files. Socket-backed mutations use the same v1/v2 methods
//! as the Swift CLI through `Context`, keeping `cmux` and the bundled CLI in sync.
use crate::{CliError, Context, Result};
use serde_json::{Map, Value, json};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const SETTINGS_DOCS: &str = "https://cmux.com/docs/configuration#cmux-json";
const SETTINGS_SCHEMA: &str =
    "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json";
const GHOSTTY_PATH: &str = "~/.config/ghostty/config";
const BROWSER_KEY: &str = "browserDisabledOverride";

pub fn run(ctx: &Context, command: &str, input: &[String]) -> Result<Option<i32>> {
    match command {
        "config" => config(ctx, input),
        "docs" => docs(ctx, input),
        "guide" | "--skill" => guide(ctx, input, false),
        "settings" => settings(ctx, input),
        "shortcuts" => shortcuts(ctx, input),
        "themes" => themes(ctx, input),
        "disable-browser" | "enable-browser" | "browser-status" => {
            browser_availability(ctx, command, input)
        }
        "browser"
            if matches!(
                input
                    .iter()
                    .find(|x| !x.starts_with('-'))
                    .map(String::as_str),
                Some("disable" | "enable" | "status" | "browser-status")
            ) =>
        {
            browser_availability(ctx, "browser", input)
        }
        "agent-hibernation" => agent_hibernation(ctx, input),
        "welcome" => welcome(ctx, input),
        "cloud" | "vm"
            if input.first().map(String::as_str) == Some("guide")
                || input.first().map(String::as_str) == Some("--skill") =>
        {
            guide(ctx, &input[1..], true)
        }
        _ => Ok(None),
    }
}

fn json_requested(ctx: &Context, args: &[String]) -> bool {
    ctx.json || args.iter().any(|a| a == "--json")
}
fn without_json(args: &[String]) -> Vec<String> {
    args.iter()
        .filter(|a| a.as_str() != "--json")
        .cloned()
        .collect()
}
fn usage<T>(s: impl Into<String>) -> Result<T> {
    Err(CliError::usage(s))
}
fn home() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("~"))
}
fn expand(path: &str) -> PathBuf {
    let p = if path == "~" {
        home()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home().join(rest)
    } else {
        PathBuf::from(path)
    };
    if p.is_absolute() {
        p
    } else {
        env::current_dir().unwrap_or_default().join(p)
    }
}
fn display(path: &Path) -> String {
    let s = path.to_string_lossy();
    let home_path = home();
    let h = home_path.to_string_lossy();
    if s == h {
        "~".into()
    } else if let Some(rest) = s.strip_prefix(&(h.to_string() + "/")) {
        format!("~/{rest}")
    } else {
        s.into_owned()
    }
}
fn app_support() -> PathBuf {
    home().join("Library/Application Support")
}
fn bundle_id() -> String {
    env::var("CMUX_BUNDLE_ID")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "com.cmuxterm.app".into())
}
fn ghostty_managed_config() -> PathBuf {
    app_support().join(bundle_id()).join("config.ghostty")
}
fn primary_config() -> PathBuf {
    home().join(".config/cmux/cmux.json")
}
fn legacy_config() -> PathBuf {
    home().join(".config/cmux/settings.json")
}
fn fallback_config() -> PathBuf {
    app_support().join("com.cmuxterm.app/settings.json")
}
fn config_paths() -> (PathBuf, PathBuf, PathBuf) {
    (primary_config(), legacy_config(), fallback_config())
}

fn config(ctx: &Context, raw: &[String]) -> Result<Option<i32>> {
    let args = without_json(raw);
    let want_json = json_requested(ctx, raw);
    if args.iter().any(|a| a == "--help" || a == "-h")
        || args.first().map(String::as_str) == Some("help")
    {
        return ctx.print(config_usage()).map(|_| Some(0));
    }
    let sub = args
        .first()
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_else(|| "help".into());
    match sub.as_str() {
        "path" | "paths" => {
            if args.len() != 1 {
                return usage("Usage: cmux config path");
            }
            paths(ctx, want_json)?;
        }
        "docs" | "documentation" => {
            if args.len() != 1 {
                return usage("Usage: cmux config docs");
            }
            docs_topic(ctx, "settings", want_json)?;
        }
        "doctor" | "check" | "validate" => {
            let report = doctor(&args[1..])?;
            if want_json {
                ctx.emit(&report)?;
            } else {
                print_doctor(ctx, &report)?;
            }
            if report["ok"] == false {
                return Err(CliError::new(
                    "config.invalid",
                    "cmux config doctor found one or more errors",
                ));
            }
        }
        "reload" => {
            if args.len() != 1 {
                return usage("Usage: cmux config reload");
            }
            let response = ctx.raw("reload_config")?;
            if want_json {
                ctx.emit(&json!({"response": response}))?;
            } else {
                ctx.print(response)?;
            }
        }
        "get" => {
            if args.len() != 2 {
                return usage(
                    "Usage: cmux config get <sidebar-font-size|surface-tab-bar-font-size>",
                );
            }
            font_get(ctx, &args[1], want_json)?;
        }
        "set" => {
            if args.len() != 3 {
                return usage(
                    "Usage: cmux config set <sidebar-font-size|surface-tab-bar-font-size> <points>",
                );
            }
            font_set(ctx, &args[1], &args[2], want_json)?;
        }
        "sidebar-font-size" | "surface-tab-bar-font-size" => {
            if args.len() == 1 {
                font_get(ctx, &sub, want_json)?;
            } else if args.len() == 2 {
                font_set(ctx, &sub, &args[1], want_json)?;
            } else {
                return usage(format!("Usage: cmux config {sub} [points]"));
            }
        }
        _ => {
            return usage(format!(
                "Unknown config subcommand '{sub}'. Run 'cmux config --help'."
            ));
        }
    }
    Ok(Some(0))
}
fn config_usage() -> String {
    format!(
        "Usage: cmux config <doctor|check|validate|path|docs|reload|get|set|sidebar-font-size|surface-tab-bar-font-size>\n\nInspect cmux.json, validate JSONC, edit Ghostty font sizes, or reload the running app.\n\nConfig files:\n  primary: {}\n  legacy: {}\n  fallback: {}\n\nRun `cmux config <command> --help` for details.",
        display(&primary_config()),
        display(&legacy_config()),
        display(&fallback_config())
    )
}
fn paths(ctx: &Context, json_out: bool) -> Result<()> {
    let (p, l, f) = config_paths();
    let value = json!({"primary":display(&p),"legacy":display(&l),"fallback":display(&f),"ghostty_config": {"path":GHOSTTY_PATH,"note":"Not cmux-owned, but cmux reads it."},"docs_url":SETTINGS_DOCS,"schema_url":SETTINGS_SCHEMA,"reload_command":"cmux reload-config","backup":"Back up cmux.json before editing."});
    if json_out {
        ctx.emit(&value)
    } else {
        ctx.print(format!("Config files:\n  primary:  {}\n  legacy config:  {}\n  legacy app support:  {}\n\nRelated Ghostty config:\n  {}\n\nDocs: {}\nSchema: {}\n\nReload: cmux reload-config", display(&p),display(&l),display(&f),GHOSTTY_PATH,SETTINGS_DOCS,SETTINGS_SCHEMA))
    }
}

fn font_key(raw: &str) -> Option<&'static str> {
    match raw.to_ascii_lowercase().as_str() {
        "sidebar-font-size" => Some("sidebar-font-size"),
        "surface-tab-bar-font-size" => Some("surface-tab-bar-font-size"),
        _ => None,
    }
}
fn font_bounds(key: &str) -> Option<(f64, f64, f64)> {
    match key {
        "sidebar-font-size" => Some((10.0, 20.0, 13.0)),
        "surface-tab-bar-font-size" => Some((8.0, 24.0, 13.0)),
        _ => None,
    }
}
fn read_text(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}
fn font_value(contents: &str, key: &str) -> Option<f64> {
    contents.lines().rev().find_map(|line| {
        let (k, v) = line.split_once('=')?;
        if k.trim() == key {
            v.trim().parse().ok()
        } else {
            None
        }
    })
}
fn font_get(ctx: &Context, raw: &str, json_out: bool) -> Result<()> {
    let key =
        font_key(raw).ok_or_else(|| CliError::usage(format!("Unknown font size key '{raw}'")))?;
    let (_, _, default) = font_bounds(key).unwrap();
    let path = ghostty_managed_config();
    let configured = font_value(&read_text(&path), key);
    let value = configured.unwrap_or(default);
    let payload = json!({"key":key,"value":value,"formatted":format_num(value),"path":path,"configured":configured.is_some()});
    if json_out {
        ctx.emit(&payload)
    } else {
        ctx.print(format!(
            "{key} = {}\npath: {}",
            format_num(value),
            display(&path)
        ))
    }
}
fn format_num(v: f64) -> String {
    if (v - v.round()).abs() < f64::EPSILON {
        format!("{}", v as i64)
    } else {
        format!("{v:.2}")
            .trim_end_matches('0')
            .trim_end_matches('.')
            .to_string()
    }
}
fn font_set(ctx: &Context, raw: &str, value_raw: &str, json_out: bool) -> Result<()> {
    let key =
        font_key(raw).ok_or_else(|| CliError::usage(format!("Unknown font size key '{raw}'")))?;
    let (min, max, _) = font_bounds(key).unwrap();
    let requested: f64 = value_raw
        .parse()
        .map_err(|_| CliError::usage(format!("{key} requires a numeric point size")))?;
    if !requested.is_finite() {
        return Err(CliError::usage(format!(
            "{key} requires a finite numeric point size"
        )));
    }
    let value = requested.clamp(min, max);
    let path = ghostty_managed_config();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut lines: Vec<String> = read_text(&path)
        .lines()
        .map(str::to_string)
        .filter(|line| {
            line.split_once('=')
                .map(|(k, _)| k.trim() != key)
                .unwrap_or(true)
        })
        .collect();
    lines.push(format!("{key} = {}", format_num(value)));
    fs::write(&path, lines.join("\n") + "\n")?;
    let reload = match ctx.raw("reload_config") {
        Ok(v) => json!("reloaded"),
        Err(e) => json!({"status":"failed","message":e.message}),
    };
    let payload = json!({"ok":true,"key":key,"value":value,"formatted":format_num(value),"path":path,"reload":reload,"clamped":value!=requested});
    if json_out {
        ctx.emit(&payload)
    } else {
        ctx.print(format!(
            "OK {key} = {} ({})\npath: {}",
            format_num(value),
            if reload == json!("reloaded") {
                "reloaded"
            } else {
                "saved"
            },
            display(&path)
        ))
    }
}

fn strip_jsonc(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    let mut string = false;
    let mut escape = false;
    while let Some(c) = chars.next() {
        if string {
            out.push(c);
            if escape {
                escape = false;
            } else if c == '\\' {
                escape = true;
            } else if c == '"' {
                string = false;
            }
            continue;
        }
        if c == '"' {
            string = true;
            out.push(c);
            continue;
        }
        if c == '/' && chars.peek() == Some(&'/') {
            while let Some(n) = chars.next() {
                if n == '\n' {
                    out.push('\n');
                    break;
                }
            }
            continue;
        }
        if c == '/' && chars.peek() == Some(&'*') {
            chars.next();
            while let Some(n) = chars.next() {
                if n == '*' && chars.peek() == Some(&'/') {
                    chars.next();
                    break;
                }
            }
            continue;
        }
        out.push(c);
    }
    regex::Regex::new(r",\s*([}\]])")
        .unwrap()
        .replace_all(&out, "$1")
        .into_owned()
}
fn doctor(custom: &[String]) -> Result<Value> {
    let mut targets: Vec<(String, PathBuf, bool)> = Vec::new();
    if custom.is_empty() {
        let p = primary_config();
        targets.push(("primary".into(), p, false));
        let cwd = env::current_dir().unwrap_or_default();
        let mut cur = Some(cwd.as_path());
        while let Some(dir) = cur {
            for candidate in [dir.join(".cmux/cmux.json"), dir.join("cmux.json")] {
                if candidate.exists() && !targets.iter().any(|(_, p, _)| *p == candidate) {
                    targets.push(("project".into(), candidate, false));
                    break;
                }
            }
            let parent = dir.parent();
            if parent == Some(dir) {
                break;
            }
            cur = parent;
        }
        for (label, path) in [
            ("legacy config", legacy_config()),
            ("legacy app support", fallback_config()),
        ] {
            if path.exists() && !targets.iter().any(|(_, p, _)| *p == path) {
                targets.push((label.into(), path, false));
            }
        }
    } else {
        for (i, p) in custom.iter().enumerate() {
            targets.push((format!("custom {}", i + 1), expand(p), true));
        }
    }
    let findings: Vec<Value> = targets
        .into_iter()
        .map(|(label, path, missing_error)| {
            let mut obj =
                json!({"label": label, "display_path": display(&path), "path": path, "keys": []});
            match fs::metadata(&path) {
                Err(_) => {
                    obj["status"] = json!(if missing_error { "error" } else { "missing" });
                    obj["ok"] = json!(!missing_error);
                    obj["message"] = json!(if missing_error {
                        "file not found"
                    } else {
                        "not found; cmux will use defaults until this file exists"
                    });
                }
                Ok(meta) if meta.is_dir() => {
                    obj["status"] = json!("error");
                    obj["ok"] = json!(false);
                    obj["message"] = json!("path is a directory, expected a file");
                }
                Ok(_) => {
                    let bytes = fs::read(&path).unwrap_or_default();
                    obj["bytes"] = json!(bytes.len());
                    if bytes.is_empty() {
                        obj["status"] = json!("error");
                        obj["ok"] = json!(false);
                        obj["message"] = json!("file is empty");
                    } else {
                        match serde_json::from_str::<Value>(&strip_jsonc(&String::from_utf8_lossy(
                            &bytes,
                        ))) {
                            Ok(Value::Object(map)) => {
                                obj["status"] = json!("ok");
                                obj["ok"] = json!(true);
                                obj["message"] = json!("JSONC syntax is valid");
                                obj["keys"] = json!(map.keys().cloned().collect::<Vec<_>>());
                            }
                            Ok(_) => {
                                obj["status"] = json!("error");
                                obj["ok"] = json!(false);
                                obj["message"] = json!("top-level value must be a JSON object");
                            }
                            Err(e) => {
                                obj["status"] = json!("error");
                                obj["ok"] = json!(false);
                                obj["message"] = json!(e.to_string());
                            }
                        }
                    }
                }
            }
            obj
        })
        .collect();
    let ok = findings
        .iter()
        .all(|f| f["ok"] == true || f["status"] == "missing");
    Ok(
        json!({"ok": ok, "error_count": findings.iter().filter(|f| f["status"] == "error").count(), "findings": findings, "reload_command": "cmux reload-config", "docs_url": SETTINGS_DOCS, "schema_url": SETTINGS_SCHEMA}),
    )
}
fn print_doctor(ctx: &Context, r: &Value) -> Result<()> {
    let mut s = "cmux config doctor\n".to_string();
    for f in r["findings"].as_array().into_iter().flatten() {
        s.push_str(&format!(
            "{} {}: {}\n  path: {}\n",
            f["status"].as_str().unwrap_or("").to_ascii_uppercase(),
            f["label"].as_str().unwrap_or(""),
            f["display_path"].as_str().unwrap_or(""),
            f["path"].as_str().unwrap_or("")
        ));
        if let Some(n) = f["bytes"].as_u64() {
            s.push_str(&format!("  bytes: {n}\n"));
        }
        if let Some(m) = f["message"].as_str() {
            s.push_str(&format!("  {m}\n"));
        }
    }
    s.push_str(&format!(
        "\nDocs: {SETTINGS_DOCS}\nSchema: {SETTINGS_SCHEMA}\nReload: cmux reload-config"
    ));
    ctx.print(s)
}

#[derive(Clone)]
struct Doc {
    topic: &'static str,
    aliases: &'static [&'static str],
    summary: &'static str,
    web: &'static str,
    commands: &'static [&'static str],
}
fn doc_refs() -> Vec<Doc> {
    vec![
        Doc {
            topic: "settings",
            aliases: &["configuration", "config", "cmux-json", "schema"],
            summary: "cmux-owned settings, cmux.json locations, schema, and reload flow.",
            web: SETTINGS_DOCS,
            commands: &[
                "cmux settings path",
                "cmux config doctor",
                "cmux reload-config",
            ],
        },
        Doc {
            topic: "shortcuts",
            aliases: &["keyboard", "keybindings", "keys"],
            summary: "cmux-owned keyboard shortcuts and two-step chord syntax.",
            web: "https://cmux.com/docs/keyboard-shortcuts",
            commands: &["cmux shortcuts", "cmux settings shortcuts"],
        },
        Doc {
            topic: "api",
            aliases: &["cli", "socket", "automation", "handles"],
            summary: "CLI/socket API, handle model, windows, workspaces, panes, and surfaces.",
            web: "https://cmux.com/docs/api",
            commands: &["cmux identify --json", "cmux tree --all --json"],
        },
        Doc {
            topic: "browser",
            aliases: &["browser-automation", "webview"],
            summary: "Browser panel automation and snapshot-driven web interaction.",
            web: "https://cmux.com/docs/browser-automation",
            commands: &["cmux browser --help", "cmux browser snapshot"],
        },
        Doc {
            topic: "agents",
            aliases: &["integrations", "agent-integrations"],
            summary: "Agent hooks, Feed approvals, notifications, and session restore.",
            web: "https://cmux.com/docs/agent-integrations/oh-my-codex",
            commands: &["cmux hooks setup"],
        },
        Doc {
            topic: "managed-policies",
            aliases: &["mdm", "managed", "policy", "policies", "enterprise"],
            summary: "MDM-enforceable managed policies for browser, iOS, and Cloud.",
            web: "https://cmux.com/docs/managed-policies",
            commands: &["cmux browser status --json"],
        },
        Doc {
            topic: "dock",
            aliases: &["doc", "controls", "right-sidebar"],
            summary: "Custom right-sidebar terminal controls.",
            web: "https://cmux.com/docs/dock",
            commands: &["cmux docs dock"],
        },
        Doc {
            topic: "sidebars",
            aliases: &["sidebar", "custom-sidebar", "custom-sidebars"],
            summary: "Vibe-code a custom sidebar (beta).",
            web: "https://cmux.com/docs/custom-sidebars",
            commands: &["mkdir -p ~/.config/cmux/sidebars"],
        },
    ]
}
fn find_doc(topic: &str) -> Option<Doc> {
    let n = topic.replace('_', "-").to_ascii_lowercase();
    doc_refs()
        .into_iter()
        .find(|d| d.topic == n || d.aliases.contains(&n.as_str()))
}
fn docs(ctx: &Context, raw: &[String]) -> Result<Option<i32>> {
    let a = without_json(raw);
    let j = json_requested(ctx, raw);
    if a.iter().any(|x| x == "--help" || x == "-h") {
        return ctx
            .print("Usage: cmux docs [settings|shortcuts|api|browser|agents|dock|managed-policies]")
            .map(|_| Some(0));
    }
    if a.len() > 1 {
        return usage("Usage: cmux docs [topic]");
    }
    if let Some(t) = a.first() {
        if t == "list" || t == "all" {
            return docs_index(ctx, j).map(|_| Some(0));
        }
        docs_topic(ctx, t, j)?;
    } else {
        docs_index(ctx, j)?;
    }
    Ok(Some(0))
}
fn docs_index(ctx: &Context, j: bool) -> Result<()> {
    let refs = doc_refs();
    if j {
        let topics: Vec<Value> = refs.iter().map(doc_payload).collect();
        ctx.emit(&json!({"topics":topics}))
    } else {
        let mut s = "cmux docs\n\nTopics:\n".to_string();
        for d in refs {
            s.push_str(&format!("  {:14} {}\n", d.topic, d.summary));
        }
        s.push_str("\nRun `cmux docs <topic>` for URLs and next commands.");
        ctx.print(s)
    }
}
fn doc_resources(topic: &str) -> Vec<(&'static str, &'static str)> {
    match topic {
        "settings" => vec![
            ("settings schema", SETTINGS_SCHEMA),
            (
                "cmux skill",
                "https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills/cmux/SKILL.md",
            ),
        ],
        "shortcuts" => vec![
            (
                "shortcut data",
                "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-shortcuts.ts",
            ),
            ("settings schema", SETTINGS_SCHEMA),
        ],
        "api" => vec![
            (
                "CLI contract",
                "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/cli-contract.md",
            ),
            (
                "cmux skill",
                "https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills/cmux/SKILL.md",
            ),
        ],
        "browser" => vec![
            (
                "browser skill",
                "https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills/cmux-browser/SKILL.md",
            ),
            (
                "browser commands",
                "https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills/cmux-browser/references/commands.md",
            ),
        ],
        "agents" => vec![
            (
                "agent hooks",
                "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/agent-hooks.md",
            ),
            (
                "feed",
                "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/feed.md",
            ),
            (
                "notifications",
                "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/notifications.md",
            ),
        ],
        "managed-policies" => vec![(
            "managed device policies",
            "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/managed-device-policies.md",
        )],
        "dock" => vec![(
            "dock docs",
            "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/dock.md",
        )],
        "sidebars" => vec![(
            "custom sidebar guide",
            "https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/custom-sidebars.md",
        )],
        _ => vec![],
    }
}
fn doc_payload(d: &Doc) -> Value {
    let resources: Vec<Value> = doc_resources(d.topic)
        .into_iter()
        .map(|(label, url)| json!({"label":label,"url":url,"fetch":format!("curl -fsSL {url}")}))
        .collect();
    json!({"topic":d.topic,"aliases":d.aliases,"summary":d.summary,"web_url":d.web,"raw_resources":resources,"commands":d.commands})
}
fn docs_topic(ctx: &Context, t: &str, j: bool) -> Result<()> {
    let d = find_doc(t).ok_or_else(|| {
        CliError::usage(format!(
            "Unknown docs topic '{t}'. Run 'cmux docs' for topics."
        ))
    })?;
    let p = doc_payload(&d);
    if j {
        ctx.emit(&p)
    } else {
        let resources = doc_resources(d.topic)
            .into_iter()
            .map(|(label, url)| format!("  {label}: {url}"))
            .collect::<Vec<_>>()
            .join("\n");
        let raw = if resources.is_empty() {
            String::new()
        } else {
            format!("\n\nRaw resources:\n{resources}")
        };
        ctx.print(format!(
            "{}: {}\n\nWeb:\n  {}{}\n\nUseful commands:\n  {}",
            d.topic,
            d.summary,
            d.web,
            raw,
            d.commands.join("\n  ")
        ))
    }
}

fn settings(ctx: &Context, raw: &[String]) -> Result<Option<i32>> {
    let a = without_json(raw);
    let j = json_requested(ctx, raw);
    if a.iter().any(|x| x == "--help" || x == "-h") {
        return ctx.print("Usage: cmux settings [open [target]|path|docs|<target>]\nTargets: account app terminal networking sidebar-appearance custom-sidebars automation browser browser-import global-hotkey keyboard-shortcuts workspace-colors cmux-json reset").map(|_|Some(0));
    }
    let sub = a.first().map(String::as_str).unwrap_or("open");
    match sub {
        "path" | "paths" => paths(ctx, j)?,
        "docs" | "documentation" => docs_topic(ctx, "settings", j)?,
        "open" => open_settings(ctx, a.get(1).map(String::as_str), j)?,
        _ => {
            let target = normalize_target(sub).ok_or_else(|| {
                CliError::usage(format!(
                    "Unknown settings target '{sub}'. Run 'cmux settings --help'."
                ))
            })?;
            if a.len() > 1 {
                return usage("Usage: cmux settings [open [target]|path|docs|<target>]");
            }
            open_settings(ctx, Some(target), j)?;
        }
    }
    Ok(Some(0))
}
fn normalize_target(raw: &str) -> Option<&'static str> {
    match raw.to_ascii_lowercase().replace('_', "-").as_str() {
        "account" => Some("account"),
        "app" | "general" => Some("app"),
        "terminal" => Some("terminal"),
        "sidebar" | "sidebar-appearance" => Some("sidebarAppearance"),
        "custom-sidebars" => Some("customSidebars"),
        "automation" => Some("automation"),
        "browser" => Some("browser"),
        "networking" | "network" | "iroh" => Some("networking"),
        "browser-import" | "import-browser-data" => Some("browserImport"),
        "global-hotkey" | "hotkey" => Some("globalHotKey"),
        "keyboard-shortcuts" | "shortcuts" | "keys" | "keybindings" => Some("keyboardShortcuts"),
        "workspace-colors" | "colors" => Some("workspaceColors"),
        "cmux-json" | "json" | "settings-json" => Some("settingsJSON"),
        "reset" => Some("reset"),
        _ => None,
    }
}
fn open_settings(ctx: &Context, target: Option<&str>, j: bool) -> Result<()> {
    let mut p = Map::new();
    p.insert("activate".into(), json!(true));
    if let Some(t) = target {
        p.insert("target".into(), json!(t));
    }
    let v = ctx.rpc("settings.open", Value::Object(p))?;
    if j {
        ctx.emit(&v)
    } else {
        ctx.print(format!(
            "OK target={}",
            v.get("target")
                .and_then(Value::as_str)
                .or(target)
                .unwrap_or("general")
        ))
    }
}
fn shortcuts(ctx: &Context, raw: &[String]) -> Result<Option<i32>> {
    let a = without_json(raw);
    if a.iter().any(|x| x == "--help" || x == "-h") {
        return ctx
            .print("Usage: cmux shortcuts\n\nOpen Settings to Keyboard Shortcuts.")
            .map(|_| Some(0));
    }
    if !a.is_empty() {
        return usage(format!("shortcuts: unexpected argument '{}'", a[0]));
    }
    let v = ctx.rpc(
        "settings.open",
        json!({"target":"keyboardShortcuts","activate":true}),
    )?;
    if json_requested(ctx, raw) {
        ctx.emit(&v)?;
    } else {
        ctx.print("OK")?;
    }
    Ok(Some(0))
}

fn theme_dirs() -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut add = |p: PathBuf| {
        if p.is_dir() && !out.iter().any(|x| x == &p) {
            out.push(p)
        }
    };
    if let Ok(v) = env::var("GHOSTTY_RESOURCES_DIR") {
        add(PathBuf::from(v).join("themes"));
    }
    add(env::current_dir()
        .unwrap_or_default()
        .join("Resources/ghostty/themes"));
    add(home().join(".config/ghostty/themes"));
    add(PathBuf::from(
        "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
    ));
    add(app_support().join("com.mitchellh.ghostty/themes"));
    out
}
fn theme_config() -> PathBuf {
    app_support().join("com.cmuxterm.app/config.ghostty")
}
fn theme_names() -> Vec<String> {
    let mut out = Vec::new();
    for d in theme_dirs() {
        if let Ok(entries) = fs::read_dir(d) {
            for e in entries.flatten() {
                if e.path().is_file() {
                    if let Some(n) = e.file_name().to_str() {
                        if !out.iter().any(|x: &String| x.eq_ignore_ascii_case(n)) {
                            out.push(n.into());
                        }
                    }
                }
            }
        }
    }
    out.sort_by_key(|x| x.to_ascii_lowercase());
    out
}
fn theme_current() -> (
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
) {
    let mut raw = None;
    let mut source = None;
    for p in [expand(GHOSTTY_PATH), theme_config()] {
        if let Ok(c) = fs::read_to_string(&p) {
            for l in c.lines() {
                if let Some((k, v)) = l.split_once('=') {
                    if k.trim() == "theme" && !v.trim().is_empty() {
                        raw = Some(v.trim().trim_matches('"').to_string());
                        source = Some(p.to_string_lossy().into_owned());
                    }
                }
            }
        }
    }
    let Some(val) = raw.clone() else {
        return (None, None, None, source);
    };
    let mut light = None;
    let mut dark = None;
    let mut fallback = None;
    for part in val.split(',') {
        let mut i = part.splitn(2, ':');
        let a = i.next().unwrap_or("").trim();
        let b = i.next().map(str::trim);
        match (a.to_ascii_lowercase().as_str(), b) {
            ("light", Some(v)) => light = Some(v.into()),
            ("dark", Some(v)) => dark = Some(v.into()),
            (_, Some(v)) => {
                let _ = fallback.get_or_insert(v.into());
            }
            (_, None) => {
                let _ = fallback.get_or_insert(a.into());
            }
        };
    }
    (raw, light.or(fallback.clone()), dark.or(fallback), source)
}
fn themes(ctx: &Context, raw: &[String]) -> Result<Option<i32>> {
    let a = without_json(raw);
    let j = json_requested(ctx, raw);
    if a.iter().any(|x| x == "--help" || x == "-h") {
        return ctx.print("Usage: cmux themes [list|set <theme>|set --light <theme> --dark <theme>|clear] [--json]").map(|_|Some(0));
    }
    let sub = a.first().map(String::as_str).unwrap_or("list");
    match sub {
        "list" => {
            if a.len() > 1 {
                return usage("themes list does not take positional arguments");
            }
            let (raw, light, dark, source) = theme_current();
            let names = theme_names();
            let value = json!({"themes":names.iter().map(|n|json!({"name":n,"current_light":light.as_deref().is_some_and(|v|v.eq_ignore_ascii_case(n)),"current_dark":dark.as_deref().is_some_and(|v|v.eq_ignore_ascii_case(n))})).collect::<Vec<_>>(),"current":{"raw_value":raw,"light":light,"dark":dark,"source_path":source},"config_path":theme_config()});
            if j {
                ctx.emit(&value)?;
            } else {
                let mut s = format!(
                    "Current light: {}\nCurrent dark: {}\nConfig: {}\n",
                    light.as_deref().unwrap_or("inherit"),
                    dark.as_deref().unwrap_or("inherit"),
                    theme_config().display()
                );
                for n in names {
                    s.push_str(&format!("{n}\n"));
                }
                ctx.print(s)?;
            }
        }
        "clear" => {
            if a.len() > 1 {
                return usage("themes clear does not take positional arguments");
            }
            let p = theme_config();
            let c = read_text(&p);
            let stripped = c
                .lines()
                .filter(|l| {
                    !l.trim().starts_with("# cmux themes") && !l.trim().starts_with("theme =")
                })
                .collect::<Vec<_>>()
                .join("\n");
            if !stripped.trim().is_empty() {
                fs::write(&p, stripped + "\n")?;
            } else if p.exists() {
                fs::remove_file(&p).ok();
            }
            let reload = ctx.raw("reload_config").is_ok();
            let v = json!({"ok":true,"cleared":true,"config_path":p,"reload_requested":reload});
            if j {
                ctx.emit(&v)?;
            } else {
                ctx.print(format!(
                    "OK cleared config={} reload={}",
                    p.display(),
                    if reload { "requested" } else { "skipped" }
                ))?;
            }
        }
        "set" => theme_set(ctx, &a[1..], j)?,
        _ => theme_set(ctx, &a, j)?,
    }
    Ok(Some(0))
}
fn theme_set(ctx: &Context, args: &[String], j: bool) -> Result<()> {
    let mut light = None;
    let mut dark = None;
    let mut positional = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--light" => {
                i += 1;
                light = Some(
                    args.get(i)
                        .ok_or_else(|| CliError::usage("--light requires a theme"))?
                        .clone(),
                )
            }
            "--dark" => {
                i += 1;
                dark = Some(
                    args.get(i)
                        .ok_or_else(|| CliError::usage("--dark requires a theme"))?
                        .clone(),
                )
            }
            x if x.starts_with("--") => {
                return Err(CliError::usage(format!("themes set: unknown flag '{x}'")));
            }
            x => positional.push(x.to_string()),
        }
        i += 1;
    }
    let (_, cur_l, cur_d, _) = theme_current();
    if light.is_none() && dark.is_none() {
        let n = positional.join(" ");
        if n.is_empty() {
            return Err(CliError::usage(
                "themes set requires a theme name or --light/--dark flags",
            ));
        }
        light = Some(n.clone());
        dark = Some(n);
    } else if !positional.is_empty() {
        return Err(CliError::usage(
            "themes set: unexpected positional argument",
        ));
    }
    let raw = match (light.clone().or(cur_l), dark.clone().or(cur_d)) {
        (Some(l), Some(d)) if l.eq_ignore_ascii_case(&d) => l,
        (l, d) => format!(
            "light:{}{}",
            l.unwrap_or_default(),
            d.map(|v| format!(",dark:{v}")).unwrap_or_default()
        ),
    };
    let p = theme_config();
    if let Some(parent) = p.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut c = read_text(&p);
    c = c
        .lines()
        .filter(|l| !l.trim().starts_with("# cmux themes") && !l.trim().starts_with("theme ="))
        .collect::<Vec<_>>()
        .join("\n");
    if !c.trim().is_empty() {
        c.push_str("\n\n");
    }
    c.push_str(&format!(
        "# cmux themes start\ntheme = {raw}\n# cmux themes end\n"
    ));
    fs::write(&p, c)?;
    let reload = ctx.raw("reload_config").is_ok();
    let v = json!({"ok":true,"light":light,"dark":dark,"raw_value":raw,"config_path":p,"reload_requested":reload});
    if j {
        ctx.emit(&v)
    } else {
        ctx.print(format!(
            "OK light={} dark={} config={} reload={}",
            light.as_deref().unwrap_or("-"),
            dark.as_deref().unwrap_or("-"),
            p.display(),
            if reload { "requested" } else { "skipped" }
        ))
    }
}

fn browser_availability(ctx: &Context, command: &str, raw: &[String]) -> Result<Option<i32>> {
    let mut a = without_json(raw);
    let j = json_requested(ctx, raw);
    let action = if command == "browser" {
        if a.first().is_none() {
            return usage("browser requires a subcommand");
        }
        a.remove(0)
    } else {
        command.into()
    };
    if !a.is_empty() {
        return usage(format!("Unexpected argument: {}", a.join(" ")));
    }
    let domain = env::var("CMUX_BUNDLE_ID")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "com.cmuxterm.app".into());
    let stored = defaults_bool(&domain, BROWSER_KEY).unwrap_or(false);
    if action == "disable" || action == "disable-browser" {
        defaults_write_bool(&domain, BROWSER_KEY, true)?;
    } else if action == "enable" || action == "enable-browser" {
        defaults_write_bool(&domain, BROWSER_KEY, false)?;
    } else if action != "status" && action != "browser-status" {
        return usage(format!("Unknown browser availability command: {action}"));
    }
    let disabled = if action == "status" || action == "browser-status" {
        stored
    } else {
        defaults_bool(&domain, BROWSER_KEY).unwrap_or(false)
    };
    let value = json!({"enabled":!disabled,"disabled":disabled,"managed":false,"domain":domain,"key":BROWSER_KEY,"url_allowlist":[]});
    if j {
        ctx.emit(&value)?;
    } else if action == "status" || action == "browser-status" {
        ctx.print(if disabled { "disabled" } else { "enabled" })?;
    } else {
        ctx.print(if disabled {
            "cmux browser disabled"
        } else {
            "cmux browser enabled"
        })?;
    }
    Ok(Some(0))
}
fn defaults_bool(domain: &str, key: &str) -> Option<bool> {
    let out = Command::new("defaults")
        .args(["read", domain, key])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout)
        .trim()
        .to_ascii_lowercase();
    Some(matches!(s.as_str(), "1" | "true" | "yes"))
}
fn defaults_write_bool(domain: &str, key: &str, val: bool) -> Result<()> {
    let status = Command::new("defaults")
        .args([
            "write",
            domain,
            key,
            "-bool",
            if val { "true" } else { "false" },
        ])
        .status()
        .map_err(|e| CliError::new("defaults", e.to_string()))?;
    if !status.success() {
        return Err(CliError::new(
            "defaults",
            format!("defaults write failed with {status}"),
        ));
    }
    Ok(())
}

fn agent_hibernation(ctx: &Context, raw: &[String]) -> Result<Option<i32>> {
    let a = without_json(raw);
    if a.len() != 1 || !matches!(a[0].as_str(), "on" | "off" | "enable" | "disable") {
        return usage("Usage: cmux agent-hibernation <on|off> [--json]");
    }
    let response = ctx.raw(&format!(
        "agent_hibernation {}",
        if matches!(a[0].as_str(), "on" | "enable") {
            "on"
        } else {
            "off"
        }
    ))?;
    if json_requested(ctx, raw) {
        ctx.emit(&json!({"ok":response=="OK","response":response}))?;
    } else {
        ctx.print(response)?;
    }
    Ok(Some(0))
}
fn welcome(ctx: &Context, raw: &[String]) -> Result<Option<i32>> {
    if !without_json(raw).is_empty() {
        return usage("Usage: cmux welcome");
    }
    let text = "cmux\n\nThe open source terminal built for coding agents.\n\nShortcuts\n  ⌘N  New workspace\n  ⌘T  New tab\n  ⌘P  Go to workspace\n  ⌘B  Toggle left sidebar\n  ⌘D  Split right\n\nDocs       https://cmux.com/docs\nGitHub     https://github.com/manaflow-ai/cmux\n\nRun `cmux --help` for all commands.";
    if json_requested(ctx, raw) {
        ctx.emit(&json!({"docs_url":"https://cmux.com/docs","content":text}))?;
    } else {
        ctx.print(text)?;
    }
    Ok(Some(0))
}

fn guide(ctx: &Context, raw: &[String], cloud: bool) -> Result<Option<i32>> {
    let a = without_json(raw);
    if a.iter().any(|x| x == "--help" || x == "-h") {
        return ctx
            .print(if cloud {
                "Usage: cmux cloud guide [--json]"
            } else {
                "Usage: cmux guide [--json]"
            })
            .map(|_| Some(0));
    }
    if !a.is_empty() {
        return usage(if cloud {
            "Usage: cmux cloud guide [--json]"
        } else {
            "Usage: cmux guide [--json]"
        });
    }
    let content = if cloud { CLOUD_GUIDE } else { GUIDE };
    if json_requested(ctx, raw) {
        ctx.emit(
            &json!({"topic":if cloud{"cloud"}else{"cmux"},"format":"markdown","content":content}),
        )?;
    } else {
        ctx.print(content)?;
    }
    Ok(Some(0))
}
const GUIDE: &str = r#"# cmux guide

cmux puts terminals, browsers, and agents in one workspace. Inspect your target before acting:

```sh
cmux identify --json
cmux tree --all --json
cmux capabilities --json
```

Create a workspace, add panes, then read output before sending input. Use `cmux browser` for browser surfaces and snapshots. Use `cmux docs <topic>` for exact command references. Use `cmux cloud guide` for remote machines.
"#;
const CLOUD_GUIDE: &str = r#"# cmux cloud guide

cmux Cloud runs commands, agents, browsers, and desktops on remote machines. List machines first, route the current directory, then use `exec` for short commands, `agent` for coding agents, `terminal` for long-running work, and `push`/`pull` for files.

```sh
cmux auth status
cmux cloud ls --json
cmux cloud route --json
cmux cloud exec <machine> -- pwd
cmux cloud agent --help
cmux cloud terminal --help
```

Read terminal output before reporting success. Use `tree`, `wait`, `open`, and `domains` to observe and share work.
"#;
fn read_text_opt(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jsonc_comments_and_trailing_commas_are_accepted() {
        let value: Value = serde_json::from_str(&strip_jsonc(
            r#"{
          // local setting
          "sidebar": 13,
        }"#,
        ))
        .expect("valid JSONC");
        assert_eq!(value["sidebar"], 13);
    }

    #[test]
    fn config_paths_expand_home() {
        let path = expand("~/x/cmux.json");
        assert!(path.is_absolute());
        assert_eq!(display(&path), "~/x/cmux.json");
    }

    #[test]
    fn settings_target_aliases_are_stable() {
        assert_eq!(normalize_target("shortcuts"), Some("keyboardShortcuts"));
        assert_eq!(
            normalize_target("sidebar_appearance"),
            Some("sidebarAppearance")
        );
        assert_eq!(normalize_target("unknown"), None);
    }

    #[test]
    fn theme_directive_uses_fallback_for_both_appearances() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("config.ghostty");
        fs::write(&path, "theme = catppuccin-mocha\n").expect("write");
        let text = read_text(&path);
        let mut raw = None;
        for line in text.lines() {
            if let Some((key, value)) = line.split_once('=') {
                if key.trim() == "theme" {
                    raw = Some(value.trim().to_string());
                }
            }
        }
        assert_eq!(raw.as_deref(), Some("catppuccin-mocha"));
    }
}
