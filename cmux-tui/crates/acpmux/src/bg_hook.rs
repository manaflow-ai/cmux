//! `__bg-hook`: Claude Code's PreToolUse hook for `Bash` in the session plugin
//! (`agent_tools.rs`). Leo, 2026-10-27: "also when it comes to hibernation...can't you hibernate
//! the agent but not hibernate the bg tasks?" A `run_in_background` shell ends when the agent
//! hibernates (Claude Code's exit cleanup), so when the chat has the `acpmux` server's
//! `bg_start` (`acpmux_mcp_bg.rs`), the hook rewrites such a call (`updatedInput`) to start the
//! same command as a daemon task, where it outlives the agent, and return at once with the task's
//! id ([`rewrite`], run by [`start_main`], `acpmux __bg-start`). It never refuses a call: Leo,
//! 2026-11-20: "stuff like the stale guards/intsructions/bad interruptions/not useful enough
//! tools are big" and "we need to fix them at the root". The refusal it used to give (resend the
//! same call, or call `bg_start`) was resent unchanged 254 of 308 times on one machine, so it
//! cost a round trip and protected nothing.
//!
//! It never strands the agent: when the chat's MCP config (`agent_tools::mcp_config_path`) has
//! no `acpmux` server, plain or behind the `cmux` server's code mode, or anything cannot be read,
//! it says nothing and Claude Code runs the shell as asked. When the start fails at run time,
//! the rewritten call says so on one line and runs the original command itself in its shell.
//!
//! It also rewrites a known-slow command run in the foreground ([`SLOW`]: builds and test
//! runs, CI waits, dev servers and follows that never end) the same way, so the turn goes on
//! while it runs (where the chat has no acpmux server, it only adds `run_in_background: true`).
//! Leo, 2026-11-02, on a session that sat about 80 minutes in one turn of foreground shell
//! calls: "but why not in cmux". A command with [`FOREGROUND_OK`] or a trailing `&` stays in the
//! foreground. Any other command still in the foreground after a minute goes to the background on
//! its own (`hub/auto_background.rs`), since no list knows a person's own scripts.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

pub const HOOK_ARG: &str = "__bg-hook";

/// How the chat reaches `bg_start`, from its Claude Code MCP config.
#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    /// `mcp__acpmux__bg_start`: the server stands on its own.
    Direct,
    /// `mcp__cmux__acpmux_bg_start`: folded behind `cmux`, which lists every tool
    /// (`--all-tools`) or the ones a preset allows ([`crate::agent_tools::MCP_TOOLS_ENV`]).
    Listed,
    /// `cmux.acpmux_bg_start` in a `cmux_exec` script: folded behind `cmux`'s code mode.
    CodeMode,
}

/// The cmux server's name for `bg_start` behind it (`cmux mcp serve`'s upstream prefix).
const FOLDED_TOOL: &str = "acpmux_bg_start";

pub fn route(config: &Value) -> Option<Route> {
    let servers = config.get("mcpServers")?;
    if servers.get(crate::acpmux_mcp_names::SERVER_NAME).is_some() {
        return Some(Route::Direct);
    }
    let cmux = servers.get("cmux")?;
    let env = |k: &str| cmux.pointer("/env")?.get(k)?.as_str();
    let upstreams: Value = serde_json::from_str(env(crate::agent_tools::UPSTREAMS_ENV)?).ok()?;
    let folded = upstreams.as_array()?.iter().any(|s| {
        s.get("name").and_then(Value::as_str) == Some(crate::acpmux_mcp_names::SERVER_NAME)
    });
    if !folded {
        return None;
    }
    // A preset's allowlist: cmux lists only those tools and refuses every other call.
    if let Some(allowed) = env(crate::agent_tools::MCP_TOOLS_ENV) {
        return allowed.split(',').any(|t| t.trim() == FOLDED_TOOL).then_some(Route::Listed);
    }
    let all = cmux
        .get("args")
        .and_then(Value::as_array)
        .is_some_and(|a| a.iter().any(|a| a == "--all-tools"));
    Some(if all { Route::Listed } else { Route::CodeMode })
}

/// The file older builds kept the commands the hook turned away in, beside the chat's MCP config:
/// nothing writes it now, and a chat's cleanup still removes one left behind.
pub fn denied_path(config: &std::path::Path) -> std::path::PathBuf {
    let mut name = config.as_os_str().to_owned();
    name.push(".bg-denied");
    name.into()
}

/// Commands known to run long, which a foreground shell would hold the turn for: (program,
/// the word after it or None for any, a word that must also appear or None, why). A program is
/// a command's first word's file name (`host_load::for_each_command` reads the words).
const SLOW: &[(&str, Option<&str>, Option<&str>, &str)] = &[
    ("cargo", Some("build"), None, "a Rust build"),
    ("cargo", Some("b"), None, "a Rust build"),
    ("cargo", Some("test"), None, "a Rust test run"),
    ("cargo", Some("t"), None, "a Rust test run"),
    ("cargo", Some("nextest"), None, "a Rust test run"),
    ("cargo", Some("clippy"), None, "a Rust lint run"),
    ("cargo", Some("bench"), None, "a Rust benchmark run"),
    ("swift", Some("build"), None, "a Swift build"),
    ("swift", Some("test"), None, "a Swift test run"),
    ("xcodebuild", None, None, "an Xcode build"),
    ("gh", Some("run"), Some("watch"), "a CI wait"),
    ("gh", Some("pr"), Some("--watch"), "a CI wait"),
    ("tail", None, Some("-f"), "a follow that never ends on its own"),
    ("tail", None, Some("-F"), "a follow that never ends on its own"),
    ("tail", None, Some("--follow"), "a follow that never ends on its own"),
    ("watch", None, None, "a watch that never ends on its own"),
    ("next", Some("dev"), None, "a dev server, which never ends on its own"),
    ("vite", Some("dev"), None, "a dev server, which never ends on its own"),
    ("vite", Some("serve"), None, "a dev server, which never ends on its own"),
    ("npm", Some("start"), None, "a dev server, which never ends on its own"),
    ("npm", Some("run"), Some("dev"), "a dev server, which never ends on its own"),
    ("npm", Some("run"), Some("start"), "a dev server, which never ends on its own"),
    ("npm", Some("run"), Some("watch"), "a watcher, which never ends on its own"),
    ("pnpm", Some("dev"), None, "a dev server, which never ends on its own"),
    ("pnpm", Some("start"), None, "a dev server, which never ends on its own"),
    ("pnpm", Some("run"), Some("dev"), "a dev server, which never ends on its own"),
    ("yarn", Some("dev"), None, "a dev server, which never ends on its own"),
    ("yarn", Some("start"), None, "a dev server, which never ends on its own"),
    ("bun", Some("dev"), None, "a dev server, which never ends on its own"),
    ("bun", Some("run"), Some("dev"), "a dev server, which never ends on its own"),
];

/// Words that make any listed command quick: help, a version, and the quick reads of the
/// listed builds (`xcodebuild -list`).
const QUICK: &[&str] = &[
    "--help",
    "-h",
    "help",
    "--version",
    "-V",
    "-version",
    "-showsdks",
    "-list",
    "-usage",
    "-showBuildSettings",
    "-checkFirstLaunchStatus",
];

/// The comment that lets a known-slow command run in the foreground.
pub const FOREGROUND_OK: &str = "# fg-ok";

/// Claude Code's input names `agent_id` only for a subagent's call (a `case` pattern; a quoted
/// `"agent_id"` in a command's own text is escaped in the JSON and does not match).
pub const SUBAGENT_PATTERN: &str = "*'\"agent_id\"'*";

/// The `Bash` calls [`main`] may answer, as shell `case` patterns on Claude Code's input
/// (`agent_tools::hook_command`): a background shell, a subagent's call ([`subagent_mark`]), and
/// for each [`SLOW`] entry its program and next word as written (`cargo test`), then the word it
/// also needs. The plugin starts this binary only on a match, so the common call, the lead's quick
/// foreground command, costs a shell and no process start. A false match only starts the binary,
/// which answers as before; a slow command spelled another way (`cargo  test`) runs as asked, and
/// `hub/auto_background.rs` moves it to the background after a minute, as for any long command.
/// The 2026-11 context audit measured the unfiltered hook at about 20-40 ms on each of 84,542
/// Bash calls.
pub fn bash_patterns() -> Vec<String> {
    let mut all: Vec<String> = ["\"run_in_background\":true", "\"run_in_background\": true"]
        .iter()
        .map(|w| format!("*'{w}'*"))
        .chain([SUBAGENT_PATTERN.to_owned()])
        .collect();
    for (tool, next, needs, _) in SLOW {
        let first = next.map_or_else(|| (*tool).to_owned(), |next| format!("{tool} {next}"));
        let then = needs.map(|w| format!("*' {w}'")).unwrap_or_default();
        let pattern = format!("*'{first}'{then}*");
        if !all.contains(&pattern) {
            all.push(pattern);
        }
    }
    all
}

/// Whether `command` asks to stay as written: it carries [`FOREGROUND_OK`] or puts itself in the
/// background with a trailing `&`, which a daemon task (a shell that ends with it) would not do.
fn keeps_shell(command: &str) -> bool {
    let trimmed = command.trim_end();
    command.contains(FOREGROUND_OK) || (trimmed.ends_with('&') && !trimmed.ends_with("&&"))
}

/// Why `command` would hold the turn for long, if one of its simple commands is known to
/// ([`SLOW`]), or None. A command that puts itself in the background (a trailing `&`) or
/// carries [`FOREGROUND_OK`] holds nothing; `nohup` or `setsid` alone still runs in the
/// foreground.
pub fn slow_reason(command: &str) -> Option<&'static str> {
    if keeps_shell(command) {
        return None;
    }
    let mut found = None;
    crate::host_load::for_each_command(command, &mut |argv: &[&str]| {
        if found.is_some() {
            return;
        }
        let Some(program) = argv.first().map(|w| w.rsplit('/').next().unwrap_or(w)) else {
            return;
        };
        let rest = argv.get(1..).unwrap_or_default();
        for (tool, next, needs, why) in SLOW {
            if *tool != program
                || next.is_some_and(|n| rest.first() != Some(&n))
                || needs.is_some_and(|n| !rest.contains(&n))
            {
                continue;
            }
            if !rest.iter().any(|w| QUICK.contains(w)) {
                found = Some(*why);
                return;
            }
        }
    });
    found
}

/// The hook's argument that starts a daemon task for a rewritten call ([`start_main`]).
pub const START_ARG: &str = "__bg-start";

/// The variable a rewritten call keeps the original command in ([`rewrite`]).
const ORIGINAL_VAR: &str = "ACPMUX_BG_ORIGINAL";

/// What the hook does with one PreToolUse `input`, or None to let the call run: the same call
/// with a changed input, never a refusal. A background shell, where the chat has the `acpmux`
/// server (`route`), and a known-slow command ([`slow_reason`]) in the foreground both become a
/// call that starts the command as a daemon task and returns at once ([`rewrite`]); where the
/// chat has no such server a slow foreground command only gets `run_in_background: true`.
/// `start` is the command that starts the task: this binary, [`START_ARG`], and the chat.
pub fn decide(input: &Value, route: Option<Route>, start: &[String]) -> Option<Value> {
    if input.get("tool_name").and_then(Value::as_str) != Some("Bash") {
        return None;
    }
    let command = input.pointer("/tool_input/command")?.as_str()?;
    let background = input.pointer("/tool_input/run_in_background") == Some(&json!(true));
    let mut tool_input = input.get("tool_input").filter(|t| t.is_object())?.clone();
    if keeps_shell(command) || (background && route.is_none()) {
        return None;
    }
    if !background {
        slow_reason(command)?;
    }
    if route.is_some() && !start.is_empty() {
        let cwd = input.get("cwd").and_then(Value::as_str).filter(|c| !c.is_empty());
        let description = tool_input.get("description").and_then(Value::as_str);
        tool_input.set("command", json!(rewrite(command, cwd, description, start)));
        if let Some(fields) = tool_input.as_object_mut() {
            fields.remove("run_in_background");
        }
    } else {
        tool_input.set("run_in_background", json!(true));
    }
    Some(json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": tool_input,
    }}))
}

/// `command` as a call that starts it as a daemon task (`acpmux __bg-start`, the path of the
/// `bg_start` tool, [`start_main`]) and prints its id, then ends: the task survives the agent's
/// hibernation and the chat is told when it ends. When the start fails (a daemon that is gone, a
/// refused call) the shell says so on one line and runs `command` itself, as it would have
/// without the hook, so the agent is never left without the command. The original is kept
/// whole in one variable, so no quoting of its own can break the fallback.
///
/// No permission decision is added: the call is allowed or asked as before.
pub fn rewrite(
    command: &str,
    cwd: Option<&str>,
    description: Option<&str>,
    start: &[String],
) -> String {
    let mut words = start.to_vec();
    if let Some(cwd) = cwd {
        words.extend(["--cwd".to_owned(), cwd.to_owned()]);
    }
    if let Some(description) = description.filter(|d| !d.trim().is_empty()) {
        words.extend(["--description".to_owned(), description.to_owned()]);
    }
    words.push("--".to_owned());
    let original = crate::agent_tools::quoted(&[command.to_owned()]);
    let start = crate::agent_tools::quoted(&words);
    format!(
        "{ORIGINAL_VAR}={original}\n{start} \"${ORIGINAL_VAR}\" || {{ echo 'acpmux: could not \
start a background task; running the command in this shell instead' >&2; eval \
\"${ORIGINAL_VAR}\"; }}"
    )
}

/// The hook's mark on a command a Claude Code subagent runs that may run the acpmux CLI, or
/// None: the same call with `export ACPMUX_CALLER_SUBAGENT=TYPE:ID` on a line before it
/// (`cli::sender::SUBAGENT_ENV`), so the send says which subagent of the session sent it.
///
/// A subagent runs in its lead's process with the lead's whole environment, the caller token
/// too, so without the mark its every `acpmux send` was the lead's: the receiver answered the
/// lead's chat instead of the subagent that asked (round-2 orchestration eval, 2026-11-08). Claude
/// Code names the subagent only in the hook's input (`agent_id`, `agent_type`; absent for the
/// lead's own calls), and a hook can change only the call's input, not its environment.
///
/// Which command may run the CLI is not a match of its text: a wrapper script, an alias, a
/// variable (`$A send`) or a path under another name runs it too. Every command is marked but
/// one made only of [`PLAIN_TOOLS`], which never start another program by a name the subagent
/// chose ([`may_run_acpmux`]); so the read-only commands a harness runs without asking stay as
/// they were. The mark carries no permission decision: the call is allowed or asked as before,
/// and acpmux's own read-only judgment reads the command without it ([`without_subagent_mark`]).
pub fn subagent_mark(input: &Value) -> Option<Value> {
    if input.get("tool_name").and_then(Value::as_str) != Some("Bash") {
        return None;
    }
    let id = input.get("agent_id").and_then(Value::as_str)?;
    let kind = input
        .get("agent_type")
        .and_then(Value::as_str)
        .filter(|k| crate::sender_env::subagent_word(k))
        .unwrap_or("subagent");
    if !crate::sender_env::subagent_word(id) {
        return None;
    }
    let command = input.pointer("/tool_input/command")?.as_str()?;
    let env = crate::sender_env::SUBAGENT_ENV;
    if !may_run_acpmux(command) || command.contains(env) {
        return None;
    }
    let mut tool_input = input.get("tool_input").filter(|t| t.is_object())?.clone();
    tool_input.set("command", json!(format!("export {env}={kind}:{id}\n{command}")));
    Some(json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": tool_input,
    }}))
}

/// Programs that start no program a subagent's Bash call names (the arguments that would are
/// checked in [`plain_command`]): a command made only of these cannot reach the acpmux CLI on
/// the call's own words, so the hook leaves it unmarked ([`subagent_mark`]). A program the
/// person's own setup starts (a git hook, a pager, a diff driver) runs unmarked; the mark is a
/// label, not a guard. Every program `hub/shell_readonly.rs` passes as a read is here.
const PLAIN_TOOLS: &[&str] = &[
    "pwd", "ls", "cat", "head", "tail", "wc", "echo", "printf", "true", "false", "which", "type",
    "stat", "du", "df", "basename", "dirname", "realpath", "readlink", "cut", "tr", "nl", "cmp",
    "comm", "grep", "egrep", "fgrep", "rg", "column", "whoami", "id", "uname", "jq", "test", "[",
    "diff", "uniq", "date", "hostname", "sort", "sed", "cd", "mkdir", "touch", "cp", "mv", "rm",
    "ln", "chmod", "file", "find", "git",
];

/// git's own commands: `git NAME` for any other NAME may run a `git-NAME` program or an alias.
const GIT_COMMANDS: &[&str] = &[
    "status",
    "diff",
    "log",
    "show",
    "add",
    "commit",
    "push",
    "pull",
    "fetch",
    "checkout",
    "switch",
    "restore",
    "branch",
    "merge",
    "reset",
    "stash",
    "rev-parse",
    "worktree",
    "tag",
    "remote",
    "config",
    "clone",
    "init",
    "grep",
    "blame",
    "describe",
    "shortlog",
    "rev-list",
    "show-ref",
    "for-each-ref",
    "ls-files",
    "ls-tree",
    "cat-file",
    "cherry-pick",
    "revert",
    "apply",
    "mv",
    "rm",
    "clean",
    "reflog",
    "merge-base",
    "name-rev",
    "count-objects",
    "range-diff",
    "diff-tree",
    "version",
];

/// Whether a subagent's Bash `command` may run the acpmux CLI: it names acpmux, or one of its
/// commands runs a program not known to run nothing else ([`PLAIN_TOOLS`]). The commands are
/// the shell's (`host_load::for_each_command`: `$(...)`, `sh -c`, `eval` and wrappers included).
pub fn may_run_acpmux(command: &str) -> bool {
    if command.contains("acpmux") {
        return true;
    }
    let mut other = false;
    crate::host_load::for_each_command(command, &mut |argv: &[&str]| {
        other |= !plain_command(argv);
    });
    other
}

/// Whether one simple command runs only a [`PLAIN_TOOLS`] program: named plainly (no
/// substitution or variable), git with one of its own commands, find with no `-exec`.
fn plain_command(argv: &[&str]) -> bool {
    let Some(first) = argv.first() else { return true };
    if first.contains(['$', '`']) {
        return false;
    }
    let program = first.rsplit('/').next().unwrap_or(first);
    if !PLAIN_TOOLS.contains(&program) {
        return false;
    }
    let rest = argv.get(1..).unwrap_or_default();
    let names_a_program = |flags: &[&str]| {
        rest.iter().any(|a| flags.iter().any(|f| a == f || a.starts_with(&format!("{f}="))))
    };
    match program {
        "find" => !rest.iter().any(|a| a.starts_with("-exec") || a.starts_with("-ok")),
        // `--pre CMD` runs CMD on each file.
        "rg" => !names_a_program(&["--pre"]),
        "sort" => !names_a_program(&["--compress-program"]),
        // GNU sed's `e` command and `s///e` run the pattern space.
        "sed" => {
            let args: Vec<String> = rest.iter().map(|a| (*a).to_owned()).collect();
            crate::shell_readonly::sed_prints_only(&args)
        }
        "git" => {
            let mut words = rest.iter();
            while let Some(w) = words.next() {
                if *w == "-C" {
                    words.next();
                } else if *w == "-c" || w.starts_with("--config-env") {
                    // A config value can name a program (`core.pager`, `diff.external`).
                    return false;
                } else if !w.starts_with('-') {
                    return GIT_COMMANDS.contains(w);
                }
            }
            true
        }
        _ => true,
    }
}

/// `command` without the hook's mark line ([`subagent_mark`]) when it starts with one, else as
/// it is. The mark only sets `ACPMUX_CALLER_SUBAGENT` to two plain words: it runs nothing.
pub fn without_subagent_mark(command: &str) -> &str {
    let prefix = format!("export {}=", crate::sender_env::SUBAGENT_ENV);
    let Some((line, rest)) = command.split_once('\n') else { return command };
    let marked = line.strip_prefix(&prefix).and_then(|value| value.split_once(':')).is_some_and(
        |(kind, id)| crate::sender_env::subagent_word(kind) && crate::sender_env::subagent_word(id),
    );
    if marked { rest } else { command }
}

/// The answer to a subagent's `PostToolUse` (its Bash or acpmux MCP call ended): the notices the
/// daemon left for it (`subagent_notice.rs`: reports of turns it asked for without waiting), taken
/// once, as `additionalContext`, which Claude Code adds to that subagent's own context. None for
/// the lead's own call (no `agent_id`) or when none waits.
pub fn subagent_notices(home: &std::path::Path, session: &str, input: &Value) -> Option<Value> {
    let agent = input.get("agent_id").and_then(Value::as_str)?;
    let dir = crate::subagent_notice::agent_dir(home, session, agent)?;
    let texts: Vec<String> = crate::subagent_notice::take_all(&dir)
        .iter()
        .filter_map(|n| n.get("text").and_then(Value::as_str).map(str::to_owned))
        .collect();
    (!texts.is_empty()).then(|| {
        json!({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": texts.join("\n\n"),
        }})
    })
}

/// A subagent's `SubagentStop`: it reads no more notices, so the daemon gives the ones left for it
/// to its lead (`hub/lane_report_subagents.rs`), and none of its tool calls runs any more
/// (`subagent_call.rs`). Prints nothing: blocking the stop to hand one over would make the
/// subagent's answer to it its last message, the result its lead reads.
pub fn subagent_stopped(home: &std::path::Path, session: &str, input: &Value) {
    let Some(agent) = input.get("agent_id").and_then(Value::as_str) else { return };
    if let Some(dir) = crate::subagent_notice::agent_dir(home, session, agent) {
        let _ = crate::subagent_notice::mark_stopped(&dir);
    }
    crate::subagent_call::end_agent(home, session, agent);
}

/// The MCP tools through which an agent reaches acpmux without Bash: acpmux's own server, and
/// cmux's in front of it (its listed tools, and `cmux_exec`, whose script calls them). acpmux's
/// hook runs on these for a subagent ([`mcp_matcher`]) and records which subagent makes each call
/// (`subagent_call.rs`): the incident's subagent ran `acpmux run` and `acpmux send` through
/// `cmux.acpmux_bg_start` in a `cmux_exec` script, so its lane reports went to its lead (W5-M,
/// 2026-11-08).
pub const MCP_CALLS: &[&str] = &[
    "mcp__acpmux__bg_start",
    "mcp__acpmux__send",
    "mcp__cmux__acpmux_bg_start",
    "mcp__cmux__acpmux_send",
    "mcp__cmux__cmux_exec",
    "mcp__cmux__cmux_workflow",
];

/// [`MCP_CALLS`] as one hooks.json matcher (a regex of alternatives).
pub fn mcp_matcher() -> String {
    MCP_CALLS.join("|")
}

/// Whether `input` is a call of one of [`MCP_CALLS`].
fn mcp_call(input: &Value) -> bool {
    input.get("tool_name").and_then(Value::as_str).is_some_and(|t| MCP_CALLS.contains(&t))
}

/// A subagent's [`MCP_CALLS`] call starts (`PreToolUse`): records which subagent makes it, by its
/// tool use id, for acpmux's MCP server (`subagent_call.rs`). Nothing for the lead's own call (no
/// `agent_id`). Prints nothing: the call runs as asked.
pub fn subagent_call_starts(home: &std::path::Path, session: &str, input: &Value) {
    let text = |key: &str| input.get(key).and_then(Value::as_str);
    let (Some(agent), Some(call), true) = (text("agent_id"), text("tool_use_id"), mcp_call(input))
    else {
        return;
    };
    let kind =
        text("agent_type").filter(|k| crate::sender_env::subagent_word(k)).unwrap_or("subagent");
    let _ = crate::subagent_call::record(home, session, call, agent, kind);
}

/// A subagent's [`MCP_CALLS`] call ended (`PostToolUse`, `PostToolUseFailure`): its id names
/// nobody any more (`subagent_call.rs`).
pub fn subagent_call_ends(home: &std::path::Path, session: &str, input: &Value) {
    if let (Some(call), true) = (input.get("tool_use_id").and_then(Value::as_str), mcp_call(input))
    {
        crate::subagent_call::end(home, session, call);
    }
}

/// The hook process: reads the call on stdin, prints a deny, a subagent's mark
/// ([`subagent_mark`]), a subagent's notices ([`subagent_notices`]) or nothing, and always
/// exits 0. `home` is the daemon's (`agent_tools::bg_hooks` passes it), where the chat's MCP
/// config and its subagents' notices are.
pub fn main(home: Option<std::path::PathBuf>) -> anyhow::Result<()> {
    let mut text = String::new();
    let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut text);
    let Ok(input) = serde_json::from_str::<Value>(&text) else { return Ok(()) };
    let Ok(session) = std::env::var(crate::acpmux_mcp_names::SESSION_ENV) else { return Ok(()) };
    let home = home.unwrap_or_else(crate::config::home);
    match input.get("hook_event_name").and_then(Value::as_str) {
        Some("PostToolUse") => {
            subagent_call_ends(&home, &session, &input);
            if let Some(answer) = subagent_notices(&home, &session, &input) {
                println!("{answer}");
            }
            return Ok(());
        }
        Some("PostToolUseFailure") => {
            subagent_call_ends(&home, &session, &input);
            return Ok(());
        }
        Some("SubagentStop") => {
            subagent_stopped(&home, &session, &input);
            return Ok(());
        }
        Some("PreToolUse") if mcp_call(&input) => {
            subagent_call_starts(&home, &session, &input);
            return Ok(());
        }
        _ => {}
    }
    let config = crate::agent_tools::mcp_config_path(&home, &session);
    let route = std::fs::read(&config)
        .ok()
        .and_then(|raw| serde_json::from_slice(&raw).ok())
        .and_then(|c: Value| route(&c));
    let start: Vec<String> = crate::self_command::SelfCommand::current()
        .map(|this| {
            let home = home.to_string_lossy().into_owned();
            let words = [START_ARG, "--home", home.as_str(), "--session", session.as_str()];
            std::iter::once(this.exe.to_string_lossy().into_owned())
                .chain(this.args_lossy(&words))
                .collect()
        })
        .unwrap_or_default();
    if let Some(answer) = decide(&input, route, &start) {
        // A subagent's rewritten command is marked like any other of its commands.
        let mut marked = input.clone();
        if let Some(updated) = answer.pointer("/hookSpecificOutput/updatedInput") {
            marked.set("tool_input", updated.clone());
        }
        println!("{}", subagent_mark(&marked).unwrap_or(answer));
        return Ok(());
    }
    if let Some(mark) = subagent_mark(&input) {
        println!("{mark}");
    }
    Ok(())
}

/// `acpmux __bg-start --home DIR --session ID [--cwd DIR] [--description TEXT] -- COMMAND`: what
/// a call the hook rewrote runs ([`rewrite`]). It starts COMMAND as the chat's background task
/// through the same path as the `bg_start` tool (`acpmux_mcp_bg.rs`, asking the daemon to tell
/// the chat when it ends) and prints the tool's answer. A subagent's mark in its environment
/// ([`subagent_mark`]) makes the task its own. It fails on any problem, after saying why, which
/// is the rewritten call's cue to run the command itself.
pub fn start_main(args: &[std::ffi::OsString]) -> anyhow::Result<()> {
    let args: Vec<String> = args.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    let (mut home, mut session, mut command) = (None, None, None);
    let mut params = json!({});
    let mut words = args.iter();
    while let Some(word) = words.next() {
        let mut value =
            || words.next().cloned().ok_or_else(|| anyhow::anyhow!("{word} needs a value"));
        match word.as_str() {
            "--home" => home = Some(value()?),
            "--session" => session = Some(value()?),
            "--cwd" => {
                params.set("cwd", json!(value()?));
            }
            "--description" => {
                params.set("description", json!(value()?));
            }
            "--" => {
                command = words.next().cloned();
                break;
            }
            other => anyhow::bail!("unknown argument {other}"),
        }
    }
    let (Some(session), Some(command)) = (session, command) else {
        anyhow::bail!("usage: __bg-start --session ID [--home DIR] [--cwd DIR] -- COMMAND");
    };
    if let Some(home) = home {
        crate::config::set_home_override(home.into());
    }
    params.set("command", json!(command));
    if let Some(sub) = crate::cli::sender::subagent_of_this_process() {
        params.set("callerSubagent", sub.to_value());
    }
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    // timeout: a hang breaker, the daemon answers a start at once; the shell then runs the command itself
    let result = runtime.block_on(tokio::time::timeout(START_BUDGET, async {
        let daemon = crate::client::Client::connect(&crate::config::socket_path()).await?;
        anyhow::Ok(crate::acpmux_mcp::bg_start(&daemon, &session, &params).await)
    }))??;
    let text = result
        .pointer("/content/0/text")
        .and_then(Value::as_str)
        .unwrap_or("started a background task");
    if result.get("isError") == Some(&json!(true)) {
        anyhow::bail!("{text}");
    }
    println!("{text}");
    Ok(())
}

/// The longest [`start_main`] waits for the daemon to start a task.
const START_BUDGET: std::time::Duration = std::time::Duration::from_secs(30);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_tools::{MCP_TOOLS_ENV, UPSTREAMS_ENV};

    fn call(background: bool) -> Value {
        json!({"tool_name": "Bash", "cwd": "/work/app",
            "tool_input": {"command": "npm run dev", "run_in_background": background}})
    }

    fn start() -> Vec<String> {
        ["/bin/acpmux", "__bg-start", "--home", "/h", "--session", "s1"].map(str::to_owned).to_vec()
    }

    fn updated(answer: &Value) -> &Value {
        let out = &answer["hookSpecificOutput"];
        assert_eq!(out["hookEventName"], "PreToolUse");
        assert!(out.get("permissionDecision").is_none(), "no decision, and never a deny: {out}");
        &out["updatedInput"]
    }

    #[test]
    fn a_background_shell_starts_a_daemon_task_with_the_same_command_and_folder() {
        for route in [Route::Direct, Route::Listed, Route::CodeMode] {
            let answer = decide(&call(true), Some(route), &start()).unwrap();
            let input = updated(&answer);
            let command = input["command"].as_str().unwrap();
            assert!(command.starts_with("ACPMUX_BG_ORIGINAL='npm run dev'\n"), "{command}");
            assert!(
                command.contains(
                    "'/bin/acpmux' '__bg-start' '--home' '/h' '--session' 's1' '--cwd' '/work/app' '--' \"$ACPMUX_BG_ORIGINAL\" ||"
                ),
                "{command}"
            );
            assert!(input.get("run_in_background").is_none(), "the rewritten call returns at once");
        }
    }

    #[test]
    fn a_failed_start_runs_the_original_command_in_the_same_shell() {
        let command = rewrite("echo 'it''s' && true", None, Some("serve"), &start());
        assert!(command.contains("'--description' 'serve' '--'"), "{command}");
        assert!(command.contains("could not start a background task"), "{command}");
        assert!(command.ends_with("eval \"$ACPMUX_BG_ORIGINAL\"; }"), "{command}");
        // Run for real with a start that fails: the original command runs, once, after the line.
        #[cfg(unix)]
        {
            let failing = ["false".to_owned()];
            let script = rewrite("echo it''s; printf 'a\nb'", None, None, &failing);
            let out = std::process::Command::new("sh").args(["-c", &script]).output().unwrap();
            assert!(out.status.success());
            assert_eq!(String::from_utf8_lossy(&out.stdout), "its\na\nb");
            assert!(
                String::from_utf8_lossy(&out.stderr).contains("running the command in this shell")
            );
            let working = ["echo".to_owned(), "started".to_owned()];
            let script = rewrite("echo ran", None, None, &working);
            let out = std::process::Command::new("sh").args(["-c", &script]).output().unwrap();
            assert_eq!(
                String::from_utf8_lossy(&out.stdout),
                "started -- echo ran\n",
                "no fallback"
            );
        }
    }

    #[test]
    fn without_the_acpmux_server_or_in_the_foreground_the_shell_runs() {
        assert_eq!(decide(&call(true), None, &start()), None);
        assert_eq!(decide(&foreground("ls -la"), Some(Route::Direct), &start()), None);
        let read = json!({"tool_name": "Read", "tool_input": {"run_in_background": true}});
        assert_eq!(decide(&read, Some(Route::Direct), &start()), None);
        let ok = json!({"tool_name": "Bash", "tool_input": {"command": "cargo test # fg-ok"}});
        assert_eq!(decide(&ok, Some(Route::Direct), &start()), None);
    }

    /// The route is the one the chat's cmux server really offers: code mode, every tool, or a
    /// preset's allowlist, which may leave bg_start out (then nothing replaces the shell).
    #[test]
    fn the_route_comes_from_the_chats_mcp_config() {
        let direct = json!({"mcpServers": {"acpmux": {"command": "acpmux"}}});
        assert_eq!(route(&direct), Some(Route::Direct));
        let ups = json!([{"name": "acpmux"}]).to_string();
        let cmux =
            |args: Value, env: Value| json!({"mcpServers": {"cmux": {"args": args, "env": env}}});
        let serve = json!(["mcp", "serve"]);
        assert_eq!(route(&cmux(serve.clone(), json!({UPSTREAMS_ENV: ups}))), Some(Route::CodeMode));
        let all = json!(["mcp", "serve", "--all-tools"]);
        assert_eq!(route(&cmux(all, json!({UPSTREAMS_ENV: ups}))), Some(Route::Listed));
        let allowed =
            |tools: &str| cmux(serve.clone(), json!({UPSTREAMS_ENV: ups, MCP_TOOLS_ENV: tools}));
        assert_eq!(route(&allowed("render, acpmux_bg_start")), Some(Route::Listed));
        assert_eq!(route(&allowed("render,agents_snapshot")), None);
        assert_eq!(route(&cmux(serve.clone(), json!({UPSTREAMS_ENV: "[]"}))), None);
        assert_eq!(route(&json!({})), None);
    }

    fn foreground(command: &str) -> Value {
        json!({"tool_name": "Bash", "cwd": "/work/app", "tool_input": {"command": command}})
    }

    #[test]
    fn known_slow_commands_are_named() {
        for slow in [
            "cargo test -p acpmux",
            "cd cmux-tui && RUST_LOG=debug cargo build --release",
            "timeout 900 cargo clippy --workspace",
            "/usr/bin/xcodebuild -scheme App build",
            "swift test --filter Foo",
            "gh run watch 123",
            "gh pr checks 12 --watch",
            "nohup npm run dev > dev.log",
            "npm run dev",
            "pnpm dev",
            "bash -lc 'yarn start'",
            "tail -f /var/log/app.log",
        ] {
            assert!(slow_reason(slow).is_some(), "{slow}");
        }
        for quick in [
            "cargo --version",
            "cargo test --help",
            "xcodebuild -version",
            "xcodebuild -list",
            "npm run build",
            "gh pr checks 12",
            "gh run view 123",
            "ls && git status",
            "cargo test -p acpmux # fg-ok",
            "npm run dev &",
            "tail -n 50 log.txt",
        ] {
            assert_eq!(slow_reason(quick), None, "{quick}");
        }
    }

    /// Only a command the shell runs is slow, never the text of an argument, a quote or a
    /// heredoc body. The lane live-apply-nightly was turned away five times on 2026-11-04 for a
    /// grep pattern and a heredoc that named `swift build`, `tail -f` and `watch`.
    #[test]
    fn words_in_arguments_quotes_and_heredocs_are_not_run() {
        for quick in [
            "grep -e 'swift build' -r .",
            r#"rg "tail -f" src"#,
            r#"grep -rIl -iE "foreground|swift build.*watch|tail -f" ~/.claude"#,
            "cat <<'EOF' > notes.md\nrun tail -f log, then watch -n1 ls\nswift build\nEOF",
            "cat <<EOF\ntail -F x\nwatch ls\nEOF\ngit status",
            "cat > f.txt <<-EOF\n\ttail -f x\n\tEOF",
            r#"git commit -m "fix: swift build | tail -f; watch""#,
            "echo 'watch this'",
            "echo watch this # tail -f x",
            "ls 2>&1 | tee log",
            "cat <<'EOF'\n$(swift build)\nEOF",
            "bash; cat <<EOF\nswift build\nEOF",
            "cat <<DATA; bash <<CODE\nswift build\nDATA\nls\nCODE",
            // ssh's remote command is not read (the policy before this change).
            "ssh host swift build",
        ] {
            assert_eq!(slow_reason(quick), None, "{quick}");
        }
        for slow in [
            "swift build",
            r#"bash -c "swift build""#,
            "sh -ec 'cd x && tail -F y'",
            "foo | tail -f x",
            "watch -n1 ls",
            "env A=1 swift build",
            r#"echo "$(swift build)""#,
            "x=`tail -f log`",
            "bash <<EOF\nswift build\nEOF",
            "cat <<EOF | sh\nswift build\nEOF",
            "cat <<EOF\nnotes\nEOF\nswift build",
            "( cd app && swift build )",
            "cat <<EOF\n$(\nswift build\n)\nEOF",
            r#"echo "${X:-$(swift build)}""#,
            "if true; then watch ls; fi",
            "tail --follow app.log",
            // Unreadable input falls back to the loose read, which names more.
            "echo 'open && swift build",
        ] {
            assert!(slow_reason(slow).is_some(), "{slow}");
        }
    }

    mod agent_messaging {
        use super::*;

        /// Claude Code names a subagent only in the hook's input (`agent_id`, `agent_type`; read on
        /// 2.1.319): its acpmux command gets the mark, with no permission decision, and the lead's
        /// own calls and any other command run unchanged.
        #[test]
        fn a_subagents_acpmux_command_is_marked_and_nothing_else_is() {
            let call = |command: &str, agent: Option<(&str, &str)>| {
                let mut input = json!({"tool_name": "Bash", "cwd": "/w",
                    "tool_input": {"command": command, "description": "ask beta", "timeout": 5000}});
                if let Some((kind, id)) = agent {
                    input.set("agent_type", json!(kind));
                    input.set("agent_id", json!(id));
                }
                input
            };
            let sub = Some(("general-purpose", "a0a68e7af3df5967e"));
            let mark = subagent_mark(&call("acpmux send beta --wait 'hi'", sub)).unwrap();
            let out = &mark["hookSpecificOutput"];
            assert_eq!(out["hookEventName"], "PreToolUse");
            assert!(out.get("permissionDecision").is_none(), "asks or allows as before: {out}");
            assert_eq!(
                out["updatedInput"]["command"],
                "export ACPMUX_CALLER_SUBAGENT=general-purpose:a0a68e7af3df5967e\nacpmux send beta --wait 'hi'"
            );
            assert_eq!(
                out["updatedInput"]["description"], "ask beta",
                "the rest of the call stays"
            );
            assert_eq!(out["updatedInput"]["timeout"], 5000);
            // The lead's own call, another command, a marked one, an odd id: unchanged.
            assert_eq!(subagent_mark(&call("acpmux send beta hi", None)), None);
            assert_eq!(subagent_mark(&call("git status", sub)), None);
            let again = "export ACPMUX_CALLER_SUBAGENT=x:y\nacpmux ls";
            assert_eq!(subagent_mark(&call(again, sub)), None);
            assert_eq!(subagent_mark(&call("acpmux ls", Some(("x", "a1;rm -rf /")))), None);
            // A type that is no plain word is named `subagent`.
            let odd = subagent_mark(&call("acpmux ls", Some(("my agent", "a1")))).unwrap();
            let command = odd["hookSpecificOutput"]["updatedInput"]["command"].as_str().unwrap();
            assert!(
                command.starts_with("export ACPMUX_CALLER_SUBAGENT=subagent:a1\n"),
                "{command}"
            );
        }
    }

    mod caller_identity {
        use super::*;

        fn sub_call(command: &str) -> Value {
            json!({"tool_name": "Bash", "cwd": "/w", "agent_type": "general-purpose",
                "agent_id": "a0a68e7af3df5967e", "tool_input": {"command": command}})
        }

        fn marked(command: &str) -> Option<String> {
            let mark = subagent_mark(&sub_call(command))?;
            let out = mark["hookSpecificOutput"]["updatedInput"]["command"].as_str()?.to_owned();
            Some(out)
        }

        /// The mark does not hang on the word "acpmux" in the command: a wrapper script, an
        /// alias, a variable or an absolute path under another name runs the same CLI, and a
        /// subagent's send through one went out as its lead's.
        #[test]
        fn a_subagents_command_through_a_wrapper_alias_or_other_path_is_marked() {
            let prefix = "export ACPMUX_CALLER_SUBAGENT=general-purpose:a0a68e7af3df5967e\n";
            for command in [
                "./scripts/tell beta 'hi'",
                "amx send beta hi",
                "/opt/tools/bin/agent-send beta hi",
                "$A send beta hi",
                "cd /w && python3 tools/notify.py beta",
                "ls && ./tell beta hi",
                "echo $(./tell beta hi)",
                "sh -c 'tell beta hi'",
                "git -c core.pager=./tell log",
                "git submodule foreach ./tell",
                "git rebase --exec ./tell main",
                "rg --pre ./tell foo",
                "sort --compress-program=./tell a.txt",
                "sed 's/x/./e' a.txt",
            ] {
                let got = marked(command).unwrap_or_else(|| panic!("not marked: {command}"));
                assert_eq!(got, format!("{prefix}{command}"), "{command}");
            }
        }

        /// A command made only of tools that never start another program stays as it was, so
        /// the harness judges it as before (Claude Code runs a read-only command unasked).
        #[test]
        fn a_subagents_plain_read_only_command_is_not_changed() {
            for command in [
                "ls -la",
                "git status",
                "git -C /w log --oneline -5",
                "rg -n foo src | head -20",
                "cat a.txt && wc -l b.txt",
                "sed -n '1,40p' src/main.rs",
            ] {
                assert_eq!(marked(command), None, "{command}");
            }
        }
    }

    #[test]
    fn a_slow_foreground_shell_goes_to_the_background() {
        let answer = decide(&foreground("cargo test"), None, &start()).unwrap();
        assert_eq!(updated(&answer)["run_in_background"], true);
        assert_eq!(updated(&answer)["command"], "cargo test");
        let answer = decide(&foreground("cargo test"), Some(Route::Direct), &start()).unwrap();
        let command = updated(&answer)["command"].as_str().unwrap();
        assert!(command.starts_with("ACPMUX_BG_ORIGINAL='cargo test'\n"), "{command}");
        assert_eq!(decide(&foreground("git status"), None, &start()), None);
        assert_eq!(decide(&foreground("git status"), Some(Route::Direct), &start()), None);
    }

    /// The rewritten command still carries a subagent's mark, so its task is the subagent's.
    #[test]
    fn a_subagents_rewritten_command_keeps_its_mark() {
        let mut input = call(true);
        input["agent_id"] = json!("a1");
        input["agent_type"] = json!("Explore");
        let answer = decide(&input, Some(Route::Direct), &start()).unwrap();
        let mut marked = input.clone();
        marked["tool_input"] = updated(&answer).clone();
        let out = subagent_mark(&marked).unwrap();
        let command = out["hookSpecificOutput"]["updatedInput"]["command"].as_str().unwrap();
        assert!(
            command.starts_with("export ACPMUX_CALLER_SUBAGENT=Explore:a1\nACPMUX_BG_ORIGINAL=")
        );
        assert!(out["hookSpecificOutput"]["updatedInput"].get("run_in_background").is_none());
    }

    /// The plugin's Bash hook starts this binary for every call [`main`] may answer (a
    /// background shell, a subagent's call, each known-slow command, the forms agents write) and
    /// for no quick foreground call of the lead, which then costs a shell and no process start.
    #[cfg(unix)]
    #[test]
    fn the_bash_hook_starts_the_binary_only_for_a_call_it_may_answer() {
        use std::io::Write;
        let words = ["sh", "-c", "cat >/dev/null; echo started"].map(str::to_owned);
        let hook = crate::agent_tools::hook_command(&words, &bash_patterns());
        let starts = |input: &Value| {
            let mut child = std::process::Command::new("sh")
                .args(["-c", &hook])
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap();
            child.stdin.take().unwrap().write_all(input.to_string().as_bytes()).unwrap();
            let out = child.wait_with_output().unwrap();
            assert!(out.status.success(), "{out:?}");
            String::from_utf8_lossy(&out.stdout).trim() == "started"
        };
        let mut slow: Vec<String> = SLOW
            .iter()
            .map(|(tool, next, needs, _)| {
                [Some(*tool), *next, *needs].into_iter().flatten().collect::<Vec<_>>().join(" ")
            })
            .collect();
        slow.extend(
            [
                "cd cmux-tui && cargo test -p acpmux --lib 2>&1 | tail -40",
                "/usr/bin/xcodebuild -scheme cmux -configuration Debug build",
                "gh pr checks 12 --watch --interval 30",
                "tail -n 50 -F /tmp/app.log",
                "npm run dev -- --port 3000",
                "set -e\nswift build -c release",
            ]
            .map(str::to_owned),
        );
        for command in &slow {
            assert!(slow_reason(command).is_some(), "{command}");
            assert!(
                starts(&foreground(command)),
                "a slow command did not start the hook: {command}"
            );
        }
        let quick =
            ["git status --short | head -20", "ls -la", "rg -n TODO src", "echo run_in_background"];
        for command in quick {
            assert!(slow_reason(command).is_none());
            assert!(!starts(&foreground(command)), "a quick command started the hook: {command}");
            let mut call = foreground(command);
            call["tool_input"]["run_in_background"] = json!(false);
            assert!(!starts(&call), "{command}");
            call["tool_input"]["run_in_background"] = json!(true);
            assert!(decide(&call, Some(Route::Direct), &start()).is_some());
            assert!(starts(&call), "a background shell did not start the hook: {command}");
            let mut call = foreground(command);
            call["agent_id"] = json!("a0");
            call["agent_type"] = json!("Explore");
            assert!(starts(&call), "a subagent's call did not start the hook: {command}");
        }
    }
}
