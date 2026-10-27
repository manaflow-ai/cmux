//! Printing helpers and the streaming/attach views for the CLI.

use crate::client::Client;
use crate::rpc::{Message, method};
use crate::transcript::{Item, Transcript};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::sync::Arc;

pub(crate) fn arg_or_stdin(words: &[String]) -> Result<String> {
    let joined = words.join(" ");
    if !joined.is_empty() && joined != "-" {
        return Ok(joined);
    }
    let mut s = String::new();
    std::io::stdin().read_to_string(&mut s)?;
    let s = s.trim_end().to_owned();
    if s.is_empty() {
        return Err(anyhow!("empty prompt"));
    }
    Ok(s)
}

/// A client prompt id (`_meta.acpmux.promptId`). The daemon runs each id
/// once, so the same prompt sent again after its connection closed answers
/// with the first run's outcome instead of starting a second turn.
#[derive(Debug, Clone)]
pub(crate) struct PromptId {
    pub id: String,
    /// The id came from `--prompt-id`: the daemon also looks for it in the
    /// session's log, which outlives a daemon restart.
    pub resend: bool,
    /// `--from`: the prompt is this agent's message (`_meta.acpmux.fromAgent`, `hub/digest.rs`).
    pub from_agent: Option<String>,
    /// `--supersede`: the same sender's prompt still queued under this key is replaced
    /// (`_meta.acpmux.supersede`, `hub/supersede.rs`).
    pub supersede: Option<String>,
    /// The person's own send from a terminal: the machine it ran on (`_meta.acpmux.cliHost`,
    /// `cli/sender.rs`), which the transcript names under their prompt.
    pub cli_host: Option<String>,
    /// `--attach`: the files' blocks, after the text (`attach.rs`).
    pub attachments: Vec<Value>,
}

impl PromptId {
    pub(crate) fn new(given: Option<String>) -> Self {
        match given {
            Some(id) => Self {
                id,
                resend: true,
                from_agent: None,
                supersede: None,
                cli_host: None,
                attachments: Vec::new(),
            },
            None => Self {
                id: uuid::Uuid::now_v7().to_string(),
                resend: false,
                from_agent: None,
                supersede: None,
                cli_host: None,
                attachments: Vec::new(),
            },
        }
    }

    /// `session/prompt` params; `provenance` names the agent that sent it
    /// (`prompt_provenance.rs`), when not the person.
    pub(crate) fn params(
        &self,
        session: &str,
        text: &str,
        steer: bool,
        provenance: Option<&Value>,
    ) -> Value {
        let mut mux = json!({"steer": steer, "promptId": self.id, "resend": self.resend});
        if let Some(p) = provenance {
            mux["provenance"] = p.clone();
        }
        if let Some(name) = &self.from_agent {
            mux["fromAgent"] = json!(name);
        }
        if let Some(key) = &self.supersede {
            mux["supersede"] = json!(key);
        }
        if let Some(host) = &self.cli_host {
            mux["cliHost"] = json!(host);
        }
        let mut prompt = vec![json!({"type": "text", "text": text})];
        prompt.extend(self.attachments.iter().cloned());
        json!({"sessionId": session, "prompt": prompt, "_meta": {"acpmux": mux}})
    }

    /// The error for a connection that closed while this prompt was in
    /// flight: the prompt may have started, and resending it is safe.
    pub(crate) fn closed(&self, client: &Client, session: &str, context: &str) -> anyhow::Error {
        crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            "daemon_closed",
            format!(
                "{} The prompt may have started; send it again with --prompt-id {} to get its outcome without running it twice.",
                client.closed(context),
                self.id
            ),
        )
        .with_session(session)
        .with_prompt(&self.id)
        .retryable()
        .into()
    }
}

/// Send a prompt and return once the daemon recorded it (queued or
/// started), signalled by `_acpmux/prompt_accepted` for this prompt id.
/// The turn keeps running in the daemon after this process exits.
pub(crate) async fn queue_prompt(
    client: Arc<Client>,
    id: &str,
    text: &str,
    steer: bool,
    provenance: Option<&Value>,
    prompt: &PromptId,
) -> Result<Value> {
    let mut notes =
        client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    let c = client.clone();
    let params = prompt.params(id, text, steer, provenance);
    let mut turn = tokio::spawn(async move { c.request(method::SESSION_PROMPT, params).await });
    loop {
        tokio::select! {
            // A turn that ends before the acceptance arrives (a fast agent,
            // or a peer that does not relay it) answers the same question.
            r = &mut turn => {
                return match r? {
                    Err(_) if client.is_closed() => Err(prompt.closed(&client, id, "queueing the prompt")),
                    other => other,
                };
            }
            n = notes.recv() => {
                let (m, params) = match n {
                    Some(Message::Notification { method, params }) => (method, params),
                    Some(_) => continue,
                    None => return Err(prompt.closed(&client, id, "queueing the prompt")),
                };
                if m == method::MUX_DISCONNECTED {
                    return Err(prompt.closed(&client, id, "queueing the prompt"));
                }
                let params = params.unwrap_or(Value::Null);
                if m == method::MUX_PROMPT_ACCEPTED
                    && params.get("promptId").and_then(Value::as_str) == Some(prompt.id.as_str())
                {
                    return Ok(params);
                }
            }
        }
    }
}

/// What `acpmux send --no-wait` prints for its acceptance.
/// With `--supersede`, a second line says how many of the sender's queued prompts it replaced.
pub(crate) fn sent_lines(accepted: &Value, supersede: bool) -> Vec<String> {
    let steered = accepted.get("steer") == Some(&json!(true));
    let mut lines = vec![if steered { "steered" } else { "queued" }.to_owned()];
    if supersede {
        // An older daemon (or a peer running one) ignores the key and says nothing.
        lines.push(match accepted.get("replaced").and_then(Value::as_u64) {
            Some(n) => format!("replaced {n} queued"),
            None => "replaced ? queued (the daemon did not report it; it may predate --supersede)"
                .to_owned(),
        });
    }
    lines
}

pub(crate) fn print_json(v: &Value) {
    println!("{}", serde_json::to_string_pretty(v).unwrap_or_default());
}

pub(crate) fn short(s: &str, n: usize) -> String {
    let s: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() > n {
        format!("{}…", s.chars().take(n.saturating_sub(1)).collect::<String>())
    } else {
        s
    }
}

pub(crate) fn age(ms: u64) -> String {
    let now = crate::store::now_ms();
    let d = now.saturating_sub(ms) / 1000;
    if d < 60 {
        format!("{d}s")
    } else if d < 3600 {
        format!("{}m", d / 60)
    } else if d < 86_400 {
        format!("{}h", d / 3600)
    } else {
        format!("{}d", d / 86_400)
    }
}

/// Send a prompt and print the reply as it streams.
/// Did this notification come from the agent, not from acpmux's own
/// bookkeeping? Only agent activity resets the stall timer.
fn agent_activity(m: &str, p: &Value) -> bool {
    match m {
        method::SESSION_UPDATE | method::MUX_PERMISSION_PENDING => true,
        method::MUX_EVENT => p.get("dir").and_then(Value::as_str) == Some("in"),
        _ => false,
    }
}

/// A `session/update` that shows agent output (text, thoughts, tools, a
/// plan), as opposed to metadata such as commands, modes or usage; only
/// output makes a failed turn unsafe to retry.
fn renders_output(p: &Value) -> bool {
    let kind = p.pointer("/update/sessionUpdate").and_then(Value::as_str).unwrap_or("");
    matches!(
        kind,
        "agent_message_chunk" | "agent_thought_chunk" | "tool_call" | "tool_call_update" | "plan"
    )
}

/// How a turn handles permissions when nobody is there to answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OnPermission {
    Wait,
    Deny,
    Fail,
}

impl OnPermission {
    pub(crate) fn parse(s: &str) -> Result<Self> {
        match s {
            "wait" => Ok(Self::Wait),
            "deny" => Ok(Self::Deny),
            "fail" => Ok(Self::Fail),
            other => Err(crate::cli::errors::AppError::usage(format!(
                "--on-permission must be wait, deny or fail, got {other:?}"
            ))
            .into()),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct CollectOpts {
    pub timeout: Option<u64>,
    pub on_permission: OnPermission,
    /// Seconds without any update after the prompt before `prompt_stalled`; 0 disables.
    pub stall_secs: u64,
    pub retries: u32,
    /// Into a running turn of an agent that steers (`_meta.acpmux.steer`): an agent's send, by
    /// default (`run/standard.rs` `send_steers`).
    pub steer: bool,
}

pub(crate) struct CollectResult {
    pub reply: String,
    pub stop_reason: String,
    pub permissions_asked: u64,
    pub permissions_denied: u64,
}

/// Answer a pending permission on the caller's behalf when the run policy
/// says so. Returns true when the turn should be treated as failed.
async fn auto_answer(client: &Arc<Client>, id: &str, p: &Value, mode: OnPermission) -> bool {
    let pid = p.get("permissionId").and_then(Value::as_str).unwrap_or("");
    let options =
        p.pointer("/request/options").and_then(Value::as_array).cloned().unwrap_or_default();
    let reject = options
        .iter()
        .find(|o| {
            o.get("kind").and_then(Value::as_str).map(|k| k.starts_with("reject")).unwrap_or(false)
        })
        .and_then(|o| o.get("optionId").and_then(Value::as_str))
        .map(str::to_owned);
    match mode {
        OnPermission::Wait => false,
        OnPermission::Deny | OnPermission::Fail => {
            let _ = client
                .request(
                    method::MUX_PERMISSION_RESPOND,
                    json!({"sessionId": id, "permissionId": pid, "optionId": reject}),
                )
                .await;
            mode == OnPermission::Fail
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn stream_prompt(
    client: Arc<Client>,
    id: &str,
    text: &str,
    steer: bool,
    quiet: bool,
    json_out: bool,
    opts: CollectOpts,
    suppress_reads: bool,
    prompt: &PromptId,
) -> Result<()> {
    let mut notes =
        client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await?;
    let c = client.clone();
    let params = prompt.params(id, text, steer, None);
    let turn = tokio::spawn(async move { c.request(method::SESSION_PROMPT, params).await });
    let mut steered = crate::cli::steer_reply::SteerReply::new(&prompt.id, steer);
    let mut end_wait: Option<crate::cli::steer_reply::EndWait> = None;
    let mut t = Transcript::default();
    let mut printed_assistant = 0usize;
    let mut last_tool = String::new();
    let stdout = std::io::stdout();
    let mut turn = turn;
    let started = tokio::time::Instant::now();
    let deadline = opts.timeout.map(|s| started + std::time::Duration::from_secs(s));
    let mut activity = false;
    let mut asked = 0u64;
    let mut denied = 0u64;
    let mut fail_permission = false;
    let mut suppressor = crate::cli::orchestrate::ReadSuppressor::default();
    let result = loop {
        let stall_at = if opts.stall_secs > 0 && !activity {
            Some(started + std::time::Duration::from_secs(opts.stall_secs))
        } else {
            None
        };
        let next_tick = match (deadline, stall_at) {
            (Some(d), Some(s)) => Some(d.min(s)),
            (Some(d), None) => Some(d),
            (None, Some(s)) => Some(s),
            (None, None) => None,
        };
        let tick = async {
            match next_tick {
                Some(t) => tokio::time::sleep_until(t).await,
                None => std::future::pending::<()>().await,
            }
        };
        tokio::select! {
            r = &mut turn, if !steered.waiting() => match steered.answered(r?) {
                Some(answer) => break answer,
                None => {
                    let turn = steered.turn().unwrap_or_default().to_owned();
                    let end = crate::cli::steer_reply::wait_end(client.clone(), id.to_owned(), turn);
                    end_wait = Some(Box::pin(end));
                    continue;
                }
            },
            // The turn it steered into ended, as the daemon tells it (`steer_reply.rs`).
            end = ended(&mut end_wait), if end_wait.is_some() => break end,
            _ = tick => {
                if let Some(d) = deadline
                    && tokio::time::Instant::now() >= d {
                        return Err(timed_out(&client, id, opts, &steered, &mut turn).await);
                    }
                if !activity {
                    return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "prompt_stalled", format!("no update from the agent within {}s of sending; the turn keeps running (acpmux last {id} to check)", opts.stall_secs)).with_session(id).into());
                }
            }
            n = notes.recv() => {
                let Some(m) = n else { return Err(prompt.closed(&client, id, "streaming the session")) };
                let Message::Notification { method: m, params } = m else { continue };
                if m == method::MUX_DISCONNECTED { return Err(prompt.closed(&client, id, "streaming the session")); }
                let p = params.unwrap_or(Value::Null);
                if p.get("sessionId").and_then(Value::as_str) != Some(id) { continue; }
                if let Some(answer) = steered.heard(&m, &p) { break answer; }
                if agent_activity(&m, &p) {
                    activity = true;
                }
                if m == method::MUX_PERMISSION_PENDING {
                    asked += 1;
                    if opts.on_permission != OnPermission::Wait {
                        denied += 1;
                        if auto_answer(&client, id, &p, opts.on_permission).await {
                            fail_permission = true;
                            let _ = client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
                        }
                        continue;
                    }
                }
                if json_out {
                    let p = match m.as_str() {
                        method::MUX_EVENT if suppress_reads => suppressor.apply(p),
                        method::SESSION_UPDATE if suppress_reads => suppressor.apply_update(p),
                        _ => p,
                    };
                    println!("{}", json!({"method": m, "params": p}));
                    continue;
                }
                match m.as_str() {
                    method::SESSION_UPDATE => {
                        t.apply_update(&p);
                        if quiet { continue; }
                        let mut out = stdout.lock();
                        if let Some(Item::Assistant { text }) = t.items.last() {
                            if text.len() > printed_assistant {
                                let _ = write!(out, "{}", &text[printed_assistant..]);
                                let _ = out.flush();
                                printed_assistant = text.len();
                            }
                        } else {
                            printed_assistant = 0;
                        }
                        if let Some(Item::Tool { title, status, kind, .. }) = t.items.last() {
                            let line = format!("[{kind} {status}] {title}");
                            if line != last_tool {
                                let _ = writeln!(out, "\n\x1b[2m{line}\x1b[0m");
                                last_tool = line;
                            }
                        }
                    }
                    method::MUX_PERMISSION_PENDING => {
                        let title = p.pointer("/request/toolCall/title").and_then(Value::as_str).unwrap_or("permission");
                        let request = p.get("request").cloned().unwrap_or(Value::Null);
                        let hint = crate::question_answer::pending_hint(&request, id);
                        eprintln!("\n\x1b[33mpermission needed:\x1b[0m {title}  (answer with: {hint})");
                    }
                    _ => {}
                }
            }
        }
    };
    if fail_permission || (asked > 0 && denied == asked && opts.on_permission == OnPermission::Deny)
    {
        return Err(crate::cli::errors::AppError::new(
            crate::cli::errors::Code::PermissionDenied,
            "all_denied",
            format!("every permission in the turn was denied ({denied}/{asked})"),
        )
        .with_session(id)
        .into());
    }
    // A steer's reply is the reply of the turn it went into, from the log: the stream may have
    // missed it (a resend after that turn ended, dropped events).
    let streamed = t.items.iter().rev().find_map(|i| match i {
        Item::Assistant { text } => Some(text.clone()),
        _ => None,
    });
    let logged = match (steered.turn(), &result) {
        (Some(turn), Ok(_)) => turn_reply(&client, id, turn).await?,
        _ => None,
    };
    match result {
        Ok(v) => {
            if quiet {
                if let Some(text) = logged.or(streamed) {
                    println!("{text}");
                }
            } else if json_out {
                print_json(&v);
            } else {
                // What the stream missed of it.
                if let Some(text) = logged.filter(|l| !l.is_empty() && Some(l) != streamed.as_ref())
                {
                    println!("\n{text}");
                }
                let stop = v.get("stopReason").and_then(Value::as_str).unwrap_or("end_turn");
                if stop != "end_turn" {
                    eprintln!("\n\x1b[2m[{stop}]\x1b[0m");
                } else {
                    println!();
                }
            }
            Ok(())
        }
        Err(_) if client.is_closed() => Err(prompt.closed(&client, id, "waiting for the turn")),
        Err(e) => Err(e),
    }
}

/// Plain streaming attach: prints everything that happens in the session.
pub(crate) async fn plain_attach(client: Arc<Client>, id: &str) -> Result<()> {
    let mut notes =
        client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    let v = client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 200})).await?;
    let mut t = Transcript::default();
    for e in v.get("events").and_then(Value::as_array).cloned().unwrap_or_default() {
        t.apply_event(&e);
    }
    let mut printed = t.items.len();
    let mut assistant_len = 0usize;
    for (i, item) in t.items.iter().enumerate() {
        match item {
            // A trailing assistant item may still be streaming: leave its
            // line open so the deltas below continue it.
            Item::Assistant { text } if i + 1 == t.items.len() && !text.is_empty() => {
                print!("\x1b[1massistant:\x1b[0m {text}");
                let _ = std::io::stdout().flush();
                printed = i;
                assistant_len = text.len();
            }
            _ => print_item(item),
        }
    }
    while let Some(m) = notes.recv().await {
        let Message::Notification { method: m, params } = m else { continue };
        if m == method::MUX_DISCONNECTED {
            return Err(client.closed("streaming the session"));
        }
        let p = params.unwrap_or(Value::Null);
        if p.get("sessionId").and_then(Value::as_str) != Some(id) {
            continue;
        }
        match m.as_str() {
            method::SESSION_UPDATE => t.apply_update(&p),
            method::MUX_EVENT => t.apply_event(&p),
            _ => continue,
        }
        // Print new whole items, and stream the trailing assistant item.
        while printed < t.items.len().saturating_sub(1) {
            match &t.items[printed] {
                // The streamed assistant item: finish its open line.
                Item::Assistant { text } if assistant_len > 0 => {
                    println!("{}", text.get(assistant_len..).unwrap_or(""));
                }
                item => print_item(item),
            }
            printed += 1;
            assistant_len = 0;
        }
        if let Some(last) = t.items.last()
            && printed == t.items.len() - 1
        {
            match last {
                Item::Assistant { text } => {
                    if assistant_len == 0 {
                        print!("\x1b[1massistant:\x1b[0m ");
                    }
                    if text.len() > assistant_len {
                        print!("{}", &text[assistant_len..]);
                        let _ = std::io::stdout().flush();
                        assistant_len = text.len();
                    }
                }
                Item::Thought { .. } => {}
                other => {
                    print_item(other);
                    printed += 1;
                    assistant_len = 0;
                }
            }
        }
    }
    Ok(())
}

pub(crate) fn print_item(item: &Item) {
    match item {
        Item::User { text, steer, queued } => println!(
            "\x1b[36muser{}:\x1b[0m {text}",
            if *steer {
                " (steer)"
            } else if *queued {
                " (queued)"
            } else {
                ""
            }
        ),
        Item::Assistant { text } => println!("\x1b[1massistant:\x1b[0m {text}"),
        Item::Thought { text } => println!("\x1b[2mthought: {}\x1b[0m", short(text, 200)),
        Item::Tool { title, kind, status, .. } => {
            println!("\x1b[2m[{kind} {status}] {title}\x1b[0m")
        }
        Item::Plan { entries } => {
            println!("\x1b[35mplan:\x1b[0m");
            for (s, c) in entries {
                println!("  [{s}] {c}");
            }
        }
        Item::Permission { title, decided, .. } => match decided {
            Some(d) => println!("\x1b[33mpermission {title}: {d}\x1b[0m"),
            None => println!("\x1b[33mpermission needed: {title}\x1b[0m"),
        },
        Item::Status { text } => println!("\x1b[2m-- {text}\x1b[0m"),
        Item::TurnEnd { stop } => println!("\x1b[2m-- turn end ({stop})\x1b[0m"),
        Item::Error { text } => println!("\x1b[31merror: {text}\x1b[0m"),
        Item::Stderr { text } => println!("\x1b[2mstderr: {text}\x1b[0m"),
    }
}

/// The error of a send whose `--timeout` passed. Its own turn is stopped first; a turn it steered
/// into is another prompt's, so that turn runs on (`steer_reply.rs`).
async fn timed_out(
    client: &Arc<Client>,
    id: &str,
    opts: CollectOpts,
    steered: &crate::cli::steer_reply::SteerReply,
    turn: &mut tokio::task::JoinHandle<Result<Value>>,
) -> anyhow::Error {
    let secs = opts.timeout.unwrap_or(0);
    if steered.in_another_turn() {
        let text = format!("no reply after {secs}s; the turn it steered into runs on");
        return crate::cli::errors::AppError::timeout(text).with_session(id).into();
    }
    let _ = client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let _ = tokio::time::timeout(std::time::Duration::from_millis(2500), turn).await;
    let text = format!("turn cancelled after {secs}s");
    crate::cli::errors::AppError::timeout(text).with_session(id).into()
}

/// Send a prompt and return the reply without printing. Honors the timeout
/// (cooperative cancel, exit 3), the permission policy (deny answers
/// reject; fail also ends the turn, exit 5), stall detection, and retries:
/// a turn is retried only on an agent-internal error and only if nothing
/// was produced, with backoff capped at 10 s.
pub(crate) async fn collect_reply(
    client: Arc<Client>,
    id: &str,
    text: &str,
    opts: CollectOpts,
    prompt: &PromptId,
) -> Result<CollectResult> {
    let mut attempt = 0u32;
    // A retry after an agent error is a new turn on purpose, so it gets a
    // new prompt id; the daemon would otherwise answer with the failure.
    let mut prompt = prompt.clone();
    loop {
        match collect_once(client.clone(), id, text, opts, &prompt).await {
            Ok(r) => return Ok(r),
            Err(e) => {
                let retryable = e
                    .downcast_ref::<crate::cli::errors::AppError>()
                    // A closed connection is retryable for the caller (resend
                    // with the same --prompt-id), never here under a new id:
                    // the turn may have run.
                    .map(|a| a.retryable && a.detail == "agent_error")
                    .unwrap_or(false);
                if !retryable || attempt >= opts.retries {
                    return Err(e);
                }
                attempt += 1;
                let backoff = std::time::Duration::from_millis(
                    (1000u64 * 2u64.pow(attempt.min(4))).min(10_000),
                );
                eprintln!("acpmux: agent error, retry {attempt}/{} in {:?}", opts.retries, backoff);
                tokio::time::sleep(backoff).await;
                // The same message again, its attachments too.
                let attachments = std::mem::take(&mut prompt.attachments);
                prompt = PromptId::new(None);
                prompt.attachments = attachments;
            }
        }
    }
}

async fn collect_once(
    client: Arc<Client>,
    id: &str,
    text: &str,
    opts: CollectOpts,
    prompt: &PromptId,
) -> Result<CollectResult> {
    let mut notes =
        client.notifications().await.ok_or_else(|| anyhow!("notifications already taken"))?;
    client.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await?;
    let c = client.clone();
    let params = prompt.params(id, text, opts.steer, None);
    let mut turn = tokio::spawn(async move { c.request(method::SESSION_PROMPT, params).await });
    let mut steered = crate::cli::steer_reply::SteerReply::new(&prompt.id, opts.steer);
    let mut end_wait: Option<crate::cli::steer_reply::EndWait> = None;
    let mut t = Transcript::default();
    let started = tokio::time::Instant::now();
    let deadline = opts.timeout.map(|s| started + std::time::Duration::from_secs(s));
    let mut activity = false;
    let mut produced = false;
    let mut asked = 0u64;
    let mut denied = 0u64;
    let mut fail_permission = false;
    let result = loop {
        let stall_at = if opts.stall_secs > 0 && !activity {
            Some(started + std::time::Duration::from_secs(opts.stall_secs))
        } else {
            None
        };
        let next_tick = [deadline, stall_at].into_iter().flatten().min();
        let tick = async {
            match next_tick {
                Some(t) => tokio::time::sleep_until(t).await,
                None => std::future::pending::<()>().await,
            }
        };
        tokio::select! {
            r = &mut turn, if !steered.waiting() => match steered.answered(r?) {
                Some(answer) => break answer,
                None => {
                    let turn = steered.turn().unwrap_or_default().to_owned();
                    let end = crate::cli::steer_reply::wait_end(client.clone(), id.to_owned(), turn);
                    end_wait = Some(Box::pin(end));
                    continue;
                }
            },
            // The turn it steered into ended, as the daemon tells it (`steer_reply.rs`).
            end = ended(&mut end_wait), if end_wait.is_some() => break end,
            _ = tick => {
                if let Some(d) = deadline
                    && tokio::time::Instant::now() >= d {
                        return Err(timed_out(&client, id, opts, &steered, &mut turn).await);
                    }
                if !activity {
                    return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "prompt_stalled", format!("no update from the agent within {}s of sending; the turn keeps running (acpmux last {id} to check)", opts.stall_secs)).with_session(id).into());
                }
            }
            n = notes.recv() => {
                let Some(m) = n else { return Err(prompt.closed(&client, id, "streaming the session")) };
                let Message::Notification { method: m, params } = m else { continue };
                if m == method::MUX_DISCONNECTED { return Err(prompt.closed(&client, id, "streaming the session")); }
                let p = params.unwrap_or(Value::Null);
                if p.get("sessionId").and_then(Value::as_str) != Some(id) { continue; }
                if let Some(answer) = steered.heard(&m, &p) { break answer; }
                if agent_activity(&m, &p) {
                    activity = true;
                }
                match m.as_str() {
                    method::SESSION_UPDATE => {
                        if renders_output(&p) {
                            produced = true;
                        }
                        t.apply_update(&p)
                    }
                    method::MUX_EVENT => {
                        // Rules and policies answer on the server; count those too.
                        if p.get("kind").and_then(Value::as_str) == Some("permission_auto") {
                            asked += 1;
                            if p.pointer("/msg/optionId").and_then(Value::as_str).map(|o| o.starts_with("reject") || o == "no").unwrap_or(false) {
                                denied += 1;
                            }
                        }
                        t.apply_event(&p)
                    }
                    method::MUX_PERMISSION_PENDING => {
                        asked += 1;
                        produced = true;
                        match opts.on_permission {
                            OnPermission::Wait => {
                                let title = p.pointer("/request/toolCall/title").and_then(Value::as_str).unwrap_or("permission");
                                eprintln!("permission needed: {title}  ({})", crate::question_answer::pending_hint(p.get("request").unwrap_or(&Value::Null), id));
                            }
                            mode => {
                                denied += 1;
                                if auto_answer(&client, id, &p, mode).await {
                                    fail_permission = true;
                                    let _ = client.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    };
    if fail_permission || (asked > 0 && denied == asked && opts.on_permission == OnPermission::Deny)
    {
        return Err(crate::cli::errors::AppError::new(
            crate::cli::errors::Code::PermissionDenied,
            "all_denied",
            format!("every permission in the turn was denied ({denied}/{asked})"),
        )
        .with_session(id)
        .into());
    }
    let result = match result {
        Ok(v) => v,
        Err(_) if client.is_closed() => {
            return Err(prompt.closed(&client, id, "waiting for the turn"));
        }
        Err(e) => {
            // ACP internal (-32603) or parse (-32700) errors with nothing
            // produced are the only retryable failures.
            let msg = e.to_string();
            let retryable = !produced
                && (msg.contains("-32603")
                    || msg.contains("-32700")
                    || msg.to_lowercase().contains("internal error"));
            let mut app = crate::cli::errors::AppError::new(
                crate::cli::errors::Code::Runtime,
                "agent_error",
                msg,
            )
            .with_session(id);
            if retryable {
                app = app.retryable();
            }
            return Err(app.into());
        }
    };
    let mut reply = t
        .items
        .iter()
        .rev()
        .find_map(|i| match i {
            Item::Assistant { text } => Some(text.clone()),
            _ => None,
        })
        .unwrap_or_default();
    // A steer's reply is the reply of the turn it went into, from the log: the send attached
    // after that turn started, and may have missed its end. A log that no longer reaches that
    // turn's start keeps the reply heard.
    if let Some(turn) = steered.turn()
        && let Some(logged) = turn_reply(&client, id, turn).await?
    {
        reply = logged;
    }
    // A resent prompt id streams nothing: its turn already ran, so read the
    // reply of that turn (not necessarily the newest) from the log.
    if reply.is_empty() && result.pointer("/_meta/acpmux/duplicate") == Some(&json!(true)) {
        reply = match result.pointer("/_meta/acpmux/turnId").and_then(Value::as_str) {
            Some(turn) => turn_reply(&client, id, turn).await?.unwrap_or_default(),
            None => last_replies(&client, id, 1).await?.pop().unwrap_or_default(),
        };
    }
    let stop_reason =
        result.get("stopReason").and_then(Value::as_str).unwrap_or("end_turn").to_owned();
    Ok(CollectResult { reply, stop_reason, permissions_asked: asked, permissions_denied: denied })
}

/// The end of the turn a steer went into, once `end_wait` is armed; never before.
async fn ended(end_wait: &mut Option<crate::cli::steer_reply::EndWait>) -> Result<Value> {
    match end_wait.as_mut() {
        Some(wait) => wait.await,
        None => std::future::pending().await,
    }
}

/// The most JSON a page of the daemon's log may hold (`_acpmux/attach` `maxBytes`; it
/// defaults to 1 MiB). A reply is read from the newest transcript records, a page at a time;
/// raw harness lines are left out so they cannot crowd the turn out of it.
const TRANSCRIPT_PAGE_BYTES: usize = 4 << 20;

/// The most transcript records `turn_reply` reads back for a turn's start.
const TURN_REPLY_RECORDS: usize = 200_000;

/// The assistant reply of one turn, read from the session's log: the last assistant item
/// between that turn's start and its result. It pages back from the newest record until that
/// turn's start, and is `None` when the log (its newest `TURN_REPLY_RECORDS`) holds no start of
/// it: a history that does not reach the turn is not an empty reply.
pub(crate) async fn turn_reply(
    client: &Arc<Client>,
    id: &str,
    turn: &str,
) -> Result<Option<String>> {
    let started = |events: &[Value]| {
        events.iter().any(|e| {
            e.get("kind").and_then(Value::as_str) == Some("turn_started")
                && e.pointer("/msg/turnId").and_then(Value::as_str) == Some(turn)
        })
    };
    // Transcript records only, in the largest page the daemon gives (`TRANSCRIPT_PAGE_BYTES`).
    let mut query = json!({
        "sessionId": id, "limit": 5000, "kinds": ["transcript"], "maxBytes": TRANSCRIPT_PAGE_BYTES
    });
    let (mut events, mut more) =
        page_events(&client.request(method::MUX_ATTACH, query.clone()).await?);
    let mut found = started(&events);
    while more && !found && events.len() < TURN_REPLY_RECORDS {
        let Some(first) = events.first().and_then(|e| e.get("seq")).and_then(Value::as_u64) else {
            break;
        };
        query["beforeSeq"] = json!(first);
        let (older, has_more) =
            page_events(&client.request(method::MUX_EVENTS, query.clone()).await?);
        if older.is_empty() {
            break;
        }
        more = has_more;
        found = started(&older);
        events.splice(0..0, older);
    }
    Ok(reply_of_turn(&events, turn))
}

fn page_events(page: &Value) -> (Vec<Value>, bool) {
    let events = page.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
    (events, page.get("hasMore").and_then(Value::as_bool).unwrap_or(false))
}

/// The newest `limit` events of a chat, oldest first: the attach `query` names (`sessionId`,
/// `limit`, and any `kinds` or `maxBytes`), then the older pages before it with the same filter,
/// since one reply holds at most `hub::MAX_PAGE_BYTES`.
pub(crate) async fn with_older(client: &Arc<Client>, query: Value) -> Result<Vec<Value>> {
    let limit = query.get("limit").and_then(Value::as_u64).unwrap_or(0) as usize;
    let (mut events, mut more) =
        page_events(&client.request(method::MUX_ATTACH, query.clone()).await?);
    while more && events.len() < limit {
        let Some(first) = events.first().and_then(|e| e.get("seq")).and_then(Value::as_u64) else {
            break;
        };
        let mut older = query.clone();
        older["beforeSeq"] = json!(first);
        older["limit"] = json!(limit - events.len());
        let (older, has_more) = page_events(&client.request(method::MUX_EVENTS, older).await?);
        if older.is_empty() {
            break;
        }
        more = has_more;
        events.splice(0..0, older);
    }
    Ok(events)
}

/// Up to `limit` events of a chat after seq `after`, oldest first, a page of at most 100000 at a
/// time.
pub(crate) async fn events_after(
    client: &Arc<Client>,
    id: &str,
    mut after: u64,
    limit: usize,
) -> Result<Vec<Value>> {
    let mut events = Vec::new();
    while events.len() < limit {
        let v = client
            .request(
                method::MUX_EVENTS,
                json!({"sessionId": id, "afterSeq": after, "limit": (limit - events.len()).min(100_000)}),
            )
            .await?;
        let (page, more) = page_events(&v);
        let Some(last) = page.last().and_then(|e| e.get("seq")).and_then(Value::as_u64) else {
            break;
        };
        after = last;
        events.extend(page);
        if !more {
            break;
        }
    }
    Ok(events)
}

/// The last assistant reply between turn `turn`'s start and its result; `None` when `events`
/// hold no start of it.
fn reply_of_turn(events: &[Value], turn: &str) -> Option<String> {
    let of_turn = |e: &Value| e.pointer("/msg/turnId").and_then(Value::as_str) == Some(turn);
    let kind = |e: &Value| e.get("kind").and_then(Value::as_str).unwrap_or("").to_owned();
    let mut t = Transcript::default();
    let mut inside = false;
    for e in events {
        if !inside {
            inside = kind(e) == "turn_started" && of_turn(e);
            continue;
        }
        if kind(e) == "turn_result" && of_turn(e) {
            break;
        }
        t.apply_event(e);
    }
    inside.then(|| {
        t.items
            .iter()
            .rev()
            .find_map(|i| match i {
                Item::Assistant { text } => Some(text.clone()),
                _ => None,
            })
            .unwrap_or_default()
    })
}

/// The last `count` assistant replies of a session, oldest first.
pub(crate) async fn last_replies(
    client: &Arc<Client>,
    id: &str,
    count: usize,
) -> Result<Vec<String>> {
    // Transcript records only, in the largest page the daemon gives (`TRANSCRIPT_PAGE_BYTES`).
    let page = json!({
        "sessionId": id, "limit": 5000, "kinds": ["transcript"], "maxBytes": TRANSCRIPT_PAGE_BYTES
    });
    let mut t = Transcript::default();
    for e in with_older(client, page).await? {
        t.apply_event(&e);
    }
    let mut out: Vec<String> = t
        .items
        .iter()
        .rev()
        .filter_map(|i| match i {
            Item::Assistant { text } => Some(text.clone()),
            _ => None,
        })
        .take(count.max(1))
        .collect();
    out.reverse();
    Ok(out)
}

#[cfg(test)]
mod prompt_tests {
    use super::*;
    use crate::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
    use std::collections::BTreeMap;

    /// A hub with the fake agent behind a real Unix socket, and a client.
    async fn daemon() -> (Arc<crate::hub::Hub>, Arc<Client>, cmux_unix_socket::TestDir) {
        daemon_with_env(BTreeMap::new()).await
    }

    /// `daemon` with extra environment for the fake agent.
    async fn daemon_with_env(
        env: BTreeMap<String, String>,
    ) -> (Arc<crate::hub::Hub>, Arc<Client>, cmux_unix_socket::TestDir) {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut harnesses = BTreeMap::new();
        harnesses.insert(
            "fake".to_owned(),
            HarnessProfile {
                kind: Default::default(),
                argv: vec!["python3".into(), fake.into()],
                env,
                description: None,
                fallback: None,
                family: None,
                models: vec![],
                model: None,
                effort: None,
                policy: None,
            },
        );
        let mut cfg =
            Config { harnesses, default_harness: Some("fake".into()), ..Default::default() };
        cfg.store.mode = StoreMode::Memory;
        cfg.permission_policy = PermissionPolicy::ApproveAll;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = crate::hub::Hub::new(cfg, store);
        // The shared helper keeps the socket path under sun_path whatever
        // $TMPDIR is (104 bytes on macOS).
        let dir = cmux_unix_socket::short_test_dir("acpmux-q");
        let path = dir.path().join("d.sock");
        let listener = crate::server::bind_unix(&path).await.unwrap();
        tokio::spawn(crate::server::serve_unix(hub.clone(), listener));
        let client = Client::connect(&path).await.unwrap();
        (hub, client, dir)
    }

    /// `acpmux send --supersede KEY`: the same sender's queued prompt under KEY is replaced, and
    /// the sender is told how many.
    #[tokio::test]
    async fn a_send_with_supersede_replaces_the_senders_queued_prompt_under_that_key() {
        let (hub, client, dir) = daemon().await;
        let s = client
            .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
            .await
            .unwrap();
        let id = s["sessionId"].as_str().unwrap().to_owned();
        let keyed = |key: &str| {
            let mut p = PromptId::new(None);
            p.from_agent = Some("lane-a".into());
            p.supersede = Some(key.into());
            p
        };
        // "slow" streams for about a second, so the two after it queue.
        queue_prompt(client.clone(), &id, "slow", false, None, &PromptId::new(None)).await.unwrap();
        let old = keyed("cause-1b");
        let first = queue_prompt(client.clone(), &id, "order", false, None, &old).await.unwrap();
        assert_eq!(first["queued"], true, "{first}");
        assert_eq!(sent_lines(&first, true), ["queued", "replaced 0 queued"]);
        let new = keyed("cause-1b");
        let second =
            queue_prompt(client.clone(), &id, "correction", false, None, &new).await.unwrap();
        assert_eq!(second["replaced"], 1, "{second}");
        assert_eq!(second["replacedPromptIds"], json!([old.id]), "{second}");
        assert_eq!(sent_lines(&second, true), ["queued", "replaced 1 queued"]);
        // Without --supersede the output is as before.
        assert_eq!(sent_lines(&second, false), ["queued"]);
        let removed = hub
            .events(&id, 0, 1000)
            .unwrap()
            .into_iter()
            .filter(|e| e.kind == "queue_removed")
            .map(|e| e.msg)
            .collect::<Vec<_>>();
        assert_eq!(removed.len(), 1, "{removed:?}");
        assert_eq!(removed[0]["promptId"], old.id.as_str());
        assert_eq!(removed[0]["reason"], "superseded");
        drop(dir);
    }

    /// A daemon that predates the key says nothing about it: the count is unknown, not 0.
    #[test]
    fn an_unreported_count_is_unknown() {
        let lines = sent_lines(&json!({"queued": true}), true);
        assert_eq!(lines[0], "queued");
        assert!(lines[1].starts_with("replaced ? queued"), "{lines:?}");
    }

    #[test]
    fn a_supersede_key_goes_in_the_prompts_meta() {
        let mut p = PromptId::new(None);
        assert!(p.params("s", "t", false, None).pointer("/_meta/acpmux/supersede").is_none());
        p.supersede = Some("k".into());
        let params = p.params("s", "t", false, None);
        assert_eq!(params.pointer("/_meta/acpmux/supersede"), Some(&json!("k")));
    }

    #[tokio::test]
    async fn queue_prompt_returns_on_acceptance_while_the_turn_runs() {
        let (hub, client, dir) = daemon().await;
        let s = client
            .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
            .await
            .unwrap();
        let id = s["sessionId"].as_str().unwrap().to_owned();
        let prompt = PromptId::new(None);
        // "slow" streams for about a second; acceptance comes first.
        let accepted =
            queue_prompt(client.clone(), &id, "slow", false, None, &prompt).await.unwrap();
        assert_eq!(accepted["promptId"], prompt.id.as_str());
        let session = hub.resolve(&id).unwrap();
        assert!(session.turn().is_some(), "the turn should still be running");
        // The same id again is answered by the first run, not a second turn.
        let again = PromptId { resend: true, ..prompt.clone() };
        let dup = queue_prompt(client.clone(), &id, "slow", false, None, &again).await.unwrap();
        assert_eq!(dup["duplicate"], true);
        let user_messages =
            hub.events(&id, 0, 1000).unwrap().iter().filter(|e| e.kind == "user_message").count();
        assert_eq!(user_messages, 1);
        drop(dir);
    }

    /// A reply holds at most `hub::MAX_PAGE_BYTES` of a chat's history: the CLI reads on through
    /// the older pages for the replies it asked for, past 12 MB of tool output.
    #[tokio::test]
    async fn the_last_reply_is_found_behind_more_than_a_page_of_output() {
        let (hub, client, dir) = daemon().await;
        let s = client
            .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
            .await
            .unwrap();
        let id = s["sessionId"].as_str().unwrap().to_owned();
        let session = hub.resolve(&id).unwrap();
        let update = |update: Value| json!({"jsonrpc": "2.0", "method": method::SESSION_UPDATE, "params": {"sessionId": "agent-1", "update": update}});
        let text = |text: String| json!({"type": "text", "text": text});
        hub.append(
            &session,
            "in",
            "agent_message_chunk",
            update(json!({"sessionUpdate": "agent_message_chunk", "content": text("the reply".into())})),
        );
        for n in 0..12 {
            hub.append(
                &session,
                "in",
                "tool_call_update",
                update(json!({"sessionUpdate": "tool_call_update", "toolCallId": format!("call-{n}"),
                    "status": "completed", "content": [{"type": "content", "content": text("x".repeat(1 << 20))}]})),
            );
        }
        assert_eq!(last_replies(&client, &id, 1).await.unwrap(), vec!["the reply".to_owned()]);
        // `session tail --since`: every event after the cursor, through the newest.
        let after = events_after(&client, &id, 0, 100000).await.unwrap();
        assert_eq!(after.last().unwrap()["seq"], session.meta().last_seq);
        assert!(after.len() > 13, "{} events", after.len());
        drop(dir);
    }

    /// A prompt to a session whose agent must start again (it died, or the daemon restarted)
    /// is acknowledged when acpmux records it, before the agent has started (P1 v2).
    #[tokio::test]
    async fn a_prompt_is_accepted_when_recorded_before_the_agent_starts() {
        let gate = std::path::PathBuf::from("/tmp")
            .join(format!("acpmux-gate-{}", &uuid::Uuid::now_v7().simple().to_string()[20..]));
        std::fs::write(&gate, b"").unwrap();
        let env =
            BTreeMap::from([("FAKE_START_GATE".to_owned(), gate.to_string_lossy().into_owned())]);
        let (hub, client, dir) = daemon_with_env(env).await;
        let s = client
            .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
            .await
            .unwrap();
        let id = s["sessionId"].as_str().unwrap().to_owned();
        let session = hub.resolve(&id).unwrap();
        // The agent is gone; its next start waits on the gate.
        hub.detach_child(&session).await;
        std::fs::remove_file(&gate).unwrap();
        let prompt = PromptId::new(None);
        let accepted = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            queue_prompt(client.clone(), &id, "hello", false, None, &prompt),
        )
        .await
        .expect("accepted while the agent is still starting")
        .unwrap();
        assert_eq!(accepted["promptId"], prompt.id.as_str());
        let kinds: Vec<String> =
            hub.events(&id, 0, 1000).unwrap().iter().map(|e| e.kind.clone()).collect();
        assert!(kinds.iter().any(|k| k == "user_message"), "recorded: {kinds:?}");
        // Let the agent start; the turn completes.
        std::fs::write(&gate, b"").unwrap();
        for _ in 0..200 {
            if hub.events(&id, 0, 1000).unwrap().iter().any(|e| e.kind == "turn_result") {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        let _ = std::fs::remove_file(&gate);
        drop(dir);
    }

    #[test]
    fn a_turns_reply_is_none_when_the_log_holds_no_start_of_it() {
        let ev = |seq: u64, kind: &str| json!({"seq": seq, "dir": "mux", "kind": kind, "msg": {"turnId": "t1"}});
        assert_eq!(reply_of_turn(&[ev(1, "turn_result")], "t1"), None, "cut off");
        let whole = [ev(1, "turn_started"), ev(2, "turn_result")];
        assert_eq!(reply_of_turn(&whole, "t1"), Some(String::new()), "it said nothing");
    }
}
