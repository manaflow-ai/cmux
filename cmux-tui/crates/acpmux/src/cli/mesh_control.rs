//! Explicit mesh lifecycle commands. They enqueue once and show a receipt; the daemon's
//! shared mesh client owns authentication, transport and execution status.
//!
//! A start always names its permission policy. With no `--policy` it takes the policy the
//! starter runs under (the session this shell runs in, `ACPMUX_SESSION_ID`): its own, else the
//! daemon default it follows, and approve-all when it runs in a mode that skips every approval.
//! Run outside a session, it is refused and names the flag. A start with none got the remote
//! daemon's default, `ask`, and sat on its first tool call with nobody shown the prompt: eight
//! lanes on a GCP host waited over an hour that way (2026-11-12). The owner's side refuses a
//! start with no policy too (`server/mesh_relay.rs`).

use crate::cli::command::SessionCmd;
use crate::rpc::method;
use anyhow::{Result, bail};
use clap::Args;
use serde_json::{Value, json};

#[derive(Args)]
pub struct StartArgs {
    /// Name for the new session on the destination daemon.
    pub name: String,
    /// Machine in the mesh address book (it need not be one you added). `--host` still works.
    #[arg(long = "machine", alias = "host", value_name = "MACHINE")]
    pub host: String,
    /// HARNESS[/MODEL], for example codex/gpt-6-astra.
    #[arg(long, short, visible_alias = "harness")]
    pub model: Option<String>,
    /// Absolute folder on the destination machine.
    #[arg(long)]
    pub cwd: Option<String>,
    #[arg(long)]
    pub preset: Option<String>,
    #[arg(long)]
    pub policy: Option<String>,
    #[arg(long)]
    pub mode: Option<String>,
    #[arg(long)]
    pub effort: Option<String>,
    /// Reuse this key when retrying an uncertain enqueue. Printed with the receipt.
    #[arg(long)]
    pub idempotency_key: Option<String>,
}

#[derive(Args)]
pub struct RouteArgs {
    /// Use the mesh hub instead of this daemon's local/peer session resolver.
    #[arg(long)]
    pub mesh: bool,
    /// Treat TARGET as an exact session id (UUID ids are recognized automatically). Without
    /// `--mesh` an id already resolves as one, so the flag changes nothing there; it is taken
    /// so `session stop --id ID` works as `session stop ID` does.
    #[arg(long)]
    pub id: bool,
    /// Reuse this key when retrying an uncertain enqueue.
    #[arg(long, requires = "mesh")]
    pub idempotency_key: Option<String>,
}

fn target(key: &str, id: bool) -> Value {
    if id || uuid::Uuid::parse_str(key).is_ok() {
        json!({"sessionId": key})
    } else if let Some((host, name)) = key.split_once('/') {
        json!({"name": name, "host": host})
    } else {
        json!({"name": key})
    }
}

/// The policy a start names when `--policy` is left out: the starter's effective one, from its
/// `_acpmux/info` (`info`). `enforcement.policy` is the policy it runs, capped to ask while full
/// access is off on its machine (`hub/views.rs` `enforcement`); the stored `policy` is read only
/// from an info that has no `enforcement`. A mode that skips every approval (`hub/start_mode.rs`
/// `FULL_ACCESS_MODES`) is approve-all, unless full access is off there or the policy denies
/// (deny-all, review): then the stricter one is sent. `None` when `info` names none.
///
/// `effective` says the daemon lists [`crate::hub::views::EFFECTIVE_POLICY_FEATURE`]. An older
/// daemon reports a stored approve-all uncapped while it enforces ask, so from it nothing looser
/// than ask is copied: deny-all and review stay, anything else is sent as ask.
pub(crate) fn starter_policy(info: &Value, effective: bool) -> Option<String> {
    use crate::config::PermissionPolicy;
    let policy = info
        .pointer("/enforcement/policy")
        .and_then(Value::as_str)
        .or_else(|| info.get("policy").and_then(Value::as_str))
        .and_then(|p| p.parse::<PermissionPolicy>().ok());
    if !effective {
        return Some(match policy {
            Some(p @ (PermissionPolicy::DenyAll | PermissionPolicy::Review)) => p.to_string(),
            _ => PermissionPolicy::Ask.to_string(),
        });
    }
    let full_access_off = info
        .pointer("/enforcement/detail")
        .and_then(Value::as_str)
        .is_some_and(|d| d.contains(crate::hub::views::FULL_ACCESS_OFF_NOTE));
    let mode = info.get("currentModeId").and_then(Value::as_str);
    let full_access_mode =
        mode.is_some_and(|m| crate::hub::start_mode::FULL_ACCESS_MODES.contains(&m));
    let denies = matches!(policy, Some(PermissionPolicy::DenyAll | PermissionPolicy::Review));
    if full_access_mode && !full_access_off && !denies {
        return Some(PermissionPolicy::ApproveAll.to_string());
    }
    policy.map(|p| p.to_string())
}

/// The refusal for a start that names no policy and runs in no session to take one from.
const NO_POLICY: &str = "mesh start needs --policy (ask, approve-reads, approve-edits, \
     approve-all, deny-all or review): run outside a session, it has no starter's policy to \
     take, and a session started with none waits on its first tool call for a person who is \
     not shown it";

fn request(command: SessionCmd, inherited: Option<String>) -> Result<Value> {
    let (op, to, params, key) = match command {
        SessionCmd::Start(mut args) => {
            if args.policy.is_none() {
                args.policy = Some(inherited.ok_or_else(|| anyhow::anyhow!(NO_POLICY))?);
            }
            let mut meta = json!({"name": args.name});
            if let Some(model) = args.model {
                let (harness, model) = crate::cli::orchestrate::split_target(&model);
                meta["harness"] = json!(harness);
                if let Some(model) = model {
                    meta["model"] = json!(model);
                }
            }
            for (field, value) in [
                ("preset", args.preset),
                ("policy", args.policy),
                ("mode", args.mode),
                ("effort", args.effort),
            ] {
                if let Some(value) = value {
                    meta[field] = json!(value);
                }
            }
            let mut params = json!({"mcpServers": [], "_meta": {"acpmux": meta}});
            if let Some(cwd) = args.cwd {
                params["cwd"] = json!(cwd);
            }
            ("start", json!({"host": args.host}), params, args.idempotency_key)
        }
        SessionCmd::Resume { session, mesh, .. } if mesh.mesh => {
            ("resume", target(&session, mesh.id), Value::Null, mesh.idempotency_key)
        }
        SessionCmd::Stop { session, purge, mesh, condition } if mesh.mesh => {
            if purge {
                bail!("mesh stop keeps the stored session; --purge is unsupported");
            }
            // Clap refuses the pair first; kept so no caller sends a conditional stop as a plain one.
            if condition.if_idle {
                bail!(
                    "mesh stop cannot carry --if-idle; run `acpmux session stop NAME --if-idle` on \
                     the session's host"
                );
            }
            ("stop", target(&session, mesh.id), Value::Null, mesh.idempotency_key)
        }
        SessionCmd::Receipt { message_id } => return Ok(json!({"receipt": message_id})),
        _ => bail!("not a mesh lifecycle command"),
    };
    let key = key.unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
    Ok(json!({"op": op, "to": to, "params": params, "idempotencyKey": key}))
}

pub async fn run(command: SessionCmd, json_out: bool) -> Result<()> {
    // The daemon keeps its token. The CLI uses only its normal local socket.
    let client = crate::daemon::connect(true).await?;
    let inherited = match &command {
        SessionCmd::Start(args) if args.policy.is_none() => {
            match std::env::var("ACPMUX_SESSION_ID").ok().filter(|id| !id.trim().is_empty()) {
                Some(id) => {
                    let info = client
                        .request(method::MUX_INFO, json!({"sessionId": id, "waitLogs": false}))
                        .await?;
                    let effective =
                        client.daemon_lists(crate::hub::views::EFFECTIVE_POLICY_FEATURE);
                    let policy = starter_policy(&info, effective);
                    if let Some(p) = &policy {
                        eprintln!("mesh start: no --policy given; taking this session's: {p}");
                    }
                    policy
                }
                None => None,
            }
        }
        _ => None,
    };
    let request = request(command, inherited)?;
    let reply = match client.request(method::MUX_MESH_CONTROL, request.clone()).await {
        Ok(reply) => reply,
        Err(error) => {
            if let Some(key) = request["idempotencyKey"].as_str() {
                return Err(error.context(format!(
                    "mesh enqueue key {key}; reuse --idempotency-key {key} if retrying"
                )));
            }
            return Err(error);
        }
    };
    if json_out {
        crate::cli::output::print_json(&reply);
    } else {
        println!(
            "{} {}",
            reply["messageId"].as_str().unwrap_or("?"),
            reply["state"].as_str().unwrap_or("unknown")
        );
        if let Some(key) = reply["idempotencyKey"].as_str() {
            println!("idempotency key: {key}");
        }
        if let Some(detail) = reply["detail"].as_str() {
            println!("{detail}");
        }
    }
    if matches!(reply["state"].as_str(), Some("refused" | "expired")) {
        bail!(
            "mesh control {}: {}",
            reply["state"],
            reply["detail"].as_str().unwrap_or("no detail")
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::command::{Cli, Command, flatten};
    use clap::Parser;

    fn parse(args: &[&str]) -> Value {
        let command = Cli::try_parse_from(args).unwrap().command.unwrap();
        let Command::Session(command) = flatten(command) else {
            panic!("mesh command flattened away")
        };
        request(command, None).unwrap()
    }

    fn start_without_policy(inherited: Option<&str>) -> Result<Value> {
        let command = Cli::try_parse_from([
            "acpmux",
            "session",
            "start",
            "lane",
            "--machine",
            "worker",
            "-m",
            "claude",
        ])
        .unwrap()
        .command
        .unwrap();
        let Command::Session(command) = flatten(command) else { panic!("flattened away") };
        request(command, inherited.map(str::to_owned))
    }

    /// 2026-11-12: eight mesh-started lanes sat over an hour on their first permission prompt
    /// (the remote default, ask) on a GCP host. A start with no --policy takes the starter's,
    /// and with no starter it is refused, never sent policy-less.
    #[test]
    fn a_start_without_policy_takes_the_starters_or_is_refused() {
        let start = start_without_policy(Some("approve-all")).unwrap();
        assert_eq!(start["params"]["_meta"]["acpmux"]["policy"], "approve-all");
        let refused = start_without_policy(None).unwrap_err().to_string();
        assert!(refused.contains("--policy"), "{refused}");
    }

    #[test]
    fn the_starters_policy_counts_its_mode() {
        // The helper that started the stuck lanes: daemon default ask, in bypassPermissions.
        let bypass = json!({"policy": null, "currentModeId": "bypassPermissions",
                            "enforcement": {"policy": "ask"}});
        assert_eq!(starter_policy(&bypass, true).as_deref(), Some("approve-all"));
        let own = json!({"policy": "approve-edits", "currentModeId": "default",
                         "enforcement": {"policy": "approve-edits"}});
        assert_eq!(starter_policy(&own, true).as_deref(), Some("approve-edits"));
        let default = json!({"policy": null, "currentModeId": "default",
                             "enforcement": {"policy": "deny-all"}});
        assert_eq!(starter_policy(&default, true).as_deref(), Some("deny-all"));
        assert_eq!(starter_policy(&json!({"policy": "bogus"}), true), None);
        assert_eq!(starter_policy(&json!({}), true), None);
    }

    /// Review P1 (#41877): a starter with its own restriction (ask, approve-reads, approve-edits)
    /// may run in a full-access mode, because the policy gate still holds that policy there
    /// (#38809). A start copies the restriction; it never makes up approve-all from the mode,
    /// which would hand the remote session unrestricted tool execution.
    #[test]
    fn an_explicit_policy_in_a_full_access_mode_is_kept() {
        for mode in crate::hub::start_mode::FULL_ACCESS_MODES {
            for own in ["ask", "approve-reads", "approve-edits"] {
                let info = json!({"policy": own, "currentModeId": mode,
                    "enforcement": {"policy": own,
                                    "detail": format!("claude mode {mode}; acpmux policy {own}")}});
                assert_eq!(starter_policy(&info, true).as_deref(), Some(own), "{mode} {own}");
            }
            let all = json!({"policy": "approve-all", "currentModeId": mode,
                             "enforcement": {"policy": "approve-all"}});
            assert_eq!(starter_policy(&all, true).as_deref(), Some("approve-all"), "{mode}");
            // Following the daemon default (no policy of its own), the mode still counts.
            let default = json!({"policy": null, "currentModeId": mode,
                "enforcement": {"policy": "ask",
                    "detail": format!("claude mode {mode}; acpmux policy ask (the daemon default)")}});
            assert_eq!(starter_policy(&default, true).as_deref(), Some("approve-all"), "{mode}");
            let absent = json!({"currentModeId": mode, "enforcement": {"policy": "ask"}});
            assert_eq!(starter_policy(&absent, true).as_deref(), Some("approve-all"), "{mode}");
        }
    }

    /// Review F1 (#41877): with full access off (MDM or a team policy) a stored approve-all runs
    /// as ask, and a mode that skips approvals does not run; the start sends the stricter policy.
    #[test]
    fn full_access_off_sends_the_capped_policy() {
        let off = crate::hub::views::FULL_ACCESS_OFF_NOTE;
        let capped = json!({"policy": "approve-all", "currentModeId": "default",
            "enforcement": {"policy": "ask",
                            "detail": format!("claude mode default; acpmux policy ask{off}")}});
        assert_eq!(starter_policy(&capped, true).as_deref(), Some("ask"));
        let bypass_capped = json!({"policy": null, "currentModeId": "bypassPermissions",
            "enforcement": {"policy": "ask",
                            "detail": format!("claude mode bypassPermissions; acpmux policy ask{off}")}});
        assert_eq!(starter_policy(&bypass_capped, true).as_deref(), Some("ask"));
        // A policy that denies stays stricter than a full-access mode.
        let deny = json!({"currentModeId": "bypassPermissions",
                          "enforcement": {"policy": "deny-all", "detail": ""}});
        assert_eq!(starter_policy(&deny, true).as_deref(), Some("deny-all"));
    }

    /// Review F1 (#41877, second round): a daemon on base code (no `effectivePolicy` at
    /// initialize) answers info with the stored approve-all and no cap note even while it
    /// enforces ask under the MDM cap. From it nothing looser than ask is copied.
    #[test]
    fn a_daemon_without_effective_policy_gets_ask() {
        let base_daemon = json!({"policy": "approve-all", "currentModeId": "default",
            "enforcement": {"policy": "approve-all",
                            "detail": "claude mode default; acpmux policy approve-all"}});
        assert_eq!(starter_policy(&base_daemon, false).as_deref(), Some("ask"));
        let bypass = json!({"policy": null, "currentModeId": "bypassPermissions",
                            "enforcement": {"policy": "ask"}});
        assert_eq!(starter_policy(&bypass, false).as_deref(), Some("ask"));
        let edits = json!({"policy": "approve-edits", "enforcement": {"policy": "approve-edits"}});
        assert_eq!(starter_policy(&edits, false).as_deref(), Some("ask"));
        // Stricter than ask stays.
        let deny = json!({"policy": "deny-all", "enforcement": {"policy": "deny-all"}});
        assert_eq!(starter_policy(&deny, false).as_deref(), Some("deny-all"));
        assert_eq!(starter_policy(&json!({}), false).as_deref(), Some("ask"));
    }

    #[test]
    fn mesh_cli_keeps_start_policy_and_exact_recipients() {
        let start = parse(&[
            "acpmux",
            "session",
            "start",
            "review",
            "--machine",
            "worker",
            "-m",
            "codex/gpt-6-astra",
            "--policy",
            "ask",
            "--cwd",
            "/remote",
            "--idempotency-key",
            "start-test",
        ]);
        assert_eq!(start["op"], "start");
        assert_eq!(start["to"], json!({"host": "worker"}));
        assert_eq!(start["params"]["_meta"]["acpmux"]["policy"], "ask");
        assert_eq!(start["params"]["_meta"]["acpmux"]["harness"], "codex");
        let stop = parse(&["acpmux", "session", "stop", "worker/review", "--mesh"]);
        assert_eq!(stop["to"], json!({"host": "worker", "name": "review"}));
        let resume = parse(&["acpmux", "session", "resume", "stable-id", "--mesh", "--id"]);
        assert_eq!(resume["to"], json!({"sessionId": "stable-id"}));
        let receipt = parse(&["acpmux", "session", "receipt", "msg_test"]);
        assert_eq!(receipt, json!({"receipt": "msg_test"}));
    }

    /// `session stop --id ID` and `session resume --id ID` need no `--mesh`: they run as the
    /// positional forms do, on this daemon's resolver.
    #[test]
    fn id_without_mesh_runs_the_local_command() {
        let local = |args: &[&str]| flatten(Cli::try_parse_from(args).unwrap().command.unwrap());
        let id = "0b7e7c2e-6f43-4a51-9d0e-2a4c3b1f5e6d";
        for argv in [
            &["acpmux", "session", "stop", "--id", id][..],
            &["acpmux", "session", "stop", id, "--id"][..],
            &["acpmux", "session", "kill", "--id", id, "--purge"][..],
        ] {
            match local(argv) {
                Command::Kill { session, purge, condition } => {
                    assert_eq!(session, id, "{argv:?}");
                    assert_eq!(purge, argv.contains(&"--purge"), "{argv:?}");
                    // Without --if-idle the stop is the plain one, as before.
                    assert_eq!(condition, crate::cli::command::StopIf::default(), "{argv:?}");
                }
                _ => panic!("{argv:?} did not run the local stop"),
            }
        }
        match local(&["acpmux", "session", "resume", "--id", id]) {
            Command::ResumeQueue { session, .. } => assert_eq!(session, id),
            _ => panic!("resume --id did not run the local resume"),
        }
        // `--idempotency-key` is still a mesh-only flag.
        assert!(
            Cli::try_parse_from(["acpmux", "session", "stop", id, "--idempotency-key", "k"])
                .is_err()
        );
        // With --mesh, --id still names the exact id.
        let stop = parse(&["acpmux", "session", "stop", "stable-id", "--mesh", "--id"]);
        assert_eq!(stop["to"], json!({"sessionId": "stable-id"}));
    }

    /// `session stop --if-idle [--expect-revision REV]` runs the local stop with its condition;
    /// a revision needs --if-idle, and the mesh hub's stop takes neither.
    #[test]
    fn if_idle_runs_the_local_stop_with_its_condition() {
        use crate::cli::command::StopIf;
        let local = |args: &[&str]| flatten(Cli::try_parse_from(args).unwrap().command.unwrap());
        let condition = |args: &[&str]| match local(args) {
            Command::Kill { condition, .. } => condition,
            _ => panic!("{args:?} did not run the local stop"),
        };
        assert_eq!(
            condition(&[
                "acpmux",
                "session",
                "stop",
                "lane",
                "--if-idle",
                "--expect-revision",
                "42"
            ]),
            StopIf { if_idle: true, expect_revision: Some(42) }
        );
        assert_eq!(
            condition(&["acpmux", "session", "stop", "lane", "--if-idle", "--purge"]),
            StopIf { if_idle: true, expect_revision: None }
        );
        assert_eq!(condition(&["acpmux", "session", "stop", "lane"]), StopIf::default());
        for argv in [
            &["acpmux", "session", "stop", "lane", "--expect-revision", "42"][..],
            &["acpmux", "session", "stop", "lane", "--mesh", "--if-idle"][..],
            &["acpmux", "session", "stop", "lane", "--if-idle", "--expect-revision", "-1"][..],
        ] {
            assert!(Cli::try_parse_from(argv).is_err(), "{argv:?} parsed");
        }
    }
}
