//! The Chief kernel's pure core (plans/cmux-next/chief-engines-DESIGN.md,
//! cloud-chief-durable-DESIGN.md section 13): what every Chief engine and
//! placement shares, with no I/O. It builds natively for the Mac and Linux
//! host and for `wasm32-unknown-unknown` inside the Cloud Chief's Durable
//! Object. Synchronous, no threads, no clock, no randomness: time and seeds
//! come in each call's context, and JSON crosses the boundary.

pub mod prompt;
mod record;
pub mod tools;

pub use record::{Record, render_record};

use prompt::{Tools, chief_system_text};
use serde_json::Value;

/// The engines a Chief turn can run on; each names its tools one way.
/// `cli` engines reach the kernel through the `chief` launcher, the others
/// through tools with their short names (an MCP server or in process).
const ENGINES: &[(&str, bool)] = &[
    ("claude", false),
    ("claude-sr", false),
    ("claude-sr2", false),
    ("claude-acp", false),
    ("native", false),
    ("pi-durable", false),
    ("codex", true),
    ("muse", true),
    ("unii", true),
    ("opencode", true),
    ("gemini", true),
];

/// The system text of a Chief turn, exactly as the Mac host renders it.
///
/// - `profile_json`: `{person?, instructions?, channels?, record?}`: the
///   person profile (`person.md`), the instructions file (`AGENTS.md`), the
///   Channels block, and the Chief's record (`{display_name, role,
///   personality, instructions, is_default}`), each optional.
/// - `engine`: one of ``ENGINES``; a `cli` engine needs `tools.chief`.
/// - `tools_json`: `{mode?: "mcp" | "cli", chief?, profile_tool?, chiefs_tool?}`;
///   the mode defaults to the engine's.
pub fn render_system(profile_json: &str, engine: &str, tools_json: &str) -> Result<String, String> {
    let profile: Value = serde_json::from_str(profile_json).map_err(|e| format!("profile: {e}"))?;
    let tools: Value = serde_json::from_str(tools_json).map_err(|e| format!("tools: {e}"))?;
    let cli_engine = ENGINES
        .iter()
        .find(|(name, _)| *name == engine)
        .map(|(_, cli)| *cli)
        .ok_or_else(|| format!("engine: no engine {engine:?}"))?;
    let flag = |k: &str| tools.get(k).and_then(Value::as_bool).unwrap_or(false);
    let mode = tools
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or(if cli_engine { "cli" } else { "mcp" });
    let tools_mode = match mode {
        "mcp" => Tools::Mcp,
        "cli" => Tools::Cli(
            tools
                .get("chief")
                .and_then(Value::as_str)
                .filter(|c| !c.is_empty())
                .ok_or("tools: a cli engine needs `chief`, the launcher's absolute path")?
                .to_owned(),
        ),
        other => return Err(format!("tools: no mode {other:?}")),
    };
    let text = |k: &str| {
        profile
            .get(k)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(str::to_owned)
    };
    // The host's order: person.md and AGENTS.md, then Channels, then the record.
    let base: Vec<String> = [text("person"), text("instructions")]
        .into_iter()
        .flatten()
        .collect();
    let mut parts: Vec<String> = Vec::new();
    if !base.is_empty() {
        parts.push(base.join("\n\n"));
    }
    parts.extend(text("channels"));
    if let Some(record) = profile.get("record").filter(|r| !r.is_null()) {
        let record = Record::from_json(record);
        parts.extend(render_record(&record));
    }
    let user = (!parts.is_empty()).then(|| parts.join("\n\n"));
    Ok(chief_system_text(
        user.as_deref(),
        &tools_mode,
        flag("profile_tool"),
        flag("chiefs_tool"),
    ))
}

/// A memory tool answered with no effect outside the memory (stub).
pub fn call_pure(
    _name: &str,
    _args_json: &str,
    _ctx_json: &str,
    _memory: &optchat_core::Memory,
    _store: &dyn optchat_core::Store,
    _dates: &dyn Fn(u64) -> Option<String>,
) -> Result<String, String> {
    Err("not yet".into())
}
