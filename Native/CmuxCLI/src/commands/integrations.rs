//! Agent integration installation and discovery.
//!
//! This module deliberately owns setup-time mutations only.  Runtime hook
//! delivery belongs to `hooks_runtime`; keeping the two paths separate means
//! `cmux hooks <agent> install` can run without a live app socket.

use crate::{CliError, Context, Result};
use serde_json::{Map, Value, json};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

const PI_SOURCE: &str = include_str!("integrations/resources/pi.ts");
const AMP_SOURCE: &str = include_str!("integrations/resources/amp.ts");
const CAMPFIRE_SOURCE: &str = include_str!("integrations/resources/campfire.ts");
const OMP_SOURCE: &str = include_str!("integrations/resources/omp.ts");
const OPENCODE_SOURCE: &str = include_str!("integrations/resources/opencode.js");
const MARKER: &str = "cmux hooks";

#[derive(Clone, Copy)]
enum Format {
    Flat,
    Nested,
    Kiro,
    Antigravity,
    Rovo,
    Hermes,
    Kimi,
}

#[derive(Clone, Copy)]
struct Agent {
    name: &'static str,
    display: &'static str,
    config: &'static str,
    file: &'static str,
    env_home: Option<&'static str>,
    format: Format,
    binary: &'static str,
    aliases: &'static [&'static str],
    events: &'static [(&'static str, &'static str)],
    feed: &'static [&'static str],
}

const EMPTY: &[(&str, &str)] = &[];
const EMPTY_FEED: &[&str] = &[];
const AGENTS: &[Agent] = &[
    Agent {
        name: "codex",
        display: "Codex",
        config: ".codex",
        file: "hooks.json",
        env_home: Some("CODEX_HOME"),
        format: Format::Nested,
        binary: "codex",
        aliases: &[],
        events: &[
            ("SessionStart", "session-start"),
            ("UserPromptSubmit", "prompt-submit"),
            ("Stop", "stop"),
        ],
        feed: &[
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "PreCompact",
            "PostCompact",
            "SubagentStart",
            "SubagentStop",
        ],
    },
    Agent {
        name: "grok",
        display: "Grok",
        config: ".grok/hooks",
        file: "cmux-session.json",
        env_home: Some("GROK_HOME"),
        format: Format::Nested,
        binary: "grok",
        aliases: &[],
        events: &[
            ("SessionStart", "session-start"),
            ("UserPromptSubmit", "prompt-submit"),
            ("Stop", "stop"),
            ("Notification", "notification"),
            ("SessionEnd", "session-end"),
        ],
        feed: &["PreToolUse"],
    },
    Agent {
        name: "opencode",
        display: "OpenCode",
        config: ".config/opencode",
        file: "plugins/cmux-session.js",
        env_home: Some("OPENCODE_CONFIG_DIR"),
        format: Format::Flat,
        binary: "opencode",
        aliases: &[],
        events: EMPTY,
        feed: EMPTY_FEED,
    },
    Agent {
        name: "pi",
        display: "Pi",
        config: ".pi/agent",
        file: "extensions/cmux-session.ts",
        env_home: Some("PI_CODING_AGENT_DIR"),
        format: Format::Flat,
        binary: "pi",
        aliases: &[],
        events: EMPTY,
        feed: EMPTY_FEED,
    },
    Agent {
        name: "omp",
        display: "OMP",
        config: ".omp/agent",
        file: "extensions/cmux-omp-session.ts",
        env_home: None,
        format: Format::Flat,
        binary: "omp",
        aliases: &[],
        events: EMPTY,
        feed: EMPTY_FEED,
    },
    Agent {
        name: "campfire",
        display: "Campfire",
        config: ".campfire/agent",
        file: "extensions/cmux-campfire-session.ts",
        env_home: None,
        format: Format::Flat,
        binary: "campfire",
        aliases: &[],
        events: EMPTY,
        feed: EMPTY_FEED,
    },
    Agent {
        name: "amp",
        display: "Amp",
        config: ".config/amp",
        file: "plugins/cmux-session.ts",
        env_home: None,
        format: Format::Flat,
        binary: "amp",
        aliases: &[],
        events: EMPTY,
        feed: EMPTY_FEED,
    },
    Agent {
        name: "cursor",
        display: "Cursor",
        config: ".cursor",
        file: "hooks.json",
        env_home: None,
        format: Format::Flat,
        binary: "cursor-agent",
        aliases: &[],
        events: &[
            ("beforeSubmitPrompt", "prompt-submit"),
            ("stop", "stop"),
            ("afterAgentResponse", "agent-response"),
            ("beforeShellExecution", "shell-exec"),
            ("afterShellExecution", "shell-done"),
            ("postToolUseFailure", "shell-failed"),
        ],
        feed: EMPTY_FEED,
    },
    Agent {
        name: "gemini",
        display: "Gemini",
        config: ".gemini",
        file: "settings.json",
        env_home: None,
        format: Format::Nested,
        binary: "gemini",
        aliases: &[],
        events: &[
            ("SessionStart", "session-start"),
            ("BeforeAgent", "prompt-submit"),
            ("AfterAgent", "stop"),
            ("SessionEnd", "session-end"),
        ],
        feed: &["PreToolUse"],
    },
    Agent {
        name: "kiro",
        display: "Kiro",
        config: ".kiro/agents",
        file: "cmux.json",
        env_home: Some("KIRO_HOME"),
        format: Format::Kiro,
        binary: "kiro-cli",
        aliases: &[],
        events: &[
            ("agentSpawn", "session-start"),
            ("userPromptSubmit", "prompt-submit"),
            ("stop", "stop"),
        ],
        feed: &["preToolUse", "postToolUse"],
    },
    Agent {
        name: "antigravity",
        display: "Antigravity",
        config: ".gemini/config",
        file: "hooks.json",
        env_home: None,
        format: Format::Antigravity,
        binary: "agy",
        aliases: &["agy"],
        events: &[
            ("SessionStart", "session-start"),
            ("PreInvocation", "prompt-submit"),
            ("Stop", "stop"),
            ("turn-completion", "stop"),
            ("Notification", "notification"),
            ("SessionEnd", "session-end"),
        ],
        feed: EMPTY_FEED,
    },
    Agent {
        name: "rovodev",
        display: "Rovo Dev",
        config: ".rovodev",
        file: "config.yml",
        env_home: None,
        format: Format::Rovo,
        binary: "acli",
        aliases: &["rovo"],
        events: &[
            ("on_complete", "stop"),
            ("on_error", "stop"),
            ("on_tool_permission", "prompt-submit"),
        ],
        feed: EMPTY_FEED,
    },
    Agent {
        name: "hermes-agent",
        display: "Hermes Agent",
        config: ".hermes",
        file: "config.yaml",
        env_home: Some("HERMES_HOME"),
        format: Format::Hermes,
        binary: "hermes",
        aliases: &[],
        events: &[
            ("on_session_start", "session-start"),
            ("pre_llm_call", "prompt-submit"),
            ("post_llm_call", "agent-response"),
            ("pre_approval_request", "notification"),
            ("post_approval_response", "approval-response"),
            ("on_session_end", "session-end"),
            ("on_session_finalize", "session-finalize"),
            ("on_session_reset", "session-start"),
        ],
        feed: &[
            "pre_tool_call",
            "post_tool_call",
            "pre_approval_request",
            "post_approval_response",
        ],
    },
    Agent {
        name: "copilot",
        display: "Copilot",
        config: ".copilot",
        file: "config.json",
        env_home: Some("COPILOT_HOME"),
        format: Format::Nested,
        binary: "copilot",
        aliases: &[],
        events: &[
            ("SessionStart", "session-start"),
            ("Stop", "stop"),
            ("Notification", "stop"),
            ("SessionEnd", "session-end"),
        ],
        feed: &["PreToolUse"],
    },
    Agent {
        name: "codebuddy",
        display: "CodeBuddy",
        config: ".codebuddy",
        file: "settings.json",
        env_home: Some("CODEBUDDY_CONFIG_DIR"),
        format: Format::Nested,
        binary: "codebuddy",
        aliases: &[],
        events: &[
            ("SessionStart", "session-start"),
            ("Stop", "stop"),
            ("Notification", "stop"),
            ("SessionEnd", "session-end"),
        ],
        feed: &["PreToolUse"],
    },
    Agent {
        name: "factory",
        display: "Factory",
        config: ".factory",
        file: "settings.json",
        env_home: None,
        format: Format::Nested,
        binary: "droid",
        aliases: &[],
        events: &[
            ("SessionStart", "session-start"),
            ("Stop", "stop"),
            ("Notification", "stop"),
            ("SessionEnd", "session-end"),
        ],
        feed: &["PreToolUse"],
    },
    Agent {
        name: "qoder",
        display: "Qoder",
        config: ".qoder",
        file: "settings.json",
        env_home: Some("QODER_CONFIG_DIR"),
        format: Format::Nested,
        binary: "qodercli",
        aliases: &[],
        events: &[
            ("SessionStart", "session-start"),
            ("Stop", "stop"),
            ("SessionEnd", "session-end"),
        ],
        feed: &["PreToolUse"],
    },
    Agent {
        name: "kimi",
        display: "Kimi Code",
        config: ".kimi",
        file: "config.toml",
        env_home: Some("KIMI_HOME"),
        format: Format::Kimi,
        binary: "kimi",
        aliases: &[],
        events: &[
            ("SessionStart", "session-start"),
            ("UserPromptSubmit", "prompt-submit"),
            ("Notification", "notification"),
            ("Stop", "stop"),
            ("StopFailure", "notification"),
            ("SessionEnd", "session-end"),
        ],
        feed: &["PreToolUse", "PostToolUse"],
    },
];

fn agent(name: &str) -> Option<&'static Agent> {
    AGENTS
        .iter()
        .find(|a| a.name == name || a.aliases.iter().any(|x| *x == name))
}
fn home() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}
fn config_dir(a: &Agent) -> PathBuf {
    if let Some(var) = a.env_home {
        if let Some(v) = env::var_os(var) {
            if !v.is_empty() {
                let mut p = PathBuf::from(v);
                if a.name == "grok" {
                    p.push("hooks");
                }
                return p;
            }
        }
    }
    home().join(a.config)
}
fn command(a: &Agent, sub: &str) -> String {
    format!("cmux hooks {} {}", a.name, sub)
}
fn feed_command(a: &Agent, event: &str) -> String {
    format!("cmux hooks feed --source {} --event {}", a.name, event)
}
fn owned(s: &str, a: &Agent) -> bool {
    s.contains(MARKER) && (s.contains(a.name) || a.aliases.iter().any(|x| s.contains(x)))
}
fn source(a: &Agent) -> Option<&'static str> {
    Some(match a.name {
        "pi" => PI_SOURCE,
        "omp" => OMP_SOURCE,
        "campfire" => CAMPFIRE_SOURCE,
        "amp" => AMP_SOURCE,
        "opencode" => OPENCODE_SOURCE,
        _ => return None,
    })
}

pub fn run(ctx: &Context, command_name: &str, args: &[String]) -> Result<Option<i32>> {
    if command_name == "codex" && args.first().map(|s| s.as_str()) == Some("install-hooks") {
        return install(ctx, agent("codex").unwrap(), false).map(|_| Some(0));
    }
    if command_name == "codex" && args.first().map(|s| s.as_str()) == Some("uninstall-hooks") {
        return install(ctx, agent("codex").unwrap(), true).map(|_| Some(0));
    }
    if command_name != "hooks" {
        return Ok(None);
    }
    let Some(first) = args.first().map(|s| s.to_ascii_lowercase()) else {
        return catalog(ctx).map(|_| Some(0));
    };
    if first == "catalog" || first == "list" || first == "help" {
        return catalog(ctx).map(|_| Some(0));
    }
    if first == "setup" || first == "uninstall" {
        let remove = first == "uninstall";
        let target = args
            .iter()
            .skip(1)
            .find(|s| !s.starts_with('-'))
            .map(|s| s.as_str());
        for a in AGENTS {
            if target.is_none()
                || target == Some(a.name)
                || a.aliases.iter().any(|x| Some(*x) == target)
            {
                // Match Swift setup's conservative gate: installation only
                // touches agents present on PATH (or an existing managed
                // config); uninstall still cleans stale integrations.
                if !remove && !binary_on_path(a.binary) {
                    continue;
                }
                install(ctx, a, remove)?;
            }
        }
        return Ok(Some(0));
    }
    let Some(a) = agent(&first) else {
        return Err(CliError::new(
            "unknown_hooks_agent",
            format!("Unknown hooks target: {first}"),
        ));
    };
    match args.get(1).map(|s| s.as_str()) {
        Some("install") => install(ctx, a, false).map(|_| Some(0)),
        Some("uninstall") | Some("remove") => install(ctx, a, true).map(|_| Some(0)),
        _ => Ok(None),
    }
}

fn binary_on_path(name: &str) -> bool {
    let Some(path) = env::var_os("PATH") else {
        return false;
    };
    path.to_string_lossy().split(':').any(|dir| {
        let p = Path::new(dir).join(name);
        fs::metadata(p).map(|m| m.is_file()).unwrap_or(false)
    })
}

fn catalog(ctx: &Context) -> Result<()> {
    let rows: Vec<Value> = AGENTS.iter().map(|a| json!({"name":a.name,"display_name":a.display,"binary":a.binary,"config_dir":config_dir(a).display().to_string(),"config_file":a.file,"aliases":a.aliases,"events":a.events.iter().map(|(n,s)|json!({"agent_event":n,"cmux_subcommand":s})).collect::<Vec<_>>(),"feed_events":a.feed,"formats":format_name(a.format),"source_embedded":source(a).is_some()})).collect();
    if ctx.json {
        ctx.emit(&json!({"agents":rows,"count":rows.len()}))?;
    } else {
        for a in AGENTS {
            ctx.print(format!(
                "{}\t{}\t{}",
                a.name,
                a.display,
                config_dir(a).display()
            ))?;
        }
    }
    Ok(())
}
fn format_name(f: Format) -> &'static str {
    match f {
        Format::Flat => "flat",
        Format::Nested => "nested",
        Format::Kiro => "kiro",
        Format::Antigravity => "antigravity",
        Format::Rovo => "yaml",
        Format::Hermes => "yaml",
        Format::Kimi => "toml",
    }
}

fn install(ctx: &Context, a: &Agent, remove: bool) -> Result<()> {
    let dir = config_dir(a);
    let path = dir.join(a.file);
    if let Some(src) = source(a) {
        return install_source(ctx, a, &path, src, remove);
    }
    let old = fs::read_to_string(&path).unwrap_or_default();
    let new = match a.format {
        Format::Rovo => marker_text(&old, a, remove, "yaml"),
        Format::Hermes => marker_text(&old, a, remove, "yaml"),
        Format::Kimi => marker_text(&old, a, remove, "toml"),
        Format::Antigravity => json_hooks(&old, a, remove, true)?,
        _ => json_hooks(&old, a, remove, false)?,
    };
    write_change(ctx, a, &path, old, new, remove)
}
fn install_source(ctx: &Context, a: &Agent, path: &Path, src: &str, remove: bool) -> Result<()> {
    let old = fs::read_to_string(path).unwrap_or_default();
    if remove {
        if !owned(&old, a) {
            return write_change(ctx, a, path, old.clone(), old, true);
        }
        return write_change(ctx, a, path, old, String::new(), true);
    }
    if !old.is_empty() && !owned(&old, a) && old != src {
        return Err(CliError::new(
            "managed_file_conflict",
            format!("{} exists and is not a cmux {}", path.display(), a.display),
        ));
    }
    write_change(ctx, a, path, old, src.to_string(), false)
}
fn write_change(
    ctx: &Context,
    a: &Agent,
    path: &Path,
    old: String,
    new: String,
    remove: bool,
) -> Result<()> {
    if old == new {
        ctx.print(format!(
            "{} hooks already up to date at {}",
            a.display,
            path.display()
        ))?;
        return Ok(());
    }
    if ctx.dry_run {
        if ctx.json {
            ctx.emit(&json!({"ok":true,"dry_run":true,"path":path.display().to_string(),"changed":true,"action":if remove{"uninstall"}else{"install"}}))?;
        } else {
            ctx.print(format!(
                "would {} {}",
                if remove { "remove" } else { "write" },
                path.display()
            ))?;
        }
        return Ok(());
    }
    if new.is_empty() {
        if path.exists() {
            fs::remove_file(path).map_err(|e| CliError::new("io", e.to_string()))?;
        }
    } else {
        fs::create_dir_all(path.parent().unwrap_or(Path::new(".")))
            .map_err(|e| CliError::new("io", e.to_string()))?;
        fs::write(path, new).map_err(|e| CliError::new("io", e.to_string()))?;
    }
    if ctx.json {
        ctx.emit(&json!({"ok":true,"path":path.display().to_string(),"action":if remove{"uninstall"}else{"install"}}))?;
    } else {
        ctx.print(format!(
            "{} hooks {} at {}",
            a.display,
            if remove { "removed" } else { "installed" },
            path.display()
        ))?;
    }
    Ok(())
}

fn json_hooks(old: &str, a: &Agent, remove: bool, anti: bool) -> Result<String> {
    let mut root: Value = if old.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(old).map_err(|_| {
            CliError::new(
                "invalid_json",
                format!("{} exists but is not valid JSON", a.file),
            )
        })?
    };
    let obj = root
        .as_object_mut()
        .ok_or_else(|| CliError::new("invalid_json", "hook config must be an object"))?;
    // Work on a detached value so the root object can be updated with metadata
    // (`version`, Kiro fields, Antigravity group) without overlapping mutable
    // borrows of its `hooks` entry.
    let mut hooks = if anti {
        obj.remove("cmux").unwrap_or_else(|| json!({}))
    } else {
        obj.remove("hooks").unwrap_or_else(|| json!({}))
    };
    let hm = hooks
        .as_object_mut()
        .ok_or_else(|| CliError::new("invalid_hooks", "hooks must be an object"))?;
    for value in hm.values_mut() {
        prune(value, a);
    }
    if !remove {
        let mut events = Map::new();
        for (event, sub) in a.events {
            let cmd = command(a, sub);
            let mut ent = if matches!(a.format, Format::Nested) {
                json!({"type":"command","command":cmd,"timeout":if a.name == "codex" || a.name == "grok" {120}else{120000}})
            } else {
                json!({"command":cmd})
            };
            if matches!(a.format, Format::Kiro) {
                ent["timeout_ms"] = json!(5000);
            }
            if matches!(a.format, Format::Nested) {
                events.insert((*event).into(), json!([{"hooks":[ent]}]));
            } else {
                events.insert((*event).into(), json!([ent]));
            }
        }
        for e in a.feed {
            let timeout = if a.name == "codex" || a.name == "grok" {
                120
            } else {
                120000
            };
            let entry = if matches!(a.format, Format::Nested) {
                json!({"type":"command","command":feed_command(a,e),"timeout":timeout})
            } else {
                json!({"command":feed_command(a,e)})
            };
            events.insert(
                (*e).into(),
                if matches!(a.format, Format::Nested) {
                    json!([{"hooks":[entry]}])
                } else {
                    json!([entry])
                },
            );
        }
        for (k, v) in events {
            if let (Some(existing), Some(incoming)) =
                (hm.get_mut(&k).and_then(Value::as_array_mut), v.as_array())
            {
                existing.extend(incoming.iter().cloned());
            } else {
                hm.insert(k, v);
            }
        }
    }
    drop(hm);
    if !remove && matches!(a.format, Format::Flat) {
        obj.insert("version".into(), json!(1));
    }
    if !remove && matches!(a.format, Format::Kiro) {
        obj.entry("name").or_insert(json!("cmux"));
        obj.entry("description").or_insert(json!(
            "CMUX notification and Feed bridge hooks for Kiro CLI."
        ));
        obj.entry("tools").or_insert(json!(["*"]));
    }
    if anti {
        if !remove {
            obj.insert("cmux".into(), hooks);
        }
    } else {
        obj.insert("hooks".into(), hooks);
    }
    serde_json::to_string_pretty(&root).map_err(|e| CliError::new("json", e.to_string()))
}
fn prune(v: &mut Value, a: &Agent) {
    match v {
        Value::Array(xs) => {
            for x in xs.iter_mut() {
                prune(x, a);
            }
            xs.retain(|x| {
                let direct_owned = x
                    .get("command")
                    .and_then(Value::as_str)
                    .map(|s| owned(s, a))
                    .unwrap_or(false);
                let empty_group = x
                    .get("hooks")
                    .and_then(Value::as_array)
                    .map(|hooks| hooks.is_empty())
                    .unwrap_or(false);
                !direct_owned && !empty_group
            });
        }
        Value::Object(m) => {
            for x in m.values_mut() {
                prune(x, a)
            }
        }
        _ => {}
    }
}
fn marker_text(old: &str, a: &Agent, remove: bool, kind: &str) -> String {
    if kind == "toml" {
        return kimi_text(old, a, remove);
    }
    if kind == "yaml" {
        return yaml_text(old, a, remove);
    }
    unreachable!()
}
fn yaml_quote(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
    )
}
fn yaml_text(old: &str, a: &Agent, remove: bool) -> String {
    let (begin, end) = (
        format!("# cmux hooks {} begin", a.name),
        format!("# cmux hooks {} end", a.name),
    );
    let mut lines: Vec<String> = old
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .split('\n')
        .map(str::to_string)
        .collect();
    if lines.last().map(String::is_empty).unwrap_or(false) {
        lines.pop();
    }
    while let Some(i) = lines.iter().position(|l| l.trim() == begin) {
        if let Some(j) = lines[i..].iter().position(|l| l.trim() == end) {
            let start = if i > 0 && lines[i - 1].trim().is_empty() {
                i - 1
            } else {
                i
            };
            lines.drain(start..=i + j);
        } else {
            lines.remove(i);
        }
    }
    if remove {
        return if lines.is_empty() {
            String::new()
        } else {
            lines.join("\n") + "\n"
        };
    }
    if a.name == "rovodev" {
        if !lines.is_empty() && lines.last().map(|x| !x.trim().is_empty()).unwrap_or(false) {
            lines.push(String::new());
        }
        lines.push(begin);
        lines.push("eventHooks:".into());
        lines.push("  events:".into());
        for (e, s) in a.events {
            lines.push(format!("    - name: {}", e));
            lines.push("      commands:".into());
            lines.push(format!("        - command: {}", yaml_quote(&command(a, s))));
        }
        lines.push(end);
    } else {
        if !lines.is_empty() && lines.last().map(|x| !x.trim().is_empty()).unwrap_or(false) {
            lines.push(String::new());
        }
        lines.push(begin);
        lines.push("hooks:".into());
        for (e, s) in a.events {
            lines.push(format!("  {}:", e));
            lines.push(format!(
                "    - command: {}",
                yaml_quote(&format!("sh -c '{}'", command(a, s)))
            ));
            lines.push("      timeout: 5".into());
        }
        for e in a.feed {
            lines.push(format!("  {}:", e));
            lines.push(format!(
                "    - command: {}",
                yaml_quote(&format!("sh -c '{}'", feed_command(a, e)))
            ));
            lines.push("      timeout: 120".into());
        }
        lines.push(end);
    }
    lines.join("\n") + "\n"
}
fn kimi_text(old: &str, a: &Agent, remove: bool) -> String {
    let begin = "# cmux-kimi-hooks-7c3a9f12-4e8b-4d2a-9f15-6b8c0d1e2a3f begin";
    let end = "# cmux-kimi-hooks-7c3a9f12-4e8b-4d2a-9f15-6b8c0d1e2a3f end";
    let mut lines: Vec<String> = old
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .split('\n')
        .map(str::to_string)
        .collect();
    if lines.last().map(String::is_empty).unwrap_or(false) {
        lines.pop();
    }
    while let Some(i) = lines.iter().position(|l| l.trim() == begin) {
        if let Some(j) = lines[i..].iter().position(|l| l.trim() == end) {
            lines.drain(i..=i + j);
        } else {
            lines.remove(i);
        }
    }
    if !remove {
        if !lines.is_empty() {
            lines.push(String::new());
        }
        lines.push(begin.into());
        for (e, s) in a.events {
            lines.extend([
                "[[hooks]]".into(),
                format!("event = \"{}\"", e),
                format!("command = \"{}\"", toml_quote(&command(a, s))),
                "timeout = 10".into(),
                String::new(),
            ]);
        }
        for e in a.feed {
            lines.extend([
                "[[hooks]]".into(),
                format!("event = \"{}\"", e),
                format!("command = \"{}\"", toml_quote(&feed_command(a, e))),
                "timeout = 120".into(),
                String::new(),
            ]);
        }
        lines.push(end.into());
    } else {
        while lines.len() > 1
            && lines.last().is_some_and(String::is_empty)
            && lines[lines.len() - 2].is_empty()
        {
            lines.pop();
        }
    }
    if lines.is_empty() {
        String::new()
    } else {
        lines.join("\n") + "\n"
    }
}
fn toml_quote(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn catalog_is_complete() {
        assert!(AGENTS.len() >= 18);
        assert!(agent("agy").is_some());
    }
    #[test]
    fn json_install_preserves_user_hook() {
        let a = agent("cursor").unwrap();
        let s = json_hooks(
            r#"{"hooks":{"stop":[{"type":"command","command":"echo user"}]}}"#,
            a,
            false,
            false,
        )
        .unwrap();
        assert!(s.contains("echo user"));
        assert!(s.contains("cmux hooks cursor stop"));
    }
    #[test]
    fn source_markers_are_embedded() {
        assert!(PI_SOURCE.contains("cmux-pi-session-extension-marker"));
        assert!(OPENCODE_SOURCE.contains("CMUXSessionRestore"));
    }
    #[test]
    fn text_configs_round_trip_owned_blocks() {
        let rovo = agent("rovodev").unwrap();
        let installed = marker_text("project: demo\n", rovo, false, "yaml");
        assert!(installed.contains("eventHooks:\n  events:"));
        assert_eq!(
            marker_text(&installed, rovo, true, "yaml"),
            "project: demo\n"
        );
        let kimi = agent("kimi").unwrap();
        let installed = marker_text("theme = \"dark\"\n\n", kimi, false, "toml");
        assert!(installed.contains("[[hooks]]"));
        assert_eq!(
            marker_text(&installed, kimi, true, "toml"),
            "theme = \"dark\"\n\n"
        );
    }
}
