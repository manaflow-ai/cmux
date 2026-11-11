//! `session stop NAME…` (also `session kill`): stop the agent of each named session, and with
//! `--purge` delete its log too. Several names are stopped in order, each on its own: one that
//! cannot be stopped (no such session, busy under `--if-idle`, a record that does not read) is
//! reported, and the rest are still stopped (bench round 5, row 11: `session kill --purge A B`
//! was refused, so a cleanup took one call per session).

use crate::cli::command::StopIf;
use crate::cli::errors::{AppError, Code, classify};
use crate::cli::output::print_json;
use crate::client::Client;
use crate::daemon::connect;
use crate::rpc::method;
use anyhow::Result;
use serde_json::{Value, json};

pub(super) async fn run(
    sessions: &[String],
    purge: bool,
    condition: StopIf,
    json_out: bool,
) -> Result<()> {
    // A revision belongs to one session: several names cannot share it.
    if sessions.len() > 1 && condition.expect_revision.is_some() {
        return Err(AppError::usage(
            "--expect-revision names one session's revision: give one session with it",
        )
        .into());
    }
    let client = connect(true).await?;
    // An older daemon would ignore the condition and stop a busy session.
    if condition.if_idle && !client.daemon_lists(crate::hub::stop_if_idle::FEATURE) {
        return Err(AppError::new(
            Code::Runtime,
            "stop_if_idle_unsupported",
            "the running daemon predates `session stop --if-idle`: nothing was stopped; \
             restart it on the installed acpmux, then retry",
        )
        .into());
    }
    let done = if purge { "purged" } else { "closed" };
    // One session: its answer and its error as before, with how to continue it.
    if let [session] = sessions {
        let mut v = stop(&client, session, purge, condition).await?;
        match (purge, json_out) {
            (true, true) => print_json(&v),
            (true, false) => println!("{done}"),
            (false, true) => {
                cmux_json::JsonSet::set(&mut v, "resume", json!(resume(session)));
                print_json(&v)
            }
            (false, false) => println!("{done}; it stays resumable: {}", resume(session)),
        }
        return Ok(());
    }
    let mut rows = Vec::new();
    let mut failed = Vec::new();
    for session in sessions {
        match stop(&client, session, purge, condition).await {
            Ok(v) => {
                if !json_out {
                    if purge {
                        println!("{session}: {done}");
                    } else {
                        println!("{session}: {done}; it stays resumable: {}", resume(session));
                    }
                }
                rows.push(
                    json!({"session": session, "sessionId": v.get("sessionId"), "purged": purge,
                           "resume": (!purge).then(|| resume(session))}),
                );
            }
            Err(e) => {
                let error = classify(&e);
                if !json_out {
                    eprintln!("{session}: {}: {}", error.code.name(), error.message);
                }
                rows.push(json!({"session": session, "error": error.envelope().get("error")}));
                failed.push((session.clone(), error));
            }
        }
    }
    if json_out {
        print_json(&json!({"sessions": rows}));
    }
    let Some((_, first)) = failed.first() else { return Ok(()) };
    // Every failure of one kind exits as that kind (6 when each was busy); a mix exits 1.
    let code =
        if failed.iter().all(|(_, e)| e.code == first.code) { first.code } else { Code::Runtime };
    let names: Vec<&str> = failed.iter().map(|(s, _)| s.as_str()).collect();
    Err(AppError::new(
        code,
        "not_all_stopped",
        format!(
            "{} of {} not {done}: {}; the others were",
            failed.len(),
            sessions.len(),
            names.join(", ")
        ),
    )
    .with_data(json!({"failed": names}))
    .into())
}

/// The command that continues stopped session `session` in the same conversation: a prompt
/// starts its agent again.
fn resume(session: &str) -> String {
    format!("acpmux send {session} \"text\"")
}

/// Stop one session: the daemon's answer, or why it refused.
async fn stop(client: &Client, session: &str, purge: bool, condition: StopIf) -> Result<Value> {
    let id = crate::cli::resolve::control_id(client, session).await?;
    let mut params = json!({"sessionId": id, "purge": purge});
    if condition.if_idle {
        cmux_json::JsonSet::set(&mut params, "ifIdle", json!(true));
    }
    if let Some(rev) = condition.expect_revision {
        cmux_json::JsonSet::set(&mut params, "expectRevision", json!(rev));
    }
    client.request(method::MUX_KILL, params).await
}
