//! `acpmux transfer SESSION --to SOCKET`: moves a chat from this daemon to another one (a sibling
//! build's) through `_acpmux/transfer_*` (`hub/transfer_out.rs`). The reference client of the
//! move: it pages the bundle from one daemon to the other, and gives the chat back on a failure.

use super::*;
use cmux_json::JsonSet as _;

/// Moves `session` to the daemon at `to`.
pub(super) async fn run(
    session: &str,
    to: &std::path::Path,
    cwd: Option<String>,
    name: Option<String>,
    running: (bool, bool),
    acked_handoff: bool,
    json_out: bool,
) -> Result<()> {
    let src = connect(true).await?;
    let dst = Client::connect(to).await?;
    let dst_init = dst
        .request(
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-transfer"}}),
        )
        .await?;
    let id = resolve_id(&src, session).await?;
    // The source asks the target itself if this client goes away midway (`hub/transfer_watch.rs`).
    let socket = std::path::absolute(to)?;
    // Absolute, as the watch's: an outbox that finds the chat moved hands its messages to the
    // daemon at this socket (`server/outbox.rs` `hand_to_socket`), whatever its own folder.
    let to_meta = json!({"socket": socket});
    let mut watch = json!({"socket": socket});
    // Carried to the begin as its own flag (`begin_move_after`).
    if acked_handoff {
        watch.set("ackedHandoff", json!(true));
    }
    let moved =
        move_chat(&src, &dst, &dst_init, &id, Some(watch), cwd, name, running, to_meta).await?;
    if json_out {
        print_json(&moved);
    } else {
        println!("moved {} to {}", field(&moved, "name").as_str().unwrap_or(&id), to.display());
    }
    Ok(())
}

/// A move begun on the source: the chat is frozen there and its bundle made. `stage_id`: the
/// target's staged prefix of a pre-copied move, whose bundle holds only what follows it.
pub(super) struct Begun {
    begin: Value,
    transfer_id: String,
    epoch: u64,
    stage_id: Option<String>,
}

/// A prefix of the chat staged on the target before the freeze (`hub/transfer_precopy.rs`).
pub(super) struct Staged {
    prepare_id: String,
    after_seq: u64,
    stage_id: String,
}

/// Freezes the chat `id` on `src` and makes its bundle (`_acpmux/transfer_begin`). `watch` is
/// the target as the source's watch reaches it if the move's client goes away
/// (`{socket}`, or `{socket, ssh}` for a daemon on another machine, `hub/transfer_watch.rs`).
pub(super) async fn begin_move(
    src: &Client,
    id: &str,
    watch: Option<Value>,
    running: (bool, bool),
) -> Result<Begun> {
    begin_move_after(src, id, watch, running, None).await
}

/// [`begin_move`] after `staged` (see [`precopy`]), whose bundle then holds only the records
/// past its prefix; a prefix the source no longer holds as it was is moved in full (the refusal
/// gave the chat back first).
pub(super) async fn begin_staged(
    src: &Client,
    id: &str,
    watch: Option<Value>,
    running: (bool, bool),
    staged: Option<&Staged>,
) -> Result<Begun> {
    if let Some(staged) = staged {
        match begin_move_after(src, id, watch.clone(), running, Some(staged)).await {
            Err(e) if refused_as(&e, "transfer.diverged") => {}
            begun => return begun,
        }
    }
    begin_move(src, id, watch, running).await
}

/// [`begin_move`]; after `staged`, the bundle holds only the records past its prefix.
async fn begin_move_after(
    src: &Client,
    id: &str,
    watch: Option<Value>,
    (interrupt, after_turn): (bool, bool),
    staged: Option<&Staged>,
) -> Result<Begun> {
    // This client hands the bundle on only to a receiver whose own `initialize` listed queue
    // approval when it carries approved prompts that still wait (`receiver_takes`).
    // `afterTurn`: a running turn ends on its own first, the chat unfrozen meanwhile
    // (`hub/transfer_out.rs` `transfer_begin`); an older daemon ignores it and refuses as busy.
    let mut begin_params = json!({"sessionId": id, "interrupt": interrupt,
                                  "afterTurn": after_turn, "gatesQueueApproval": true});
    if let Some(mut to) = watch {
        // The acked hand-off (`hub/transfer_handoff.rs`) is the begin's flag, not the watch's.
        if to.as_object_mut().and_then(|o| o.remove("ackedHandoff")) == Some(json!(true)) {
            begin_params.set("ackedHandoff", json!(true));
        }
        begin_params.set("to", to);
    }
    if let Some(staged) = staged {
        begin_params.set("prepareId", json!(staged.prepare_id));
        begin_params.set("afterSeq", json!(staged.after_seq));
    }
    let begin = src.request("_acpmux/transfer_begin", begin_params).await?;
    let transfer_id = field(&begin, "transferId").as_str().unwrap_or_default().to_owned();
    let epoch = match begin.get("epoch") {
        None => 0,
        Some(value) => value
            .as_u64()
            .ok_or_else(|| anyhow!("transfer_begin: epoch must be an unsigned integer"))?,
    };
    let stage_id = staged.filter(|_| begin.get("prefix").is_some()).map(|s| s.stage_id.clone());
    Ok(Begun { begin, transfer_id, epoch, stage_id })
}

/// Gives the chat back on the source: the move did not happen.
pub(super) async fn abort_move(src: &Client, id: &str, begun: &Begun) {
    let abort = json!({"sessionId": id, "transferId": begun.transfer_id, "epoch": begun.epoch});
    if let Err(e) = src.request("_acpmux/transfer_abort", abort).await {
        eprintln!("acpmux: the move failed and the chat stays frozen here: {e}");
    }
}

/// Moves the chat `id` from `src` to `dst`, both clients of the daemons' local sockets, and
/// commits it on `src` with `to_meta` (plus the chat's id there) as where it went.
#[allow(clippy::too_many_arguments)]
pub(super) async fn move_chat(
    src: &Client,
    dst: &Client,
    dst_init: &Value,
    id: &str,
    watch: Option<Value>,
    cwd: Option<String>,
    name: Option<String>,
    running: (bool, bool),
    to_meta: Value,
) -> Result<Value> {
    // Pre-copied when both daemons can: the freeze then costs only what changed since. A target
    // that lost its stage refuses the bundle, and the move is made again in full.
    let staged = precopy(src, dst, dst_init, id).await;
    let begun = begin_staged(src, id, watch.clone(), running, staged.as_ref()).await?;
    if begun.stage_id.is_some() {
        let (cwd, name, meta) = (cwd.clone(), name.clone(), to_meta.clone());
        match finish_move(src, dst, dst_init, id, &begun, cwd, name, meta).await {
            Err(e) if refused_as(&e, "transfer.unstaged") => {}
            moved => return moved,
        }
    } else {
        return finish_move(src, dst, dst_init, id, &begun, cwd, name, to_meta).await;
    }
    let begun = begin_move(src, id, watch, running).await?;
    finish_move(src, dst, dst_init, id, &begun, cwd, name, to_meta).await
}

fn refused_as(e: &anyhow::Error, code: &str) -> bool {
    format!("{e:#}").contains(code)
}

/// Whether a daemon's `initialize` or `_acpmux/status` reply lists pre-copy.
fn lists_precopy(reply: &Value, pointer: &str) -> bool {
    let ids = reply.pointer(pointer).and_then(Value::as_array);
    ids.is_some_and(|ids| ids.iter().any(|id| id == crate::capabilities::TRANSFER_PRECOPY))
}

/// The chat's history as of now staged on `dst`, with no freeze, when both daemons list
/// pre-copy; None (a full move) when either does not or any step fails.
pub(super) async fn precopy(
    src: &Client,
    dst: &Client,
    dst_init: &Value,
    id: &str,
) -> Option<Staged> {
    if !lists_precopy(dst_init, "/_meta/acpmux/capabilities") {
        return None;
    }
    let status = src.request(method::MUX_STATUS, json!({})).await.ok()?;
    if !lists_precopy(&status, "/capabilities") {
        return None;
    }
    // The copy `dst` still holds from the chat's last move, if any: the source prepares only
    // what came after it. A base either side refuses falls back to a full prefix.
    let base = dst.request("_acpmux/transfer_base", json!({"sessionId": id})).await.ok();
    let base = base.map(|b| field(&b, "base").clone()).filter(|b| !b.is_null());
    if let Some(base) = base
        && let Some(staged) = stage_prefix(src, dst, id, Some(base)).await
    {
        return Some(staged);
    }
    stage_prefix(src, dst, id, None).await
}

/// One prepare on `src`, staged on `dst`: from `base` when it is given and the source holds it.
async fn stage_prefix(src: &Client, dst: &Client, id: &str, base: Option<Value>) -> Option<Staged> {
    let mut params = json!({"sessionId": id});
    if let Some(base) = &base {
        params.set("base", base.clone());
    }
    let prepared = src.request("_acpmux/transfer_prepare", params).await.ok()?;
    if base.is_some() && field(&prepared, "base").is_null() {
        return None;
    }
    let stage = dst.request("_acpmux/transfer_stage", json!({"manifest": prepared})).await.ok()?;
    let stage_id = field(&stage, "stageId").as_str()?.to_owned();
    let receive_id = json!(stage_id);
    page_files(src, dst, &prepared, field(&prepared, "prepareId"), &receive_id, None).await.ok()?;
    dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage_id})).await.ok()?;
    Some(Staged {
        prepare_id: field(&prepared, "prepareId").as_str()?.to_owned(),
        after_seq: field(&prepared, "afterSeq").as_u64()?,
        stage_id,
    })
}

/// Whether the receiver may take the bundle `begin` made: one that carries prompts the owner
/// approved that still wait (`approvedWaiting`) goes only to a daemon whose own `initialize`
/// (`dst_init`, the reply on the connection that sends the bundle) listed queue approval. An
/// older one ignores `queue_approved` and would run them under their sender's rules alone; a
/// peer record or host name says nothing of the daemon at this socket (review of #28859).
pub(crate) fn receiver_takes(begin: &Value, dst_init: &Value) -> Result<()> {
    let Some(ids) =
        begin.get("approvedWaiting").filter(|v| v.as_array().is_some_and(|a| !a.is_empty()))
    else {
        return Ok(());
    };
    let features = dst_init.pointer("/_meta/acpmux/features").and_then(Value::as_array);
    let listed = features.is_some_and(|f| {
        f.iter().any(|f| f.as_str() == Some(crate::author::QUEUE_APPROVAL_FEATURE))
    });
    if listed {
        return Ok(());
    }
    let why = "the daemon it moves to does not list queue approval";
    let e = crate::hub::approved_prompts_error(ids.clone(), why);
    Err(anyhow::Error::from(crate::client::DaemonError(e)))
}

/// The rest of a move [`begin_move`] began: the bundle paged into a receive on `dst`, finished
/// there, and committed on `src`. A failure that leaves the chat nowhere else aborts the move.
#[allow(clippy::too_many_arguments)]
pub(super) async fn finish_move(
    src: &Client,
    dst: &Client,
    dst_init: &Value,
    id: &str,
    begun: &Begun,
    cwd: Option<String>,
    name: Option<String>,
    to_meta: Value,
) -> Result<Value> {
    let (begin, transfer_id) = (&begun.begin, &begun.transfer_id);
    if let Err(e) = receiver_takes(begin, dst_init) {
        abort_move(src, id, begun).await;
        return Err(e);
    }
    let mut receive_params = json!({"manifest": begin});
    if let Some(stage_id) = &begun.stage_id {
        receive_params.set("stageId", json!(stage_id));
    }
    let receive = match dst.request("_acpmux/transfer_receive", receive_params).await {
        Ok(receive) => receive,
        Err(e) => {
            abort_move(src, id, begun).await;
            return Err(e);
        }
    };
    let moved = match copy(
        src,
        dst,
        begin,
        receive.get("receiveId").unwrap_or(&Value::Null),
        begun.epoch,
        cwd,
        name,
    )
    .await
    {
        Ok(moved) => moved,
        // A finish whose answer was lost may have landed, and the target runs the queue then:
        // the source commits. Only a target that shows no such move lets the chat come back.
        Err(e) => match landed(dst, id, transfer_id).await {
            Some(true) => dst.request(method::MUX_INFO, json!({"sessionId": id})).await?,
            Some(false) => {
                abort_move(src, id, begun).await;
                return Err(e);
            }
            None => {
                eprintln!(
                    "acpmux: the move failed and the target cannot say whether it took the chat; it stays frozen here until the move is retried or aborted"
                );
                return Err(e);
            }
        },
    };
    let mut to_meta = to_meta;
    to_meta.set("sessionId", moved.get("sessionId").cloned().unwrap_or(Value::Null));
    src.request(
        "_acpmux/transfer_commit",
        json!({"sessionId": id, "transferId": transfer_id, "to": to_meta, "epoch": begun.epoch}),
    )
    .await?;
    Ok(moved)
}

/// Whether the target took this move (its log has the `transferred_in` of `transfer_id`); `None`
/// when it cannot say.
async fn landed(dst: &Client, id: &str, transfer_id: &str) -> Option<bool> {
    let kinds = json!({"sessionId": id, "afterSeq": 0, "kinds": ["transferred_in"]});
    match dst.request(method::MUX_EVENTS, kinds).await {
        Ok(page) => Some(
            field(&page, "events")
                .as_array()
                .into_iter()
                .flatten()
                .any(|e| *field(field(e, "msg"), "transferId") == transfer_id),
        ),
        Err(e) => {
            let m = e.to_string().to_lowercase();
            (m.contains("no session") || m.contains("not found")).then_some(false)
        }
    }
}

/// Pages every bundle file from `src` into the receive on `dst`, and finishes it there.
async fn copy(
    src: &Client,
    dst: &Client,
    begin: &Value,
    receive_id: &Value,
    epoch: u64,
    cwd: Option<String>,
    name: Option<String>,
) -> Result<Value> {
    page_files(src, dst, begin, &begin["transferId"], receive_id, Some(epoch)).await?;
    let mut finish =
        json!({"receiveId": receive_id, "from": {"sessionId": begin["sessionId"]}, "epoch": epoch});
    if let Some(cwd) = cwd {
        finish.set("cwd", json!(cwd));
    }
    if let Some(name) = name {
        finish.set("name", json!(name));
    }
    dst.request("_acpmux/transfer_finish", finish).await
}

/// Pages every file `manifest` lists from `src`'s `transfer_id` into `receive_id` on `dst`.
async fn page_files(
    src: &Client,
    dst: &Client,
    manifest: &Value,
    transfer_id: &Value,
    receive_id: &Value,
    epoch: Option<u64>,
) -> Result<()> {
    for file in manifest["files"].as_array().into_iter().flatten() {
        let path = &file["path"];
        let mut offset = 0u64;
        loop {
            let mut read = json!({"transferId": transfer_id, "path": path, "offset": offset});
            let page = src.request("_acpmux/transfer_read", stamped(&mut read, epoch)).await?;
            let mut write = json!({"receiveId": receive_id, "path": path, "offset": offset, "data": field(&page, "data")});
            dst.request("_acpmux/transfer_write", stamped(&mut write, epoch)).await?;
            offset =
                field(&page, "next").as_u64().ok_or_else(|| anyhow!("transfer_read: no next"))?;
            if *field(&page, "eof") == true {
                break;
            }
        }
    }
    Ok(())
}

/// `params` with the move's `epoch`, when it has one (a prepare's pages carry none).
fn stamped(params: &mut Value, epoch: Option<u64>) -> Value {
    if let Some(epoch) = epoch {
        params.set("epoch", json!(epoch));
    }
    params.take()
}

/// A client of the target's daemon at `socket`, through an ssh forward of it unless `ssh` is
/// empty (this machine's own daemon), and the receiving daemon's own `initialize` reply on it
/// (`receiver_takes`).
pub(super) async fn connect_target(
    ssh: &str,
    socket: &str,
) -> Result<(Option<crate::ssh_forward::Forward>, std::sync::Arc<Client>, Value)> {
    let (forward, dst) = if ssh.is_empty() {
        (None, Client::connect(std::path::Path::new(socket)).await?)
    } else {
        let forward = crate::ssh_forward::Forward::open(ssh, socket).await?;
        let dst = Client::connect(&forward.local).await?;
        (Some(forward), dst)
    };
    let init = json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-move"}});
    let dst_init = dst.request(method::INITIALIZE, init).await?;
    Ok((forward, dst, dst_init))
}

/// `v[k]` without the indexing lint: Null when absent.
fn field<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}
