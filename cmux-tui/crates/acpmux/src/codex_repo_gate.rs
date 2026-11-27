//! A Codex start at a repository's head: every Codex tool call waits for the whole checkout
//! through a PreToolUse hook, as Claude Code's do through acpmux's `cmux-repo-sync` callback
//! (`claude_stdio/hook_callback.rs`, cmuxterm-hq goals/cloud-no-network-wait.md). Leo's rule:
//! "Block edits until the repo sync finishes: the agent's file-write tools wait on the sync
//! barrier instead of racing it."
//!
//! A `codex app-server` that acpmux starts in a checkout still filling (a repository sync
//! barrier short of ready, `cmux_git::sync_barrier`) gets `--enable hooks` and one PreToolUse
//! command hook in its session-flag layer, trusted by its hash (cmux-tui-hooks
//! `codex_session_flag_hook_settings`, the one the terminal's Codex launch uses): this binary's
//! [`HOOK_ARG`], which waits as Claude's callback does (`native_hook::wait`, the call's folder
//! and paths, [`cmux_git::native_hook::WAIT`]) and refuses the call (exit 2, the reason on
//! stderr) when the checkout is not whole by then. With no matcher it runs before every tool
//! that has a PreToolUse event: shell, `apply_patch` and MCP calls alike. The user's own hooks
//! keep running and keep their trust: Codex adds the session-flag layer's hooks to theirs and
//! merges `hooks.state` key by key.
//!
//! Only such a launch counts as gating its tools (`ChildAgent::codex_repo_gated`, judged from
//! the argv it was started with): one Codex older than [`MIN_VERSION`] (0.120 refuses
//! `--enable hooks` and would not start), one whose own command line names hooks, a remote
//! chain's sandboxed launch, or one started once the checkout was whole gets no hook, and a
//! start at the head then waits for the whole checkout before its first prompt
//! (`hub/repo_sync.rs`).

use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
#[cfg(unix)]
use std::time::Duration;

/// The hidden word that runs the hook (`cli/entry.rs`, before any runtime starts).
pub const HOOK_ARG: &str = "__codex-repo-gate";

/// Codex lets a call through when its hook outlives the hook's timeout, so this outlasts the
/// hook's own wait ([`cmux_git::native_hook::WAIT`]), as the terminal's Codex hook does
/// (cmux-tui-hooks `codex_hook_timeout`).
pub const HOOK_TIMEOUT_SECS: u64 = 90;

/// The oldest Codex shown to block a call by a session-flag PreToolUse hook: 0.130.0, 0.135.0,
/// 0.140.0, 0.150.0, 0.156.1 and 0.160.0 each blocked a shell call (`codex exec`, 2026-11-16);
/// 0.120.0 refuses `--enable hooks` ("Unknown feature flag: hooks") and does not start.
pub const MIN_VERSION: &str = "0.130.0";

/// The hook: Codex's PreToolUse input on stdin. Ends once the checkout is whole; fails with the
/// reason on stderr, which Codex shows the model, when it is not by the wait's end. The hook's
/// command turns that failure into the exit 2 that refuses the call ([`hook_command`]).
pub fn main() -> anyhow::Result<()> {
    #[cfg(unix)]
    {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut text);
        // An unreadable input still waits, on the folder Codex runs the hook in (its cwd).
        let input = serde_json::from_str(&text).unwrap_or(serde_json::Value::Null);
        check(&input, cmux_git::native_hook::WAIT).map_err(anyhow::Error::msg)?;
    }
    Ok(())
}

/// The hook's decision on Codex's PreToolUse `input`: wait up to `timeout` for the call's folder
/// and paths to be whole, or the reason it is refused.
#[cfg(unix)]
fn check(input: &serde_json::Value, timeout: Duration) -> Result<(), String> {
    cmux_git::native_hook::wait("codex", "PreToolUse", input, timeout)
        .map_err(|reason| refusal(&reason.to_string()))
}

/// What the model reads for a refused call: the text Claude's callback gives.
#[cfg(unix)]
fn refusal(reason: &str) -> String {
    let denial = cmux_git::native_hook::denial(reason);
    denial
        .pointer("/hookSpecificOutput/permissionDecisionReason")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("Repository sync is not ready. Retry after synchronization completes.")
        .to_owned()
}

/// The hook's shell command: this binary's [`HOOK_ARG`], whose failure refuses the call (exit 2).
/// Any other failure (a binary that is gone, a crash) refuses it too, as the terminal's Codex hook
/// does (`||exit 2`).
pub fn hook_command(exe: &str, prefix: &[String]) -> String {
    let mut words = vec![exe.to_owned()];
    words.extend(prefix.iter().cloned());
    words.push(HOOK_ARG.to_owned());
    let quoted: Vec<String> =
        words.iter().map(|w| format!("'{}'", w.replace('\'', "'\\''"))).collect();
    format!("{}||exit 2", quoted.join(" "))
}

/// The global options that add the hook running `command` to a `codex app-server` launch.
pub fn hook_flags(command: &str) -> anyhow::Result<Vec<String>> {
    let [hook, state] =
        cmux_tui_hooks::codex_session_flag_hook_settings("PreToolUse", command, HOOK_TIMEOUT_SECS)?;
    Ok(vec!["--enable".into(), "hooks".into(), "-c".into(), hook, "-c".into(), state])
}

/// `args` of a `codex app-server` launch with the hook first (global options go before the
/// subcommand), run by this binary. `None` when this binary cannot be named.
pub fn gated_args(args: &[String]) -> Option<Vec<String>> {
    let this = crate::self_command::SelfCommand::current().ok()?;
    let exe = this.exe.to_str()?.to_owned();
    let prefix: Vec<String> =
        this.prefix.iter().map(|w| w.to_str().map(str::to_owned)).collect::<Option<_>>()?;
    let flags = hook_flags(&hook_command(&exe, &prefix)).ok()?;
    Some(flags.into_iter().chain(args.iter().cloned()).collect())
}

/// Whether `args` (a launch's, as started) carry the hook [`gated_args`] adds.
pub fn in_args<'a>(args: impl IntoIterator<Item = &'a std::ffi::OsStr>) -> bool {
    let mut enabled = false;
    let mut hook = false;
    let mut previous: Option<&std::ffi::OsStr> = None;
    for arg in args {
        let text = arg.to_string_lossy();
        if previous.is_some_and(|p| p == "--enable") && text == "hooks" {
            enabled = true;
        }
        if previous.is_some_and(|p| p == "-c")
            && text.starts_with("hooks.PreToolUse=")
            && text.contains(HOOK_ARG)
        {
            hook = true;
        }
        previous = Some(arg);
    }
    enabled && hook
}

/// Whether a `codex app-server` launch of `program args` in `cwd` gets the hook: on unix, in a
/// checkout still filling, when its command line leaves Codex's hooks alone, and when `program`
/// (run with `probe_env`, the launch's own environment changes) is [`MIN_VERSION`] or later.
pub fn wanted(
    program: &str,
    args: &[String],
    cwd: &Path,
    probe_env: &[(String, Option<String>)],
) -> bool {
    cfg!(unix)
        && crate::codex_app_server::is_launch(program, args)
        && !args.iter().any(|a| a.contains("hooks"))
        && filling(cwd)
        && supported(program, cwd, probe_env)
}

/// A repository sync at `cwd` is short of ready: a start there may go ahead at its head.
fn filling(cwd: &Path) -> bool {
    #[cfg(unix)]
    {
        use cmux_git::sync_barrier::{Probe, probe};
        matches!(probe(cwd), Ok(Probe::HeadReady | Probe::Syncing))
    }
    #[cfg(not(unix))]
    {
        let _ = cwd;
        false
    }
}

/// Answers of `codex --version`, by the binary's path, size and change time: once per build.
static VERSIONS: LazyLock<Mutex<std::collections::HashMap<(PathBuf, u64, i128), bool>>> =
    LazyLock::new(Mutex::default);

/// Whether `program` is a Codex at [`MIN_VERSION`] or later. Its first start in a filling
/// checkout asks it (`--version`, `harness_health::probe::installed_version`, bounded by that
/// probe's timeout); later ones read the answer. One that does not answer gets no hook, and its
/// start waits for the whole checkout instead.
fn supported(program: &str, cwd: &Path, env: &[(String, Option<String>)]) -> bool {
    let Some(path) = resolve(program, cwd, env) else { return false };
    let Ok(meta) = std::fs::metadata(&path) else { return false };
    let changed = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_nanos() as i128);
    let key = (path.clone(), meta.len(), changed);
    if let Some(known) = VERSIONS.lock().unwrap_or_else(|e| e.into_inner()).get(&key) {
        return *known;
    }
    let answer = crate::harness_health::probe::installed_version(&path.to_string_lossy())
        .is_ok_and(|v| at_least(&v, MIN_VERSION));
    VERSIONS.lock().unwrap_or_else(|e| e.into_inner()).insert(key, answer);
    answer
}

/// Whether `version` is `min` or later.
pub fn at_least(version: &str, min: &str) -> bool {
    crate::harness_health::probe::compare_versions(version, min)
        .is_some_and(|order| order != std::cmp::Ordering::Less)
}

/// `program` as the launch finds it: a path as given (relative to `cwd`), a name on the
/// launch's `PATH`.
fn resolve(program: &str, cwd: &Path, env: &[(String, Option<String>)]) -> Option<PathBuf> {
    if program.contains('/') {
        let path = Path::new(program);
        return Some(if path.is_absolute() { path.to_path_buf() } else { cwd.join(path) });
    }
    let path = match env.iter().rev().find(|(k, _)| k == "PATH") {
        Some((_, value)) => value.clone()?.into(),
        None => std::env::var_os("PATH")?,
    };
    crate::config::which_in(&path, program).map(PathBuf::from)
}

#[cfg(all(test, unix))]
#[path = "codex_repo_gate_tests.rs"]
mod tests;
