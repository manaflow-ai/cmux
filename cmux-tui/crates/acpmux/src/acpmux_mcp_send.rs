//! The `send` tool: one message, or a batch (`messages`), to sessions by name or by tag, with
//! each message's text inline or read from a file. Coordinators batch-sent through a shell
//! function (`s(){ acpmux send --no-wait --from X "$1" "$(cat "$2")"; }`), which a chat draws as
//! raw shell; this is the same send as one tool call the chat draws as message cards (Leo,
//! 2026-10-30: "acpmux batch send tools given to you rendered consistently with other stuff").
//!
//! Every message goes through this daemon's outbox, as `acpmux send --no-wait` does
//! (`cli/run/send_async.rs`). A batch sends to each session in turn and to different sessions
//! side by side ([`in_order`]), inside one [`STATUS_WAIT`]: a batch answers as fast as one
//! message. A bad recipient is its own row's error; the rest still go.
//!
//! The call without `messages` and `tag` keeps its first shape: the same result fields and text,
//! the same errors. A tag or a batch answers with `results`, one row per recipient.

use super::*;
use cmux_json::JsonSet as _;
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
/// How long a batch gives each session name to resolve to its id ([`aliases`]), before its
/// own wait for the deliveries.
const RESOLVE_WAIT: Duration = Duration::from_secs(2);

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
                "file": {"type": "string", "description": "Instead of text: a file of yours whose contents are the message (UTF-8, at most 256 KiB). Best an absolute path; a relative one is read from the folder your agent runs in."},
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
pub(super) struct Target {
    pub index: usize,
    /// The session as the caller named it, or as its tag listed it.
    pub to: String,
    /// What the outbox routes it by: the name, an id, or a peer's `peer/id`.
    pub key: String,
    pub tag: Option<String>,
    pub text: String,
    pub item: Item,
}

impl Target {
    /// Its result row, before the outbox answered.
    pub(super) fn row(&self, ok: bool, status: &str, error: Option<String>) -> Value {
        let mut row = json!({"index": self.index, "to": self.to, "target": self.key,
            "tag": self.tag, "ok": ok, "promptId": null, "deliveryId": null, "status": status});
        if let Some(error) = error {
            row.set("error", json!(error));
        }
        row
    }
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
/// path is from this server's folder, which it inherits from the chat's agent. Another user's
/// file is refused even when it is readable: a message goes to other sessions and peers, so it
/// carries only the sender's own files.
pub(super) fn read_message_file(path: &str) -> Result<String, String> {
    use std::io::Read;
    let path = std::path::Path::new(path);
    let shown = path.display();
    let mut open = std::fs::OpenOptions::new();
    open.read(true);
    // Non-blocking, so a FIFO at the path is refused below instead of waiting for a writer.
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::custom_flags(&mut open, libc::O_NONBLOCK);
    let file = open.open(path).map_err(|e| format!("cannot read {shown}: {e}"))?;
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
            meta.len() / 1024,
            MAX_FILE_BYTES / 1024
        ));
    }
    let mut bytes = Vec::new();
    // A file that grew after the check is still read only to the bound.
    file.take(MAX_FILE_BYTES.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read {shown}: {e}"))?;
    if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > MAX_FILE_BYTES {
        return Err(format!("{shown} grew past {} KiB while it was read", MAX_FILE_BYTES / 1024));
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
    let row = settle(daemon, &target, &prompt, queued, STATUS_WAIT).await;
    let field = |k: &str| row.get(k).cloned().unwrap_or(Value::Null);
    let text_of = |k: &str| row.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    let delivery = text_of("deliveryId");
    if !row_ok(&row) {
        let error = row.get("error").and_then(Value::as_str).unwrap_or("delivery failed");
        return error_result(format!("Not sent to {to} (delivery {delivery}): {error}"));
    }
    let mut structured = json!({"deliveryId": delivery, "target": key, "sessionId": field("sessionId"),
        "promptId": prompt.id, "status": field("status"), "accepted": field("accepted"),
        "delivery": field("delivery")});
    if target.item.supersede.is_some() {
        structured.set("replaced", field("replaced"));
        structured.set("replacedPromptIds", field("replacedPromptIds"));
    }
    ok(sent_line(&row), structured)
}

/// `send` with `messages` or `tag`: every item's recipients, then the messages, a row per
/// recipient; an item that names no one is one row with its error.
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
    let chains = same_session(&aliases(daemon, &targets).await);
    let now = tokio::time::Instant::now();
    let deadline = now.checked_add(STATUS_WAIT).unwrap_or(now);
    let sent = futures::future::join_all(chains.into_iter().map(|chain| {
        in_order(&targets, chain, deadline, move |target, wait| async move {
            match queue(daemon, target).await {
                Ok((prompt, queued)) => settle(daemon, target, &prompt, queued, wait).await,
                Err(e) => target.row(false, "failed", Some(format!("{e:#}"))),
            }
        })
    }))
    .await;
    for (seat, row) in sent.into_iter().flatten() {
        let index = targets.get(seat).map_or(0, |t| t.index);
        rows.insert((index, seat.saturating_add(1)), row);
    }
    batch_result(rows.into_values().collect())
}

/// The batch's targets in chains, each the seats (indexes into `targets`) of one session in the
/// order given. `aliases` holds, per target, every name it may go by ([`aliases`]); two targets
/// that share one, directly or through others, are one chain.
pub(super) fn same_session(aliases: &[Vec<String>]) -> Vec<Vec<usize>> {
    // Union-find over the seats: each seat joins the first seat that had any of its aliases.
    let mut parent: Vec<usize> = (0..aliases.len()).collect();
    fn root(parent: &[usize], mut seat: usize) -> usize {
        while let Some(&up) = parent.get(seat) {
            if up == seat {
                break;
            }
            seat = up;
        }
        seat
    }
    let mut first: BTreeMap<&str, usize> = BTreeMap::new();
    for (seat, names) in aliases.iter().enumerate() {
        for name in names {
            match first.get(name.as_str()) {
                Some(&other) => {
                    let (a, b) = (root(&parent, other), root(&parent, seat));
                    // The older seat stays the root, so a chain's order is its first seat's.
                    if let Some(slot) = parent.get_mut(a.max(b)) {
                        *slot = a.min(b);
                    }
                }
                None => {
                    first.insert(name, seat);
                }
            }
        }
    }
    let mut chains: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for seat in 0..aliases.len() {
        chains.entry(root(&parent, seat)).or_default().push(seat);
    }
    chains.into_values().collect()
}

/// Every name each target may go by, so a session named two ways (its name, its id,
/// `host/name`, a tag's `peer/id`) is one chain: its key and name, and for a named target its
/// session id, resolved (each distinct name once, side by side, within [`RESOLVE_WAIT`]) to the
/// form a tag's target has (`peer/id` on a peer, as [`crate::cli::resolve::routed_id`] gives).
/// A name that resolves to nothing cannot be told apart from any session it might be: all such
/// names are one chain, and one on a peer (`host/...`) also joins every target on that host.
pub(super) async fn aliases(daemon: &Arc<Client>, targets: &[Target]) -> Vec<Vec<String>> {
    let mut names: Vec<&str> =
        targets.iter().filter(|t| t.tag.is_none()).map(|t| t.key.as_str()).collect();
    names.sort_unstable();
    names.dedup();
    let resolved: BTreeMap<&str, Option<String>> =
        futures::future::join_all(names.into_iter().map(|name| async move {
            let id = tokio::time::timeout(RESOLVE_WAIT, crate::cli::run::resolve_id(daemon, name))
                .await
                .ok()
                .and_then(Result::ok);
            (name, id)
        }))
        .await
        .into_iter()
        .collect();
    let unresolved =
        |t: &Target| t.tag.is_none() && !matches!(resolved.get(t.key.as_str()), Some(Some(_)));
    let host_of = |key: &str| key.split_once('/').map(|(host, _)| format!("\0host:{host}"));
    // The hosts some unresolved name is on: every target there is in its chain.
    let dark: Vec<String> =
        targets.iter().filter(|t| unresolved(t)).filter_map(|t| host_of(&t.key)).collect();
    targets
        .iter()
        .map(|t| {
            let mut names = vec![t.key.clone(), t.to.clone()];
            if let Some(Some(id)) = resolved.get(t.key.as_str()).filter(|_| t.tag.is_none()) {
                names.push(id.clone());
            }
            if unresolved(t) {
                names.push("\0unresolved".to_owned());
            }
            if let Some(host) = host_of(&t.key).or_else(|| host_of(&t.to))
                && dark.contains(&host)
            {
                names.push(host);
            }
            names
        })
        .collect()
}

/// One session's messages, in order: each is queued only once the one before it settled (the
/// receiver took it, or refused it). The outbox runs each delivery on its own and retries it, so
/// two queued at once can arrive swapped, and a `supersede` correction be replaced by the order
/// it corrects. A message whose predecessor is still on its way at `deadline` is not sent; its
/// row says so. Chains to different sessions run side by side, so a batch answers inside one
/// [`STATUS_WAIT`].
pub(super) async fn in_order<'t, F, Fut>(
    targets: &'t [Target],
    chain: Vec<usize>,
    deadline: tokio::time::Instant,
    send: F,
) -> Vec<(usize, Value)>
where
    F: Fn(&'t Target, Duration) -> Fut,
    Fut: std::future::Future<Output = Value>,
{
    let mut rows = Vec::new();
    let mut before: Option<String> = None;
    for seat in chain {
        let Some(target) = targets.get(seat) else { continue };
        if let Some(delivery) = &before {
            let why = format!(
                "not sent: the message before it to {} (delivery {delivery}) is still on its way, \
and this one must not arrive first; send it again once info {} shows that one arrived",
                target.to, target.to
            );
            rows.push((seat, target.row(false, "failed", Some(why))));
            continue;
        }
        let wait = deadline.saturating_duration_since(tokio::time::Instant::now());
        let row = send(target, wait).await;
        let status = row.get("status").and_then(Value::as_str).unwrap_or_default();
        if !matches!(status, "delivered" | "failed" | "held") {
            before = Some(row.get("deliveryId").and_then(Value::as_str).unwrap_or("?").to_owned());
        }
        rows.push((seat, row));
    }
    rows
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

/// Wait up to `wait` for a queued message's delivery to settle; its row.
async fn settle(
    daemon: &Arc<Client>,
    target: &Target,
    prompt: &PromptId,
    queued: Value,
    wait: Duration,
) -> Value {
    let delivery = queued.get("deliveryId").and_then(Value::as_str).unwrap_or_default().to_owned();
    let wait_ms = u64::try_from(wait.as_millis()).unwrap_or(u64::MAX);
    let ask = json!({"deliveryId": delivery, "waitMs": wait_ms});
    let status = daemon.request(method::MUX_SEND_STATUS, ask).await.unwrap_or(queued);
    let state = status.get("status").and_then(Value::as_str).unwrap_or("queued").to_owned();
    let accepted = status.get("accepted").cloned().unwrap_or(Value::Null);
    let session_id = accepted.get("sessionId").cloned().unwrap_or_else(|| json!(target.key));
    // A refusal the target gave at once (its folder's trust, a paused agent pair) is this row's
    // error, as `acpmux send --no-wait` says it.
    let refused = matches!(state.as_str(), "failed" | "held");
    let error = refused.then(|| {
        status.get("error").and_then(Value::as_str).unwrap_or("delivery failed").to_owned()
    });
    let mut row = target.row(!refused, &state, error);
    row.set("promptId", json!(prompt.id));
    row.set("deliveryId", json!(delivery));
    row.set("sessionId", session_id);
    if refused {
        row.set("accepted", accepted);
        return row;
    }
    let how = if state != "delivered" {
        "sending"
    } else if accepted.get("steer") == Some(&json!(true)) {
        "next_step"
    } else if accepted.get("queued") == Some(&json!(true)) {
        "queued"
    } else {
        "started"
    };
    row.set("delivery", json!(how));
    if target.item.supersede.is_some() {
        // null until delivered, or when the target's daemon predates the key.
        row.set("replaced", accepted.get("replaced").cloned().unwrap_or(Value::Null));
        row.set(
            "replacedPromptIds",
            accepted.get("replacedPromptIds").cloned().unwrap_or(Value::Null),
        );
    }
    row.set("accepted", accepted);
    row
}

fn row_ok(row: &Value) -> bool {
    row.get("ok").and_then(Value::as_bool).unwrap_or(false)
}

/// One row's line, as the first shape always said it.
fn sent_line(row: &Value) -> String {
    let s = |k: &str| row.get(k).and_then(Value::as_str).unwrap_or_default();
    let (to, prompt_id, delivery) = (s("to"), s("promptId"), s("deliveryId"));
    if !row_ok(row) {
        if to.is_empty() {
            let index = row.get("index").cloned().unwrap_or(Value::Null);
            return format!("Not sent (messages[{index}]): {}", s("error"));
        }
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
    let sent = results.iter().filter(|r| row_ok(r)).count();
    let failed = results.len().saturating_sub(sent);
    let mut lines: Vec<String> = results.iter().map(sent_line).collect();
    lines.push(format!("{sent} of {} sent.", results.len()));
    let structured = json!({"results": results, "sent": sent, "failed": failed});
    let mut out = ok(lines.join("\n"), structured);
    if sent == 0 {
        out.set("isError", json!(true));
    }
    out
}
