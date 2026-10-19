//! The environment a daemon or agent started from inside a Claude Code session must not
//! inherit (moved out of `config.rs`).

/// Variables a Claude Code session plants for its own children: a
/// per-session API proxy and auth, hooks, and wrapper shims. A daemon or
/// agent launched from inside such a session must not inherit them, or its
/// Claude processes dial a proxy that dies with that session ("API Error:
/// Connection refused"). Applied only when `CLAUDECODE` is set, so a user's
/// own `ANTHROPIC_*` settings in a plain shell still pass through. The
/// person's own values for those keys, from the login shell (which runs
/// without them, `login_env.rs`), are put back: the child signs in the way
/// the person's terminal does.
pub fn scrub_nested_claude_env(cmd: &mut std::process::Command) {
    scrub_nested_claude_env_for(cmd, None);
}

/// Same, for a harness of `family` (its allow-list's login values go back).
pub fn scrub_nested_claude_env_for(cmd: &mut std::process::Command, family: Option<&str>) {
    for k in nested_claude_keys() {
        cmd.env_remove(k);
    }
    cmd.envs(crate::login_env::nested_overrides(family));
    cmd.env_remove(LAUNCH_CREDENTIAL_ENV);
    for key in CHIEF_CREDENTIAL_ENV {
        cmd.env_remove(key);
    }
}

/// The cmux terminal launch credential (plans/cmux-next/identity.md
/// section 2). It names the one terminal that started a process; acpmux, its
/// daemon, agents and hooks serve many terminals, so none of them carries it.
/// Both scrubs remove it from every child they prepare; an agent gets one
/// minted for its own session instead (`launch_credential.rs`).
pub const LAUNCH_CREDENTIAL_ENV: &str = "CMUX_LAUNCH_CREDENTIAL";

/// A Chief host's credential and participant (optchat-chief: the token file
/// that binds as that Chief, `agent_mux` for the default Chief). The host
/// that starts a Chief home's acpmux is one Chief of many; the daemon serves
/// every Chief of the home and the person, so no child it starts carries
/// the starter's credential, not even through a preset (hq-6d 2026-10-14).
/// Both scrubs remove them from every child they prepare.
pub const CHIEF_CREDENTIAL_ENV: [&str; 2] = ["MUX_AGENT_TOKEN_FILE", "OPTCHAT_CHIEF_PARTICIPANT"];

/// Whether `key` is one a Claude Code session plants for its children.
pub(crate) fn is_nested_claude_key(key: &str) -> bool {
    key.starts_with("CLAUDE")
        || key.starts_with("ANTHROPIC_")
        || key.starts_with("CMUX_CLAUDE_")
        || key.starts_with("SUBROUTER_CLAUDE_")
        || key == "NODE_OPTIONS"
        || is_prompt_cache_key(key)
}

/// Claude Code's prompt-cache switches. A session's settings env puts them
/// in its process env, so its Bash children inherit them: an OptChat turn
/// that places its own cache marks runs with `DISABLE_PROMPT_CACHING=1`,
/// and an acpmux client run from that turn started the daemon with it
/// (2026-10-19). Every agent that daemon spawned then sent no cache marks
/// at all and paid its whole context uncached on every request. Only a
/// profile, preset or session that sets one of them passes it on.
pub(crate) fn is_prompt_cache_key(key: &str) -> bool {
    key.starts_with("DISABLE_PROMPT_CACHING")
        || key.starts_with("ENABLE_PROMPT_CACHING_1H")
        || key == "FORCE_PROMPT_CACHING_5M"
}

/// Values that name one turn or one session of the process that started
/// the daemon. A Chief turn's shell carries its turn's subrouter session key
/// and seal; an acpmux client run from that shell started the NIGHTLY
/// Chief's daemon with them (2026-10-19), and every agent it spawned
/// inherited what its preset did not set again: its subagents and
/// compactors held that turn's seal, meant for that turn's session alone
/// (`session_env.rs`). Per-session acpmux values
/// (`ACPMUX_*`, `CMUX_AGENT_SESSION`) are set again for each agent in
/// `agent/command.rs`; these have no per-agent value, so they are removed.
pub(crate) const TURN_SCOPED_ENV: [&str; 5] = [
    // `sr claude proxy` sends it as X-Subrouter-Session: one sticky account.
    "SUBROUTER_SESSION_KEY",
    // Codex's prompt-cache key, the same per-role key for Codex harnesses.
    "CODEX_PROMPT_CACHE_KEY",
    // A Chief turn's seal (session_env.rs): its turn session's alone.
    "OPTCHAT_TURN_SEAL",
    // The subagent preset's role flag.
    "OPTCHAT_SUBAGENT",
    // A coding agent's mark for the commands its tools run.
    "AI_AGENT",
];

/// Whether `key` belongs to the daemon starter's turn or session alone: the
/// prompt-cache switches ([`is_prompt_cache_key`]) and [`TURN_SCOPED_ENV`].
pub(crate) fn is_caller_scoped_key(key: &str) -> bool {
    is_prompt_cache_key(key) || TURN_SCOPED_ENV.contains(&key)
}

/// The caller-scoped keys in this process's own environment
/// ([`is_caller_scoped_key`]). Neither the daemon nor an agent inherits them,
/// whoever started it; an agent's profile, preset and session env are
/// applied after this removal, so a value set on purpose still wins.
pub(crate) fn inherited_caller_scoped_keys() -> Vec<std::ffi::OsString> {
    std::env::vars_os()
        .map(|(k, _)| k)
        .filter(|k| is_caller_scoped_key(&k.to_string_lossy()))
        .collect()
}

/// The keys `scrub_nested_claude_env` removes from the daemon's own
/// environment (none outside a Claude Code session).
pub(crate) fn nested_claude_keys() -> Vec<std::ffi::OsString> {
    if std::env::var_os("CLAUDECODE").is_none() {
        return Vec::new();
    }
    std::env::vars_os()
        .map(|(k, _)| k)
        .filter(|k| is_nested_claude_key(&k.to_string_lossy()))
        .collect()
}

/// Same, for tokio's process builder.
pub fn scrub_nested_claude_env_tokio(cmd: &mut tokio::process::Command) {
    scrub_nested_claude_env_tokio_for(cmd, None);
}

/// Same, for a harness of `family`: the login values put back are those of
/// that family's allow-list (`login_env::allowed`).
pub fn scrub_nested_claude_env_tokio_for(cmd: &mut tokio::process::Command, family: Option<&str>) {
    for k in nested_claude_keys() {
        cmd.env_remove(k);
    }
    cmd.envs(crate::login_env::nested_overrides(family));
    cmd.env_remove(LAUNCH_CREDENTIAL_ENV);
    for key in CHIEF_CREDENTIAL_ENV {
        cmd.env_remove(key);
    }
}
