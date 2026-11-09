//! `acpmux bridge connect|send|inbox` (`desktop_bridge.rs`): connect Claude Desktop and Codex
//! Desktop to cmux, and message them from a shell or a cmux session.
//!
//! `connect` registers the `cmux-bridge` MCP server (`acpmux bridge mcp --as APP`,
//! `acpmux_mcp_bridge.rs`) through each harness's own CLI (`codex mcp add`, `claude mcp add
//! --scope user`), which Codex Desktop and Claude Code desktop read, and in the Claude Desktop
//! app's `claude_desktop_config.json` when that app is installed. acpmux never edits Codex's
//! `config.toml` or Claude Code's `.claude.json` itself (`trust.rs`).

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
                    println!("{}", step["text"].as_str().unwrap_or_default());
                }
            }
            if steps.iter().all(|s| s["ok"] == false) {
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
        && let Some(name) = info["name"].as_str().filter(|n| !n.is_empty())
    {
        return name.to_owned();
    }
    crate::cli::sender::of_this_process()
        .unwrap_or_else(|| format!("a terminal on {}", crate::host_pressure::host_name()))
}

/// The server's command line: this binary, `bridge mcp --as APP`.
fn server_argv(app: App) -> Result<Vec<String>> {
    let exe = std::env::current_exe().context("finding the acpmux binary")?;
    Ok(vec![
        exe.to_string_lossy().into_owned(),
        "bridge".into(),
        "mcp".into(),
        "--as".into(),
        app.address.into(),
    ])
}

/// `ACPMUX_HOME` when this process has one, so the apps read the same mailboxes (Codex starts
/// its MCP servers with a short env).
fn home_env() -> Option<String> {
    std::env::var("ACPMUX_HOME").ok().filter(|v| !v.is_empty()).map(|v| format!("ACPMUX_HOME={v}"))
}

async fn connect(app: App, dry_run: bool) -> Vec<Value> {
    let argv = match server_argv(app) {
        Ok(argv) => argv,
        Err(e) => return vec![step(false, format!("{}: {e:#}", app.name))],
    };
    let env = home_env();
    let mut steps = Vec::new();
    let mut add: Vec<String> = match app.harness {
        "codex" => vec!["codex".into(), "mcp".into(), "add".into(), SERVER_NAME.into()],
        _ => vec![
            "claude".into(),
            "mcp".into(),
            "add".into(),
            "--scope".into(),
            "user".into(),
            SERVER_NAME.into(),
        ],
    };
    if let Some(env) = &env {
        add.extend([if app.harness == "codex" { "--env" } else { "-e" }.into(), env.clone()]);
    }
    add.push("--".into());
    add.extend(argv.iter().cloned());
    if dry_run {
        steps.push(step(true, format!("would run: {}", shell_line(&add))));
    } else {
        if app.harness == "claude" {
            // `claude mcp add` refuses a name it has; a reconnect replaces it.
            let _ = run_quiet(&["claude", "mcp", "remove", "--scope", "user", SERVER_NAME]).await;
        }
        steps.push(match run_quiet(&add.iter().map(String::as_str).collect::<Vec<_>>()).await {
            Ok(()) => step(
                true,
                format!("{}: added {SERVER_NAME} with `{} mcp add`.", app.name, app.harness),
            ),
            Err(e) => step(false, format!("{}: `{}` failed: {e:#}", app.name, shell_line(&add))),
        });
    }
    if app.harness == "claude"
        && let Some(path) = claude_app_config()
    {
        let entry = server_entry(&argv, env.as_deref());
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

fn step(ok: bool, text: String) -> Value {
    json!({"ok": ok, "text": text})
}

fn shell_line(argv: &[String]) -> String {
    argv.iter()
        .map(|a| if a.contains(' ') { format!("'{a}'") } else { a.clone() })
        .collect::<Vec<_>>()
        .join(" ")
}

async fn run_quiet(argv: &[&str]) -> Result<()> {
    let (program, args) = argv.split_first().context("empty command")?;
    let out = tokio::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .with_context(|| format!("running {program}"))?;
    if !out.status.success() {
        bail!("{}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

/// The Claude Desktop app's config, when the app has a config folder on this machine.
fn claude_app_config() -> Option<PathBuf> {
    let dir = dirs::config_dir()?.join("Claude");
    dir.is_dir().then(|| dir.join("claude_desktop_config.json"))
}

fn server_entry(argv: &[String], env: Option<&str>) -> Value {
    let mut entry = json!({"command": argv[0], "args": argv[1..]});
    if let Some((key, value)) = env.and_then(|e| e.split_once('=')) {
        entry["env"] = json!({key: value});
    }
    entry
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
    servers.insert(SERVER_NAME.to_owned(), entry.clone());
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
            Some("ACPMUX_HOME=/h"),
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
    fn a_claude_app_config_that_is_not_json_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("claude_desktop_config.json");
        std::fs::write(&path, "{ not json").unwrap();
        assert!(add_to_claude_app_config(&path, &json!({})).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
    }
}
