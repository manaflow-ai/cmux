//! `optchat-chief agent-memory`: long-term memory shared by the Codex and
//! Claude Code sessions a person runs, on one or more machines (cmux#21611).
//!
//! The index is derived data in its own OptChat home (index.rs), rebuilt
//! from the agents' own memory files and decision folders (sources.rs) when
//! they change. The only thing it writes for good is the notes log
//! (notes.rs). One machine owns the index; the others reach it through
//! `cmux remote rpc` (relay.rs) and fall back to their own index for reads.
//! cmux registers the MCP server (mcp.rs) for every agent session it starts
//! when `agents.memory.enabled` is on (acpmux `agent_tools.rs`).

pub mod index;
pub mod mcp;
pub mod notes;
pub mod relay;
pub mod settings;
pub mod sources;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use index::Index;
use settings::MemorySettings;
use sources::Sources;

pub const USAGE: &str = "optchat-chief agent-memory search [--json] [--limit N] [--local] WORDS...   entries holding every word
optchat-chief agent-memory get ID [--json] [--local]          one entry in full
optchat-chief agent-memory remember [--local] TEXT...         save a dated note (lesson, host fact, decision)
optchat-chief agent-memory mcp [--local]                      stdio MCP server: memory_search, memory_get, memory_remember
optchat-chief agent-memory sync [--force]                     rebuild this machine's index now (search does it when stale)
optchat-chief agent-memory sources                            what this machine's index is built from
optchat-chief agent-memory config codex|claude                the MCP entry for sessions cmux does not start
Settings (cmux.json): agents.memory.enabled, .owner (a cmux remote route), .ownerArgs, .ownerCommand, .remember, .sources
Env: CMUX_AGENT_MEMORY_HOME (~/.cmux/agent-memory), CMUX_AGENT_MEMORY_NOTES (~/.cmux/agent-memory-notes.jsonl),
     CMUX_NEXT_CONFIG_FILE; sources are always ~/.claude/projects/*/memory, ~/.codex/memories and .sources
--local: this machine's index, even when agents.memory.owner names another
Options go before the text; `--` ends them, and the text is kept as written";

/// `agent-memory` arguments: options anywhere before the text, then the
/// text verbatim, so a note about `--no-verify` keeps its words.
#[derive(Debug, Default, PartialEq, Eq)]
struct Args {
    verb: Option<String>,
    words: Vec<String>,
    json: bool,
    local: bool,
    force: bool,
    limit: Option<String>,
}

impl Args {
    fn parse(args: &[String]) -> Result<Args, String> {
        let mut out = Args::default();
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            match arg.as_str() {
                "--" => {
                    out.words.extend(it.by_ref().cloned());
                }
                "--json" => out.json = true,
                "--local" => out.local = true,
                "--force" => out.force = true,
                "--limit" => {
                    out.limit = Some(it.next().cloned().ok_or("--limit needs a number")?);
                }
                option if option.starts_with("--") => {
                    return Err(format!("unknown option {option}\n{USAGE}"));
                }
                _ if out.verb.is_none() => out.verb = Some(arg.clone()),
                _ => {
                    out.words.push(arg.clone());
                    out.words.extend(it.by_ref().cloned());
                }
            }
        }
        Ok(out)
    }
}

/// The user's home: `HOME`, else the password database (a client may pass
/// a stdio server only an allowlisted environment).
fn user_home() -> PathBuf {
    if let Some(home) = crate::cli::env("HOME") {
        return PathBuf::from(home);
    }
    // SAFETY: getpwuid returns a pointer into static storage or null; the
    // directory string is copied out before any other passwd call.
    unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if !entry.is_null() && !(*entry).pw_dir.is_null() {
            let dir = std::ffi::CStr::from_ptr((*entry).pw_dir);
            return PathBuf::from(dir.to_string_lossy().into_owned());
        }
    }
    PathBuf::from("/")
}

/// This machine's index, its sources and the settings.
pub fn open(home: &Path) -> (Index, MemorySettings) {
    let settings = MemorySettings::read(home);
    let path = |key: &str, default: &str| {
        crate::cli::env(key)
            .map(|v| settings::expand_tilde(&v, home))
            .unwrap_or_else(|| home.join(default))
    };
    let root = path("CMUX_AGENT_MEMORY_HOME", ".cmux/agent-memory");
    let notes = path("CMUX_AGENT_MEMORY_NOTES", ".cmux/agent-memory-notes.jsonl");
    let sources = Sources::new(home, settings.sources.clone(), notes);
    (Index::new(root, sources), settings)
}

/// The relay to the owner, unless `local` or none is set.
fn owner(settings: &MemorySettings, local: bool) -> Option<Box<dyn mcp::Owner>> {
    let route = settings.owner.clone().filter(|_| !local)?;
    Some(Box::new(relay::Relay::new(
        route,
        settings.owner_args.clone(),
        relay::owner_argv(&settings.owner_command),
        relay::cmux_cli(),
    )))
}

/// Runs `agent-memory ARGS`; returns what to print.
pub fn run(args: &[String]) -> Result<String, String> {
    let parsed = Args::parse(args)?;
    let (json_out, local, force) = (parsed.json, parsed.local, parsed.force);
    let words: Vec<&str> = parsed.words.iter().map(String::as_str).collect();
    let home = user_home();
    let (index, settings) = open(&home);
    match parsed.verb.as_deref() {
        Some("mcp") => {
            let mut server = mcp::Server {
                index,
                remember: settings.remember,
                owner: owner(&settings, local),
            };
            let stdin = std::io::stdin();
            mcp::serve(stdin.lock(), std::io::stdout().lock(), &mut server)
                .map_err(|e| e.to_string())?;
            Ok(String::new())
        }
        Some(verb @ ("search" | "get" | "remember")) => {
            let (tool, arguments) = match verb {
                "search" => {
                    if words.is_empty() {
                        return Err(format!("search needs words\n{USAGE}"));
                    }
                    let limit = parsed
                        .limit
                        .as_deref()
                        .map(|v| v.parse::<u64>().map_err(|e| format!("--limit {v}: {e}")))
                        .transpose()?;
                    let mut a = json!({"query": words.join(" ")});
                    if let Some(limit) = limit {
                        a["limit"] = json!(limit);
                    }
                    ("memory_search", a)
                }
                "get" => {
                    let id = words
                        .first()
                        .and_then(|w| w.trim_start_matches('#').parse::<u64>().ok())
                        .ok_or_else(|| format!("get needs an entry id\n{USAGE}"))?;
                    ("memory_get", json!({"id": id}))
                }
                _ => {
                    if words.is_empty() {
                        return Err(format!("remember needs text\n{USAGE}"));
                    }
                    ("memory_remember", json!({"text": words.join(" ")}))
                }
            };
            if json_out {
                if tool == "memory_remember" {
                    return Err(format!("--json is for search and get\n{USAGE}"));
                }
                return json_call(&index, &settings, local, tool, &arguments);
            }
            let mut server = mcp::Server {
                index,
                remember: settings.remember,
                owner: owner(&settings, local),
            };
            tool_text(&mut server, tool, arguments)
        }
        Some("sync") => index.refresh(force),
        Some("sources") => {
            let (entries, skipped) = index.sources.scan();
            let mut lines: Vec<String> = entries.into_iter().map(|e| e.source).collect();
            lines.extend(
                skipped
                    .into_iter()
                    .map(|s| format!("{s} (skipped: looks like a credential)")),
            );
            Ok(lines.join("\n"))
        }
        Some("config") => config(words.first().copied()),
        _ => Err(USAGE.to_owned()),
    }
}

/// One tool call through the server (so the owner answers when set); its
/// text, or the text as the error.
fn tool_text(server: &mut mcp::Server, tool: &str, arguments: Value) -> Result<String, String> {
    let message = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": tool, "arguments": arguments}});
    let answer = server.handle(&message).ok_or("no answer")?;
    let result = &answer["result"];
    let text = result["content"][0]["text"]
        .as_str()
        .map(str::to_owned)
        .or_else(|| answer["error"]["message"].as_str().map(str::to_owned))
        .unwrap_or_else(|| answer.to_string());
    if result["isError"] == json!(true) || answer.get("error").is_some() {
        Err(text)
    } else {
        Ok(text)
    }
}

/// `--json` (search and get): hits with id, kind, date, source, snippet and
/// full text. On a machine with an owner, the owner answers over the same
/// route; when it cannot, this machine's index does, and stderr says so
/// (stdout stays the JSON).
fn json_call(
    index: &Index,
    settings: &MemorySettings,
    local: bool,
    tool: &str,
    arguments: &Value,
) -> Result<String, String> {
    if let Some(route) = settings.owner.as_ref().filter(|_| !local) {
        // The owner's own `--json`, through its MCP server: a JSON text the
        // server returns for the hidden `format: json` argument.
        let mut args = arguments.clone();
        args["format"] = json!("json");
        let mut relay = relay::Relay::new(
            route.clone(),
            settings.owner_args.clone(),
            relay::owner_argv(&settings.owner_command),
            relay::cmux_cli(),
        );
        let message = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": tool, "arguments": args}});
        match relay.call(&message) {
            Ok(answer) => {
                if let Some(error) = answer.get("error") {
                    return Err(error["message"]
                        .as_str()
                        .map_or_else(|| error.to_string(), str::to_owned));
                }
                let text = answer["result"]["content"][0]["text"]
                    .as_str()
                    .unwrap_or("");
                if answer["result"]["isError"] == json!(true) {
                    return Err(text.to_owned());
                }
                return Ok(text.to_owned());
            }
            // An unreachable owner: this machine's own index, as for MCP reads.
            Err(why) => eprintln!(
                "agent memory: the owner ({route}) did not answer, so this machine's index answered and its ids are this machine's: {why}"
            ),
        }
    }
    json_local(index, tool, arguments)
}

/// The JSON answer of a search or get on this machine's index.
pub fn json_local(index: &Index, tool: &str, arguments: &Value) -> Result<String, String> {
    match tool {
        "memory_search" => {
            let query = arguments["query"].as_str().unwrap_or("");
            let limit = arguments["limit"].as_u64().unwrap_or(20).clamp(1, 200) as usize;
            let hits = index.search(query, limit)?;
            Ok(Value::Array(hits.iter().map(index::Hit::to_json).collect()).to_string())
        }
        "memory_get" => {
            let id = arguments["id"].as_u64().ok_or("get needs an id")?;
            Ok(index.get(id)?.to_json().to_string())
        }
        _ => Err(format!("--json is for search and get, not {tool}")),
    }
}

/// The MCP entry for a harness cmux does not start (`sr codex` on a
/// server, a terminal `claude`): the same server, with every tool
/// pre-approved for Codex (a session with approval_policy=never refuses
/// an MCP tool that would ask).
fn config(harness: Option<&str>) -> Result<String, String> {
    let exe = std::env::current_exe()
        .map(|p| p.display().to_string())
        .map_err(|e| e.to_string())?;
    match harness {
        Some("codex") => {
            let mut out = format!(
                "[mcp_servers.cmux-agent-memory]\ncommand = {}\nargs = [\"agent-memory\", \"mcp\"]\nstartup_timeout_sec = 10\ntool_timeout_sec = 120\n",
                toml_string(&exe)
            );
            for tool in ["memory_search", "memory_get", "memory_remember"] {
                out.push_str(&format!(
                    "\n[mcp_servers.cmux-agent-memory.tools.{tool}]\napproval_mode = \"approve\"\n"
                ));
            }
            Ok(out)
        }
        Some("claude") => Ok(format!(
            "{:#}",
            json!({"mcpServers": {"cmux-agent-memory": {
                "type": "stdio", "command": exe, "args": ["agent-memory", "mcp"]}}})
        )),
        _ => Err(format!("config needs codex or claude\n{USAGE}")),
    }
}

fn toml_string(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(line: &str) -> Result<Args, String> {
        Args::parse(&line.split(' ').map(String::from).collect::<Vec<_>>())
    }

    #[test]
    fn text_keeps_option_like_words() {
        let a = parse("remember --local never pass --no-verify, use --force-with-lease --json")
            .unwrap();
        assert!(a.local && !a.json && !a.force);
        assert_eq!(a.verb.as_deref(), Some("remember"));
        assert_eq!(
            a.words.join(" "),
            "never pass --no-verify, use --force-with-lease --json"
        );
    }

    #[test]
    fn options_go_before_the_text_and_dashes_end_them() {
        let a = parse("search --json --limit 5 hooks").unwrap();
        assert!(a.json);
        assert_eq!(a.limit.as_deref(), Some("5"));
        assert_eq!(a.words, ["hooks"]);
        let a = parse("remember -- --local is a flag").unwrap();
        assert!(!a.local);
        assert_eq!(a.words.join(" "), "--local is a flag");
        assert!(parse("search --nope x").is_err());
        assert!(parse("search --limit").is_err());
    }
}
