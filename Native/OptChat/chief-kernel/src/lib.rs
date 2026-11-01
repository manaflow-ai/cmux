//! The Chief kernel's pure core (plans/cmux-next/chief-engines-DESIGN.md,
//! cloud-chief-durable-DESIGN.md section 13): what every Chief engine and
//! placement shares, with no I/O. It builds natively for the Mac and Linux
//! host and for `wasm32-unknown-unknown` inside the Cloud Chief's Durable
//! Object. Synchronous, no threads, no clock, no randomness: time and seeds
//! come in each call's context, and JSON crosses the boundary.

mod cron;
pub mod ledger;
pub mod prompt;
mod record;
pub mod replies;
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
/// - `profile_json`: `{person?, instructions?, channels?, record?, contact?}`:
///   the person profile (`person.md`), the instructions file (`AGENTS.md`), the
///   Channels block, the optional coordinator session, and the Chief's record (`{display_name, role,
///   personality, instructions, is_default}`), each optional.
/// - `engine`: one of ``ENGINES``; a `cli` engine needs `tools.chief`.
/// - `tools_json`: `{mode?: "mcp" | "cli" | "cloud", chief?, offered?, profile_tool?, chiefs_tool?}`;
///   `cloud` (the pi-durable Cloud Chief) names exactly the `offered` tools;
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
        "cloud" => {
            let offered: Vec<String> = tools
                .get("offered")
                .and_then(Value::as_array)
                .ok_or("tools: a cloud mode needs `offered`, the tool names the Chief has")?
                .iter()
                .map(|t| {
                    t.as_str()
                        .map(str::to_owned)
                        .ok_or("tools: `offered` holds names")
                })
                .collect::<Result<_, _>>()?;
            let known = tools::tool_list(false, &|_| true);
            let known: Vec<&str> = known
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|t| t["name"].as_str())
                .collect();
            if let Some(bad) = offered.iter().find(|t| !known.contains(&t.as_str())) {
                return Err(format!("tools: `offered` names no tool {bad:?}"));
            }
            Tools::Cloud(offered)
        }
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
    let user = prompt::with_coordinator_contact(user, text("contact").as_deref());
    Ok(chief_system_text(
        user.as_deref(),
        &tools_mode,
        flag("profile_tool"),
        flag("chiefs_tool"),
    ))
}

/// A memory tool answered with no effect outside the memory: `zoom` (its
/// lines, or a message whole) and `date` (a message's stored time in the
/// person's offset, `ctx.utc_offset_minutes`, default UTC). `dates` reads a
/// message's stored ISO time from the host. Every other tool is the host's.
pub fn call_pure(
    name: &str,
    args_json: &str,
    ctx_json: &str,
    memory: &optchat_core::Memory,
    store: &dyn optchat_core::Store,
    dates: &dyn Fn(u64) -> Option<String>,
) -> Result<String, String> {
    let args: Value = serde_json::from_str(args_json).map_err(|e| format!("{name}: {e}"))?;
    let ctx: Value = serde_json::from_str(ctx_json).map_err(|e| format!("ctx: {e}"))?;
    let num = |k: &str| {
        args.get(k)
            .and_then(Value::as_u64)
            .ok_or_else(|| format!("{name}: `{k}` must be a whole number"))
    };
    match name {
        "zoom" => {
            optchat_core::zoom(memory, store, num("id")?, num("n")?).map_err(|e| e.to_string())
        }
        "date" => {
            let id = num("id")?;
            let offset = ctx
                .get("utc_offset_minutes")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            Ok(match dates(id) {
                Some(iso) => local_date(&iso, offset),
                None => format!("No message {id}."),
            })
        }
        other => Err(format!("{other}: not a pure tool; the host runs it")),
    }
}

/// A stored ISO time in the person's offset, as the host's `date(id)` shows it.
fn local_date(iso: &str, offset_minutes: i64) -> String {
    let offset = i32::try_from(offset_minutes * 60)
        .ok()
        .and_then(chrono::FixedOffset::east_opt)
        .unwrap_or_else(|| chrono::FixedOffset::east_opt(0).expect("UTC"));
    match chrono::DateTime::parse_from_rfc3339(iso) {
        Ok(t) => t
            .with_timezone(&offset)
            .format("%Y-%m-%d %H:%M:%S %:z")
            .to_string(),
        // An imported note may carry a date in another format; show it as stored.
        Err(_) => iso.to_owned(),
    }
}
