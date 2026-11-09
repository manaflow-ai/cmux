//! `acpmux bridge connect|send|inbox` (`desktop_bridge.rs`): connect Claude Desktop and Codex
//! Desktop to cmux, and message them from a shell or a cmux session.
//!
//! `connect` registers the `cmux-bridge` MCP server (`acpmux bridge mcp --as APP`,
//! `acpmux_mcp_bridge.rs`) through each harness's own CLI (`codex mcp add`, `claude mcp add-json
//! --scope user`), which Codex Desktop and Claude Code desktop read, and in the Claude Desktop
//! app's `claude_desktop_config.json` when that app is installed. acpmux never edits Codex's
//! `config.toml` or Claude Code's `.claude.json` itself (`trust.rs`). A server already named
//! `cmux-bridge` that does not run `bridge mcp --as` is someone else's and is never replaced.

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

use crate::acpmux_mcp::bridge::SERVER_NAME;
use crate::desktop_bridge::{self, App, Bridge};

#[derive(Subcommand)]
pub enum BridgeCmd {
    /// Add the cmux bridge to Claude Desktop and Codex Desktop, so each can message the other and
    /// every cmux session. Restart the app after.
    Connect {
        /// claude, codex, or both when left out.
        app: Option<String>,
        /// Print what it would run and write, change nothing.
        #[arg(long)]
        dry_run: bool,
    },
    /// Leave a message for Claude Desktop or Codex Desktop; its agent reads it with the bridge's
    /// inbox tool.
    Send {
        /// claude-desktop or codex-desktop.
        to: String,
        /// Who it is from (default: this session's name, or what this shell names).
        #[arg(long)]
        from: Option<String>,
        /// The message.
        #[arg(required = true)]
        text: Vec<String>,
    },
    /// Read the messages left for Claude Desktop or Codex Desktop, and mark them read.
    Inbox {
        /// claude-desktop or codex-desktop.
        app: String,
        /// Leave them unread.
        #[arg(long)]
        peek: bool,
    },
    /// The MCP server `connect` adds (run by the apps, not by people).
    #[command(hide = true)]
    Mcp {
        #[arg(long = "as")]
        app: String,
    },
}

pub async fn run(cmd: BridgeCmd, json_out: bool) -> Result<()> {
    match cmd {
        BridgeCmd::Connect { app, dry_run } => {
            let apps = match app.as_deref() {
                None => desktop_bridge::APPS.to_vec(),
                Some(word) => vec![named(word)?],
            };
            let mut steps = Vec::new();
            for app in apps {
                steps.extend(connect(app, dry_run).await);
            }
            if json_out {
                println!("{}", serde_json::to_string_pretty(&json!({"steps": steps}))?);
            } else {
                for step in &steps {
                    println!("{}", step.get("text").and_then(Value::as_str).unwrap_or_default());
                }
            }
            if steps.iter().all(|s| s.get("ok") == Some(&Value::Bool(false))) {
                bail!("nothing was connected");
            }
            Ok(())
        }
        BridgeCmd::Send { to, from, text } => {
            let to = named(&to)?;
            let from = match from {
                Some(from) => from,
                None => sender().await,
            };
            let message = Bridge::current().send(&from, to, &text.join(" "))?;
            if json_out {
                println!("{}", serde_json::to_string_pretty(&message)?);
            } else {
                println!("Left for {} ({}).", to.name, message.id);
            }
            Ok(())
        }
        BridgeCmd::Inbox { app, peek } => {
            let app = named(&app)?;
            let (messages, more) = Bridge::current().inbox(app, !peek)?;
            if json_out {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&json!({"messages": messages, "more": more}))?
                );
            } else {
                println!("{}", desktop_bridge::inbox_text(app, &messages, more));
            }
            Ok(())
        }
        BridgeCmd::Mcp { app } => crate::acpmux_mcp::bridge::run(&app).await,
    }
}

fn named(word: &str) -> Result<App> {
    desktop_bridge::app(word)
        .with_context(|| format!("unknown app {word:?}: claude-desktop or codex-desktop"))
}

/// Who a `send` with no `--from` is from: `ACPMUX_FROM`, this session's name, what an agent
/// harness's shell names (`cli/sender.rs`), else this machine's terminal.
async fn sender() -> String {
    if let Some(from) = std::env::var(crate::cli::sender::FROM_ENV).ok().filter(|v| !v.is_empty()) {
        return from;
    }
    if let Ok(id) = std::env::var(crate::acpmux_mcp::SESSION_ENV)
        && let Ok(daemon) = crate::daemon::connect(false).await
        && let Ok(info) =
            daemon.request(crate::rpc::method::MUX_INFO, json!({"sessionId": id})).await
        && let Some(name) = info.get("name").and_then(Value::as_str).filter(|n| !n.is_empty())
    {
        return name.to_owned();
    }
    crate::cli::sender::of_this_process()
        .unwrap_or_else(|| format!("a terminal on {}", crate::host_pressure::host_name()))
}

/// The server's command line: this acpmux binary and its prefix (`self_command.rs`: in the cmux
/// app's multicall binary, which an `acpmux` link resolves to, it is `cmux acp …`), then
/// `bridge mcp --as APP`.
fn server_argv(app: App) -> Result<Vec<String>> {
    let me = crate::self_command::SelfCommand::current().context("finding the acpmux binary")?;
    let mut argv = vec![me.exe.to_string_lossy().into_owned()];
    argv.extend(me.args_lossy(&["bridge", "mcp", "--as", app.address]));
    Ok(argv)
}

/// `ACPMUX_HOME=<this process's home>`, absolute, so the apps read the same mailboxes as this
/// CLI: Codex starts its MCP servers with a short env, an app starts them in another folder, and
/// a tagged build's home is not the default one (`config::set_home_override`).
fn home_env() -> String {
    let home = crate::config::home();
    let home = std::path::absolute(&home).unwrap_or(home);
    format!("ACPMUX_HOME={}", home.display())
}

/// A server entry is ours when it runs `bridge mcp --as`: one `connect` wrote, maybe for an
/// older install. Any other server with our name is left alone.
fn ours(args_text: &str) -> bool {
    args_text.contains("bridge mcp --as")
}

/// Who holds the `cmux-bridge` name in a harness's own config.
#[derive(Debug, PartialEq)]
enum Holder {
    Nobody,
    Us,
    Other,
}

async fn holder(harness: &str) -> Result<Holder> {
    let get = run_cmd(&[harness, "mcp", "get", SERVER_NAME]).await?;
    Ok(match get {
        Err(_) => Holder::Nobody,
        Ok(out) if ours(&out) => Holder::Us,
        Ok(_) => Holder::Other,
    })
}

/// Claude Code's user config, which `claude mcp add --scope user` writes; read only.
fn claude_code_config() -> Option<PathBuf> {
    match std::env::var_os("CLAUDE_CONFIG_DIR").filter(|v| !v.is_empty()) {
        Some(dir) => Some(PathBuf::from(dir).join(".claude.json")),
        None => Some(dirs::home_dir()?.join(".claude.json")),
    }
}

/// Our old entry in Claude Code's user config, to put back if the replacement fails.
fn claude_code_entry() -> Option<Value> {
    let bytes = std::fs::read(claude_code_config()?).ok()?;
    let config: Value = serde_json::from_slice(&bytes).ok()?;
    config.get("mcpServers")?.get(SERVER_NAME).cloned()
}

async fn connect(app: App, dry_run: bool) -> Vec<Value> {
    let argv = match server_argv(app) {
        Ok(argv) => argv,
        Err(e) => return vec![step(false, format!("{}: {e:#}", app.name))],
    };
    let env = home_env();
    let entry = server_entry(&argv, &env);
    let mut steps = vec![if dry_run {
        step(
            true,
            format!(
                "would add {SERVER_NAME} to {} with `{} mcp`: {}",
                app.name,
                app.harness,
                shell_line(&argv)
            ),
        )
    } else {
        match register(app, &argv, &env, &entry).await {
            Ok(text) => step(true, format!("{}: {text}", app.name)),
            Err(e) => step(false, format!("{}: {e:#}", app.name)),
        }
    }];
    if app.harness == "claude" {
        let Some(path) = claude_app_config() else {
            steps.push(json!({"ok": true, "skipped": true, "text": "Claude Desktop app: not installed on this machine; skipped."}));
            return steps;
        };
        steps.push(if dry_run {
            step(true, format!("would add {SERVER_NAME} to {}", path.display()))
        } else {
            match add_to_claude_app_config(&path, &entry) {
                Ok(()) => step(
                    true,
                    format!("Claude Desktop app: added {SERVER_NAME} to {}.", path.display()),
                ),
                Err(e) => step(false, format!("Claude Desktop app: {e:#}")),
            }
        });
    }
    steps
}

/// Adds the server through the harness's own CLI. A `cmux-bridge` that is not ours is never
/// touched; ours is replaced, and for Claude Code (whose `mcp add` refuses a name it has) put back
/// when the replacement fails.
async fn register(app: App, argv: &[String], env: &str, entry: &Value) -> Result<String> {
    let held = holder(app.harness).await?;
    if held == Holder::Other {
        bail!(
            "its `{SERVER_NAME}` server is not cmux's; not changed (`{} mcp remove {SERVER_NAME}` frees the name)",
            app.harness
        );
    }
    if app.harness == "codex" {
        // `codex mcp add` replaces a server of the same name in one write.
        let mut add = vec!["codex", "mcp", "add", SERVER_NAME, "--env", env, "--"];
        add.extend(argv.iter().map(String::as_str));
        run_cmd(&add).await?.map_err(anyhow::Error::msg)?;
        return Ok(format!("added {SERVER_NAME} with `codex mcp add`."));
    }
    let old = if held == Holder::Us { claude_code_entry() } else { None };
    if held == Holder::Us {
        run_cmd(&["claude", "mcp", "remove", "--scope", "user", SERVER_NAME])
            .await?
            .map_err(anyhow::Error::msg)?;
    }
    let json = serde_json::to_string(
        &json!({"type": "stdio", "command": entry.get("command"), "args": entry.get("args"), "env": entry.get("env")}),
    )?;
    let added =
        run_cmd(&["claude", "mcp", "add-json", "--scope", "user", SERVER_NAME, &json]).await?;
    if let Err(e) = added {
        let restored = match &old {
            Some(old) => run_cmd(&[
                "claude",
                "mcp",
                "add-json",
                "--scope",
                "user",
                SERVER_NAME,
                &old.to_string(),
            ])
            .await?
            .is_ok(),
            None => false,
        };
        bail!(
            "`claude mcp add-json` failed: {e}{}",
            if restored { "; the earlier entry is back" } else { "" }
        );
    }
    Ok(format!("added {SERVER_NAME} with `claude mcp add-json --scope user`."))
}

fn step(ok: bool, text: String) -> Value {
    json!({"ok": ok, "text": text})
}

fn shell_line(argv: &[String]) -> String {
    argv.iter()
        .map(|a| if a.contains(' ') { format!("'{a}'") } else { a.clone() })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Runs a harness CLI: `Err` when it cannot start, `Ok(Err(stderr))` when it fails.
async fn run_cmd(argv: &[&str]) -> Result<Result<String, String>> {
    let (program, args) = argv.split_first().context("empty command")?;
    let out = tokio::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .with_context(|| format!("running {program}"))?;
    Ok(if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_owned())
    })
}

/// The Claude Desktop app's config, when the app is installed: its config folder exists, or (a
/// fresh install that has not written one yet) its app bundle does.
fn claude_app_config() -> Option<PathBuf> {
    let dir = dirs::config_dir()?.join("Claude");
    let bundle =
        ["/Applications/Claude.app".into(), dirs::home_dir()?.join("Applications/Claude.app")];
    (dir.is_dir() || bundle.iter().any(|b: &PathBuf| b.is_dir()))
        .then(|| dir.join("claude_desktop_config.json"))
}

fn server_entry(argv: &[String], env: &str) -> Value {
    let (key, value) = env.split_once('=').unwrap_or((env, ""));
    json!({"command": argv.first(), "args": argv.get(1..).unwrap_or_default(), "env": {key: value}})
}

/// Sets `mcpServers.cmux-bridge` in the Claude Desktop app's config, keeping everything else.
fn add_to_claude_app_config(path: &Path, entry: &Value) -> Result<()> {
    let mut config = match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice::<Value>(&bytes)
            .with_context(|| format!("{} is not JSON; not changed", path.display()))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => json!({}),
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    };
    let Some(root) = config.as_object_mut() else {
        bail!("{} is not a JSON object; not changed", path.display());
    };
    let servers = root.entry("mcpServers").or_insert_with(|| json!({}));
    let Some(servers) = servers.as_object_mut() else {
        bail!("mcpServers in {} is not an object; not changed", path.display());
    };
    if let Some(held) = servers.get(SERVER_NAME)
        && !ours(
            &held
                .get("args")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
                .unwrap_or_default(),
        )
    {
        bail!("its `{SERVER_NAME}` server in {} is not cmux's; not changed", path.display());
    }
    servers.insert(SERVER_NAME.to_owned(), entry.clone());
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    let mut bytes = serde_json::to_vec_pretty(&config)?;
    bytes.push(b'\n');
    crate::config::write_atomic(path, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_claude_app_config_gains_the_server_and_keeps_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("claude_desktop_config.json");
        std::fs::write(
            &path,
            r#"{"mcpServers": {"other": {"command": "x"}}, "globalShortcut": "Alt+Space"}"#,
        )
        .unwrap();
        let entry = server_entry(
            &[
                "/opt/acpmux".into(),
                "bridge".into(),
                "mcp".into(),
                "--as".into(),
                "claude-desktop".into(),
            ],
            "ACPMUX_HOME=/h",
        );
        add_to_claude_app_config(&path, &entry).unwrap();
        let config: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(config["globalShortcut"], "Alt+Space");
        assert_eq!(config["mcpServers"]["other"]["command"], "x");
        let ours = &config["mcpServers"][SERVER_NAME];
        assert_eq!(ours["command"], "/opt/acpmux");
        assert_eq!(ours["args"], json!(["bridge", "mcp", "--as", "claude-desktop"]));
        assert_eq!(ours["env"]["ACPMUX_HOME"], "/h");
    }

    #[test]
    fn a_fresh_claude_app_install_gets_its_config_folder_and_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("Claude/claude_desktop_config.json");
        add_to_claude_app_config(&path, &json!({"command": "/opt/acpmux"})).unwrap();
        let config: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(config["mcpServers"][SERVER_NAME]["command"], "/opt/acpmux");
    }

    #[test]
    fn a_cmux_bridge_entry_that_is_not_ours_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("claude_desktop_config.json");
        let theirs =
            r#"{"mcpServers": {"cmux-bridge": {"command": "/opt/other", "args": ["serve"]}}}"#;
        std::fs::write(&path, theirs).unwrap();
        assert!(add_to_claude_app_config(&path, &json!({"command": "/opt/acpmux"})).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), theirs);
        // Ours, from an older install, is replaced.
        let older = r#"{"mcpServers": {"cmux-bridge": {"command": "/old/acpmux", "args": ["bridge", "mcp", "--as", "claude-desktop"]}}}"#;
        std::fs::write(&path, older).unwrap();
        add_to_claude_app_config(&path, &json!({"command": "/new/acpmux"})).unwrap();
        let config: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(config["mcpServers"][SERVER_NAME]["command"], "/new/acpmux");
    }

    #[test]
    fn the_server_runs_this_binary_under_its_prefix() {
        let argv = server_argv(desktop_bridge::APPS[1]).unwrap();
        assert!(argv.ends_with(&[
            "bridge".into(),
            "mcp".into(),
            "--as".into(),
            "codex-desktop".into()
        ]));
        let me = crate::self_command::SelfCommand::current().unwrap();
        assert_eq!(argv[1..argv.len() - 4], me.args_lossy::<&str>(&[])[..]);
        assert!(ours(&argv[1..].join(" ")));
    }

    #[test]
    fn a_claude_app_config_that_is_not_json_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("claude_desktop_config.json");
        std::fs::write(&path, "{ not json").unwrap();
        assert!(add_to_claude_app_config(&path, &json!({})).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
    }
}
