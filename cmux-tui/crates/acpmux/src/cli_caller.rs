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
/// no caller: it names the client and says which CLI to run instead. The daemon does not know the
/// old client's locale, so the text is English, then Japanese.
pub fn old_cli_refused(client: &str, what: &str) -> crate::rpc::RpcError {
    let daemon = crate::hub::VERSION;
    crate::rpc::RpcError::new(
        -32000,
        format!(
            "{client} is older than this acpmux daemon ({daemon}) and does not say who runs it, so \
             {what} is refused: run the daemon's own acpmux (in an agent session: \"$ACPMUX_BIN\"; \
             `acpmux daemon status` names its path), or update the one on your PATH. / \
             {client} はこの acpmux デーモン ({daemon}) より古く、だれが実行しているかを伝えないため、\
             この操作は拒否されました。デーモン自身の acpmux を実行してください \
             (エージェントのセッションでは \"$ACPMUX_BIN\"、パスは `acpmux daemon status` で確認できます)。\
             または PATH 上の acpmux を更新してください。"
        ),
    )
    .with_data(json!({"reason": OLD_CLI_REASON, "client": client, "daemonVersion": daemon}))
}

/// This process's executable, for [`BIN_ENV`]: absolute, or `None`.
pub fn own_bin() -> Option<std::path::PathBuf> {
    std::env::current_exe().ok().filter(|p| p.is_absolute())
}

/// What runs this daemon's acpmux CLI by one path, for [`BIN_ENV`] ([`bin_choice`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BinChoice {
    /// The daemon's executable itself: a standalone acpmux.
    Exe(std::path::PathBuf),
    /// The `acpmux` alias beside a host binary, the same file.
    Alias(std::path::PathBuf),
    /// A host binary with no such alias: the text of a script that runs it with its prefix.
    Wrapper(String),
}

/// How [`BIN_ENV`] runs this daemon's acpmux CLI, from its executable `exe`, the words before an
/// acpmux subcommand in it (`daemon_prefix`, `acp` in cmux) and whether a path is the same file
/// as `exe`.
pub fn bin_choice(
    exe: &std::path::Path,
    _prefix: &[std::ffi::OsString],
    _same_file: impl Fn(&std::path::Path) -> bool,
) -> Option<BinChoice> {
    exe.is_absolute().then(|| BinChoice::Exe(exe.to_path_buf()))
}

/// Where the daemon whose home is `home` keeps its [`BinChoice::Wrapper`] script.
pub fn wrapper_path(home: &std::path::Path) -> std::path::PathBuf {
    home.join("bin").join("acpmux")
}

/// Writes `script` at `path`, owner-only and executable, unless the file there holds it already.
pub fn install_wrapper(_path: &std::path::Path, _script: &str) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    }

    /// Review 2 of #39020 (B1): in cmux the daemon is `<cmux> acp daemon run`, and its executable
    /// is cmux, whose own `send` is no acpmux verb. `ACPMUX_BIN` is one path that runs acpmux's
    /// CLI: the `acpmux` alias beside it when that is the same file (cmux-tui runs acpmux when
    /// argv0 is `acpmux`), else a wrapper script that runs the executable with its prefix. A
    /// standalone acpmux replaced by an update names its installed path (N4).
    #[test]
    fn w5s_acpmux_bin_is_one_path_that_runs_acpmux_under_a_host_prefix() {
        use std::path::{Path, PathBuf};
        let acp = [std::ffi::OsString::from("acp")];
        let none = |_: &Path| false;
        let standalone = bin_choice(Path::new("/opt/x/acpmux (deleted)"), &[], none);
        assert_eq!(standalone, Some(BinChoice::Exe(PathBuf::from("/opt/x/acpmux"))));
        let alias = |p: &Path| p == Path::new("/app/bin/acpmux");
        let aliased = bin_choice(Path::new("/app/bin/cmux"), &acp, alias);
        assert_eq!(aliased, Some(BinChoice::Alias(PathBuf::from("/app/bin/acpmux"))));
        let wrapped = bin_choice(Path::new("/A B/it's/cmux"), &acp, none);
        let script = "#!/bin/sh\nexec '/A B/it'\\''s/cmux' 'acp' \"$@\"\n";
        assert_eq!(wrapped, Some(BinChoice::Wrapper(script.to_owned())));
        assert_eq!(bin_choice(Path::new("cmux"), &acp, none), None, "never a relative path");
    }

    /// The wrapper script is written once, owner-only and executable, atomically; it is written
    /// again only when its text changes (another executable).
    #[cfg(unix)]
    #[test]
    fn w5s_the_wrapper_is_written_owner_only_and_only_when_it_changes() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let home = std::env::temp_dir().join(format!("w5s-wrapper-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let path = wrapper_path(&home);
        install_wrapper(&path, "#!/bin/sh\nexec '/a/cmux' 'acp' \"$@\"\n").unwrap();
        let meta = std::fs::symlink_metadata(&path).ok();
        assert!(meta.as_ref().is_some_and(|m| m.is_file()), "no wrapper at {}", path.display());
        let meta = meta.unwrap();
        assert_eq!(meta.permissions().mode() & 0o777, 0o700, "owner-only and executable");
        install_wrapper(&path, "#!/bin/sh\nexec '/a/cmux' 'acp' \"$@\"\n").unwrap();
        let again = std::fs::symlink_metadata(&path).unwrap();
        assert_eq!(again.ino(), meta.ino(), "the same text is not written again");
        install_wrapper(&path, "#!/bin/sh\nexec '/b/cmux' 'acp' \"$@\"\n").unwrap();
        assert!(std::fs::read_to_string(&path).unwrap().contains("/b/cmux"));
        let _ = std::fs::remove_dir_all(&home);
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

    #[test]
    fn the_old_cli_refusal_names_the_client_and_the_fix_in_english_and_japanese() {
        let e = old_cli_refused("acpmux-cli 0.1.0", "changing a session's turn cap");
        assert!(e.message.contains("acpmux-cli 0.1.0 is older than this acpmux daemon"), "{e:?}");
        assert!(e.message.contains("\"$ACPMUX_BIN\""), "{e:?}");
        assert!(e.message.contains("より古く"), "{e:?}");
        assert_eq!(e.data.unwrap()["reason"], OLD_CLI_REASON);
    }
}
