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
    interrupt: bool,
    json_out: bool,
) -> Result<()> {
    let src = connect(true).await?;
    let dst = Client::connect(to).await?;
    dst.request(
        method::INITIALIZE,
        json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-transfer"}}),
    )
    .await?;
    let id = resolve_id(&src, session).await?;
    // The source asks the target itself if this client goes away midway (`hub/transfer_watch.rs`).
    let socket = std::path::absolute(to)?;
    let to_meta = json!({"socket": to});
    let watch = json!({"socket": socket});
    let moved = move_chat(&src, &dst, &id, Some(watch), cwd, name, interrupt, to_meta).await?;
    if json_out {
        print_json(&moved);
    } else {
        println!("moved {} to {}", moved["name"].as_str().unwrap_or(&id), to.display());
    }
    Ok(())
}

/// A move begun on the source: the chat is frozen there and its bundle made.
pub(super) struct Begun {
    begin: Value,
    transfer_id: String,
}

/// Freezes the chat `id` on `src` and makes its bundle (`_acpmux/transfer_begin`). `watch` is
/// the target as the source's watch reaches it if the move's client goes away
/// (`{socket}`, or `{socket, ssh}` for a daemon on another machine, `hub/transfer_watch.rs`).
pub(super) async fn begin_move(
    src: &Client,
    id: &str,
    watch: Option<Value>,
    interrupt: bool,
) -> Result<Begun> {
    let mut begin_params = json!({"sessionId": id, "interrupt": interrupt});
    if let Some(to) = watch {
        begin_params.set("to", to);
    }
    let begin = src.request("_acpmux/transfer_begin", begin_params).await?;
    let transfer_id = begin["transferId"].as_str().unwrap_or_default().to_owned();
    Ok(Begun { begin, transfer_id })
}

/// Gives the chat back on the source: the move did not happen.
pub(super) async fn abort_move(src: &Client, id: &str, begun: &Begun) {
    let abort = json!({"sessionId": id, "transferId": begun.transfer_id});
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
    id: &str,
    watch: Option<Value>,
    cwd: Option<String>,
    name: Option<String>,
    interrupt: bool,
    to_meta: Value,
) -> Result<Value> {
    let begun = begin_move(src, id, watch, interrupt).await?;
    finish_move(src, dst, id, &begun, cwd, name, to_meta).await
}

/// The rest of a move [`begin_move`] began: the bundle paged into a receive on `dst`, finished
/// there, and committed on `src`. A failure that leaves the chat nowhere else aborts the move.
pub(super) async fn finish_move(
    src: &Client,
    dst: &Client,
    id: &str,
    begun: &Begun,
    cwd: Option<String>,
    name: Option<String>,
    to_meta: Value,
) -> Result<Value> {
    let (begin, transfer_id) = (&begun.begin, &begun.transfer_id);
    let receive = match dst.request("_acpmux/transfer_receive", json!({"manifest": begin})).await {
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
        json!({"sessionId": id, "transferId": transfer_id, "to": to_meta}),
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
            page["events"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|e| e["msg"]["transferId"] == transfer_id),
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
    cwd: Option<String>,
    name: Option<String>,
) -> Result<Value> {
    for file in begin["files"].as_array().into_iter().flatten() {
        let path = &file["path"];
        let mut offset = 0u64;
        loop {
            let read = json!({"transferId": begin["transferId"], "path": path, "offset": offset});
            let page = src.request("_acpmux/transfer_read", read).await?;
            let write = json!({"receiveId": receive_id, "path": path, "offset": offset, "data": page["data"]});
            dst.request("_acpmux/transfer_write", write).await?;
            offset = page["next"].as_u64().ok_or_else(|| anyhow!("transfer_read: no next"))?;
            if page["eof"] == true {
                break;
            }
        }
    }
    let mut finish = json!({"receiveId": receive_id, "from": {"sessionId": begin["sessionId"]}});
    if let Some(cwd) = cwd {
        finish.set("cwd", json!(cwd));
    }
    if let Some(name) = name {
        finish.set("name", json!(name));
    }
    dst.request("_acpmux/transfer_finish", finish).await
}
