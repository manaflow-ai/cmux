//! Explicit mesh lifecycle commands. They enqueue once and show a receipt; the daemon's
//! shared mesh client owns authentication, transport and execution status.

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
    #[arg(long, short)]
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

fn request(command: SessionCmd) -> Result<Value> {
    let (op, to, params, key) = match command {
        SessionCmd::Start(args) => {
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
        SessionCmd::Resume { session, mesh } if mesh.mesh => {
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
    let request = request(command)?;
    // The daemon keeps its token. The CLI uses only its normal local socket.
    let client = crate::daemon::connect(true).await?;
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
        request(command).unwrap()
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
            Command::ResumeQueue { session } => assert_eq!(session, id),
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
