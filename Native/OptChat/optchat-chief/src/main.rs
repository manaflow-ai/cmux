//! `optchat-chief`: the OptChat Chief host, its MCP memory tools and its
//! `agents` verbs. See README.md.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use optchat_chief::cli::Flags;
use optchat_chief::paths::{Paths, mux_home};

const USAGE: &str = "optchat-chief host --daemon-socket PATH [--mux-home DIR]   run the Chief host (one per MUX_HOME)
optchat-chief mcp [--socket PATH | --mux-home DIR]           stdio MCP server with zoom and date
optchat-chief zoom ID N | date ID [--socket PATH | --mux-home DIR]  the memory tools as commands (harnesses without MCP)
optchat-chief spawn \"task\" [\"task\" ...] | tell ID \"message\"     section 9's subagent tools as commands
optchat-chief trace [--since 1h] [--turn ID] [--json] [--mux-home DIR]  the monitoring trace as a timeline
optchat-chief workspace                                   the person's Home workspace now (panes, terminal tails, browsers)
optchat-chief engine show | set [--harness H] [--model M] [--effort E] [--compactor-harness H] [--compactor-model M]
optchat-chief stats [--since 24h] [--json] [--mux-home DIR]      per turn, node and subagent: latency, tools, cache, cost
optchat-chief usage [--since 7d] [--by chief|agent|model|harness|kind] [--top N] [--json] [--mux-home DIR]... [--chiefs]
                                                          tokens, cost, cache hit and turn time over time (the usage ledger)
optchat-chief usage backfill [--force] [--mux-home DIR]   convert old traces into the usage ledger
optchat-chief agents list | prompt NAME \"text\" | allow NAME [OPTION_ID] | deny NAME
optchat-chief browse [--mux-home DIR] [--out FILE]          the whole memory as one HTML page
optchat-chief import [--mux-home DIR] FILE                  append JSON lines {\"text\", \"kind\"?, \"date\"?} (host stopped)
optchat-chief settings [show | set cache.ttl 5m|1h | set replies.thread auto|always|never | set show.afterReport true|false
                       | set subagents.showWorkspaces true|false | set cloud.autoPauseIdleSeconds N] [--mux-home DIR]
                                                           per-Chief settings (none of them makes the Chief ask before it acts)
optchat-chief import-claude-code dry-run|write [--projects DIR] [--mux-home DIR] [--append-after-live]
                                                           Claude Code transcripts (default ~/.claude/projects) as messages;
                                                           dry-run prints counts only, write appends them (host stopped)
optchat-chief memory export|import|search|stats ...         the memory database (see `optchat-chief memory`)
optchat-chief move --to local:/path|ssh:HOST[:/path] [--stop-host] [--dry-run] | rollback | checkpoint | restore | verify
                                                           move this Chief to another home or host (see `optchat-chief move help`)
optchat-chief agent-memory search|get|remember|mcp|sync|sources|config ...  long-term memory shared by Codex and Claude Code sessions (see `optchat-chief agent-memory`)
optchat-chief host --conversation-source cloud --cloud-install FILE --daemon-socket PATH [--mux-home DIR]
                                                             answer the chief's cloud conversation (an always-on brain host)
optchat-chief peer-chiefs list | tell chief:NAME TEXT [--key K] | read [--after N] [--wait S] [--config FILE]
                                                           Chief-to-Chief messages through the agent hub ($MUX_HOME/optchat/peer-chiefs.json)
optchat-chief cloud pair|enroll|register|chief|status --install FILE   the brain host's cloud identity (see `cloud help`)
optchat-chief pack list | status|login|wait|paste|share|logout|token|check|install NAME [--json] [--mux-home DIR]
                                                           the Chief's tool packs: CLIs, skills and sign-ins (plans/cmux-next/chief-toolpacks-DESIGN.md)
optchat-chief github status | login | wait [SECONDS] | pat FILE|- | mac | logout [--json] [--mux-home DIR]
                                                           this Chief's GitHub login (default: the Mac's gh): `pack ... github`
Env: CMUX_DAEMON_SOCKET, MUX_HOME (~/.cmux/mux), MUX_AGENT_TOKEN_FILE,
     OPTCHAT_CHIEF_HARNESS / MUX_HARNESS (claude-cr when acpmux has a configured CodeRouter route, else claude), OPTCHAT_COMPACTOR_HARNESS (the Chief's),
     MUX_POLICY (approve-all), OPTCHAT_CHIEF_MODEL, ACPMUX_SOCKET / ACPMUX_HOME / ACPMUX_BIN,
     CMUX_SOCKET_PATH, OPTCHAT_ANTHROPIC_BASE_URL (compactor; the team subrouter)";

fn main() -> std::process::ExitCode {
    let started_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    // Agent memory parses its own arguments: note text keeps every word,
    // including the Chief's own flags below.
    if args.first().is_some_and(|a| a == "agent-memory") {
        return match optchat_chief::agent_memory::run(&args[1..]) {
            Ok(out) => {
                if !out.is_empty() {
                    println!("{out}");
                }
                std::process::ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("optchat-chief agent-memory: {e}");
                std::process::ExitCode::from(1)
            }
        };
    }
    // `move` parses its own switches (`--stop-host`, `--dry-run`, ...).
    if args.first().is_some_and(|a| a == "move") {
        let code = optchat_chief::migrate::cli(&args[1..]);
        return std::process::ExitCode::from(u8::try_from(code).unwrap_or(1));
    }
    // `pack mcp|mcp-headers PACK SERVER`: a pack's MCP server (stdout is the
    // protocol) and Claude Code's headers helper.
    if args.first().is_some_and(|a| a == "pack")
        && args
            .get(1)
            .is_some_and(|a| a == "mcp" || a == "mcp-headers")
    {
        let flags = Flags::parse(&args);
        let (pack, server) = (
            flags.words.get(2).cloned().unwrap_or_default(),
            flags.words.get(3).cloned().unwrap_or_default(),
        );
        let home = home(&flags);
        let out = if args[1] == "mcp" {
            optchat_chief::toolpacks::serve_mcp(&home, &pack, &server)
        } else {
            optchat_chief::toolpacks::mcp_headers(&home, &pack, &server).map(|h| {
                println!("{h}");
                0
            })
        };
        return match out {
            Ok(code) => std::process::ExitCode::from(u8::try_from(code).unwrap_or(1)),
            Err(e) => {
                eprintln!("optchat-chief pack: {e}");
                std::process::ExitCode::from(1)
            }
        };
    }
    // `pack` and its `github` alias read their own `--json`.
    if let Some(verb) = args
        .first()
        .filter(|a| *a == "github" || *a == "pack")
        .cloned()
    {
        let as_json = args.iter().any(|a| a == "--json");
        args.retain(|a| a != "--json");
        let flags = Flags::parse(&args);
        let out = if verb == "github" {
            optchat_chief::github::run(&flags, &home(&flags), as_json)
        } else {
            optchat_chief::toolpacks::run(&flags, &home(&flags), as_json)
        };
        return match out {
            Ok(out) => {
                println!("{out}");
                std::process::ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("optchat-chief {verb}: {e}");
                std::process::ExitCode::from(1)
            }
        };
    }
    // `peer-chiefs` parses its own switches (`--config`, `--key`, ...).
    if args.first().is_some_and(|a| a == "peer-chiefs") {
        return match optchat_chief::peer_chiefs::cli(&args[1..]) {
            Ok(out) => {
                println!("{out}");
                std::process::ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("optchat-chief peer-chiefs: {e}");
                std::process::ExitCode::from(1)
            }
        };
    }
    // A boolean flag: taken out before parsing, which would read the next
    // argument as its value.
    let append_after_live = args.iter().any(|a| a == "--append-after-live");
    args.retain(|a| a != "--append-after-live");
    // `memory import-from ... --stop-host`: also a boolean (a bare flag would take the next word).
    for a in args.iter_mut() {
        if a == "--stop-host" {
            *a = "--stop-host=1".to_owned();
        }
    }
    let mut flags = Flags::parse(&args);
    // `memory search --json` (and only there: `trace` and `stats` read their
    // own `--json` from the raw arguments). The verb may follow options.
    let memory_json =
        flags.words.first().is_some_and(|w| w == "memory") && args.iter().any(|a| a == "--json");
    if memory_json {
        args.retain(|a| a != "--json");
        flags = Flags::parse(&args);
    }
    let code = match flags.words.first().map(String::as_str) {
        Some("host") => optchat_chief::host::run(&flags, started_ms),
        Some("mcp") => {
            let socket = flags.value("socket").map(PathBuf::from).unwrap_or_else(|| {
                let home = flags
                    .value("mux-home")
                    .map(PathBuf::from)
                    .unwrap_or_else(mux_home);
                Paths::new(&home).tools_socket
            });
            let subagent = flags.value("role") == Some("subagent");
            match optchat_chief::mcp::run(&socket, subagent) {
                Ok(()) => 0,
                Err(e) => {
                    eprintln!("optchat-chief mcp: {e}");
                    1
                }
            }
        }
        Some(
            tool @ ("zoom" | "date" | "spawn" | "tell" | "peers" | "react" | "reply" | "send"
            | "stop" | "sleep" | "remember" | "transcript" | "control" | "profile"
            | "chiefs" | "escalate-auth" | "escalate_auth" | "cloud-workspace"
            | "cloud_workspace"),
        ) => {
            let socket = flags
                .value("socket")
                .map(PathBuf::from)
                .unwrap_or_else(|| Paths::new(&home(&flags)).tools_socket);
            let args: Vec<&str> = flags.words.iter().skip(1).map(String::as_str).collect();
            let call = match optchat_chief::tools::command(tool, &args) {
                Ok(optchat_chief::tools::Command::Call(call)) => Ok(call),
                Ok(optchat_chief::tools::Command::Help(usage)) => {
                    println!("{usage}");
                    return std::process::ExitCode::SUCCESS;
                }
                Ok(optchat_chief::tools::Command::Usage(usage)) => Err(usage),
                Err(e) => Err(e),
            };
            // A subagent's tools (OPTCHAT_SUBAGENT=1) have no spawn or tell.
            let subagent =
                optchat_chief::cli::env(optchat_chief::session_dir::SUBAGENT_ENV).is_some();
            let call = call.map(optchat_chief::tools::with_turn_key);
            match call.and_then(|c| optchat_chief::tools::ask_as(&socket, c, subagent)) {
                Ok(text) => {
                    println!("{text}");
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief {tool}: {e}");
                    1
                }
            }
        }
        Some(verb @ ("trace" | "stats")) => match optchat_chief::report::run(verb, &args[1..]) {
            Ok(out) => {
                print!("{out}");
                0
            }
            Err(e) => {
                eprintln!("optchat-chief {verb}: {e}");
                1
            }
        },
        Some("usage") => match optchat_chief::usage::run(&args[1..]) {
            Ok(out) => {
                print!("{out}");
                0
            }
            Err(e) => {
                eprintln!("optchat-chief usage: {e}");
                1
            }
        },
        Some("workspace") => match optchat_chief::home_view::HomeView::from_env().read() {
            Some(block) => {
                println!("{block}");
                0
            }
            None => {
                eprintln!(
                    "chief workspace: this cmux session has no Home workspace (the cmux app makes it)"
                );
                1
            }
        },
        Some("engine") => match optchat_chief::engine::run(&flags) {
            Ok(out) => {
                print!("{out}");
                0
            }
            Err(e) => {
                eprintln!("optchat-chief engine: {e}");
                1
            }
        },
        // The daemon's Chief brain supervisor, when it deletes a Chief on
        // a shared acpmux: that Chief's sessions end, the daemon stays.
        Some("end-sessions") => {
            match optchat_chief::agents::end_own_sessions(&optchat_chief::paths::mux_home()) {
                Ok(names) => {
                    println!("ended {} session(s)", names.len());
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief end-sessions: {e}");
                    1
                }
            }
        }
        Some("agents") if optchat_chief::agents::retired(&flags.words).is_some() => {
            eprintln!(
                "{}",
                optchat_chief::agents::retired(&flags.words).unwrap_or_default()
            );
            2
        }
        Some("agents") => match optchat_chief::agents::run(&flags) {
            Ok(out) => {
                println!("{out}");
                0
            }
            Err(e) => {
                eprintln!("chief agents: {e}");
                1
            }
        },
        Some("settings") => {
            let paths = Paths::new(&home(&flags));
            let set = match (
                flags.words.get(1).map(String::as_str),
                flags.words.get(2),
                flags.words.get(3),
            ) {
                (None | Some("show"), None, None) => Ok(None),
                (Some("set"), Some(key), Some(value)) => Ok(Some((key.as_str(), value.as_str()))),
                _ => Err(USAGE.to_owned()),
            };
            let result = set.and_then(|set| {
                match optchat_chief::tools::ask_settings(&paths.tools_socket, set) {
                    // No host: no turn runs, so the Mac's own CLI edits the file.
                    // A subagent gets no owner controls this way either (the host
                    // refuses it on the socket, tools.rs).
                    Err(e)
                        if e.contains("not running")
                            && optchat_chief::turn_caller::this_process_is_a_subagent() =>
                    {
                        Err("subagents have no owner controls".to_owned())
                    }
                    Err(e) if e.contains("not running") => {
                        let file = paths.root.join("settings.json");
                        let mut s = optchat_chief::chief_settings::ChiefSettings::load(&file);
                        if let Some((key, value)) = set {
                            use optchat_chief::chief_settings::{CACHE_TTL, parse_ttl};
                            match key {
                                CACHE_TTL => s.cache_ttl = Some(parse_ttl(value)?),
                                optchat_chief::chief_settings::CLOUD_AUTO_PAUSE_IDLE_SECONDS => {
                                    s.cloud_auto_pause_idle_secs =
                                        optchat_chief::chief_settings::parse_idle_secs(value)?
                                }
                                optchat_chief::chief_settings::SHOW_SUBAGENT_WORKSPACES => {
                                    s.show_subagent_workspaces =
                                        optchat_chief::chief_settings::parse_bool(value)?
                                }
                                _ => return Err(format!("unknown setting {key:?}")),
                            }
                            s.save(&file)
                                .map_err(|e| format!("{}: {e}", file.display()))?;
                        }
                        Ok(format!("{:#}", s.to_json()))
                    }
                    other => other,
                }
            });
            match result {
                Ok(text) => {
                    println!("{text}");
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief settings: {e}");
                    1
                }
            }
        }
        Some("browse") => {
            let paths = Paths::new(&home(&flags));
            let page = optchat_chief::tools::ask_browse(&paths.tools_socket).or_else(|e| {
                // The host's refusal stands, and a subagent gets no page
                // from the files either (the settings arm above).
                if e.contains("subagents have no owner controls")
                    || optchat_chief::turn_caller::this_process_is_a_subagent()
                {
                    return Err("subagents have no owner controls".to_owned());
                }
                let chat = optchat_chief::browse::open_offline(&paths.chat, &paths.memory_db)?;
                let page = optchat_chief::browse::html(&chat);
                chat.shutdown();
                Ok::<_, String>(page)
            });
            let out = flags
                .value("out")
                .map(PathBuf::from)
                .unwrap_or_else(|| paths.root.join("memory.html"));
            match page.and_then(|p| std::fs::write(&out, p).map_err(|e| e.to_string())) {
                Ok(()) => {
                    println!("{}", out.display());
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief browse: {e}");
                    1
                }
            }
        }
        Some("import") => {
            let paths = Paths::new(&home(&flags));
            let result = flags
                .words
                .get(1)
                .ok_or_else(|| USAGE.to_owned())
                .and_then(|file| std::fs::read_to_string(file).map_err(|e| format!("{file}: {e}")))
                .and_then(|text| optchat_chief::browse::parse_import(&text))
                .and_then(|items| {
                    optchat_chief::browse::import(&paths.chat, &paths.memory_db, &items)
                });
            match result {
                Ok(n) => {
                    println!("imported {n} messages");
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief import: {e}");
                    1
                }
            }
        }
        Some("cloud") => match optchat_chief::cloud::cli::run(&flags) {
            Ok(out) => {
                println!("{out}");
                0
            }
            Err(e) => {
                eprintln!("optchat-chief cloud: {e}");
                1
            }
        },
        Some("memory") => {
            match optchat_chief::memory_cli::run(&flags, &home(&flags), memory_json) {
                Ok(out) => {
                    println!("{out}");
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief memory: {e}");
                    1
                }
            }
        }
        Some("import-claude-code") => {
            let paths = Paths::new(&home(&flags));
            let projects = flags
                .values
                .get("projects")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    let user_home = std::env::var_os("HOME")
                        .map(PathBuf::from)
                        .unwrap_or_default();
                    optchat_chief::claude_import::default_projects_dir(
                        &user_home,
                        std::env::var("CLAUDE_CONFIG_DIR").ok(),
                    )
                });
            let mode = flags.words.get(1).map(String::as_str);
            let converted = match mode {
                Some("dry-run" | "write") => {
                    optchat_chief::claude_import::convert_projects(&projects)
                        .map_err(|e| format!("{}: {e}", projects.display()))
                }
                _ => Err(USAGE.to_owned()),
            };
            match converted.and_then(|(items, stats)| {
                println!("{}: {stats}", projects.display());
                if mode == Some("write") {
                    optchat_chief::claude_import::import_history(
                        &paths.chat,
                        &paths.memory_db,
                        &items,
                        append_after_live,
                    )
                    .map(Some)
                } else {
                    match optchat_chief::claude_import::existing_messages(
                        &paths.chat,
                        &paths.memory_db,
                    ) {
                        Ok(n) => {
                            if let Some(warning) = optchat_chief::claude_import::order_warning(n) {
                                println!("warning: {warning}");
                            }
                        }
                        Err(e) => println!("warning: cannot count the memory's messages: {e}"),
                    }
                    Ok(None)
                }
            }) {
                Ok(Some(n)) => {
                    println!("imported {n} messages");
                    0
                }
                Ok(None) => {
                    println!("dry run: nothing written");
                    0
                }
                Err(e) => {
                    eprintln!("optchat-chief import-claude-code: {e}");
                    1
                }
            }
        }
        Some("help") | Some("--help") => {
            println!("{USAGE}");
            0
        }
        _ => {
            eprintln!("{USAGE}");
            2
        }
    };
    std::process::ExitCode::from(u8::try_from(code).unwrap_or(1))
}

fn home(flags: &Flags) -> PathBuf {
    flags
        .value("mux-home")
        .map(PathBuf::from)
        .unwrap_or_else(mux_home)
}
