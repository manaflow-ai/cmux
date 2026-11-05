//! `cmux harness login ID` (cx-1785): sign in to a harness through the
//! Agent Client Protocol's own sign-in, the same way for every ACP harness.
//!
//! The harness starts in a private temp folder (like doctor) and answers
//! `initialize` with its `authMethods`. `--status` only tries `session/new`:
//! an answer means signed in, error -32000 means sign-in is required. A
//! login runs one method:
//! - `agent` (the default type): `authenticate {methodId}`; the agent does
//!   the sign-in itself (it usually opens the browser) and answers when done;
//! - `terminal`: the harness's command line runs again with the method's
//!   arguments and env added, in this terminal, for an interactive sign-in;
//! - `env_var`: nothing runs; the command prints how to store the variable
//!   in the Keychain (`cmux harness secret set`).
//!
//! Claude Code (acpmux's own adapter) has no ACP sign-in: its login runs
//! `claude auth login` in this terminal. Neither has Codex through `codex
//! app-server` (the in-process bridge, which speaks app-server, not ACP):
//! its login runs `codex login` here, and `--status` asks `codex login status`.
//!
//! Sign-in types and the terminal hand-off follow the ACP auth methods that
//! t3code's ACP Registry auth uses (apps/server/src/provider/acp/
//! AcpRegistryAuth.ts). Portions adapted from t3code, Copyright (c) 2026
//! T3 Tools Inc., MIT License (https://github.com/pingdotgg/t3code; see
//! THIRD_PARTY_LICENSES.md).

use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use serde::Serialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, BufReader};

use super::harness::wire::{TempFolder, Wire};
use crate::config::profiles;
use crate::config::{Config, HarnessKind, HarnessProfile};

/// ACP's "authentication required" error code.
pub const AUTH_REQUIRED: i64 = -32000;

/// One sign-in method a harness offers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthMethod {
    pub id: String,
    pub name: String,
    /// `agent`, `terminal` or `env_var`.
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub var_name: Option<String>,
}

/// The `authMethods` of an `initialize` result; unusable entries are left out.
pub fn auth_methods(init: &Value) -> Vec<AuthMethod> {
    let text = |v: &Value| v.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned);
    init["authMethods"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let id = text(&m["id"])?;
            let kind = text(&m["type"]).unwrap_or_else(|| "agent".into());
            if !matches!(kind.as_str(), "agent" | "terminal" | "env_var") {
                return None;
            }
            let args = m["args"]
                .as_array()
                .map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_owned)).collect())
                .unwrap_or_default();
            let env = m["env"]
                .as_object()
                .map(|o| {
                    o.iter()
                        .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                        .collect()
                })
                .unwrap_or_default();
            Some(AuthMethod {
                name: text(&m["name"]).unwrap_or_else(|| id.clone()),
                description: text(&m["description"]),
                var_name: text(&m["varName"]).or_else(|| (kind == "env_var").then(|| id.clone())),
                id,
                kind,
                args,
                env,
            })
        })
        .collect()
}

/// Whether a harness is signed in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum AuthState {
    SignedIn {
        methods: Vec<AuthMethod>,
    },
    Required {
        methods: Vec<AuthMethod>,
        message: String,
    },
    /// No ACP sign-in to check (Claude Code's own adapter, a terminal harness).
    NotAcp {
        hint: String,
    },
}

/// A started harness: its process, the wire, its temp folder and its
/// `initialize` result. Dropping it stops the harness's process group.
struct Started {
    child: tokio::process::Child,
    wire: Wire,
    folder: TempFolder,
    init: Value,
}

impl Drop for Started {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = self.child.id() {
            unsafe {
                libc::killpg(pid as libc::pid_t, libc::SIGKILL);
            }
        }
    }
}

fn profile<'a>(cfg: &'a Config, id: &str) -> Result<&'a HarnessProfile> {
    cfg.harnesses.get(id).ok_or_else(|| anyhow!("no harness {id:?}; see `cmux harness list`"))
}

/// The profile with its env references resolved (Keychain, login env).
fn resolved(profile: &HarnessProfile) -> Result<HarnessProfile> {
    let mut spawn = profile.clone();
    profiles::resolve_env_refs(
        &mut spawn.env,
        &|var| std::env::var(var).ok(),
        &profiles::keychain_lookup,
    )
    .map_err(|e| anyhow!("env: {e}"))?;
    Ok(spawn)
}

async fn start(id: &str, profile: &HarnessProfile, timeout: Duration) -> Result<Started> {
    let folder = TempFolder::new(id)?;
    let spawn = resolved(profile)?;
    let mut cmd = crate::agent::harness_command(id, &spawn, &folder.path, None, None)?;
    // The sign-in may print to stderr (a URL); show it.
    cmd.stderr(std::process::Stdio::inherit());
    let mut child = cmd.spawn().map_err(|e| anyhow!("start {}: {e}", spawn.argv[0]))?;
    let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        bail!("no stdio pipes");
    };
    let wire = Wire {
        stdin,
        lines: BufReader::new(stdout).lines(),
        next: 1,
        reply: String::new(),
        noise: 0,
    };
    let mut started = Started { child, wire, folder, init: Value::Null };
    let init = json!({
        "protocolVersion": 1,
        "clientCapabilities": {
            "fs": {"readTextFile": false, "writeTextFile": false},
            "terminal": false,
            "auth": {"terminal": true},
            "_meta": {"terminal-auth": true},
        },
        "clientInfo": {"name": "cmux harness login", "version": env!("CARGO_PKG_VERSION")},
    });
    started.init = started.wire.call("initialize", init, timeout).await.map_err(|e| anyhow!(e))?;
    Ok(started)
}

/// `session/new` in the started harness: Ok(true) answered, Ok(false) sign-in
/// required (with the agent's message).
async fn session_new(started: &mut Started, timeout: Duration) -> Result<Result<(), String>> {
    let params = json!({"cwd": started.folder.path.to_string_lossy(), "mcpServers": []});
    match started.wire.call("session/new", params, timeout).await {
        Ok(_) => Ok(Ok(())),
        Err(e) if e.contains(&format!("({AUTH_REQUIRED})")) => Ok(Err(e)),
        Err(e) => Err(anyhow!(e)),
    }
}

fn not_acp(id: &str, profile: &HarnessProfile) -> Option<String> {
    match profile.kind {
        HarnessKind::Acp => None,
        HarnessKind::Terminal => Some(format!("{id} runs in a terminal tab; sign in there")),
        HarnessKind::ClaudeStdio if profile.argv.len() == 1 => {
            Some(format!("run `cmux harness login {id}` (it runs `claude auth login`)"))
        }
        HarnessKind::ClaudeStdio => Some(format!("{id} signs in through its router command")),
    }
}

/// Whether a profile runs `codex app-server` through the in-process bridge:
/// `session/new` and `authenticate` are not app-server methods, so its
/// sign-in goes through the codex CLI.
fn codex_bridge(profile: &HarnessProfile) -> bool {
    matches!(profile.kind, HarnessKind::Acp)
        && crate::codex_app_server::is_profile_launch(&profile.argv)
}

/// How the bridge's launch runs codex, for its own CLI: the program, the
/// global options before `app-server` and the env.
struct CodexCli {
    /// `CODEX_PATH` of the env, as the launch picks it (`agent::command`),
    /// else the profile's command.
    program: String,
    /// `-c key=value`, `--enable x`, `-p profile`: they pick the config
    /// (`cli_auth_credentials_store`, `CODEX_HOME`'s profile) the harness
    /// signs in with, so `login` gets them too.
    globals: Vec<String>,
    env: BTreeMap<String, String>,
}

impl CodexCli {
    /// `<codex> <globals...> <sub...>`.
    fn argv(&self, sub: &[&str]) -> Vec<String> {
        std::iter::once(self.program.clone())
            .chain(self.globals.iter().cloned())
            .chain(sub.iter().map(|s| (*s).to_owned()))
            .collect()
    }
}

/// The bridge's codex as its launch builds it: the profile's env, then the
/// family's and the profile's `defaults`; then `${home}`, `${cwd}`,
/// `${model}` and a leading `~/` expanded in the env and the argv
/// (`hub::spawn`); then the env's references resolved (`agent::command`),
/// in that order, so `${file:${home}/key}` reads the expanded path.
fn codex_cli(cfg: &Config, id: &str, profile: &HarnessProfile) -> Result<CodexCli> {
    let cwd = std::env::current_dir().unwrap_or_default();
    let home = dirs::home_dir().unwrap_or_default();
    codex_cli_at(cfg, id, profile, &cwd, &home)
}

/// `codex_cli` with this `cwd` and `home`.
fn codex_cli_at(
    cfg: &Config,
    id: &str,
    profile: &HarnessProfile,
    cwd: &std::path::Path,
    home: &std::path::Path,
) -> Result<CodexCli> {
    let defaults = cfg.defaults_for(id);
    let model = defaults.model.unwrap_or_default();
    let mut layered = profile.clone();
    for (k, v) in defaults.env {
        layered.env.entry(k).or_insert(v);
    }
    for v in layered.env.values_mut() {
        *v = crate::hub::expand_env_value(v, cwd, home, &model);
    }
    for a in layered.argv.iter_mut() {
        *a = crate::hub::expand_env_value(a, cwd, home, &model);
    }
    let layered = resolved(&layered)?;
    let (command, args) =
        layered.argv.split_first().ok_or_else(|| anyhow!("{id} has an empty argv"))?;
    let program = layered
        .env
        .get("CODEX_PATH")
        .filter(|p| !p.is_empty())
        .cloned()
        .unwrap_or_else(|| command.clone());
    Ok(CodexCli { program, globals: codex_globals(args).to_vec(), env: layered.env })
}

/// The global options before `app-server` in a bridge launch's args, read
/// the way `codex_app_server::is_launch` reads them: `--flag=value` is one
/// word, `-c value` and `--flag value` are two.
pub(crate) fn codex_globals(args: &[String]) -> &[String] {
    let mut i = 0;
    while let Some(a) = args.get(i) {
        if a == "app-server" || !a.starts_with('-') {
            return &args[..i];
        }
        i += if a.contains('=') { 1 } else { 2 };
    }
    &args[..i.min(args.len())]
}

/// Whether harness `id` is signed in.
pub async fn auth_state(cfg: &Config, id: &str, timeout: Duration) -> Result<AuthState> {
    let profile = profile(cfg, id)?;
    if let Some(hint) = not_acp(id, profile) {
        return Ok(AuthState::NotAcp { hint });
    }
    if codex_bridge(profile) {
        let codex = codex_cli(cfg, id, profile)?;
        let status = tokio::task::spawn_blocking(move || {
            crate::harness_health::probe::codex_login_status_argv(
                &codex.argv(&["login", "status"]),
                &codex.env,
            )
        })
        .await?;
        return match status {
            Some(true) => Ok(AuthState::SignedIn { methods: vec![] }),
            Some(false) => Ok(AuthState::Required {
                methods: vec![],
                message: "`codex login status`: not logged in".into(),
            }),
            None => Err(anyhow!(
                "`codex login status` did not say: a custom provider, a config error or an older codex"
            )),
        };
    }
    let mut started = start(id, profile, timeout).await?;
    let methods = auth_methods(&started.init);
    Ok(match session_new(&mut started, timeout).await? {
        Ok(()) => AuthState::SignedIn { methods },
        Err(message) => AuthState::Required { methods, message },
    })
}

/// Runs a terminal sign-in: `argv` with `env`, in this terminal; its exit code.
pub type TerminalRunner<'a> = dyn Fn(&[String], &BTreeMap<String, String>) -> Result<i32> + 'a;

/// Runs `argv` in this terminal (stdin, stdout and stderr inherited).
/// The env hygiene of `agent::harness_command` (login env, no nested
/// Claude markers, no `ACPMUX_*` context, no helper tokens), on a plain
/// command that stays in this terminal's process group so Ctrl-C reaches it.
pub fn run_in_this_terminal(argv: &[String], env: &BTreeMap<String, String>) -> Result<i32> {
    let (program, args) = argv.split_first().ok_or_else(|| anyhow!("empty command"))?;
    let mut cmd = std::process::Command::new(program);
    crate::login_env::apply_std(&mut cmd);
    crate::config::scrub_nested_claude_env(&mut cmd);
    for (k, _) in std::env::vars_os() {
        if k.to_string_lossy().starts_with("ACPMUX_") {
            cmd.env_remove(&k);
        }
    }
    for key in crate::cua_socket::AGENT_SCRUBBED_ENV {
        cmd.env_remove(key);
    }
    cmd.env_remove("CODEX_THREAD_ID").env_remove("OMPCODE");
    let status = cmd
        .args(args)
        .envs(env)
        .env_remove("CLAUDECODE")
        .env_remove("CLAUDE_CODE_ENTRYPOINT")
        .status()?;
    Ok(status.code().unwrap_or(1))
}

/// Merges a sign-in method's env under the profile's: a profile key (a
/// Keychain secret, PATH) always wins, and loader keys never come from the
/// agent.
fn method_env(
    profile: &BTreeMap<String, String>,
    method: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut env = profile.clone();
    for (k, v) in method {
        if k == "PATH" || k.starts_with("LD_") || k.starts_with("DYLD_") {
            continue;
        }
        env.entry(k.clone()).or_insert_with(|| v.clone());
    }
    env
}

/// Signs in to harness `id` with `method` (default: its first `agent`
/// method, else its first `terminal` method). Returns what happened, in a
/// sentence.
pub async fn login(
    cfg: &Config,
    id: &str,
    method: Option<&str>,
    timeout: Duration,
    terminal: &TerminalRunner<'_>,
) -> Result<String> {
    let profile = profile(cfg, id)?;
    match profile.kind {
        HarnessKind::Acp => {}
        HarnessKind::ClaudeStdio if profile.argv.len() == 1 => {
            let argv = vec![profile.argv[0].clone(), "auth".into(), "login".into()];
            let env = resolved(profile)?.env;
            let code = terminal(&argv, &env)?;
            return if code == 0 {
                Ok(format!("{id}: signed in"))
            } else {
                Err(anyhow!("`claude auth login` exited {code}"))
            };
        }
        _ => bail!("{}", not_acp(id, profile).unwrap_or_default()),
    }
    if codex_bridge(profile) {
        if let Some(m) = method {
            bail!("{id} signs in with `codex login`; it has no sign-in method {m:?}");
        }
        let codex = codex_cli(cfg, id, profile)?;
        let code = terminal(&codex.argv(&["login"]), &codex.env)?;
        return if code == 0 {
            Ok(format!("{id}: signed in"))
        } else {
            Err(anyhow!("`codex login` exited {code}"))
        };
    }
    let mut started = start(id, profile, timeout).await?;
    let methods = auth_methods(&started.init);
    let chosen = match method {
        Some(m) => methods.iter().find(|x| x.id == m).ok_or_else(|| {
            let ids: Vec<&str> = methods.iter().map(|x| x.id.as_str()).collect();
            anyhow!("{id} has no sign-in method {m:?}; it offers: {}", ids.join(", "))
        })?,
        None => methods
            .iter()
            .find(|x| x.kind == "agent")
            .or_else(|| methods.iter().find(|x| x.kind == "terminal"))
            .ok_or_else(|| match methods.first() {
                Some(_) => anyhow!(
                    "{id} signs in only with an API key: see `cmux harness login {id} --list`"
                ),
                None => anyhow!(
                    "{id} offers no ACP sign-in; sign in with its own command{}",
                    cfg.profile_meta
                        .get(id)
                        .and_then(|m| m.auth.as_ref())
                        .and_then(|a| a.login.as_ref())
                        .map(|l| format!(" (`{l}`)"))
                        .unwrap_or_default()
                ),
            })?,
    };
    match chosen.kind.as_str() {
        "env_var" => {
            let var = chosen.var_name.clone().unwrap_or_else(|| chosen.id.clone());
            Ok(format!(
                "{id} reads {var}: store it with `cmux harness secret set {id} {var}` and add \
                 `{var} = {{ keychain = \"cmux-harness/{id}/{var}\" }}` to the profile's [env]"
            ))
        }
        "terminal" => {
            let spawn = resolved(profile)?;
            // The harness's own command line plus the method's arguments
            // (ACP terminal sign-in), as t3code runs it.
            let mut argv = spawn.argv.clone();
            argv.extend(chosen.args.iter().cloned());
            let env = method_env(&spawn.env, &chosen.env);
            drop(started);
            let code = terminal(&argv, &env)?;
            if code != 0 {
                bail!("{} exited {code}", chosen.name);
            }
            Ok(format!("{id}: signed in with {}", chosen.name))
        }
        _ => {
            eprintln!("waiting for the {} sign-in (up to 5 min; Ctrl-C stops it)", chosen.name);
            let params = json!({"methodId": chosen.id});
            started.wire.call("authenticate", params, timeout).await.map_err(|e| anyhow!(e))?;
            match session_new(&mut started, timeout).await? {
                Ok(()) => Ok(format!("{id}: signed in with {}", chosen.name)),
                Err(e) => Err(anyhow!("{id}: still not signed in after {}: {e}", chosen.name)),
            }
        }
    }
}

pub async fn run_cmd(
    id: &str,
    method: Option<String>,
    list: bool,
    status: bool,
    json_out: bool,
) -> Result<()> {
    let cfg = Config::load()?;
    let timeout = Duration::from_secs(300);
    if list || status {
        // Ctrl-C drops the started harness, which stops its process group.
        let state = tokio::select! {
            state = auth_state(&cfg, id, Duration::from_secs(60)) => state?,
            _ = tokio::signal::ctrl_c() => bail!("stopped"),
        };
        if json_out {
            println!("{}", serde_json::to_string_pretty(&state)?);
            return Ok(());
        }
        match &state {
            AuthState::NotAcp { hint } => println!("{hint}"),
            AuthState::SignedIn { methods } | AuthState::Required { methods, .. } => {
                let signed = matches!(state, AuthState::SignedIn { .. });
                println!("{id}: {}", if signed { "signed in" } else { "sign-in required" });
                for m in methods {
                    println!("  {:<24} {:<9} {}", m.id, m.kind, m.name);
                }
            }
        }
        return Ok(());
    }
    let outcome = tokio::select! {
        outcome = login(&cfg, id, method.as_deref(), timeout, &run_in_this_terminal) => outcome?,
        _ = tokio::signal::ctrl_c() => bail!("stopped"),
    };
    if json_out {
        println!("{}", json!({"id": id, "result": outcome}));
    } else {
        println!("{outcome}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn acp(argv: &[&str], env: &[(&str, &str)]) -> HarnessProfile {
        HarnessProfile {
            kind: HarnessKind::Acp,
            argv: argv.iter().map(|s| s.to_string()).collect(),
            env: env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        }
    }

    fn config(profile: HarnessProfile) -> Config {
        let mut cfg = Config::default();
        cfg.harnesses.insert("codex".into(), profile);
        cfg
    }

    /// The commands a login ran in the terminal (each exits 0).
    async fn ran(cfg: &Config, method: Option<&str>) -> (Result<String>, Vec<Vec<String>>) {
        let ran = std::sync::Mutex::new(Vec::new());
        let terminal = |argv: &[String], _: &BTreeMap<String, String>| {
            ran.lock().unwrap().push(argv.to_vec());
            Ok(0)
        };
        let outcome = login(cfg, "codex", method, Duration::from_secs(5), &terminal).await;
        (outcome, ran.into_inner().unwrap())
    }

    /// The commands and envs a login ran in the terminal (each exits 0).
    async fn ran_with_env(cfg: &Config) -> Vec<(Vec<String>, BTreeMap<String, String>)> {
        let ran = std::sync::Mutex::new(Vec::new());
        let terminal = |argv: &[String], env: &BTreeMap<String, String>| {
            ran.lock().unwrap().push((argv.to_vec(), env.clone()));
            Ok(0)
        };
        login(cfg, "codex", None, Duration::from_secs(5), &terminal).await.unwrap();
        ran.into_inner().unwrap()
    }

    /// A fake `codex` that answers `out` and exits `code` only when it is run
    /// as `codex <args>` with `CODEX_HOME=<home>`; any other command exits 2
    /// with output that is not Codex's "Not logged in".
    #[cfg(unix)]
    fn fake_codex(test: &str, args: &str, home: &str, out: &str, code: i32) -> String {
        let dir = std::env::temp_dir().join(format!("acpmux-login-{test}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("codex");
        let script = format!(
            "#!/bin/sh\n\
             if [ \"$*\" != '{args}' ] || [ \"${{CODEX_HOME-}}\" != '{home}' ]; then\n\
             echo \"unexpected: $* (CODEX_HOME=${{CODEX_HOME-}})\"; exit 2\nfi\n\
             echo '{out}'\nexit {code}\n"
        );
        crate::test_exec::write_executable(&path, script);
        path.to_string_lossy().into_owned()
    }

    #[tokio::test]
    async fn codex_bridge_login_runs_codex_login_in_this_terminal() {
        let (outcome, ran) = ran(&config(acp(&["/opt/bin/codex", "app-server"], &[])), None).await;
        assert_eq!(outcome.unwrap(), "codex: signed in");
        assert_eq!(ran, vec![vec!["/opt/bin/codex".to_owned(), "login".to_owned()]]);
    }

    #[tokio::test]
    async fn codex_bridge_login_runs_the_codex_path_binary_like_the_launch() {
        let profile = acp(&["codex", "app-server"], &[("CODEX_PATH", "/opt/codex-new")]);
        let (outcome, ran) = ran(&config(profile), None).await;
        assert_eq!(outcome.unwrap(), "codex: signed in");
        assert_eq!(ran, vec![vec!["/opt/codex-new".to_owned(), "login".to_owned()]]);
    }

    #[tokio::test]
    async fn codex_bridge_login_takes_codex_path_from_the_family_defaults() {
        let mut cfg = config(acp(&["codex", "app-server"], &[]));
        let mut defaults = crate::config::SessionDefaults::default();
        defaults.env.insert("CODEX_PATH".into(), "/opt/codex-family".into());
        cfg.defaults.insert("codex".into(), defaults);
        let (outcome, ran) = ran(&cfg, None).await;
        assert_eq!(outcome.unwrap(), "codex: signed in");
        assert_eq!(ran, vec![vec!["/opt/codex-family".to_owned(), "login".to_owned()]]);
    }

    #[tokio::test]
    async fn codex_bridge_login_refuses_an_acp_method() {
        let (outcome, ran) =
            ran(&config(acp(&["/opt/bin/codex", "app-server"], &[])), Some("chatgpt")).await;
        let err = outcome.unwrap_err().to_string();
        assert!(err.contains("codex login"), "{err}");
        assert!(ran.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn codex_bridge_status_asks_codex_login_status() {
        let timeout = Duration::from_secs(5);
        let home = [("CODEX_HOME", "/tmp/acpmux-login-codex-home")];
        let codex = |test, out, code| {
            fake_codex(test, "login status", "/tmp/acpmux-login-codex-home", out, code)
        };
        let signed_in =
            config(acp(&[&codex("in", "Logged in using ChatGPT", 0), "app-server"], &home));
        assert_eq!(
            auth_state(&signed_in, "codex", timeout).await.unwrap(),
            AuthState::SignedIn { methods: vec![] }
        );
        let signed_out = config(acp(&[&codex("out", "Not logged in", 1), "app-server"], &home));
        assert!(matches!(
            auth_state(&signed_out, "codex", timeout).await.unwrap(),
            AuthState::Required { .. }
        ));
        // A failure that is not Codex's own "Not logged in" says nothing about a sign-in.
        let broken =
            config(acp(&[&codex("err", "Error loading config.toml", 1), "app-server"], &home));
        assert!(auth_state(&broken, "codex", timeout).await.is_err());
        // The fake answers nothing but `login status` with that CODEX_HOME.
        let wrong_home = config(acp(&[&codex("home", "Logged in", 0), "app-server"], &[]));
        assert!(auth_state(&wrong_home, "codex", timeout).await.is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn codex_bridge_status_keeps_the_launch_global_options() {
        let store = "cli_auth_credentials_store=\"keyring\"";
        let codex = fake_codex(
            "globals",
            &format!("-c {store} --profile=work login status"),
            "/tmp/acpmux-login-codex-home",
            "Logged in using ChatGPT",
            0,
        );
        let cfg = config(acp(
            &[&codex, "-c", store, "--profile=work", "app-server", "--listen", "stdio://"],
            &[("CODEX_HOME", "/tmp/acpmux-login-codex-home")],
        ));
        assert_eq!(
            auth_state(&cfg, "codex", Duration::from_secs(5)).await.unwrap(),
            AuthState::SignedIn { methods: vec![] }
        );
    }

    #[tokio::test]
    async fn codex_bridge_login_keeps_the_launch_global_options() {
        let cfg = config(acp(
            &["/opt/bin/codex", "--enable", "x", "-c", "k=v", "--profile=work", "app-server"],
            &[],
        ));
        let (outcome, ran) = ran(&cfg, None).await;
        assert_eq!(outcome.unwrap(), "codex: signed in");
        let want = ["/opt/bin/codex", "--enable", "x", "-c", "k=v", "--profile=work", "login"];
        assert_eq!(ran, vec![want.map(String::from).to_vec()]);
    }

    #[tokio::test]
    async fn codex_bridge_login_expands_paths_like_the_launch() {
        let home = dirs::home_dir().unwrap_or_default().to_string_lossy().into_owned();
        let mut cfg = config(acp(&["codex", "app-server"], &[("CODEX_HOME", "~/.codex-work")]));
        let mut defaults = crate::config::SessionDefaults::default();
        defaults.env.insert("CODEX_PATH".into(), "${home}/bin/codex".into());
        cfg.defaults.insert("codex".into(), defaults);
        let ran = ran_with_env(&cfg).await;
        assert_eq!(ran.len(), 1);
        let (argv, env) = &ran[0];
        assert_eq!(argv, &vec![format!("{home}/bin/codex"), "login".to_owned()]);
        assert_eq!(env.get("CODEX_HOME"), Some(&format!("{home}/.codex-work")));
        assert_eq!(env.get("CODEX_PATH"), Some(&format!("{home}/bin/codex")));
    }

    /// A `${file:…}` reference reads the path after `${home}` is expanded,
    /// as the launch does (`hub::spawn` expands, `agent::command` resolves).
    #[cfg(unix)]
    #[test]
    fn codex_bridge_expands_paths_before_reading_references() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("acpmux-login-refs-{}", std::process::id()));
        std::fs::create_dir_all(home.join(".secrets")).unwrap();
        let key = home.join(".secrets/openai");
        std::fs::write(&key, "sk-test\n").unwrap();
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).unwrap();
        let cfg = config(acp(
            &["codex", "app-server"],
            &[("OPENAI_API_KEY", "${file:${home}/.secrets/openai}")],
        ));
        let codex =
            codex_cli_at(&cfg, "codex", &cfg.harnesses["codex"], std::path::Path::new("/"), &home)
                .unwrap();
        assert_eq!(codex.env.get("OPENAI_API_KEY").map(String::as_str), Some("sk-test"));
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn codex_globals_stop_at_app_server() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(codex_globals(&args(&["app-server"])).is_empty());
        assert_eq!(
            codex_globals(&args(&["-c", "a=b", "--enable=x", "-p", "w", "app-server", "--x"])),
            &args(&["-c", "a=b", "--enable=x", "-p", "w"])[..]
        );
    }
}
