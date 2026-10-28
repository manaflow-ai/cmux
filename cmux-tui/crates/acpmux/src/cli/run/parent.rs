//! `acpmux new|run --parent SESSION`: a chat starts a child agent of any harness family (a Claude
//! chat's Codex child) from its shell, as its sub-session (`_acpmux/subsession/start`,
//! `hub/subsessions.rs`), the same one its `start_session` tool makes. The daemon checks that this
//! command may speak for SESSION (its proven caller, or one of the caller's sub-sessions) and
//! holds the child to SESSION's policy and mode. The parent's log gets the child's `subsession`
//! records (`hub/subsession_results.rs`); this command prints the child's reply when its first
//! turn ends, or with `-d` only starts it.

use super::launch::Launch;
use super::*;
use std::sync::Arc;

/// Flags a sub-session start takes no part of, and why.
fn refused_flags(args: &NewArgs) -> Option<String> {
    let flags = [
        (args.host.is_some(), "--host", "a family lives on one daemon"),
        (args.preset.is_some(), "--preset", "the child takes -m and -e"),
        (args.policy.is_some(), "--policy", "the child runs its parent's policy"),
        (args.mode.is_some(), "--mode", "the child starts in the mode its parent's allows"),
        (args.ephemeral, "--ephemeral", "the child stays under its parent's chat"),
        (args.worktree.is_some(), "--worktree", "give --cwd"),
        (args.reuse, "--reuse", "each start makes a new child"),
        (args.group.is_some(), "--group", "the child lists under its parent's chat"),
        (args.prompt_id.is_some(), "--prompt-id", "the daemon sends the first prompt"),
        // `wait` is what a child does: its permissions wait for the person.
        (args.on_permission != "wait", "--on-permission", "the person answers the child's"),
    ];
    let (_, flag, why) = flags.into_iter().find(|(given, _, _)| *given)?;
    Some(format!("--parent takes no {flag}: {why}"))
}

/// The `_acpmux/subsession/start` params of this command, with its first prompt.
fn start_params(args: &NewArgs, parent: &str, prompt: &str) -> Result<Value> {
    let mut p = json!({"parent": parent, "prompt": prompt});
    if let Some(spec) = &args.model {
        let (harness, model) = orchestrate::split_target(spec);
        p["harness"] = json!(harness);
        if let Some(model) = model {
            p["model"] = json!(model);
        }
    }
    if let Some(e) = &args.effort {
        p["effort"] = json!(e);
    }
    if let Some(n) = &args.name {
        p["name"] = json!(n);
    }
    if args.force_admit {
        p["_meta"] = json!({"acpmux": {"forceAdmit": true}});
    }
    // No --cwd: the parent's folder, not this shell's.
    if let Some(cwd) = &args.cwd {
        let abs = if cwd.is_absolute() { cwd.clone() } else { std::env::current_dir()?.join(cwd) };
        p["cwd"] = json!(abs);
    }
    Ok(p)
}

pub(super) async fn run(args: NewArgs, json_out: bool) -> Result<()> {
    if let Some(why) = refused_flags(&args) {
        return Err(errors::AppError::usage(why).into());
    }
    let tags = orchestrate::parse_tags(&args.tags)?;
    let launch = Launch::prepare(&args)?;
    let Some(prompt) = launch.first_prompt(&args, &Value::Null) else {
        return Err(errors::AppError::usage(
            "--parent goes with the child's first prompt: give one or --prompt-file",
        )
        .into());
    };
    let parent = args.parent.clone().unwrap_or_default();
    let client = connect(true).await?;
    let started = client
        .request(method::MUX_SUBSESSION_START, start_params(&args, &parent, &prompt)?)
        .await?;
    let id = started["sessionId"].as_str().unwrap_or_default().to_owned();
    let name = started["name"].as_str().unwrap_or(&id).to_owned();
    if !args.tags.is_empty() {
        client.request(method::MUX_TAG, json!({"sessionId": id, "set": tags})).await?;
    }
    if args.detach {
        if json_out {
            print_json(&started);
        } else {
            println!("started {name} ({}) under {parent}", &id[..8.min(id.len())]);
        }
        return Ok(());
    }
    let row = wait_turn(&client, &id, args.timeout).await?;
    // Masked as the sub-session tools mask what they hand another session's agent; whole, not cut.
    let reply = last_replies(&client, &id, 1).await?.pop().map(|r| crate::secret_scan::mask(&r));
    let last = &row["lastTurn"];
    let (state, error) = turn_end(last);
    if json_out {
        print_json(&json!({
            "sessionId": id, "name": name, "parent": parent, "harness": started["harness"],
            "state": state,
            "result": {"state": state, "turnId": last["turnId"], "stopReason": last["stopReason"],
                       "reply": reply, "error": error},
        }));
    } else if let Some(reply) = &reply {
        println!("{reply}");
    }
    if state == "done" {
        return Ok(());
    }
    // Exit 1, as `acpmux wait` for a failed turn.
    let why = error.unwrap_or_else(|| state.to_owned());
    let e = errors::AppError::new(
        errors::Code::Runtime,
        state,
        format!("{name}'s turn {state}: {why}"),
    );
    Err(e.with_session(&id).into())
}

/// A child's `lastTurn` as its state (`done`, `failed`, `cancelled`) and its error, masked.
fn turn_end(last: &Value) -> (&'static str, Option<String>) {
    let state = match last["status"].as_str() {
        Some("completed") => "done",
        Some("cancelled") => "cancelled",
        _ => "failed",
    };
    let error = last["errorText"].as_str().or_else(|| last["error"].as_str());
    (state, error.map(crate::secret_scan::mask))
}

/// The child's summary once its turn ended (`_acpmux/wait` until ready): a question or
/// permission it asks waits on the person in the app.
async fn wait_turn(client: &Arc<Client>, id: &str, timeout: Option<u64>) -> Result<Value> {
    let mut params = json!({"sessions": [id], "until": ["ready", "closed"]});
    if let Some(secs) = timeout {
        params["timeoutMs"] = json!(secs.saturating_mul(1000));
    }
    let v = client.request(method::MUX_WAIT, params).await?;
    if v["timedOut"].as_bool().unwrap_or(false) {
        return Err(errors::AppError::timeout(format!(
            "the child {id} still runs; read it later with `acpmux wait {id}` and `acpmux last {id}`"
        ))
        .with_session(id)
        .into());
    }
    Ok(v["sessions"][0].clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new_args(words: &[&str]) -> NewArgs {
        #[derive(clap::Parser)]
        struct New {
            #[command(flatten)]
            args: NewArgs,
        }
        let argv = std::iter::once("new").chain(words.iter().copied());
        <New as clap::Parser>::try_parse_from(argv).unwrap().args
    }

    #[test]
    fn a_child_start_names_its_parent_harness_model_and_effort() {
        let args = new_args(&["--parent", "lead", "-m", "codex/gpt-5.5", "-e", "high", "-n", "t"]);
        assert_eq!(refused_flags(&args), None);
        let p = start_params(&args, "lead", "fix it").unwrap();
        assert_eq!(
            p,
            json!({"parent": "lead", "prompt": "fix it", "harness": "codex", "model": "gpt-5.5",
                   "effort": "high", "name": "t"})
        );
    }

    #[test]
    fn force_admit_reaches_the_child_start() {
        let args = new_args(&["--parent", "lead", "--force-admit", "go"]);
        assert_eq!(refused_flags(&args), None);
        let p = start_params(&args, "lead", "go").unwrap();
        assert_eq!(p["_meta"]["acpmux"]["forceAdmit"], true, "{p}");
        let p = start_params(&new_args(&["--parent", "lead", "go"]), "lead", "go").unwrap();
        assert!(p.get("_meta").is_none(), "{p}");
    }

    #[test]
    fn a_turn_end_reads_as_its_state_and_error() {
        let ok = json!({"status": "completed", "stopReason": "end_turn"});
        assert_eq!(turn_end(&ok), ("done", None));
        let failed = json!({"status": "failed", "errorText": "no credit"});
        assert_eq!(turn_end(&failed), ("failed", Some("no credit".to_owned())));
        // A turn that never started (`fail_unstarted_turn`) before it said `errorText`.
        let unstarted = json!({"status": "failed", "error": "agent gone"});
        assert_eq!(turn_end(&unstarted), ("failed", Some("agent gone".to_owned())));
        assert_eq!(turn_end(&json!({"status": "cancelled"})).0, "cancelled");
        assert_eq!(turn_end(&Value::Null).0, "failed");
    }

    #[test]
    fn flags_a_child_start_takes_no_part_of_are_refused() {
        let why = refused_flags(&new_args(&["--parent", "lead", "--host", "box", "go"]));
        assert_eq!(why.as_deref(), Some("--parent takes no --host: a family lives on one daemon"));
        assert!(refused_flags(&new_args(&["--parent", "lead", "--policy", "ask"])).is_some());
        assert!(refused_flags(&new_args(&["--parent", "lead", "--ephemeral"])).is_some());
    }
}
