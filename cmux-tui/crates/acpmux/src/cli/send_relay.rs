//! `sendRelay` (config.json): the command `acpmux send` hands a message to when its target names
//! no session here and no peer lists it.
//!
//! Some hosts have no peer that reaches the target: an agent VM that cannot dial back to the
//! machine that drives it. A relay command, e.g. one that hands the message to a broker the
//! driving machine keeps a connection to, still delivers it there. With
//! `"sendRelay": {"argv": ["relay", "send"]}` the CLI runs `relay send SESSION -` with the
//! message on stdin and `ACPMUX_FROM` set to the sender it would have named, prints the
//! command's stdout (its delivery id) and exits with its status.
//!
//! Only the no-session refusal relays: a target here or on a peer, down or not, is sent as
//! always, and with no `sendRelay` nothing changes. The relay carries text only, so a send with
//! `--attach` is refused rather than relayed without its files.

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::cli::sender::FROM_ENV;
use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

/// `sendRelay`: the relay command's argv; the CLI appends the session and `-`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct SendRelay {
    pub argv: Vec<String>,
}

/// The relay config.json names, if any. Read on its own: a send loads no profiles.
pub(crate) fn configured() -> Option<SendRelay> {
    configured_in(&crate::config::Config::path())
}

fn configured_in(path: &Path) -> Option<SendRelay> {
    let text = std::fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let relay = value.get("sendRelay").filter(|v| !v.is_null())?;
    match serde_json::from_value::<SendRelay>(relay.clone()) {
        Ok(relay) if relay.argv.first().is_some_and(|p| !p.trim().is_empty()) => Some(relay),
        Ok(_) => {
            eprintln!("acpmux: sendRelay in {} has no argv; not relaying", path.display());
            None
        }
        Err(e) => {
            eprintln!(
                "acpmux: sendRelay in {} is not {{\"argv\": [...]}} ({e}); not relaying",
                path.display()
            );
            None
        }
    }
}

/// The send was refused because its target names no session here and no peer lists it: the
/// CLI's own no-session error (`run.rs` `resolve_id`, `send_async.rs` `queue`), never a
/// delivery's later failure or `@` outside a session.
pub(crate) fn no_such_session(e: &anyhow::Error) -> bool {
    e.downcast_ref::<AppError>()
        .is_some_and(|a| a.code == Code::NoSession && a.detail == "no_session")
}

/// Uploading `--attach` files that do not fit one message first asks the daemon about the
/// target: with a relay configured, its "no session" answer is the no-session refusal, so the
/// send says the relay carries text only instead of a bare daemon error.
pub(crate) fn attach_error(e: anyhow::Error, relaying: bool, session: &str) -> anyhow::Error {
    let unknown = relaying
        && e.downcast_ref::<crate::client::DaemonError>().is_some()
        && e.to_string().to_lowercase().contains("no session");
    if unknown { AppError::no_session(session).into() } else { e }
}

/// The sender the relay names in `ACPMUX_FROM`: `--from` or `ACPMUX_FROM` outside a session
/// (`named`), else `ACPMUX_FROM`, else the acpmux session this runs in, which its own daemon
/// would have proved; the relay's receiver has no daemon to prove it to.
pub(crate) fn sender(named: Option<&str>, env: impl Fn(&str) -> Option<String>) -> Option<String> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    named
        .map(str::to_owned)
        .or_else(|| set(FROM_ENV))
        .or_else(|| set("ACPMUX_SESSION_ID").and_then(|_| set("ACPMUX_SESSION_NAME")))
}

/// What the relay did.
#[derive(Debug, PartialEq)]
pub(crate) struct Relayed {
    /// Its exit status (1 when a signal ended it).
    pub status: i32,
    /// Its stdout, when captured (`--json`).
    pub output: Option<String>,
}

/// Run the relay for SESSION with TEXT on stdin; `capture` keeps its stdout instead of passing
/// it through.
pub(crate) fn relay(
    relay: &SendRelay,
    session: &str,
    text: &str,
    from: Option<&str>,
    capture: bool,
) -> Result<Relayed> {
    let (program, args) =
        relay.argv.split_first().ok_or_else(|| anyhow!("sendRelay has no argv"))?;
    let mut cmd = Command::new(program);
    cmd.args(args)
        .arg(session)
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(if capture { Stdio::piped() } else { Stdio::inherit() })
        .stderr(Stdio::inherit());
    match from {
        Some(from) => cmd.env(FROM_ENV, from),
        None => cmd.env_remove(FROM_ENV),
    };
    let mut child =
        cmd.spawn().with_context(|| format!("cannot run the send relay {program:?}"))?;
    let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("the send relay has no stdin"))?;
    // Written beside the wait, so a relay that answers before reading it all never blocks us.
    let body = text.as_bytes().to_owned();
    let writer = std::thread::spawn(move || stdin.write_all(&body));
    let out = child.wait_with_output().context("the send relay")?;
    let written = writer.join().unwrap_or_else(|_| Err(std::io::Error::other("writer panicked")));
    let status = out.status.code().unwrap_or(1);
    // A relay that stopped reading and still said yes was not handed the whole message; its own
    // refusal stays its status.
    if status == 0
        && let Err(e) = written
    {
        return Err(anyhow!("the send relay {program:?} did not read the whole message: {e}"));
    }
    Ok(Relayed {
        status,
        output: capture.then(|| String::from_utf8_lossy(&out.stdout).trim_end().to_owned()),
    })
}

/// `acpmux send` to a target nobody here resolves, with a relay configured: run it, print what
/// it printed and exit with its status (a refusal is an error that exits with it).
pub(crate) fn send(
    config: &SendRelay,
    session: &str,
    text: &str,
    from: Option<&str>,
    attachments: bool,
    json_out: bool,
) -> Result<()> {
    if attachments {
        return Err(AppError::usage(format!(
            "no session {session:?} here or on a peer, and the send relay carries text only: send it without --attach"
        ))
        .into());
    }
    if !json_out {
        eprintln!("acpmux: no session {session:?} here or on a peer; handing it to the send relay");
    }
    let done = relay(config, session, text, from, json_out)?;
    if json_out {
        print_json(&json!({
            "target": session,
            "status": if done.status == 0 { "relayed" } else { "refused" },
            "relayed": done.status == 0,
            "exit": done.status,
            "output": done.output,
        }));
    }
    let _ = std::io::stdout().flush();
    if done.status != 0 {
        let refused =
            format!("the send relay refused the message for {session:?} (exit {})", done.status);
        return Err(AppError::new(Code::Runtime, "relay_refused", refused)
            .with_exit(done.status)
            .into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("acpmux-send-relay-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_relay_is_read_from_config_json_and_absent_means_none() {
        let dir = scratch("config");
        let path = dir.join("config.json");
        assert_eq!(configured_in(&path), None);
        std::fs::write(&path, r#"{"harnesses": {}}"#).unwrap();
        assert_eq!(configured_in(&path), None);
        std::fs::write(&path, r#"{"sendRelay": {"argv": ["relay", "send"]}}"#).unwrap();
        assert_eq!(
            configured_in(&path),
            Some(SendRelay { argv: vec!["relay".into(), "send".into()] })
        );
        std::fs::write(&path, r#"{"sendRelay": {"argv": []}}"#).unwrap();
        assert_eq!(configured_in(&path), None);
        std::fs::write(&path, r#"{"sendRelay": "relay send"}"#).unwrap();
        assert_eq!(configured_in(&path), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn only_the_clis_no_session_refusal_relays() {
        assert!(no_such_session(&AppError::no_session("lane").into()));
        // `@` outside a session, and a delivery that failed later with the same words.
        let current = AppError::new(Code::NoSession, "no_current_session", "no current session");
        assert!(!no_such_session(&current.into()));
        assert!(!no_such_session(&anyhow!("unknown session lane")));
        assert!(!no_such_session(&AppError::timeout("timed out").into()));
    }

    #[test]
    fn the_sender_is_the_named_one_else_the_session_this_runs_in() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
        };
        let in_session = env(&[("ACPMUX_SESSION_ID", "s-1"), ("ACPMUX_SESSION_NAME", "lane-a")]);
        assert_eq!(sender(Some("vm/lane"), in_session).as_deref(), Some("vm/lane"));
        assert_eq!(sender(None, in_session).as_deref(), Some("lane-a"));
        assert_eq!(sender(None, env(&[("ACPMUX_SESSION_NAME", "lane-a")])), None);
        let named_in_session = env(&[
            (FROM_ENV, "vm/lane"),
            ("ACPMUX_SESSION_ID", "s-1"),
            ("ACPMUX_SESSION_NAME", "lane-a"),
        ]);
        assert_eq!(sender(None, named_in_session).as_deref(), Some("vm/lane"));
        assert_eq!(sender(None, env(&[])), None);
    }

    #[cfg(unix)]
    #[test]
    fn the_relay_gets_the_session_the_text_and_the_sender_and_its_status_is_ours() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch("run");
        let script = dir.join("relay");
        let seen = dir.join("seen");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\n{{ printf '%s|' \"$1\" \"$2\" \"$3\" \"${{ACPMUX_FROM-unset}}\"; cat; }} > {}\n[ \"$2\" = refuse ] && {{ echo refused >&2; exit 7; }}\necho delivery-42\n",
                seen.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let config = SendRelay { argv: vec![script.display().to_string(), "send".into()] };

        let done = relay(&config, "lane-b", "hello\nthere", Some("vm/lane"), true).unwrap();
        assert_eq!(done, Relayed { status: 0, output: Some("delivery-42".into()) });
        assert_eq!(std::fs::read_to_string(&seen).unwrap(), "send|lane-b|-|vm/lane|hello\nthere");

        let done = relay(&config, "refuse", "x", None, true).unwrap();
        assert_eq!(done.status, 7);
        assert_eq!(std::fs::read_to_string(&seen).unwrap(), "send|refuse|-|unset|x");

        // One that stops reading early and exits 0 did not take the message.
        let early = dir.join("early");
        std::fs::write(&early, "#!/bin/sh\nexec 0<&-\nsleep 1\necho delivery-0\n").unwrap();
        std::fs::set_permissions(&early, std::fs::Permissions::from_mode(0o755)).unwrap();
        let early = SendRelay { argv: vec![early.display().to_string()] };
        let big = "x".repeat(1 << 20);
        let e = relay(&early, "lane-b", &big, None, true).unwrap_err();
        assert!(e.to_string().contains("did not read the whole message"), "{e}");

        let missing = SendRelay { argv: vec![dir.join("absent").display().to_string()] };
        assert!(relay(&missing, "lane-b", "x", None, true).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_relayed_send_with_attachments_is_refused() {
        let config = SendRelay { argv: vec!["/nonexistent/relay".into()] };
        let e = send(&config, "lane-b", "x", None, true, true).unwrap_err();
        assert_eq!(e.downcast_ref::<AppError>().map(|a| a.code), Some(Code::Usage));
        assert!(e.to_string().contains("text only"), "{e}");
    }
}
