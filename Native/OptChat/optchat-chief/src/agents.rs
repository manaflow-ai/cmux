//! `optchat-chief agents ...` (also `chief agents ...` in the turn session):
//! how the Chief starts and steers its children. Each verb is one short
//! acpmux connection; the host, watching acpmux, turns a child's turn end into
//! a `[name] report` message (section 9), so nothing here waits for a child.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::time::Duration;

use cmux_chief::acp::SessionSummary;
use cmux_chief::rules::PARENT_TAG;
use serde_json::{Value, json};

use crate::acpmux::{SessionSpec, sessions};
use crate::brain::parent_tag;
use crate::cli::{Flags, env};
use crate::rpc::{Notification, RpcClient};

pub const USAGE: &str =
    "chief agents list | prompt NAME \"text\" | allow NAME [OPTION_ID] | deny NAME";

type Notes = (Sender<Notification>, Receiver<Notification>);

fn connect() -> Result<(Arc<RpcClient>, Notes), String> {
    let socket = crate::acpmux_daemon::socket_path();
    let (tx, rx) = channel();
    let forward = tx.clone();
    let client = crate::acpmux_peer::connect(&socket, move |n| {
        let _ = forward.send(n);
    })
    .map_err(|e| format!("acpmux is not reachable at {}: {e}", socket.display()))?;
    client
        .request(
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "chief-agents", "version": env!("CARGO_PKG_VERSION")}}),
        )
        .map_err(|e| format!("initialize: {e}"))?;
    Ok((client, (tx, rx)))
}

/// This Chief's `mux.parent` value (its `MUX_HOME`, which the `chief`
/// launcher bakes in).
fn parent() -> String {
    parent_tag(&crate::paths::mux_home())
}

fn is_mine(s: &SessionSummary, parent: &str) -> bool {
    s.tags.get(PARENT_TAG).map(String::as_str) == Some(parent)
}

fn mine(list: Vec<SessionSummary>) -> Vec<SessionSummary> {
    let parent = parent();
    list.into_iter().filter(|s| is_mine(s, &parent)).collect()
}

/// Whether `s` is one of the sessions of the Chief whose `MUX_HOME` is
/// `home`: its turns and compactor (`cmux.chief` = its home id) or its
/// children (`mux.parent` = its parent tag).
pub fn owned_by(s: &SessionSummary, home: &std::path::Path) -> bool {
    s.tags.get(crate::acpmux::CHIEF_TAG).map(String::as_str)
        == Some(crate::paths::home_id(home).as_str())
        || is_mine(s, &parent_tag(home))
}

/// Stops (`_acpmux/kill`, records kept, so each stays resumable) every
/// session of the Chief of `home` on this host's acpmux, and no other: on
/// a Chief home's shared acpmux (`acpmux_daemon::shared`), what `acpmux
/// daemon shutdown` did for a Chief's own daemon. The daemon keeps
/// running. Returns the names it stopped.
pub fn end_own_sessions(home: &std::path::Path) -> Result<Vec<String>, String> {
    let client = connect_bounded()?;
    // All kills at once, bounded together: a host stops within the
    // supervisor's grace (5 s before SIGKILL), whatever one session does.
    let started: Vec<_> = sessions_bounded(&client)?
        .into_iter()
        .filter(|s| owned_by(s, home) && s.status != cmux_chief::acp::SessionStatus::Closed)
        .map(|s| {
            let answer = client.start(
                "_acpmux/kill",
                json!({"sessionId": s.session_id, "purge": false}),
            );
            (s.name, answer)
        })
        .collect();
    let deadline = std::time::Instant::now() + END_SESSIONS_LIMIT;
    let mut ended = Vec::new();
    let mut failed = Vec::new();
    for (name, answer) in started {
        match answer.recv_timeout(deadline.saturating_duration_since(std::time::Instant::now())) {
            Ok(Ok(_)) => ended.push(name),
            Ok(Err(e)) => failed.push(format!("{name}: {e}")),
            Err(_) => failed.push(format!("{name}: no answer")),
        }
    }
    client.close();
    if failed.is_empty() {
        Ok(ended)
    } else {
        Err(format!("stopping {}", failed.join("; ")))
    }
}

/// Who else uses the acpmux of the Chief at `home`, whose Chief home is
/// `chief_home` (hq-6d 2026-10-14: the Chief home's acpmux stops only when
/// its last user leaves): another Chief of that home whose host runs (its
/// host lock held: the Chief home's own, the default Chief's, or one of
/// `chief_home/c/*`), or another Chief's open session on the daemon (its
/// turns and compactor, `cmux.chief`, or its children, `mux.parent`). The
/// person's own sessions do not count. Names, for the log.
pub fn other_users(
    home: &std::path::Path,
    chief_home: &std::path::Path,
) -> Result<Vec<String>, String> {
    let mut users = Vec::new();
    let chiefs = std::fs::read_dir(chief_home.join("c"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| chief_home.join("c").join(entry.file_name()));
    for chief in std::iter::once(chief_home.to_path_buf()).chain(chiefs) {
        if chief != home && crate::lock::in_use(&chief.join("state/host.lock")) {
            users.push(format!("host {}", chief.display()));
        }
    }
    let client = connect_bounded()?;
    let listed = sessions_bounded(&client);
    client.close();
    let listed = listed?;
    let me = crate::paths::home_id(home);
    let my_parent = parent_tag(home);
    for s in listed {
        if s.status == cmux_chief::acp::SessionStatus::Closed {
            continue;
        }
        let other_chief = s
            .tags
            .get(crate::acpmux::CHIEF_TAG)
            .is_some_and(|id| *id != me);
        let other_child = s.tags.get(PARENT_TAG).is_some_and(|parent| {
            parent
                .strip_prefix(crate::brain::PARENT)
                .is_some_and(|rest| rest.starts_with(':'))
                && *parent != my_parent
        });
        if other_chief || other_child {
            users.push(format!("session {}", s.name));
        }
    }
    Ok(users)
}

/// How long a stop waits for each acpmux answer ([`connect_bounded`]).
const STOP_ANSWER_LIMIT: Duration = Duration::from_secs(1);

/// [`connect`] for a stop: it never hangs on a daemon that does not answer.
fn connect_bounded() -> Result<Arc<RpcClient>, String> {
    let socket = crate::acpmux_daemon::socket_path();
    let client = crate::acpmux_peer::connect(&socket, |_| {})
        .map_err(|e| format!("acpmux is not reachable at {}: {e}", socket.display()))?;
    let answer = ask_bounded(
        &client,
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "chief-agents", "version": env!("CARGO_PKG_VERSION")}}),
    );
    if let Err(e) = answer {
        client.close();
        return Err(e);
    }
    Ok(client)
}

fn ask_bounded(client: &RpcClient, method: &str, params: Value) -> Result<Value, String> {
    client
        .start(method, params)
        .recv_timeout(STOP_ANSWER_LIMIT)
        .map_err(|_| format!("{method}: no answer in {} s", STOP_ANSWER_LIMIT.as_secs()))?
        .map_err(|e| format!("{method}: {e}"))
}

/// `_acpmux/sessions`, every page, each bounded.
fn sessions_bounded(client: &RpcClient) -> Result<Vec<SessionSummary>, String> {
    let list = crate::acpmux::whole_list(
        |m, p| ask_bounded(client, m, p),
        "_acpmux/sessions",
        json!({}),
    )?;
    Ok(crate::acpmux::session_rows(&list).unwrap_or_default())
}

/// How long [`end_own_sessions`] waits for all its kills.
const END_SESSIONS_LIMIT: Duration = Duration::from_secs(3);

/// Which session `spawn --name` uses: a child of this Chief with that name
/// (left by a failed earlier start) is reused; a session of that name that
/// is not this Chief's (the user's, mux/host's, another home's) is refused,
/// so the Chief never sends its task into it or claims its reports.
pub fn spawn_target(
    list: &[SessionSummary],
    name: &str,
    parent: &str,
) -> Result<Option<String>, String> {
    match list.iter().find(|s| s.name == name) {
        None => Ok(None),
        Some(s) if is_mine(s, parent) => Ok(Some(s.session_id.clone())),
        Some(_) => Err(format!(
            "an acpmux session named {name} exists and is not one of the Chief's agents; pick another --name"
        )),
    }
}

fn child(client: &RpcClient, name: &str) -> Result<SessionSummary, String> {
    mine(sessions(client)?)
        .into_iter()
        .find(|s| s.name == name || s.session_id == name)
        .ok_or_else(|| format!("no agent {name} started by the Chief (see `chief agents list`)"))
}

/// The prompt's own answer, forwarded into the notification stream.
const ANSWER: &str = "\u{0}answer";

/// A message to a child: steered into its running turn when its agent steers (acpmux queues it
/// otherwise), so the child reads it at its next tool boundary instead of when that turn ends.
fn tell_params(session: &str, text: &str, prompt_id: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "steer": true}}})
}

/// Sends a prompt and returns once acpmux accepted it (ran, steered or queued it), not when its
/// turn ends.
fn prompt_accepted(
    client: &RpcClient,
    notes: &Notes,
    session: &str,
    text: &str,
) -> Result<(), String> {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let prompt_id = format!("chief-cli-{}-{nanos}", std::process::id());
    let answer = client.start("session/prompt", tell_params(session, text, &prompt_id));
    let forward = notes.0.clone();
    std::thread::spawn(move || {
        let params = match answer.recv() {
            Ok(Ok(_)) => Value::Null,
            Ok(Err(e)) => Value::String(e.to_string()),
            Err(_) => Value::String("acpmux closed the connection".into()),
        };
        let _ = forward.send(Notification {
            method: ANSWER.into(),
            params,
        });
    });
    loop {
        match notes.1.recv_timeout(Duration::from_secs(60)) {
            Ok(n)
                if n.method == "_acpmux/prompt_accepted"
                    && n.params.get("promptId").and_then(Value::as_str)
                        == Some(prompt_id.as_str()) =>
            {
                return Ok(());
            }
            Ok(n) if n.method == ANSWER => {
                return match n.params {
                    Value::String(error) => Err(error),
                    _ => Ok(()),
                };
            }
            Ok(n) if n.method.is_empty() => return Err("acpmux closed the connection".into()),
            Ok(_) => {}
            Err(RecvTimeoutError::Timeout) => {
                return Err("acpmux did not accept the prompt within 60 s".into());
            }
            Err(RecvTimeoutError::Disconnected) => {
                return Err("acpmux closed the connection".into());
            }
        }
    }
}

/// A child's acpmux session: its tags are set after creation (`mux.parent`
/// only), so it never carries `cmux.chief`, which marks the Chief's own
/// turn and compactor sessions.
pub fn child_spec(flags: &Flags, name: &str, cwd: &str) -> SessionSpec {
    SessionSpec {
        name: name.to_owned(),
        cwd: cwd.into(),
        harness: flags
            .value("harness")
            .map(str::to_owned)
            .or_else(|| env("MUX_HARNESS"))
            .unwrap_or_else(|| crate::host::DEFAULT_HARNESS.into()),
        policy: flags
            .value("policy")
            .map(str::to_owned)
            .or_else(|| env("MUX_POLICY"))
            .unwrap_or_else(|| "approve-all".into()),
        model: flags.value("model").map(str::to_owned),
        effort: None,
        preset: None,
        tags: BTreeMap::new(),
        env: Default::default(),
        fast: false,
        peer: None,
    }
}

/// The policy a child gets: the host's floor (`ask` while the Chief works
/// in a turn another person started, README "Remote-origin messages") wins over
/// `--policy` and `MUX_POLICY`.
pub fn apply_floor(requested: &str, floor: Option<&str>) -> String {
    floor.unwrap_or(requested).to_owned()
}

fn asks(s: &SessionSummary) -> bool {
    s.tags.get(crate::approval::POLICY_TAG).map(String::as_str) == Some(crate::approval::ASK)
}

/// Whether `agents allow|deny` may answer `child`'s `pending` permission (an
/// `_acpmux/info` pending entry): not a child that runs with policy `ask`,
/// whose local effects the host refuses, and never a question
/// (`toolCall._meta.acpmux.question`), which only a person answers or
/// declines.
pub fn cli_may_answer(child: &SessionSummary, pending: &Value) -> Result<(), String> {
    if asks(child) {
        return Err(format!(
            "{} runs under the spawn floor of another person's turn: the host refuses its local effects",
            child.name
        ));
    }
    if pending
        .pointer("/request/toolCall/_meta/acpmux/question")
        .is_some_and(|q| !q.is_null())
    {
        return Err(format!(
            "{} is asking a question: only a person answers it, in its agent tab or the Home card; an agent never answers or declines a question",
            child.name
        ));
    }
    Ok(())
}

/// `agents spawn` is retired: its children got no workspace and no chat tab.
pub const SPAWN_RETIRED: &str = "chief agents spawn is retired: use chief spawn \"task\" [\"task\" ...] (a workspace and chat per subagent, one combined report); chief tell ID \"message\" steers one";

/// The refusal for a retired `agents` verb in `words` (`agents VERB ...`).
pub fn retired(words: &[String]) -> Option<&'static str> {
    (words.get(1).map(String::as_str) == Some("spawn")).then_some(SPAWN_RETIRED)
}

/// Runs one `agents` verb; Ok carries what to print.
pub fn run(flags: &Flags) -> Result<String, String> {
    let words = &flags.words[1..];
    let verb = words.first().map(String::as_str).unwrap_or("");
    let args = &words[words.len().min(1)..];
    match verb {
        "spawn" => Err(SPAWN_RETIRED.into()),
        "list" => {
            let (client, _) = connect()?;
            let rows: Vec<String> = mine(sessions(&client)?)
                .into_iter()
                .map(|s| {
                    let pending = if s.pending_permissions > 0 {
                        format!("\t{} pending permission(s)", s.pending_permissions)
                    } else {
                        String::new()
                    };
                    format!(
                        "{}\t{:?}\t{}\t{}{pending}",
                        s.name, s.status, s.harness, s.cwd
                    )
                })
                .collect();
            client.close();
            Ok(if rows.is_empty() {
                "(no agents)".into()
            } else {
                rows.join("\n")
            })
        }
        "prompt" => {
            let name = args.first().ok_or(USAGE)?;
            let text = args[1..].join(" ");
            if text.trim().is_empty() {
                return Err(USAGE.into());
            }
            let (client, notes) = connect()?;
            let target = child(&client, name)?;
            prompt_accepted(&client, &notes, &target.session_id, &text)?;
            client.close();
            Ok(format!(
                "sent to {name}; its report comes back as a message"
            ))
        }
        "allow" | "deny" => {
            let name = args.first().ok_or(USAGE)?;
            let (client, _) = connect()?;
            let target = child(&client, name)?;
            let info = client
                .request("_acpmux/info", json!({"sessionId": target.session_id}))
                .map_err(|e| e.to_string())?;
            let pending = info
                .get("pending")
                .and_then(Value::as_array)
                .and_then(|p| p.first())
                .cloned()
                .ok_or_else(|| format!("{name} has no pending permission"))?;
            cli_may_answer(&target, &pending)?;
            let permission = pending
                .get("permissionId")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            let options: Vec<Value> = pending
                .pointer("/request/options")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let starts = |o: &Value, p: &str| {
                o.get("kind")
                    .and_then(Value::as_str)
                    .is_some_and(|k| k.starts_with(p))
            };
            let id_of = |o: &Value| o.get("optionId").and_then(Value::as_str).map(str::to_owned);
            let option = if verb == "allow" {
                args.get(1)
                    .cloned()
                    .or_else(|| options.iter().find(|o| starts(o, "allow")).and_then(id_of))
                    .or_else(|| options.first().and_then(id_of))
            } else {
                options.iter().find(|o| starts(o, "reject")).and_then(id_of)
            };
            let mut params = json!({"sessionId": target.session_id, "permissionId": permission});
            if let Some(option) = &option {
                params["optionId"] = json!(option);
            }
            client
                .request("_acpmux/permission_respond", params)
                .map_err(|e| {
                    if verb == "allow" {
                        // acpmux takes an allow only from the person's app,
                        // and a child has no tab there: say what still works.
                        format!(
                            "{e}\nOnly the person's cmux app can allow, and {name} has no tab there: `chief agents deny {name}` denies it, or tell it what to do instead with `chief agents prompt {name} \"...\"`."
                        )
                    } else {
                        e.to_string()
                    }
                })?;
            client.close();
            Ok(format!(
                "{}: {}",
                if verb == "allow" { "allowed" } else { "denied" },
                option.unwrap_or_else(|| "(cancelled)".into())
            ))
        }
        _ => Err(USAGE.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::tell_params;

    #[test]
    fn a_message_to_a_child_steers_its_running_turn() {
        let params = tell_params("s-1", "look at this", "chief-cli-1");
        assert_eq!(params["_meta"]["acpmux"]["steer"], true, "{params}");
        assert_eq!(
            params["_meta"]["acpmux"]["promptId"], "chief-cli-1",
            "{params}"
        );
        assert_eq!(params["prompt"][0]["text"], "look at this", "{params}");
    }
}
