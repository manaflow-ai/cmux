//! `acpmux transfer SESSION --to SOCKET`: moves a chat from this daemon to another one (a sibling
//! build's) through `_acpmux/transfer_*` (`hub/transfer_out.rs`). The reference client of the
//! move: it pages the bundle from one daemon to the other, and gives the chat back on a failure.

use super::*;

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
    let begin = src
        .request("_acpmux/transfer_begin", json!({"sessionId": id, "interrupt": interrupt}))
        .await?;
    let transfer_id = begin["transferId"].as_str().unwrap_or_default().to_owned();
    let moved = copy(&src, &dst, &begin, cwd, name).await;
    let moved = match moved {
        Ok(moved) => moved,
        Err(e) => {
            // A finish whose answer was lost may have landed, and the target runs the queue
            // then: the source commits. Only a target that lacks the chat lets it come back.
            let there = dst.request(method::MUX_INFO, json!({"sessionId": id})).await;
            let lacks = match &there {
                Ok(there) => there["status"] == "closed",
                Err(lookup) => {
                    let m = lookup.to_string().to_lowercase();
                    m.contains("no session") || m.contains("not found")
                }
            };
            match there {
                Ok(there) if !lacks => there,
                _ if lacks => {
                    let abort = json!({"sessionId": id, "transferId": transfer_id});
                    if let Err(e2) = src.request("_acpmux/transfer_abort", abort).await {
                        eprintln!("acpmux: the move failed and the chat stays frozen here: {e2}");
                    }
                    return Err(e);
                }
                _ => {
                    eprintln!(
                        "acpmux: the move failed and the target cannot say whether it took the chat; it stays frozen here until the move is retried or aborted"
                    );
                    return Err(e);
                }
            }
        }
    };
    let to_meta = json!({"sessionId": moved["sessionId"], "socket": to});
    src.request(
        "_acpmux/transfer_commit",
        json!({"sessionId": id, "transferId": transfer_id, "to": to_meta}),
    )
    .await?;
    if json_out {
        print_json(&moved);
    } else {
        println!("moved {} to {}", moved["name"].as_str().unwrap_or(&id), to.display());
    }
    Ok(())
}

/// Pages every bundle file from `src` into a receive on `dst`, and finishes it there.
async fn copy(
    src: &Client,
    dst: &Client,
    begin: &Value,
    cwd: Option<String>,
    name: Option<String>,
) -> Result<Value> {
    let receive = dst.request("_acpmux/transfer_receive", json!({"manifest": begin})).await?;
    let receive_id = receive["receiveId"].clone();
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
        finish["cwd"] = json!(cwd);
    }
    if let Some(name) = name {
        finish["name"] = json!(name);
    }
    Ok(dst.request("_acpmux/transfer_finish", finish).await?)
}
