//! The `send` tool: one message, or a batch (`messages`), to sessions by name or by tag, with
//! each message's text inline or read from a file. Coordinators batch-sent through a shell
//! function (`s(){ acpmux send --no-wait --from X "$1" "$(cat "$2")"; }`), which a chat draws as
//! raw shell; this is the same send as one tool call the chat draws as message cards (Leo,
//! 2026-10-30: "acpmux batch send tools given to you rendered consistently with other stuff").
//!
//! Every message goes through this daemon's outbox, as `acpmux send --no-wait` does
//! (`cli/run/send_async.rs`). A batch queues its messages one after another, in order, so two
//! messages to one session arrive in the order given, then waits for all their deliveries to
//! settle at once, inside one [`STATUS_WAIT`]: a batch answers as fast as one message. A bad
//! recipient is its own row's error; the rest still go.
//!
//! The call without `messages` and `tag` keeps its first shape: the same result fields and text,
//! the same errors. A tag or a batch answers with `results`, one row per recipient.

use super::*;
use std::collections::BTreeMap;

/// Most messages one call carries. A batch is a coordinator's round of orders (a handful of
/// lanes); a bound keeps one call inside a harness's tool timeout and its result readable.
pub(super) const MAX_MESSAGES: usize = 32;
/// Most sessions one tag reaches. Beyond it the item is refused, never cut short: a tag that wide
/// is a broadcast the sender did not mean (the CLI's `--tag --dry-run` lists it first).
pub(super) const MAX_TAG_SESSIONS: usize = 32;
/// Most recipients of one call, tags expanded. Over it nothing is sent.
pub(super) const MAX_RECIPIENTS: usize = 64;
/// Largest message file, in bytes. A message lands whole in the receiver's context: 256 KiB is
/// about 64k tokens, a third of a 200k-token context and more than any brief. A file past it is an
/// attachment (`acpmux send --attach`), which the receiver opens when it needs it.
pub(super) const MAX_FILE_BYTES: u64 = 256 << 10;

pub(super) fn tool() -> Value {
    json!({
        "name": "send",
        "description": "Message another agent session: a lane, a coordinator, or a chat on a peer (host/name). Use it instead of running `acpmux send` in a shell; to message several sessions, batch them in one call with messages instead of a shell loop. It goes through this daemon's outbox, like `acpmux send --no-wait`: it returns within seconds with the message's promptId and delivery id, and a slow target or a peer that is down is retried; it does not wait for a reply (read one later with last). The receiver's chat shows the message as yours. By default it steers: an agent in the middle of a turn reads it at its next tool step; steer: false queues it behind that turn. With messages or tag, the result has one row per recipient (to, ok, promptId, deliveryId, status, error); one bad recipient does not stop the others.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "to": {"type": "string", "description": "The session: its name, id, or host/name for a session on a peer (as ls lists them)."},
                "text": {"type": "string", "description": "The message, self-contained."},
                "steer": {"type": "boolean", "description": "true (default): into a running turn at its next tool step. false: queued behind the running turn."},
                "class": {"type": "string", "enum": ["block", "question", "result", "fyi", "blocker", "action"], "description": "What the message asks of the receiver: block or blocker (you cannot go on until it acts; wakes an idle receiver), question (you wait for its answer; wakes it too), result or action (work you finished or work for it; the default; wakes an idle receiver only when you started it or gave it its first work) or fyi (wakes no one)."},
                "pr": {"type": "integer", "description": "The pull request this message is about: the receiver's inbox threads it with the others about it."},
                "thread": {"type": "string", "description": "The thread this message goes in, a topic or a threadId from inbox_read (default: your messages about the PR its first line names, else all your messages)."},
                "file": {"type": "string", "description": "Instead of text: a file of yours whose contents are the message (UTF-8, at most 256 KiB). A relative path is from this chat's folder."},
                "tag": {"type": "string", "description": "Instead of to: every live session carrying this tag, key or key=value (as acpmux send --tag), at most 32, not yourself."},
                "supersede": {"type": "string", "description": "A key: your message still queued at the receiver under the same key is replaced by this one, so a correction is never read after the order it corrects."},
                "messages": {
                    "type": "array",
                    "maxItems": MAX_MESSAGES,
                    "description": "A batch: one message per item, sent in order. The fields above are each item's defaults; an item's to or tag replaces the default recipient, its text or file the default message.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "to": {"type": "string"},
                            "tag": {"type": "string"},
                            "text": {"type": "string"},
                            "file": {"type": "string"},
                            "steer": {"type": "boolean"},
                            "class": {"type": "string", "enum": ["block", "question", "result", "fyi", "blocker", "action"]},
                            "pr": {"type": "integer"},
                            "thread": {"type": "string"},
                            "supersede": {"type": "string"}
                        }
                    }
                }
            }
        }
    })
}

/// One message as the caller gave it, defaults applied.
#[derive(Debug, Clone, Default, PartialEq)]
pub(super) struct Item {
    pub to: Option<String>,
    pub tag: Option<String>,
    pub text: Option<String>,
    pub file: Option<String>,
    pub steer: bool,
    pub class: Option<String>,
    pub pr: Option<u64>,
    pub thread: Option<String>,
    pub supersede: Option<String>,
}

/// One recipient's message, ready to queue.
struct Target {
    index: usize,
    to: String,
    key: String,
    tag: Option<String>,
    text: String,
    item: Item,
}

/// `send`'s entry: the first shape when the call names one session, else the batch.
pub(super) async fn send(daemon: &Arc<Client>, args: &Value) -> Value {
    if args.get("messages").is_none() && arg(args, "tag").is_none() {
        return send_one(daemon, args).await;
    }
    send_batch(daemon, args).await
}

/// The items of a call: `messages`, each over the top-level defaults, or the call itself.
pub(super) fn items(args: &Value) -> Result<Vec<Result<Item, String>>, String> {
    let Some(messages) = args.get("messages") else {
        return Ok(vec![item_of(args, None)]);
    };
    let Some(list) = messages.as_array() else {
        return Err("messages must be an array of objects".to_owned());
    };
    if list.is_empty() {
        return Err("messages is empty".to_owned());
    }
    if list.len() > MAX_MESSAGES {
        return Err(format!("messages has {} items, at most {MAX_MESSAGES}", list.len()));
    }
    Ok(list
        .iter()
        .map(
            |m| {
                if m.is_object() { item_of(m, Some(args)) } else { Err("not an object".to_owned()) }
            },
        )
        .collect())
}

/// An item from `own`'s fields over `defaults`'. The recipient (to or tag) and the message
/// (text or file) each come whole from the item when it names one, else from the defaults.
fn item_of(own: &Value, defaults: Option<&Value>) -> Result<Item, String> {
    let field = |key: &str| own.get(key).or_else(|| defaults.and_then(|d| d.get(key)));
    let who = pick(own, defaults, "to", "tag");
    let body = pick(own, defaults, "text", "file");
    let class_of = json!({"class": field("class").cloned().unwrap_or(Value::Null)});
    let item = Item {
        to: arg(who, "to").map(str::to_owned),
        tag: arg(who, "tag").map(str::to_owned),
        text: body.get("text").and_then(Value::as_str).map(str::to_owned),
        file: arg(body, "file").map(str::to_owned),
        steer: field("steer").and_then(Value::as_bool).unwrap_or(true),
        class: send_class(&class_of)?,
        pr: field("pr").and_then(Value::as_u64),
        thread: field("thread")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(str::to_owned),
        supersede: field("supersede")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(str::to_owned),
    };
    match (&item.to, &item.tag) {
        (Some(_), Some(_)) => return Err("give to or tag, not both".to_owned()),
        (None, None) => return Err("to (or tag) is required".to_owned()),
        _ => {}
    }
    match (&item.text, &item.file) {
        (Some(_), Some(_)) => Err("give text or file, not both".to_owned()),
        (None, None) => Err("text (or file) is required".to_owned()),
        _ => Ok(item),
    }
}

/// Where an item's pair of fields (to or tag, text or file) comes from: the item when it gives
/// either, else the defaults.
fn pick<'v>(own: &'v Value, defaults: Option<&'v Value>, a: &str, b: &str) -> &'v Value {
    let given = |k: &str| own.get(k).is_some_and(|v| !v.is_null());
    match defaults {
        Some(d) if !given(a) && !given(b) => d,
        _ => own,
    }
}

/// The message: its text, or its file's contents.
fn body(item: &Item) -> Result<String, String> {
    let text = match (&item.text, &item.file) {
        (Some(text), _) => text.clone(),
        (None, Some(path)) => read_message_file(path)?,
        (None, None) => return Err("text (or file) is required".to_owned()),
    };
    if text.trim().is_empty() {
        return Err(
            if item.file.is_some() { "the file is empty" } else { "text is empty" }.to_owned()
        );
    }
    Ok(text)
}

/// A message file: a regular file of this user's, UTF-8, at most [`MAX_FILE_BYTES`]. A relative
/// path is from this server's folder, the chat's (its harness starts it there). Another user's
/// file is refused even when it is readable: a message goes to other sessions and peers, so it
/// carries only the sender's own files.
pub(super) fn read_message_file(path: &str) -> Result<String, String> {
    use std::io::Read;
    let path = std::path::Path::new(path);
    let shown = path.display();
    let file = std::fs::File::open(path).map_err(|e| format!("cannot read {shown}: {e}"))?;
    // The open file's own metadata, so what is checked is what is read.
    let meta = file.metadata().map_err(|e| format!("cannot read {shown}: {e}"))?;
    if !meta.is_file() {
        return Err(format!("{shown} is not a regular file"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // SAFETY: geteuid has no preconditions.
        let me = unsafe { libc::geteuid() };
        if meta.uid() != me {
            return Err(format!("{shown} is not your file: send only files you own"));
        }
    }
    if meta.len() > MAX_FILE_BYTES {
        return Err(format!(
            "{shown} is {} KiB, more than {} KiB: send it with acpmux send --attach",
            meta.len() >> 10,
            MAX_FILE_BYTES >> 10
        ));
    }
    let mut bytes = Vec::new();
    // A file that grew after the check is still read only to the bound.
    file.take(MAX_FILE_BYTES.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read {shown}: {e}"))?;
    if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > MAX_FILE_BYTES {
        return Err(format!("{shown} grew past {} KiB while it was read", MAX_FILE_BYTES >> 10));
    }
    String::from_utf8(bytes).map_err(|_| {
        format!("{shown} is not UTF-8 text: send a binary file with acpmux send --attach")
    })
}

/// `send` with one session (the first shape): its result fields, text and errors are the ones
/// this tool always gave; only `file` and `supersede` are new.
async fn send_one(daemon: &Arc<Client>, args: &Value) -> Value {
    if arg(args, "to").is_none()
        || (args.get("text").and_then(Value::as_str).is_none() && arg(args, "file").is_none())
    {
        return error_result("to and text are required".to_owned());
    }
    let item = match item_of(args, None) {
        Ok(item) => item,
        Err(e) => return error_result(e),
    };
    let text = match body(&item) {
        Ok(text) => text,
        Err(e) => return error_result(e),
    };
    let to = item.to.clone().unwrap_or_default();
    let key = match crate::cli::orchestrate::expand_session_key(&to) {
        Ok(key) => key,
        Err(e) => return refusal(e),
    };
    let target = Target { index: 0, to: to.clone(), key: key.clone(), tag: None, text, item };
    let (prompt, queued) = match queue(daemon, &target).await {
        Ok(sent) => sent,
        Err(e) => return refusal(e),
    };
    let row = settle(daemon, &target, &prompt, queued).await;
    let state = row["status"].as_str().unwrap_or("queued").to_owned();
    let delivery = row["deliveryId"].as_str().unwrap_or_default().to_owned();
    if row["ok"] == json!(false) {
        let error = row["error"].as_str().unwrap_or("delivery failed");
        return error_result(format!("Not sent to {to} (delivery {delivery}): {error}"));
    }
    let mut structured = json!({"deliveryId": delivery, "target": key, "sessionId": row["sessionId"],
        "promptId": prompt.id, "status": state, "accepted": row["accepted"], "delivery": row["delivery"]});
    if target.item.supersede.is_some() {
        structured["replaced"] = row["replaced"].clone();
        structured["replacedPromptIds"] = row["replacedPromptIds"].clone();
    }
    ok(sent_line(&row), structured)
}

/// `send` with `messages` or `tag`: every item's recipients, queued in order, then settled
/// together. A row per recipient; an item that names no one is one row with its error.
async fn send_batch(daemon: &Arc<Client>, args: &Value) -> Value {
    let items = match items(args) {
        Ok(items) => items,
        Err(e) => return error_result(e),
    };
    let mut sessions: Option<Vec<Value>> = None;
    let mut targets = Vec::new();
    let mut rows: BTreeMap<(usize, usize), Value> = BTreeMap::new();
    for (index, item) in items.into_iter().enumerate() {
        let failed = |to: &str, tag: Option<&str>, error: String| {
            json!({"index": index, "to": to, "tag": tag, "ok": false, "promptId": null,
                "deliveryId": null, "status": "failed", "error": error})
        };
        let item = match item {
            Ok(item) => item,
            Err(e) => {
                rows.insert((index, 0), failed("", None, e));
                continue;
            }
        };
        let (to, tag) = (item.to.clone().unwrap_or_default(), item.tag.clone());
        let text = match body(&item) {
            Ok(text) => text,
            Err(e) => {
                rows.insert((index, 0), failed(&to, tag.as_deref(), e));
                continue;
            }
        };
        let recipients = match &tag {
            None => crate::cli::orchestrate::expand_session_key(&to)
                .map(|key| vec![(key, to.clone())])
                .map_err(|e| format!("{e:#}")),
            Some(tag) => tag_recipients(daemon, &mut sessions, tag).await,
        };
        match recipients {
            Ok(list) => targets.extend(list.into_iter().map(|(key, name)| Target {
                index,
                to: name,
                key,
                tag: tag.clone(),
                text: text.clone(),
                item: item.clone(),
            })),
            Err(e) => {
                rows.insert((index, 0), failed(tag.as_deref().unwrap_or(&to), tag.as_deref(), e));
            }
        }
    }
    if targets.len() > MAX_RECIPIENTS {
        return error_result(format!(
            "this send reaches {} sessions, at most {MAX_RECIPIENTS}: nothing was sent",
            targets.len()
        ));
    }
    // Queued one after another, so two messages to one session keep their order.
    let mut queued = Vec::new();
    for (seat, target) in targets.iter().enumerate() {
        match queue(daemon, target).await {
            Ok((prompt, answer)) => queued.push((seat, target, prompt, answer)),
            Err(e) => {
                let row = json!({"index": target.index, "to": target.to, "target": target.key,
                    "tag": target.tag, "ok": false, "promptId": null, "deliveryId": null,
                    "status": "failed", "error": format!("{e:#}")});
                rows.insert((target.index, seat.saturating_add(1)), row);
            }
        }
    }
    // Settled together: the whole batch waits one STATUS_WAIT at most.
    let settled = futures::future::join_all(
        queued
            .iter()
            .map(|(_, target, prompt, answer)| settle(daemon, target, prompt, answer.clone())),
    )
    .await;
    for ((seat, target, ..), row) in queued.iter().zip(settled) {
        rows.insert((target.index, seat.saturating_add(1)), row);
    }
    batch_result(rows.into_values().collect())
}

/// A tag's recipients, `(key, name)`, from one session list per call (`fanout::tag_targets`).
async fn tag_recipients(
    daemon: &Arc<Client>,
    sessions: &mut Option<Vec<Value>>,
    tag: &str,
) -> Result<Vec<(String, String)>, String> {
    if sessions.is_none() {
        let listed = daemon
            .whole_list(method::MUX_SESSIONS, json!({}))
            .await
            .map_err(|e| format!("cannot list the sessions: {e:#}"))?;
        *sessions =
            Some(listed.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default());
    }
    let all = sessions.as_deref().unwrap_or_default();
    let own = std::env::var(SESSION_ENV).ok();
    let found = crate::cli::run::fanout::tag_targets(all, tag, own.as_deref());
    if found.is_empty() {
        return Err(format!("no live session carries the tag {tag}"));
    }
    if found.len() > MAX_TAG_SESSIONS {
        return Err(format!(
            "the tag {tag} names {} sessions, at most {MAX_TAG_SESSIONS}: nothing sent to them; narrow it with key=value",
            found.len()
        ));
    }
    Ok(found)
}

/// Hand one message to the outbox (`_acpmux/send_queue`).
async fn queue(daemon: &Arc<Client>, target: &Target) -> Result<(PromptId, Value)> {
    let mut prompt = PromptId::new(None);
    prompt.class = target.item.class.clone();
    prompt.pr = target.item.pr;
    prompt.thread = target.item.thread.clone();
    prompt.supersede = target.item.supersede.clone();
    let request = prompt.params(&target.key, &target.text, target.item.steer, None);
    let queued = daemon.request(method::MUX_SEND_QUEUE, json!({"request": request})).await?;
    Ok((prompt, queued))
}

/// Wait up to [`STATUS_WAIT`] for a queued message's delivery to settle; its row.
async fn settle(daemon: &Arc<Client>, target: &Target, prompt: &PromptId, queued: Value) -> Value {
    let delivery = queued.get("deliveryId").and_then(Value::as_str).unwrap_or_default().to_owned();
    let wait_ms = u64::try_from(STATUS_WAIT.as_millis()).unwrap_or(u64::MAX);
    let wait = json!({"deliveryId": delivery, "waitMs": wait_ms});
    let status = daemon.request(method::MUX_SEND_STATUS, wait).await.unwrap_or(queued);
    let state = status.get("status").and_then(Value::as_str).unwrap_or("queued").to_owned();
    let accepted = status.get("accepted").cloned().unwrap_or(Value::Null);
    let session_id = accepted.get("sessionId").cloned().unwrap_or_else(|| json!(target.key));
    let mut row = json!({"index": target.index, "to": target.to, "target": target.key,
        "tag": target.tag, "ok": true, "promptId": prompt.id, "deliveryId": delivery,
        "status": state, "sessionId": session_id, "accepted": accepted});
    // A refusal the target gave at once (its folder's trust, a paused agent pair) is this row's
    // error, as `acpmux send --no-wait` says it.
    if matches!(state.as_str(), "failed" | "held") {
        row["ok"] = json!(false);
        row["error"] =
            json!(status.get("error").and_then(Value::as_str).unwrap_or("delivery failed"));
        return row;
    }
    row["delivery"] = json!(if state != "delivered" {
        "sending"
    } else if accepted.get("steer") == Some(&json!(true)) {
        "next_step"
    } else if accepted.get("queued") == Some(&json!(true)) {
        "queued"
    } else {
        "started"
    });
    if target.item.supersede.is_some() {
        // null until delivered, or when the target's daemon predates the key.
        row["replaced"] = accepted.get("replaced").cloned().unwrap_or(Value::Null);
        row["replacedPromptIds"] =
            accepted.get("replacedPromptIds").cloned().unwrap_or(Value::Null);
    }
    row
}

/// One row's line, as the first shape always said it.
fn sent_line(row: &Value) -> String {
    let s = |k: &str| row[k].as_str().unwrap_or_default();
    let (to, prompt_id, delivery) = (s("to"), s("promptId"), s("deliveryId"));
    if row["ok"] == json!(false) {
        return format!("Not sent to {to}: {}", s("error"));
    }
    let how = match s("delivery") {
        "next_step" => "steered into its running turn: it reads it at its next tool step",
        "queued" => "queued behind its running turn: it reads it when that turn ends",
        "started" => "it started a turn with it",
        _ => {
            return format!(
                "On its way to {to} (delivery {delivery}, promptId {prompt_id}): this daemon keeps \
delivering it, retrying while the target is slow or its peer is down. Do not send it again; info \
{to} shows it once it arrives."
            );
        }
    };
    format!("Sent to {to}: {how} (promptId {prompt_id}).")
}

/// The batch's result: a line per row and `results`; an error only when nothing went.
fn batch_result(results: Vec<Value>) -> Value {
    let sent = results.iter().filter(|r| r["ok"] == json!(true)).count();
    let failed = results.len().saturating_sub(sent);
    let mut lines: Vec<String> = results.iter().map(sent_line).collect();
    lines.push(format!("{sent} of {} sent.", results.len()));
    let structured = json!({"results": results, "sent": sent, "failed": failed});
    let mut out = ok(lines.join("\n"), structured);
    if sent == 0 {
        out["isError"] = json!(true);
    }
    out
}
