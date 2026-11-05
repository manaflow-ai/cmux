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
//! `--attach` is refused rather than relayed without its files. The MCP `send` tool relays the
//! same way (`acpmux_mcp_send.rs`), and every relayed send is a line in the cross-host audit log
//! (`xhost_audit.rs`).
//!
//! `"lsArgv": ["relay", "sessions"]` is how such a host sees the other machines' sessions: `acpmux
//! ls` (and the MCP `ls` tool) runs it, reads `{"sessions": [...]}` from its stdout, and lists every
//! row whose `peer` names another machine beside this host's own, so `HOST/NAME` is found before
//! it is sent to. A relay that fails or is slow costs a warning, never the local list.
//! Leo, 2026-11-05, on sends between lane machines: "Just do what's expected. Just do the magic."

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::cli::sender::FROM_ENV;
use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use tokio::time::Instant;

/// `sendRelay`: the relay command's argv; the CLI appends the session and `-`. `lsArgv`, when
/// set, prints the other machines' live sessions as `{"sessions": [...]}` (see the module doc).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct SendRelay {
    pub argv: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ls_argv: Option<Vec<String>>,
}

/// How long a relay listing may take before `ls` goes on without it.
pub(crate) const LS_DEADLINE: std::time::Duration = std::time::Duration::from_secs(20);

/// The other machines' sessions the relay's `lsArgv` lists: rows whose `peer` is a machine name
/// other than this one's, at most `LS_MAX_ROWS`. `Ok(None)` when no `lsArgv` is configured.
pub(crate) fn relay_ls(relay: &SendRelay, deadline: Option<Instant>) -> Result<Option<Vec<Value>>> {
    let Some((program, args)) = relay.ls_argv.as_deref().and_then(<[String]>::split_first) else {
        return Ok(None);
    };
    let mut cmd = Command::new(program);
    cmd.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    let child = cmd.spawn().with_context(|| format!("cannot run the relay listing {program:?}"))?;
    let deadline = deadline.unwrap_or_else(|| Instant::now() + LS_DEADLINE);
    let done = crate::cli::bounded_child::wait(child, None, Some(deadline), "the relay listing")
        .map_err(|e| anyhow!("the relay listing {program:?}: {e}"))?;
    if !done.status.success() {
        return Err(anyhow!(
            "the relay listing {program:?} exited {}",
            done.status.code().unwrap_or(1)
        ));
    }
    let value: Value = serde_json::from_slice(&done.stdout)
        .with_context(|| format!("the relay listing {program:?} printed no JSON"))?;
    let own = crate::pairing::machine_name();
    let rows = value
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("the relay listing {program:?} printed no sessions list"))?;
    Ok(Some(
        rows.iter()
            .filter(|r| {
                r.get("peer")
                    .and_then(Value::as_str)
                    .is_some_and(|p| !p.is_empty() && p != "local" && !p.eq_ignore_ascii_case(&own))
                    && r.get("sessionId").and_then(Value::as_str).is_some()
            })
            .take(LS_MAX_ROWS)
            .cloned()
            .collect(),
    ))
}

/// At most this many rows from one relay listing.
const LS_MAX_ROWS: usize = 5000;

/// The other machines' sessions the configured relay lists (`relay_ls`, off the async runtime),
/// or none: no relay, no `lsArgv`, or a listing that failed, which is said on stderr unless
/// `quiet`.
pub(crate) async fn relay_rows(quiet: bool) -> Vec<Value> {
    let Some(relay) = configured().filter(|r| r.ls_argv.is_some()) else { return Vec::new() };
    match tokio::task::spawn_blocking(move || relay_ls(&relay, None)).await {
        Ok(Ok(Some(rows))) => rows,
        Ok(Ok(None)) => Vec::new(),
        Ok(Err(e)) => {
            if !quiet {
                eprintln!("acpmux: other machines' sessions are not listed: {e}");
            }
            Vec::new()
        }
        Err(e) => {
            if !quiet {
                eprintln!("acpmux: other machines' sessions are not listed: {e}");
            }
            Vec::new()
        }
    }
}

/// `rows` (this daemon's list) with `far` (the relay's) added, none twice: a peer row this
/// daemon lists already, by its machine and session id. How many were added.
pub(crate) fn merge_rows(rows: &mut Vec<Value>, far: Vec<Value>) -> usize {
    let key = |r: &Value| {
        (
            r.get("peer").and_then(Value::as_str).unwrap_or_default().to_owned(),
            r.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned(),
        )
    };
    let mut seen: std::collections::HashSet<_> = rows.iter().map(key).collect();
    let before = rows.len();
    rows.extend(far.into_iter().filter(|r| seen.insert(key(r))));
    rows.len() - before
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

/// The cross-host audit line of one relayed send (`xhost_audit.rs`), never its text: `sent`
/// when the relay took it, `refused` when it exited non-zero (nothing crossed machines).
pub(crate) fn audit_sent(session: &str, text: &str, from: Option<&str>, done: &Relayed) {
    crate::xhost_audit::record(
        if done.status == 0 { "sent" } else { "refused" },
        json!({"via": "sendRelay", "to": session, "from": from, "bytes": text.len(),
               "exit": done.status, "delivery": done.output.as_deref().map(str::trim)}),
    );
}

/// What the relay did.
#[derive(Debug, PartialEq)]
pub(crate) struct Relayed {
    /// Its exit status (1 when a signal ended it).
    pub status: i32,
    /// Its stdout, when captured (`--json`).
    pub output: Option<String>,
    /// Its stderr, when captured (with stdout): a refusal's reason, for a caller with no
    /// terminal of its own (the MCP `send` tool) or to print it after the JSON.
    pub stderr: Option<String>,
}

/// Run a relay while respecting the caller's absolute deadline. The child is
/// put in its own process group so expiry can only terminate this command and
/// any descendants it started.
pub(crate) fn relay_with_deadline(
    relay: &SendRelay,
    session: &str,
    text: &str,
    from: Option<&str>,
    capture: bool,
    deadline: Option<Instant>,
) -> Result<Relayed> {
    let (program, args) =
        relay.argv.split_first().ok_or_else(|| anyhow!("sendRelay has no argv"))?;
    let mut cmd = Command::new(program);
    cmd.args(args)
        .arg(session)
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(if capture { Stdio::piped() } else { Stdio::inherit() })
        .stderr(if capture { Stdio::piped() } else { Stdio::inherit() });
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    match from {
        Some(from) => cmd.env(FROM_ENV, from),
        None => cmd.env_remove(FROM_ENV),
    };
    let child = cmd.spawn().with_context(|| format!("cannot run the send relay {program:?}"))?;
    // Written beside the wait, so a relay that answers before reading it all never blocks us.
    let done = crate::cli::bounded_child::wait(
        child,
        Some(text.as_bytes().to_owned()),
        deadline,
        "the send relay",
    )
    .map_err(|e| -> anyhow::Error {
        if e.kind() == std::io::ErrorKind::TimedOut {
            AppError::timeout(format!(
                "the send relay for {session:?} exceeded its caller deadline"
            ))
            .into()
        } else {
            anyhow::Error::new(e).context("the send relay")
        }
    })?;
    let (status, output, stderr) = (done.status, done.stdout, done.stderr);
    let written = done.written.unwrap_or_else(|| Err(std::io::Error::other("no stdin")));
    let status = status.code().unwrap_or(1);
    // A relay that stopped reading and still said yes was not handed the whole message; its own
    // refusal stays its status.
    if status == 0
        && let Err(e) = written
    {
        return Err(anyhow!("the send relay {program:?} did not read the whole message: {e}"));
    }
    Ok(Relayed {
        status,
        output: capture.then(|| String::from_utf8_lossy(&output).trim_end().to_owned()),
        stderr: capture.then(|| String::from_utf8_lossy(&stderr).trim_end().to_owned()),
    })
}

/// `acpmux send` to a target nobody here resolves, with a relay configured: run it, print what
/// it printed and exit with its status (a refusal is an error that exits with it).
pub(crate) fn send_with_deadline(
    config: &SendRelay,
    session: &str,
    text: &str,
    from: Option<&str>,
    attachments: bool,
    json_out: bool,
    deadline: Option<Instant>,
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
    let done = relay_with_deadline(config, session, text, from, json_out, deadline)?;
    audit_sent(session, text, from, &done);
    if let Some(said) = done.stderr.as_deref().filter(|s| !s.is_empty()) {
        eprintln!("{said}");
    }
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

    #[test]
    fn merged_rows_are_each_listed_once_by_machine_and_id() {
        let row = |peer: &str, id: &str| json!({"peer": peer, "sessionId": id});
        let mut rows = vec![row("hostb", "a")];
        let far = vec![row("hostb", "a"), row("hostb", "b"), row("hostb", "b"), row("hostc", "b")];
        assert_eq!(merge_rows(&mut rows, far), 2);
        assert_eq!(rows, vec![row("hostb", "a"), row("hostb", "b"), row("hostc", "b")]);
    }

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
            Some(SendRelay { argv: vec!["relay".into(), "send".into()], ls_argv: None })
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
        let dir = scratch("run");
        let script = dir.join("relay");
        let seen = dir.join("seen");
        crate::test_exec::write_executable(
            &script,
            format!(
                "#!/bin/sh\n{{ printf '%s|' \"$1\" \"$2\" \"$3\" \"${{ACPMUX_FROM-unset}}\"; cat; }} > {}\n[ \"$2\" = refuse ] && {{ echo refused >&2; exit 7; }}\necho delivery-42\n",
                seen.display()
            ),
        );
        let config =
            SendRelay { argv: vec![script.display().to_string(), "send".into()], ls_argv: None };

        let done =
            relay_with_deadline(&config, "lane-b", "hello\nthere", Some("vm/lane"), true, None)
                .unwrap();
        assert_eq!(done.status, 0);
        assert_eq!(done.output.as_deref(), Some("delivery-42"));
        assert_eq!(std::fs::read_to_string(&seen).unwrap(), "send|lane-b|-|vm/lane|hello\nthere");

        let done = relay_with_deadline(&config, "refuse", "x", None, true, None).unwrap();
        assert_eq!(done.status, 7);
        assert_eq!(std::fs::read_to_string(&seen).unwrap(), "send|refuse|-|unset|x");

        // One that stops reading early and exits 0 did not take the message.
        let early = dir.join("early");
        crate::test_exec::write_executable(
            &early,
            "#!/bin/sh\nexec 0<&-\nsleep 1\necho delivery-0\n",
        );
        let early = SendRelay { argv: vec![early.display().to_string()], ls_argv: None };
        let big = "x".repeat(1 << 20);
        let e = relay_with_deadline(&early, "lane-b", &big, None, true, None).unwrap_err();
        assert!(e.to_string().contains("did not read the whole message"), "{e}");

        let missing =
            SendRelay { argv: vec![dir.join("absent").display().to_string()], ls_argv: None };
        assert!(relay_with_deadline(&missing, "lane-b", "x", None, true, None).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_relayed_send_with_attachments_is_refused() {
        let config = SendRelay { argv: vec!["/nonexistent/relay".into()], ls_argv: None };
        let e = send_with_deadline(&config, "lane-b", "x", None, true, true, None).unwrap_err();
        assert_eq!(e.downcast_ref::<AppError>().map(|a| a.code), Some(Code::Usage));
        assert!(e.to_string().contains("text only"), "{e}");
    }
}
