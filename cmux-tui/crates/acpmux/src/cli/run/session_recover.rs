//! `acpmux session recover SESSION`: death routing for a dead chat on this machine
//! (`cmux_supervise_core::route`). It reads this daemon's placement verdict (`_acpmux/place`, the
//! same one `new --host auto` and `session move --host auto` weigh), decides restart, move or
//! successor, and runs a restart or a move. A successor, a wait or a hand-off is the caller's: the
//! product names it and why, and starts nothing. A fleet calls this instead of deciding itself.

use super::*;
use cmux_supervise_core::route::{Cause, Facts, Route, route};

pub(crate) use crate::cli::command::RecoverArgs;

/// The facts for one dead chat from `place` (`_acpmux/place`'s verdict) and the registry.
/// `source`: the peer the chat lives on (its routed id's `HOST/`), or `None` for this machine.
pub(super) fn facts(
    place: &Value,
    registry: Option<&Value>,
    args: &RecoverArgs,
    source: Option<&str>,
) -> Facts {
    let mut hosts = place.get("hosts").and_then(Value::as_array).cloned().unwrap_or_default();
    let named = |h: &Value, name: &str| {
        h["name"]
            .as_str()
            .is_some_and(|n| crate::placement::canonical(n) == crate::placement::canonical(name))
    };
    let local = match source {
        Some(src) => hosts.iter().find(|h| named(h, src)).cloned(),
        None => hosts.iter().find(|h| h["local"] == true).cloned(),
    };
    // Never a move back onto its own host.
    if let Some(src) = source {
        hosts.retain(|h| !named(h, src));
    }
    let local = local.as_ref();
    // Its own host takes one more chat only when placement would put new work there.
    let host_room = local.is_some_and(|h| h["ok"] == true);
    let me = local.and_then(|h| h["name"].as_str()).or(source).unwrap_or_default();
    let on_demand = crate::placement::machine(registry, me).is_some_and(|m| m["on_demand"] == true);
    let (targets, _) =
        crate::placement::move_targets::ranked(&hosts, &Default::default(), |name| {
            if crate::placement::interactive(registry, name) {
                return Some("a person works at it".to_owned());
            }
            crate::placement::auto_move_refusal(registry, name)
        });
    Facts {
        cause: if args.network { Cause::Network } else { Cause::Died },
        host_down_ms: None,
        host_bound_ms: 0,
        has_record: true,
        on_demand,
        host_room,
        targets,
        restarts: args.restarts,
        max_restarts: args.max_restarts,
        move_failed: args.move_failed,
    }
}

pub(super) async fn run(args: RecoverArgs, json_out: bool) -> Result<()> {
    let client = connect(true).await?;
    let id = resolve_id(&client, &args.session).await?;
    let place =
        client.request("_acpmux/place", json!({"work": "agent", "outdatedOk": true})).await?;
    let registry = crate::placement::load_registry();
    // A chat on a peer reads `HOST/ID`: its host's room decides, and a move runs `--from` it.
    let (source, bare) = match id.split_once('/') {
        Some((host, bare)) => (Some(host.to_owned()), bare.to_owned()),
        None => (None, id.clone()),
    };
    let facts = facts(&place, registry.as_ref(), &args, source.as_deref());
    let decided = route(&facts);
    let mut out = serde_json::to_value(&decided)?;
    cmux_json::JsonSet::set(&mut out, "session", json!(id));
    cmux_json::JsonSet::set(&mut out, "facts", serde_json::to_value(&facts)?);
    cmux_json::JsonSet::set(&mut out, "dryRun", json!(args.dry_run));
    let line = match &decided {
        Route::Move { to, .. } => format!("move to {to}: {}", decided.why()),
        Route::Restart { .. } => format!("restart in place: {}", decided.why()),
        Route::Wait { .. } => format!("wait: {}", decided.why()),
        Route::Successor { .. } => format!("successor: {}", decided.why()),
        Route::HandOff { .. } => format!("hand off: {}", decided.why()),
    };
    // The route is printed before it runs: a move prints its own result after it.
    if json_out {
        print_json(&out);
    } else {
        println!("{line}");
    }
    if args.dry_run {
        return Ok(());
    }
    match decided {
        Route::Restart { .. } => {
            let v = client
                .request(method::MUX_SESSIONS_RESTART_HARNESS, json!({"sessions": [id]}))
                .await?;
            if let Some(error) = v.pointer("/errors/0/error").and_then(Value::as_str) {
                return Err(anyhow!("the agent did not start again: {error}"));
            }
            Ok(())
        }
        Route::Move { to, .. } => {
            let move_args = super::session_move::MoveArgs {
                sessions: vec![bare],
                host: to,
                all_idle: false,
                interrupt: false,
                after_turn: false,
                turn_timeout: super::session_move::DEFAULT_TURN_TIMEOUT,
                leave_dirty: false,
                carry_changes: false,
                cwd: None,
                dry_run: false,
                resume_there: false,
                from: source,
            };
            super::session_move::run(move_args, json_out).await
        }
        // Not this machine's to start: the error's detail `recover_not_here` tells a caller "decided,
        // yours" from a failure.
        Route::Successor { .. } | Route::HandOff { .. } | Route::Wait { .. } => {
            Err(crate::cli::errors::AppError::new(
                crate::cli::errors::Code::Runtime,
                "recover_not_here",
                line,
            )
            .into())
        }
    }
}

#[cfg(test)]
#[path = "session_recover_tests.rs"]
mod tests;
