//! `acpmux account sign-in|sign-out|switch|remove|list|readiness`: the subscription and GitHub accounts this
//! machine's agents run on, through the daemon's `_acpmux/account/*` methods (Leo, 2026-11-22:
//! "this is simply logins, done righr").
//!
//! - `sign-in --account ID`: sign that account in again; `--family codex|claude|github`: add
//!   one (`--name` names it). Prints the link and code, then waits for the browser; Ctrl-C
//!   cancels, and a cancelled add leaves nothing behind. Claude asks for the code it shows on
//!   its page: paste it here.
//! - `sign-out ID`: the CLI's own logout in the account's home; the account stays listed.
//! - `switch ID`: make it its family's default (GitHub: gh's active account).
//! - `remove ID`: drop its route (its login folder stays), or sign it out of gh.
//! - `list`: every account, from `_acpmux/accounts`.
//! - `readiness`: GitHub, Codex and Claude each installed, signed in, and on which account.

use std::io::{BufRead as _, IsTerminal as _, Write as _};

use anyhow::{Result, bail};
use clap::Subcommand;
use serde_json::{Value, json};

use crate::cli::output::print_json;
use crate::rpc::method;

#[derive(Subcommand, Debug, PartialEq, Eq)]
pub enum AccountCmd {
    /// Sign in: an account again (`--account ID`) or a new one (`--family codex|claude|github`).
    #[command(name = "sign-in")]
    SignIn {
        /// The account to sign in again (an id from `acpmux account list`).
        #[arg(long, conflicts_with = "family")]
        account: Option<String>,
        /// Add a new account of this family: codex, claude or github.
        #[arg(long, required_unless_present = "account")]
        family: Option<String>,
        /// The new account's name (default: "ChatGPT 2", "Claude 2", ...).
        #[arg(long, conflicts_with = "account")]
        name: Option<String>,
    },
    /// Sign an account out (its CLI's own logout); it stays listed.
    #[command(name = "sign-out")]
    SignOut { id: String },
    /// Make an account its family's default (GitHub: gh's active account).
    Switch { id: String },
    /// Remove an account: its route goes and its login folder stays; GitHub: gh signs it out.
    Remove { id: String },
    /// Every account: id, family, name, signed in, default.
    #[command(alias = "ls")]
    List,
    /// Whether GitHub, Codex and Claude are installed and signed in, and on which account.
    Readiness,
}

pub async fn run(cmd: AccountCmd, json_out: bool) -> Result<()> {
    let client = crate::daemon::connect(true).await?;
    match cmd {
        AccountCmd::SignIn { account, family, name } => {
            let mut params = serde_json::Map::new();
            for (key, value) in [("account", account), ("family", family), ("name", name)] {
                if let Some(v) = value {
                    params.insert(key.to_owned(), json!(v));
                }
            }
            let params = Value::Object(params);
            let started = client.request(method::MUX_ACCOUNT_SIGN_IN, params).await?;
            let Some(login_id) = started.get("loginId").and_then(Value::as_str).map(str::to_owned)
            else {
                bail!("the daemon started no sign-in");
            };
            show_start(&started, json_out);
            let code = if flag(&started, "needsCode") { Some(read_code(json_out)?) } else { None };
            let finish = json!({"loginId": login_id, "code": code});
            let done = tokio::select! {
                done = client.request(method::MUX_ACCOUNT_SIGN_IN_FINISH, finish) => done?,
                _ = tokio::signal::ctrl_c() => {
                    let _ = client
                        .request(method::MUX_ACCOUNT_SIGN_IN_CANCEL, json!({"loginId": login_id}))
                        .await;
                    bail!("sign-in cancelled");
                }
            };
            if json_out {
                print_json(&done);
            } else if flag(&done, "signedIn") {
                println!("signed in: {}", text(&done, "account").unwrap_or("(account)"));
            } else {
                bail!("not signed in");
            }
            Ok(())
        }
        AccountCmd::SignOut { id } => {
            let reply =
                client.request(method::MUX_ACCOUNT_SIGN_OUT, json!({"account": id})).await?;
            if json_out {
                print_json(&reply);
            } else {
                println!("{id} signed out");
            }
            Ok(())
        }
        AccountCmd::Switch { id } => {
            let reply = client.request(method::MUX_ACCOUNT_SWITCH, json!({"account": id})).await?;
            if json_out {
                print_json(&reply);
            } else {
                println!("{id} is now the default");
            }
            Ok(())
        }
        AccountCmd::Remove { id } => {
            let reply = client.request(method::MUX_ACCOUNT_REMOVE, json!({"account": id})).await?;
            if json_out {
                print_json(&reply);
            } else {
                println!("{id} removed");
            }
            Ok(())
        }
        AccountCmd::Readiness => {
            let reply = client.request(method::MUX_ACCOUNT_READINESS, json!({})).await?;
            if json_out {
                print_json(&reply);
                return Ok(());
            }
            for line in readiness_lines(&reply) {
                println!("{line}");
            }
            Ok(())
        }
        AccountCmd::List => {
            let reply = client.request(method::MUX_ACCOUNTS, json!({})).await?;
            if json_out {
                print_json(&reply);
                return Ok(());
            }
            for row in rows(&reply) {
                println!("{row}");
            }
            Ok(())
        }
    }
}

/// The link and code to show, on stderr when `--json` keeps stdout for the result.
fn show_start(started: &Value, json_out: bool) {
    let mut lines = Vec::new();
    if let Some(url) = text(started, "url") {
        lines.push(format!("Open {url}"));
    }
    if let Some(code) = text(started, "userCode") {
        lines.push(format!("and enter the code {code}"));
    }
    if flag(started, "needsCode") {
        lines.push("then paste the code the page shows here.".to_owned());
    } else {
        lines.push("Waiting for the browser (Ctrl-C cancels)...".to_owned());
    }
    let text = lines.join("\n");
    if json_out {
        eprintln!("{text}");
    } else {
        println!("{text}");
    }
}

fn read_code(json_out: bool) -> Result<String> {
    let stdin = std::io::stdin();
    if stdin.is_terminal() {
        if json_out {
            eprint!("code: ");
        } else {
            print!("code: ");
        }
        let _ = std::io::stdout().flush();
    }
    let mut line = String::new();
    stdin.lock().read_line(&mut line)?;
    let code = line.trim().to_owned();
    if code.is_empty() {
        bail!("no code given");
    }
    Ok(code)
}

/// One line per account: id, family, name, signed in, default.
pub fn rows(reply: &Value) -> Vec<String> {
    let list = reply.get("accounts").unwrap_or(reply);
    list.as_array()
        .into_iter()
        .flatten()
        .map(|a| {
            let signed = match a.get("signedIn").and_then(Value::as_bool) {
                Some(true) => "signed in",
                Some(false) => "signed out",
                None => "",
            };
            format!(
                "{:<28} {:<7} {:<24} {:<10}{}",
                text(a, "id").unwrap_or_default(),
                text(a, "family").unwrap_or_default(),
                text(a, "name").unwrap_or_default(),
                signed,
                if flag(a, "default") { " default" } else { "" },
            )
        })
        .collect()
}

fn text<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

fn flag(v: &Value, key: &str) -> bool {
    v.get(key).and_then(Value::as_bool) == Some(true)
}

/// One line per provider: family, what it needs, and the account it is ready on.
pub fn readiness_lines(reply: &Value) -> Vec<String> {
    reply
        .get("providers")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|p| {
            let state = match text(p, "state") {
                Some("ready") => "ready",
                Some("signInRequired") => "sign-in required",
                Some("notInstalled") => "not installed",
                Some(other) => other,
                None => "",
            };
            let on = match (text(p, "label"), text(p, "account")) {
                (Some(label), Some(id)) => format!("  {label} ({id})"),
                (None, Some(id)) => format!("  {id}"),
                _ => String::new(),
            };
            format!("{:<7} {state}{on}", text(p, "family").unwrap_or_default())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readiness_reads_one_line_per_provider() {
        let reply = json!({"providers": [
            {"family": "github", "state": "ready", "account": "github:bob", "label": "bob"},
            {"family": "codex", "state": "signInRequired"},
            {"family": "claude", "state": "notInstalled"},
        ]});
        assert_eq!(
            readiness_lines(&reply),
            [
                "github  ready  bob (github:bob)",
                "codex   sign-in required",
                "claude  not installed"
            ]
        );
    }
}
