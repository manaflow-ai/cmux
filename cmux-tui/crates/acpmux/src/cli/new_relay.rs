//! `newRelay` (config.json): the command `acpmux new --machine HOST` hands the start to when this
//! daemon refuses it because HOST names no peer.
//!
//! The analogue of `sendRelay` (`cli/send_relay.rs`) for starting a session. An agent VM may have
//! no peer link to the other machines, yet a placer command there can still start a session on
//! one, say through a broker the driving machine keeps a connection to. With
//! `"newRelay": {"argv": ["placer", "new"]}` the CLI runs `placer new --machine HOST WORDS...`,
//! WORDS being the caller's other `new` words verbatim and in order (its `--machine`/`--host`
//! left out), with stdin, stdout and stderr inherited, and exits with the command's status.
//! `--json` captures its stdout and prints `{"machine", "status": "relayed"|"refused",
//! "relayed", "exit", "output"}`, as a relayed send does.
//!
//! Only the daemon's no-peer refusal relays (`RpcError::no_peer`): a peer that is configured but
//! down is refused as always, and `--machine auto`, `auto-build`, `local` or this machine's own
//! name never relay. The relay runs with `ACPMUX_NEW_RELAYED=1`, and a `new` that sees it set never
//! relays again, so a relay that calls `acpmux new --machine HOST` back cannot loop. With no
//! `newRelay` nothing changes.

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::cli::send_relay::Relayed;
use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use tokio::time::Instant;

pub use crate::config::NewRelay;

/// Set on the relay's process; a `new` that sees it set never relays.
pub(crate) const RELAYED_ENV: &str = "ACPMUX_NEW_RELAYED";

/// The relay config.json names, if any. Read on its own: a `new` loads no profiles for it.
pub(crate) fn configured() -> Option<NewRelay> {
    configured_in(&crate::config::Config::path())
}

fn configured_in(path: &Path) -> Option<NewRelay> {
    let text = std::fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let relay = value.get("newRelay").filter(|v| !v.is_null())?;
    match serde_json::from_value::<NewRelay>(relay.clone()) {
        Ok(relay) if relay.argv.first().is_some_and(|p| !p.trim().is_empty()) => Some(relay),
        Ok(_) => {
            eprintln!("acpmux: newRelay in {} has no argv; not relaying", path.display());
            None
        }
        Err(e) => {
            eprintln!(
                "acpmux: newRelay in {} is not {{\"argv\": [...]}} ({e}); not relaying",
                path.display()
            );
            None
        }
    }
}

/// Whether a `new --machine HOST` that `error` refused goes to the relay: HOST names another
/// machine (not `auto`, `auto-build`, `local` or one of `own`, this machine's names), the
/// daemon refused it because HOST names no peer ([`no_such_peer`]), and this process is not
/// itself a relay's (`relayed`, the value of [`RELAYED_ENV`]).
pub(crate) fn should_relay(
    host: &str,
    error: &anyhow::Error,
    own: &[&str],
    relayed: Option<&str>,
) -> bool {
    relayed.is_none_or(|v| v.trim().is_empty())
        && names_another_machine(host, own)
        && no_such_peer(error, host)
}

/// The relay and its args for a `new --machine HOST` that `error` refused, when it goes to the
/// relay ([`should_relay`]) and config.json names one.
pub(crate) fn for_refusal(
    host: Option<&str>,
    error: &anyhow::Error,
) -> Option<(NewRelay, String, Vec<String>)> {
    let host = host?;
    let own = crate::pairing::machine_name();
    let relayed = std::env::var(RELAYED_ENV).ok();
    if !should_relay(host, error, &[&own, crate::hub::host_label()], relayed.as_deref()) {
        return None;
    }
    let relay = configured()?;
    let args = relay_args(crate::cli::entry::original_args()?, host);
    Some((relay, host.to_owned(), args))
}

fn names_another_machine(host: &str, own: &[&str]) -> bool {
    let host = host.trim();
    !host.is_empty()
        && host != "local"
        && crate::placement::Work::of_host(host).is_none()
        && !own.iter().any(|o| !o.is_empty() && host.eq_ignore_ascii_case(o))
}

/// The daemon refused the start because `host` names no peer of it: `RpcError::no_peer`, or
/// the same refusal from a daemon older than its `data.reason`. A peer that is down is a peer.
pub(crate) fn no_such_peer(e: &anyhow::Error, host: &str) -> bool {
    let Some(d) = e.downcast_ref::<crate::client::DaemonError>() else { return false };
    let data = d.0.data.as_ref();
    match data.and_then(|v| v.get("reason")).and_then(Value::as_str) {
        Some(reason) => {
            reason == crate::rpc::NO_PEER
                && data.and_then(|v| v.get("peer")).and_then(Value::as_str) == Some(host)
        }
        None => d.0.code == -32002 && d.0.message == format!("no peer {host:?}"),
    }
}

/// What the relay is given after its own argv: `--machine HOST`, then the caller's `new` words
/// (`original`, the command line without the program) verbatim and in order, without the global
/// flags before the command word, the command word itself, or `--machine`/`--host` and its value.
/// Words after a `--` are all kept.
pub(crate) fn relay_args(original: &[String], host: &str) -> Vec<String> {
    let mut words = original.iter().skip_while(|w| *w == "--json" || *w == "--suppress-reads");
    // The command word (`new`, or an alias such as `run`).
    words.next();
    let mut out = vec!["--machine".to_owned(), host.to_owned()];
    let mut literal = false;
    let mut skip_value = false;
    for word in words {
        if literal {
            out.push(word.clone());
        } else if skip_value {
            skip_value = false;
        } else if word == "--" {
            literal = true;
            out.push(word.clone());
        } else if word == "--machine" || word == "--host" {
            skip_value = true;
        } else if !(word.starts_with("--machine=") || word.starts_with("--host=")) {
            out.push(word.clone());
        }
    }
    out
}

/// Run the relay with `args` ([`relay_args`]) and [`RELAYED_ENV`] set: stdin and stderr
/// inherited, stdout too unless `capture` (then kept in an unnamed file and returned). Run from
/// a terminal it stays in the terminal's group, so it may read from it and Ctrl-C reaches it
/// (`cmux_process::Command::spawn`). Past `deadline` it is ended (with its group, when it leads
/// one) and the error is a timeout.
pub(crate) fn relay_with_deadline(
    relay: &NewRelay,
    args: &[String],
    capture: bool,
    deadline: Option<Instant>,
) -> Result<Relayed> {
    use std::io::{Read, Seek};
    let (program, own) = relay.argv.split_first().ok_or_else(|| anyhow!("newRelay has no argv"))?;
    let mut out = if capture { Some(tempfile::tempfile().context("the new relay")?) } else { None };
    let mut cmd = cmux_process::Command::new(crate::cli::send_relay::find_relay_program(program)?);
    cmd.args(own)
        .args(args)
        .env(RELAYED_ENV, "1")
        .stdin(cmux_process::Stdio::inherit())
        .stderr(cmux_process::Stdio::inherit());
    match &out {
        Some(file) => cmd.stdout(file.try_clone().context("the new relay")?),
        None => cmd.stdout(cmux_process::Stdio::inherit()),
    };
    let mut child = cmd.spawn().with_context(|| format!("cannot run the new relay {program:?}"))?;
    let status = match deadline {
        None => child.wait().context("the new relay")?,
        Some(deadline) => {
            let left = deadline.saturating_duration_since(Instant::now());
            // Dropped while it runs, the child ends (`cmux_process::Child`).
            child.wait_timeout(left).context("the new relay")?.ok_or_else(|| {
                anyhow::Error::from(AppError::timeout("the new relay exceeded its caller deadline"))
            })?
        }
    };
    let output = match out.as_mut() {
        Some(file) => {
            let mut bytes = Vec::new();
            file.rewind().and_then(|()| file.read_to_end(&mut bytes)).context("the new relay")?;
            Some(String::from_utf8_lossy(&bytes).trim_end().to_owned())
        }
        None => None,
    };
    Ok(Relayed { status: status.code().unwrap_or(1), output, stderr: None })
}

/// `acpmux new --machine HOST` that this daemon refused because HOST names no peer, with a relay
/// configured: run it, and exit with its status (a refusal is an error that exits with it).
pub(crate) async fn start(
    relay: NewRelay,
    host: &str,
    args: Vec<String>,
    json_out: bool,
    deadline: Option<Instant>,
) -> Result<()> {
    if !json_out {
        eprintln!("acpmux: no peer {host:?} here; handing the new session to the new relay");
    }
    let done =
        tokio::task::spawn_blocking(move || relay_with_deadline(&relay, &args, json_out, deadline))
            .await
            .context("the new relay")??;
    if json_out {
        print_json(&json!({
            "machine": host,
            "status": if done.status == 0 { "relayed" } else { "refused" },
            "relayed": done.status == 0,
            "exit": done.status,
            "output": done.output,
        }));
    }
    let _ = std::io::stdout().flush();
    if done.status != 0 {
        let refused =
            format!("the new relay refused the session on {host:?} (exit {})", done.status);
        return Err(AppError::new(Code::Runtime, "relay_refused", refused)
            .with_exit(done.status)
            .into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::DaemonError;
    use crate::rpc::RpcError;

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|w| (*w).to_owned()).collect()
    }

    fn refused(e: RpcError) -> anyhow::Error {
        DaemonError(e).into()
    }

    #[test]
    fn only_a_machine_no_peer_names_relays_and_never_from_a_relay() {
        let own = ["lane-vm", "lane-vm"];
        let no_peer = refused(RpcError::no_peer("far"));
        assert!(should_relay("far", &no_peer, &own, None));
        assert!(should_relay("far", &no_peer, &own, Some("")));
        // A relay's own `new` never relays again.
        assert!(!should_relay("far", &no_peer, &own, Some("1")));
        // Placement words and this machine are never relayed.
        for host in ["auto", "auto-build", "local", "lane-vm", "LANE-VM", ""] {
            let e = refused(RpcError::no_peer(host));
            assert!(!should_relay(host, &e, &own, None), "{host}");
        }
        // The refusal must name this host.
        assert!(!should_relay("other", &no_peer, &own, None));
        // A peer that is known but down, or any other failure, is not relayed.
        let down = refused(RpcError::internal("peer \"far\" is not connected"));
        assert!(!should_relay("far", &down, &own, None));
        let unreachable = refused(
            RpcError::new(-32000, "far is unreachable")
                .with_data(json!({"reason": "peer_unreachable", "peer": "far"})),
        );
        assert!(!should_relay("far", &unreachable, &own, None));
        assert!(!should_relay("far", &anyhow!("no peer \"far\""), &own, None));
        // An older daemon's refusal, with no reason: the exact words.
        assert!(should_relay("far", &refused(RpcError::not_found("no peer \"far\"")), &own, None));
        assert!(!should_relay(
            "far",
            &refused(RpcError::not_found("no peer \"far\"; connect it")),
            &own,
            None
        ));
    }

    #[test]
    fn the_relay_gets_the_machine_then_the_callers_other_new_words_in_order() {
        let original = words(&[
            "--json",
            "new",
            "-n",
            "x",
            "--machine",
            "far",
            "-d",
            "fix the bug",
            "--reuse",
        ]);
        assert_eq!(
            relay_args(&original, "far"),
            words(&["--machine", "far", "-n", "x", "-d", "fix the bug", "--reuse"])
        );
        let original = words(&["new", "--host=far", "-m", "codex", "--", "--machine", "far"]);
        assert_eq!(
            relay_args(&original, "far"),
            words(&["--machine", "far", "-m", "codex", "--", "--machine", "far"])
        );
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("acpmux-new-relay-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_relay_is_read_from_config_json_and_absent_means_none() {
        let dir = scratch("config");
        let path = dir.join("config.json");
        assert_eq!(configured_in(&path), None);
        std::fs::write(&path, r#"{"sendRelay": {"argv": ["relay", "send"]}}"#).unwrap();
        assert_eq!(configured_in(&path), None);
        std::fs::write(&path, r#"{"newRelay": {"argv": ["placer", "new"]}}"#).unwrap();
        assert_eq!(
            configured_in(&path),
            Some(NewRelay { argv: vec!["placer".into(), "new".into()] })
        );
        std::fs::write(&path, r#"{"newRelay": {"argv": []}}"#).unwrap();
        assert_eq!(configured_in(&path), None);
        std::fs::write(&path, r#"{"newRelay": "placer new"}"#).unwrap();
        assert_eq!(configured_in(&path), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn the_relay_gets_its_args_and_the_guard_and_its_status_is_ours() {
        let dir = scratch("run");
        let script = dir.join("placer");
        let seen = dir.join("seen");
        crate::test_exec::write_executable(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s|' \"$@\" \"${{{env}-unset}}\" > {seen}\n[ \"$3\" = refuse ] && exit 5\necho started\n",
                env = RELAYED_ENV,
                seen = seen.display()
            ),
        );
        let relay = NewRelay { argv: vec![script.display().to_string(), "new".into()] };
        let done =
            relay_with_deadline(&relay, &words(&["--machine", "far", "-d", "hi"]), true, None)
                .unwrap();
        assert_eq!(done.status, 0);
        assert_eq!(done.output.as_deref(), Some("started"));
        assert_eq!(std::fs::read_to_string(&seen).unwrap(), "new|--machine|far|-d|hi|1|");
        let done =
            relay_with_deadline(&relay, &words(&["--machine", "refuse"]), true, None).unwrap();
        assert_eq!(done.status, 5);
        let missing = NewRelay { argv: vec![dir.join("absent").display().to_string()] };
        assert!(relay_with_deadline(&missing, &[], true, None).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
