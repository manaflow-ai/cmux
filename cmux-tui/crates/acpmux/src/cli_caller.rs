//! What an acpmux CLI says about its caller at `initialize` (`_meta.acpmux.callerProtocol`,
//! `callerKind`), and which CLI an agent runs ([`BIN_ENV`]).
//!
//! Bench round 4 (2026-11-08, A5 defect 1): an agent's Bash ran the user's old
//! `~/.local/bin/acpmux` (0.1.0), which sends no caller token, and the daemon recorded the send as
//! the person's (`origin: {actor: "person", verified: true}`, `server/requests.rs`
//! `owner_terminal`). A daemon cannot tell the person's terminal from an agent's shell by a
//! connection alone, and it reads no process to find out (plans/cmux-next/pty-holder.md section 4,
//! no process scanning). So the person's path says what it is:
//!
//! - This CLI, from caller protocol [`PROTOCOL`], declares at `initialize` whether it runs in an
//!   acpmux session's environment (`agent`: `ACPMUX_SESSION_ID` or `ACPMUX_SESSION_TOKEN` set,
//!   whether or not its token proves the session to this daemon) or not (`terminal`). Only a
//!   `terminal` declaration lets an unnamed send be the owner's terminal send. An `agent` one
//!   whose token proved nothing (another daemon's, or none) is `unverified`.
//! - An `acpmux-cli` that declares no protocol is older than this rule and checked nothing: its
//!   sends are `unverified` and name that client (`claimed.client`, "acpmux-cli 0.1.0"), never the
//!   person's.
//! - A client that is no acpmux CLI and declares nothing (a script, a test, another tool's raw
//!   socket client) keeps the rule from before (`owner_terminal`).
//!
//! A declaration is a claim of the same user's process, never a proof: what proves the person is
//! `hub/person.rs`. It closes the accident (an agent that runs an old or foreign CLI), not a
//! deliberate forgery, which the trust boundary in `owner_terminal` already describes.
//!
//! So that an agent runs its daemon's own CLI, each session's harness gets [`BIN_ENV`], the
//! absolute path of the daemon's executable (`agent/command.rs`). A login shell profile that puts
//! `~/.local/bin` first on PATH (Claude Code's shell snapshot keeps it) cannot change that path.

use serde_json::{Map, Value, json};

/// `_meta.acpmux` field of `initialize`: the caller protocol this CLI speaks.
pub const PROTOCOL_FIELD: &str = "callerProtocol";
/// `_meta.acpmux` field of `initialize`: `terminal` or `agent` (module docs).
pub const KIND_FIELD: &str = "callerKind";
/// The caller protocol of this build.
pub const PROTOCOL: u64 = 1;
/// The `clientInfo.name` every acpmux CLI sends, this one and the old ones.
pub const CLI_NAME: &str = "acpmux-cli";
/// The `callerKind` of a CLI outside any acpmux session's environment.
pub const KIND_TERMINAL: &str = "terminal";
/// The `callerKind` of a CLI inside an acpmux session's environment.
pub const KIND_AGENT: &str = "agent";
/// The env var that gives each session's harness its daemon's own acpmux, an absolute path.
pub const BIN_ENV: &str = "ACPMUX_BIN";
/// `claimed` key of an unverified prompt from an old acpmux CLI: "acpmux-cli 0.1.0".
pub const CLAIMED_CLIENT: &str = "client";

/// What a unix client declared about its caller at its first `initialize`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Declared {
    /// Caller protocol 1 or later, outside any acpmux session's environment.
    Terminal,
    /// Caller protocol 1 or later, inside an acpmux session's environment, or a kind this build
    /// does not know.
    Agent,
    /// An acpmux CLI older than caller protocol 1: its `clientInfo` as "acpmux-cli VERSION".
    OldCli(String),
}

impl Declared {
    /// Whether an unnamed send on this connection may be the owner's terminal send.
    pub fn may_be_owner_terminal(&self) -> bool {
        matches!(self, Self::Terminal)
    }

    /// The old acpmux CLI this connection is, as an unverified prompt claims it.
    pub fn old_client(&self) -> Option<&str> {
        match self {
            Self::OldCli(client) => Some(client),
            _ => None,
        }
    }
}

/// What the `params` of a first `initialize` declare: `None` for a client that is no acpmux CLI
/// and declares no caller protocol.
pub fn of_initialize(params: &Value) -> Option<Declared> {
    let mux = params.pointer("/_meta/acpmux");
    let field = |key: &str| mux.and_then(|m| m.get(key));
    if field(PROTOCOL_FIELD).and_then(Value::as_u64).is_some_and(|p| p >= PROTOCOL) {
        // An unknown kind fails closed: never the owner's terminal.
        return Some(match field(KIND_FIELD).and_then(Value::as_str) {
            Some(KIND_TERMINAL) => Declared::Terminal,
            _ => Declared::Agent,
        });
    }
    let info = params.get("clientInfo")?;
    if info.get("name").and_then(Value::as_str) != Some(CLI_NAME) {
        return None;
    }
    let version = info
        .get("version")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|v| !v.is_empty() && v.len() <= 64 && !v.chars().any(char::is_control));
    Some(Declared::OldCli(match version {
        Some(version) => format!("{CLI_NAME} {version}"),
        None => CLI_NAME.to_owned(),
    }))
}

/// Whether `env` is an acpmux session's environment: its session id or its caller token is set.
pub fn in_session_env(env: impl Fn(&str) -> Option<String>) -> bool {
    let set = |key: &str| env(key).is_some_and(|v| !v.trim().is_empty());
    set("ACPMUX_SESSION_ID") || set(crate::hub::person::CALLER_TOKEN_ENV)
}

/// Adds this CLI's declaration to the `_meta.acpmux` of its `initialize`.
pub fn declare(mux: &mut Map<String, Value>, env: impl Fn(&str) -> Option<String>) {
    let kind = if in_session_env(env) { KIND_AGENT } else { KIND_TERMINAL };
    mux.insert(PROTOCOL_FIELD.to_owned(), json!(PROTOCOL));
    mux.insert(KIND_FIELD.to_owned(), json!(kind));
}

/// The `_meta.acpmux` fields a replay declares for a send whose own connection declared no
/// terminal (`server/outbox.rs`): the replay is no owner's terminal send either.
pub fn agent_declaration() -> Map<String, Value> {
    let mut mux = Map::new();
    mux.insert(PROTOCOL_FIELD.to_owned(), json!(PROTOCOL));
    mux.insert(KIND_FIELD.to_owned(), json!(KIND_AGENT));
    mux
}

/// The `data.reason` of [`old_cli_refused`].
pub const OLD_CLI_REASON: &str = "caller.old_client";

/// The refusal of a verb only the person's own terminal may use, to an old acpmux CLI that proves
/// no caller: it names the client and says which CLI to run instead.
pub fn old_cli_refused(client: &str, what: &str) -> crate::rpc::RpcError {
    let daemon = crate::hub::VERSION;
    crate::rpc::RpcError::new(
        -32000,
        format!(
            "{client} is older than this acpmux daemon ({daemon}) and does not say who runs it, so \
             {what} is refused: run the daemon's own acpmux (in an agent session: \"$ACPMUX_BIN\"; \
             `acpmux daemon status` names its path), or update the one on your PATH"
        ),
    )
    .with_data(json!({"reason": OLD_CLI_REASON, "client": client, "daemonVersion": daemon}))
}

/// This process's executable, for [`BIN_ENV`]: absolute, or `None`.
pub fn own_bin() -> Option<std::path::PathBuf> {
    std::env::current_exe().ok().filter(|p| p.is_absolute())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    #[test]
    fn this_cli_declares_terminal_outside_a_session_and_agent_inside_one() {
        let mut mux = Map::new();
        declare(&mut mux, env(&[]));
        let hello = json!({"clientInfo": {"name": CLI_NAME}, "_meta": {"acpmux": mux}});
        assert_eq!(of_initialize(&hello), Some(Declared::Terminal));
        // A session id alone (no token for this daemon) is still an agent's shell.
        let mut mux = Map::new();
        declare(&mut mux, env(&[("ACPMUX_SESSION_ID", "s1")]));
        let hello = json!({"clientInfo": {"name": CLI_NAME}, "_meta": {"acpmux": mux}});
        assert_eq!(of_initialize(&hello), Some(Declared::Agent));
    }

    #[test]
    fn an_old_cli_is_named_and_a_foreign_client_declares_nothing() {
        let old = json!({"clientInfo": {"name": CLI_NAME, "version": "0.1.0"}});
        let declared = of_initialize(&old).unwrap();
        assert_eq!(declared.old_client(), Some("acpmux-cli 0.1.0"));
        assert!(!declared.may_be_owner_terminal());
        assert_eq!(of_initialize(&json!({"clientInfo": {"name": "my-script"}})), None);
        assert_eq!(of_initialize(&json!({"protocolVersion": 1})), None);
        // An unknown kind fails closed.
        let odd = json!({"_meta": {"acpmux": {"callerProtocol": 1, "callerKind": "robot"}}});
        assert_eq!(of_initialize(&odd), Some(Declared::Agent));
    }
}
