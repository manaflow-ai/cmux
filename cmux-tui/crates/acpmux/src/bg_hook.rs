//! `__bg-hook`: Claude Code's PreToolUse hook for `Bash` in the session plugin
//! (`agent_tools.rs`). Leo, 2026-10-27: "also when it comes to hibernation...can't you hibernate
//! the agent but not hibernate the bg tasks?" A `run_in_background` shell ends when the agent
//! hibernates (Claude Code's exit cleanup), so when the chat has the `acpmux` server's
//! `bg_start` (`acpmux_mcp_bg.rs`), the hook rewrites such a call into this binary's
//! `process start` with the same command ([`decide`]), which starts it under the daemon, where it
//! outlives the agent, and answers at once with its id. (It used to turn the call away with the
//! `bg_start` call to make instead, which cost the agent a turn each time.)
//!
//! It never strands the agent: when the chat's MCP config (`agent_tools::mcp_config_path`) has
//! no `acpmux` server, plain or behind the `cmux` server's code mode, or anything cannot be read,
//! it says nothing and Claude Code runs the shell as asked. A configured server may still be
//! unusable (it failed to start), so it turns a command away only once: the same call again
//! runs as asked, and the deny says so. The commands turned away and not yet repeated are kept
//! beside the config (`<config>.bg-denied`, one hash a line, the newest [`PENDING`], under a
//! lock so parallel calls never lose one), one file per chat, removed with the config.
//!
//! With [`SLOW_SETTING`] on (off by default), it also moves a known-slow command run in the
//! foreground ([`SLOW`]: builds and test runs, CI waits, dev servers and follows that never end)
//! to a daemon task where the chat has `bg_start`, else turns it away once towards
//! `run_in_background: true`, so the turn goes on while it runs. Leo, 2026-11-02, on a session
//! that sat about 80 minutes in one turn of foreground shell calls: "but why not in cmux". The
//! same call again runs as asked, and so does a command with [`FOREGROUND_OK`] or a trailing `&`.
//! The list is the fleet's own habits (its CI wait tools among them), so cmux ships it off and
//! the fleet turns it on in its settings (Leo, 2026-11-26: "identify all the weird opinoinated
//! fleet things we shipped into the app and remove them"). With it off, a command still in the
//! foreground after five minutes goes to the background on its own (`hub/auto_background.rs`).
//!
//! With it on, a CI wait (`glaeda-gh wait`, `lane-gh call ci_wait`, `gh run watch`) in the foreground is
//! rewritten too, a subagent's included, so no wait runs as a shell under the harness. Before,
//! a background subagent's foreground `glaeda-gh wait` (with a 90-minute Bash `timeout`, so
//! neither `hub/auto_background.rs` nor Claude Code moved it) kept its chat's idle harness up:
//! the lead's turn had ended, no turn, queue or command ran, and the idle census saw a bash
//! under the harness (`hub/idle_census.rs`). A Ctrl-B or a Bash `timeout` cannot hand a running
//! shell to the daemon; only the hook, before it starts, can. A wait whose own bound is short
//! (`--timeout 60`, [`QUICK_WAIT_SECS`]) is a read and runs as asked. Leo, on 60 such chats of
//! about 190 awake on the fleet: "thats extremely dumb. simply clear th bullshit. theres noway
//! tere's >100 of actually needed stuff much less >400".

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

pub const HOOK_ARG: &str = "__bg-hook";
/// Passed by the local launch that installed cmux's session plugin to its translator.
pub(crate) const HOME_ENV: &str = "ACPMUX_CLAUDE_TOOL_HOOK_HOME";

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

/// The most denied calls a chat's file remembers; an older one is denied again on its repeat.
const PENDING: usize = 64;

/// Where the hook keeps the commands it turned away, beside the chat's MCP config.
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
    ("glaeda-gh", Some("wait"), None, "a CI wait"),
    ("lane-gh", Some("call"), Some("ci_wait"), "a CI wait"),
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

/// The setting that turns the known-slow handling ([`SLOW`]) on: off unless `true`.
pub const SLOW_SETTING: &str = "agents.slowForeground.enabled";
/// The environment switch over [`SLOW_SETTING`]: `1` (or `true`, `on`, `yes`) on, `0` (or
/// `false`, `off`, `no`) off. The hook runs under the harness, so it sees the daemon's env.
pub const SLOW_ENV: &str = "ACPMUX_SLOW_FOREGROUND";

/// Whether a known-slow foreground command is moved or turned away ([`SLOW_SETTING`],
/// [`SLOW_ENV`]). Read only for a call [`slow_reason`] names, so other calls read no file.
pub fn slow_foreground_on() -> bool {
    let env = std::env::var(SLOW_ENV).ok();
    if let Some(on) = env.as_deref().and_then(switch_word) {
        return on;
    }
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => slow_foreground_in(&doc),
        _ => false,
    }
}

/// Whether the settings document turns [`SLOW_SETTING`] on.
fn slow_foreground_in(doc: &Value) -> bool {
    crate::user_settings::value(doc, SLOW_SETTING).and_then(|v| v.as_bool()) == Some(true)
}

fn switch_word(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "on" | "yes" => Some(true),
        "0" | "false" | "off" | "no" => Some(false),
        _ => None,
    }
}

/// Why `command` would hold the turn for long, if one of its simple commands is known to
/// ([`SLOW`]), or None. A command that puts itself in the background (a trailing `&`) or
/// carries [`FOREGROUND_OK`] holds nothing; `nohup` or `setsid` alone still runs in the
/// foreground.
pub fn slow_reason(command: &str) -> Option<&'static str> {
    let trimmed = command.trim_end();
    if command.contains(FOREGROUND_OK) || (trimmed.ends_with('&') && !trimmed.ends_with("&&")) {
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
            // `tail -f --pid=N` ends with process N: a bounded wait, not a follow that never
            // ends. 418 of the 479 tail refusals on one lane host in 24 h (2026-11-20) were this
            // form, and 463 of the 479 were sent again unchanged (from #47746).
            if program == "tail" && rest.iter().any(|w| w.starts_with("--pid")) {
                continue;
            }
            // `glaeda-gh wait ... --timeout 60 --json` reads the state now: a wait whose own
            // bound is short holds the turn no longer than a read.
            if program == "glaeda-gh" && short_bound(rest) {
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

/// The longest own bound (`--timeout S` or `--max S`) of a wait that is a read, not a wait.
const QUICK_WAIT_SECS: u64 = 120;

/// Whether a wait's words set its own bound to at most [`QUICK_WAIT_SECS`].
fn short_bound(rest: &[&str]) -> bool {
    let mut words = rest.iter();
    while let Some(w) = words.next() {
        let value = match w.split_once('=') {
            Some(("--timeout" | "--max", v)) => Some(v),
            None if matches!(*w, "--timeout" | "--max") => words.next().copied(),
            _ => None,
        };
        if value.and_then(seconds).is_some_and(|v| v <= QUICK_WAIT_SECS as f64) {
            return true;
        }
    }
    false
}

/// A wait's bound in seconds: `90`, `90s`, `2m`, `1h`.
fn seconds(value: &str) -> Option<f64> {
    let (number, unit) = if let Some(number) = value.strip_suffix('s') {
        (number, 1.0)
    } else if let Some(number) = value.strip_suffix('m') {
        (number, 60.0)
    } else if let Some(number) = value.strip_suffix('h') {
        (number, 3600.0)
    } else {
        (value, 1.0)
    };
    number.parse::<f64>().ok().filter(|n| n.is_finite()).map(|n| n * unit)
}

/// How the hook names this binary's `process start` in a rewritten call ([`decide`]): the CLI's
/// words (its executable and prefix, `self_command.rs`), and the chat's denied-calls file
/// ([`denied_path`]) with the call's key there, so a task that started forgets the key
/// ([`forget`]) and a start that failed leaves it, which lets the same call again run as asked.
#[derive(Debug, Clone)]
pub struct TaskCli {
    pub words: Vec<String>,
    pub denied: std::path::PathBuf,
    pub key: String,
    /// The command the task runs instead of the call's own: the call wrapped in
    /// `acpmux run-vm` when it goes to a run VM (`placement/run_vm.rs`, RFD 0144 piece 3).
    pub run_vm: Option<String>,
    /// Whether a known-slow foreground command is handled ([`slow_foreground_on`]).
    pub slow: bool,
}

/// The `--route` word of `process start` for each [`Route`], and back: the CLI's answer names
/// the chat's own tool that reads the task's output ([`read_call`]).
pub fn route_word(route: &Route) -> &'static str {
    match route {
        Route::Direct => "direct",
        Route::Listed => "listed",
        Route::CodeMode => "code-mode",
    }
}

pub fn route_of_word(word: &str) -> Option<Route> {
    match word {
        "direct" => Some(Route::Direct),
        "listed" => Some(Route::Listed),
        "code-mode" => Some(Route::CodeMode),
        _ => None,
    }
}

/// The call that reads task `id`'s output through the chat's own route to acpmux's MCP server.
pub fn read_call(route: Option<&Route>, id: &str) -> String {
    let args = json!({"id": id});
    match route {
        Some(Route::Direct) => format!("mcp__acpmux__bg_output {args}"),
        Some(Route::Listed) => format!("mcp__cmux__acpmux_bg_output {args}"),
        Some(Route::CodeMode) => {
            format!("cmux_exec with: return await cmux.acpmux_bg_output({args});")
        }
        None => format!("bg_output {args}"),
    }
}

/// The hook's answer to one PreToolUse `input`, or None to let the call run.
///
/// When the chat reaches `bg_start` (`route`), a background shell, and a known-slow command
/// ([`slow_reason`]) in the foreground, run as a background task the daemon owns: the call is
/// rewritten (`updatedInput`, no permission decision, so it is asked or allowed as before) into
/// this binary's `process start` with the same command, in the foreground, which starts the task
/// and answers at once with its id and how to read it. Before, the hook turned such a call away
/// with the `bg_start` call to make instead, and agents lost a turn on it: on one agent host over
/// 24 h (53,061 Claude tool calls) the two were the top refusals of every guard, 245 and 221.
/// Leo: "our processes deserve more eyes on it. stuff like the stale guards/intsructions/bad
/// interruptions/not useful enough tools are big".
///
/// With no route, a known-slow foreground command is still turned away towards
/// `run_in_background: true`, and a background shell runs as asked. With `cli.slow` off a
/// foreground command always runs as asked.
pub fn decide(input: &Value, route: Option<Route>, cli: &TaskCli) -> Option<Value> {
    if input.get("tool_name").and_then(Value::as_str) != Some("Bash") {
        return None;
    }
    let command = input.pointer("/tool_input/command")?.as_str()?;
    let background = input.pointer("/tool_input/run_in_background") == Some(&json!(true));
    let slow = match (background, cli.slow) {
        (true, _) => None,
        (false, true) => Some(slow_reason(command)?),
        (false, false) => return None,
    };
    let Some(route) = route else {
        let why = slow?;
        let reason = format!(
            "Not run: this is {why}, and a shell in the foreground holds the whole turn until it \
ends. Send the same Bash call again with run_in_background: true; you are told when it ends, so \
keep working meanwhile. If it must run in the foreground, send this same call again and it runs \
as asked."
        );
        return Some(json!({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }}));
    };
    let mut words = cli.words.clone();
    words.extend(["process", "start", "--route", route_word(&route)].map(str::to_owned));
    words.extend(["--hook-denied".to_owned(), cli.denied.to_string_lossy().into_owned()]);
    words.extend(["--hook-key".to_owned(), cli.key.clone()]);
    let description = input.pointer("/tool_input/description").and_then(Value::as_str);
    if let Some(d) = description.filter(|d| !d.trim().is_empty()) {
        words.extend(["--description".to_owned(), d.to_owned()]);
    }
    if let Some(why) = slow {
        words.extend(["--slow".to_owned(), why.to_owned()]);
    }
    words.extend(["--".to_owned(), cli.run_vm.as_deref().unwrap_or(command).to_owned()]);
    let mut tool_input = input.get("tool_input").filter(|t| t.is_object())?.clone();
    tool_input.set("command", json!(crate::agent_tools::quoted(&words)));
    tool_input.set("run_in_background", json!(false));
    Some(json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": tool_input,
    }}))
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

/// Whether `text` begins with the subagent mark line `subagent_mark` writes (even cut short, as
/// Claude Code's truncated one-line description of a marked command is).
pub fn starts_with_subagent_mark(text: &str) -> bool {
    text.trim_start().starts_with(&format!("export {}=", crate::sender_env::SUBAGENT_ENV))
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
/// exits 0. Older command plugins pass the daemon's home, where the chat's MCP
/// config and its subagents' notices are.
pub fn main(home: Option<std::path::PathBuf>) -> anyhow::Result<()> {
    let mut text = String::new();
    let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut text);
    let Ok(input) = serde_json::from_str::<Value>(&text) else { return Ok(()) };
    let Ok(session) = std::env::var(crate::acpmux_mcp_names::SESSION_ENV) else { return Ok(()) };
    let home = home.unwrap_or_else(crate::config::home);
    if let Some(answer) = answer(&home, &session, input) {
        println!("{answer}");
    }
    Ok(())
}

/// The same hook decision for Claude's resident translator and already installed command hooks.
pub(crate) fn answer(home: &std::path::Path, session: &str, input: Value) -> Option<Value> {
    match input.get("hook_event_name").and_then(Value::as_str) {
        Some("PostToolUse") => {
            subagent_call_ends(home, session, &input);
            return subagent_notices(home, session, &input);
        }
        Some("PostToolUseFailure") => {
            subagent_call_ends(home, session, &input);
            return None;
        }
        Some("SubagentStop") => {
            subagent_stopped(home, session, &input);
            return None;
        }
        Some("PreToolUse") if mcp_call(&input) => {
            subagent_call_starts(home, session, &input);
            return None;
        }
        // Harness magic `router` (RFD 0158 §6, `model_router.rs`): a subagent start with no
        // model names the one its kind is routed to.
        Some("PreToolUse") if crate::model_router::starts_subagent(&input) => {
            return crate::model_router::route(&input);
        }
        _ => {}
    }
    input.pointer("/tool_input/command").and_then(Value::as_str)?;
    if input.get("tool_name").and_then(Value::as_str) != Some("Bash") {
        return None;
    }
    let self_words = || {
        let this = crate::self_command::SelfCommand::current()
            .unwrap_or_else(|_| crate::self_command::SelfCommand::new("acpmux".into(), Vec::new()));
        let mut words = vec![this.exe.to_string_lossy().into_owned()];
        words.extend(this.args_lossy::<&str>(&[]));
        words
    };
    // Harness magic `sharedCache` (RFD 0158 §9, `ci_log_cache.rs`): a CI log read goes through
    // this machine's cache of finished logs. The rewritten call is the one every later rule
    // reads; with nothing else to say, the answer is the rewrite itself.
    let mut input = input;
    let shared = shared_cache(&mut input, &self_words);
    let shared_answer = |input: &Value| shared.then(|| updated_answer(input)).flatten();
    let command = input.pointer("/tool_input/command").and_then(Value::as_str)?;
    // A heavy build or test on a Cloud machine with AutoCloud on runs on a fork (RFD 0144
    // piece 3): the class is read from the text first, so no other call reads the settings.
    // With `CMUX_WORK_PLACER=1` the work placer decides instead, from this host's samples
    // (`placement/work_wire.rs`); off, nothing changes.
    let run_vm = crate::placement::run_vm::heavy_class(command)
        .and_then(|_| {
            let machine = crate::placement::sub_fork::this_machine();
            let on = crate::placement::run_vm::run_vms_on();
            if crate::placement::work_place::enabled() {
                return crate::placement::work_wire::hook_goes(on, machine.as_deref(), command);
            }
            crate::placement::run_vm::goes(on, machine.as_deref(), command)
        })
        .map(|_| crate::placement::run_vm::wrap(&self_words(), command));
    let background =
        input.pointer("/tool_input/run_in_background").and_then(Value::as_bool) == Some(true);
    let slow = !background && slow_reason(command).is_some() && slow_foreground_on();
    if !background && !slow {
        let Some(wrapped) = run_vm else {
            return subagent_mark(&input).or_else(|| shared_answer(&input));
        };
        return run_vm_answer(&input, &wrapped);
    }
    let config = crate::agent_tools::mcp_config_path(home, session);
    let route = std::fs::read(&config)
        .ok()
        .and_then(|raw| serde_json::from_slice(&raw).ok())
        .map(|c: Value| crate::mcp_gateway::stdio_view(home, session, c))
        .and_then(|c: Value| route(&c));
    // Keyed by what the call runs, not its per-call ids.
    let what = json!([input.get("cwd"), input.get("tool_input")]);
    let key = crate::sha256::sha256_hex(what.to_string().as_bytes());
    if route.is_none()
        && let Some(wrapped) = &run_vm
    {
        // No daemon task to run it in: the call itself runs on the fork, as asked otherwise.
        return run_vm_answer(&input, wrapped);
    }
    let cli = TaskCli {
        words: self_words(),
        denied: denied_path(&config),
        key,
        run_vm: run_vm.clone(),
        slow,
    };
    if let Some(answer) = decide(&input, route, &cli) {
        // The same call turned away, or rewritten into a task that did not start, just before
        // runs as asked (the replacement may be unusable). A task that started forgets the key
        // (`process start`, [`forget`]), so the same call later is rewritten again.
        // Unrecorded, a repeat could not get through: then the call runs.
        if first_time(&cli.denied, &cli.key).unwrap_or(false) {
            // A subagent's rewritten call still carries its mark: `process start` names it.
            let marked = answer
                .pointer("/hookSpecificOutput/updatedInput")
                .map(|updated| {
                    let mut call = input.clone();
                    call.set("tool_input", updated.clone());
                    call
                })
                .and_then(|call| subagent_mark(&call));
            return Some(marked.unwrap_or(answer));
        }
    }
    match &run_vm {
        Some(wrapped) => run_vm_answer(&input, wrapped),
        None => subagent_mark(&input).or_else(|| shared_answer(&input)),
    }
}

/// Rewrites `input`'s command through the shared CI log cache when the feature is on and the
/// command reads a log (`ci_log_cache::rewrite`); whether it did.
fn shared_cache(input: &mut Value, self_words: &dyn Fn() -> Vec<String>) -> bool {
    let Some(command) = input.pointer("/tool_input/command").and_then(Value::as_str) else {
        return false;
    };
    // The text test first, so no other call reads the settings.
    if !command.contains("gh run view") || !crate::ci_log_cache::enabled() {
        return false;
    }
    let mut words = self_words();
    words.extend([crate::ci_log_cache::SUBCOMMAND.to_owned(), "--".to_owned()]);
    let Some(rewritten) =
        crate::ci_log_cache::rewrite(command, &crate::agent_tools::quoted(&words))
    else {
        return false;
    };
    match input.pointer_mut("/tool_input/command") {
        Some(slot) => {
            *slot = json!(rewritten);
            true
        }
        None => false,
    }
}

/// The answer that runs `input`'s tool input as it now is, permission as before.
fn updated_answer(input: &Value) -> Option<Value> {
    let tool_input = input.get("tool_input").filter(|t| t.is_object())?.clone();
    Some(json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": tool_input,
    }}))
}

/// The call rewritten to run `wrapped` (`acpmux run-vm -- CMD`) in its place, everything else
/// as it was, with a subagent's mark when it has one.
fn run_vm_answer(input: &Value, wrapped: &str) -> Option<Value> {
    let mut tool_input = input.get("tool_input").filter(|t| t.is_object())?.clone();
    tool_input.set("command", json!(wrapped));
    let mut call = input.clone();
    call.set("tool_input", tool_input.clone());
    subagent_mark(&call).or_else(|| {
        Some(json!({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": tool_input,
        }}))
    })
}

/// Whether `key` is new to the chat's denied calls: then it is added (true); a repeat is taken
/// out (false). Under an exclusive lock on the file, so parallel hooks of one chat never drop
/// each other's entries.
fn first_time(path: &std::path::Path, key: &str) -> std::io::Result<bool> {
    edit_keys(path, |keys| match keys.iter().position(|k| k == key) {
        Some(at) => {
            keys.remove(at);
            false
        }
        None => {
            keys.push(key.to_owned());
            true
        }
    })
}

/// Takes `key` out of the chat's denied calls (`process start`, once its task started), so the
/// same call later is rewritten again instead of running as asked. Whether it was there.
pub fn forget(path: &std::path::Path, key: &str) -> std::io::Result<bool> {
    edit_keys(path, |keys| {
        let before = keys.len();
        keys.retain(|k| k != key);
        keys.len() != before
    })
}

/// Runs `edit` on the keys of the chat's denied-calls file and writes back the newest
/// [`PENDING`]. Under an exclusive lock on the file, so parallel hooks of one chat never drop
/// each other's entries.
#[cfg(unix)]
fn edit_keys<R>(
    path: &std::path::Path,
    edit: impl FnOnce(&mut Vec<String>) -> R,
) -> std::io::Result<R> {
    use std::io::{Read, Seek, Write};
    use std::os::fd::AsRawFd;
    // Through `home_fs`: the denied-calls file is under the home the daemon holds.
    let mut file = crate::home_fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    // SAFETY: flock on a descriptor this function owns; closing it releases the lock.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    let mut keys: Vec<String> = text.lines().filter(|k| !k.is_empty()).map(str::to_owned).collect();
    let answer = edit(&mut keys);
    let keep = keys.get(keys.len().saturating_sub(PENDING)..).unwrap_or_default();
    file.set_len(0)?;
    file.rewind()?;
    file.write_all(keep.iter().map(|k| format!("{k}\n")).collect::<String>().as_bytes())?;
    Ok(answer)
}
#[cfg(not(unix))]
fn edit_keys<R>(
    _path: &std::path::Path,
    _edit: impl FnOnce(&mut Vec<String>) -> R,
) -> std::io::Result<R> {
    Err(std::io::Error::other("no denied-calls file off unix"))
}

#[cfg(test)]
#[path = "bg_hook_tests.rs"]
mod tests;
