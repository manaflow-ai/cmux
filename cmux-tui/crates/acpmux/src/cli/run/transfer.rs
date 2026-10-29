//! `acpmux transfer SESSION --to SOCKET`: moves a chat from this daemon to another one (a sibling
//! build's) through `_acpmux/transfer_*` (`hub/transfer_out.rs`). The reference client of the
//! move: it pages the bundle from one daemon to the other, and gives the chat back on a failure.

use super::*;
use crate::no_panic::JsonExt;

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
    let begin_params = json!({"sessionId": id, "interrupt": interrupt, "to": {"socket": socket}});
    let begin = src.request("_acpmux/transfer_begin", begin_params).await?;
    let transfer_id = begin.field("transferId").as_str().unwrap_or_default().to_owned();
    let abort = async || {
        let abort = json!({"sessionId": id, "transferId": transfer_id});
        if let Err(e) = src.request("_acpmux/transfer_abort", abort).await {
            eprintln!("acpmux: the move failed and the chat stays frozen here: {e}");
        }
    };
    let receive = match dst.request("_acpmux/transfer_receive", json!({"manifest": begin})).await {
        Ok(receive) => receive,
        Err(e) => {
            abort().await;
            return Err(e);
        }
    };
    let moved = match copy(&src, &dst, &begin, receive.field("receiveId"), cwd, name).await {
        Ok(moved) => moved,
        // A finish whose answer was lost may have landed, and the target runs the queue then:
        // the source commits. Only a target that shows no such move lets the chat come back.
        Err(e) => match landed(&dst, &id, &transfer_id).await {
            Some(true) => dst.request(method::MUX_INFO, json!({"sessionId": id})).await?,
            Some(false) => {
                abort().await;
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
    let to_meta = json!({"sessionId": moved.field("sessionId"), "socket": to});
    src.request(
        "_acpmux/transfer_commit",
        json!({"sessionId": id, "transferId": transfer_id, "to": to_meta}),
    )
    .await?;
    if json_out {
        print_json(&moved);
    } else {
        println!("moved {} to {}", moved.field("name").as_str().unwrap_or(&id), to.display());
    }
    Ok(())
}

/// Whether the target took this move (its log has the `transferred_in` of `transfer_id`); `None`
/// when it cannot say.
async fn landed(dst: &Client, id: &str, transfer_id: &str) -> Option<bool> {
    let kinds = json!({"sessionId": id, "afterSeq": 0, "kinds": ["transferred_in"]});
    match dst.request(method::MUX_EVENTS, kinds).await {
        Ok(page) => Some(
            page.field("events")
                .as_array()
                .into_iter()
                .flatten()
                .any(|e| *e.field("msg").field("transferId") == transfer_id),
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
            let write = json!({"receiveId": receive_id, "path": path, "offset": offset, "data": page.field("data")});
            dst.request("_acpmux/transfer_write", write).await?;
            offset =
                page.field("next").as_u64().ok_or_else(|| anyhow!("transfer_read: no next"))?;
            if *page.field("eof") == true {
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
