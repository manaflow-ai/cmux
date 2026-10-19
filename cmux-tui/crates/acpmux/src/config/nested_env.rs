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

/// The prompt-cache keys in this process's own environment
/// ([`is_prompt_cache_key`]). An agent never inherits them from the daemon,
/// whoever started it; the agent's profile env is applied after this
/// removal, so a preset that sets one on purpose still wins.
pub(crate) fn inherited_prompt_cache_keys() -> Vec<std::ffi::OsString> {
    std::env::vars_os()
        .map(|(k, _)| k)
        .filter(|k| is_prompt_cache_key(&k.to_string_lossy()))
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
