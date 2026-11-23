//! `acpmux transfer SESSION --to SOCKET`: moves a chat from this daemon to another one (a sibling
//! build's) through `_acpmux/transfer_*` (`hub/transfer_out.rs`). The reference client of the
//! move: it pages the bundle from one daemon to the other, and gives the chat back on a failure.

use super::move_end::{Journal, MoveEnd, Reach, Wait, journal_dir};
use super::*;
use cmux_json::JsonSet as _;

/// Moves `session` to the daemon at `to`.
pub(super) async fn run(
    session: &str,
    to: &std::path::Path,
    cwd: Option<String>,
    name: Option<String>,
    interrupt: bool,
    after_turn: bool,
    json_out: bool,
) -> Result<()> {
    let src = connect(true).await?;
    // A move this machine began whose client went away is ended first (`move_end.rs`).
    super::move_end::reclaim_dead_moves(&journal_dir()).await;
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
    let watch = json!({"socket": socket});
    let running = (interrupt, after_turn);
    let reach = (
        Some(Reach::Socket { path: std::path::absolute(crate::config::socket_path())? }),
        Some(Reach::Socket { path: socket.clone() }),
    );
    let moved =
        move_chat(&src, &dst, &dst_init, &id, Some(watch), cwd, name, running, to_meta, reach)
            .await?;
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
    epoch: u64,
}

/// Freezes the chat `id` on `src` and makes its bundle (`_acpmux/transfer_begin`). `watch` is
/// the target as the source's watch reaches it if the move's client goes away
/// (`{socket}`, or `{socket, ssh}` for a daemon on another machine, `hub/transfer_watch.rs`).
/// `turn_bound`: with `after_turn`, the longest the daemon waits for the running turn
/// (`afterTurnTimeoutMs`; a daemon too old to read it waits its own 15 minutes).
pub(super) async fn begin_move(
    src: &Client,
    id: &str,
    watch: Option<Value>,
    (interrupt, after_turn): (bool, bool),
    turn_bound: Option<std::time::Duration>,
) -> Result<Begun> {
    begin_with(src, id, watch, (interrupt, false, after_turn), turn_bound).await
}

/// Longest [`begin_move_live`] waits for a running turn's tool calls to end before it stops the
/// turn all the same (its continuation then names the calls it cut, `restart_resume.rs`).
pub(super) const TOOL_WAIT: std::time::Duration = std::time::Duration::from_secs(15 * 60);
/// How often [`begin_move_live`] asks again while a tool call runs.
const TOOL_POLL: std::time::Duration = std::time::Duration::from_millis(500);

/// [`begin_move`] for a chat whose turn may be running, which moves with it (Leo, 2026-11-21:
/// "you're supposed to be able to move shit while it's running. that's teh whole point."). The
/// begin stops the turn only between its tool calls (`atToolBoundary`, `hub/transfer_out.rs`
/// `TurnCut`): every tool result is then in the agent's transcript, which the bundle carries,
/// and the turn's continuation goes on from there on the target. While a call runs (a build, a
/// test) the begin answers `transfer.tool_in_flight` and this asks again, up to `wait`; past it
/// the turn stops as with `--interrupt`. A turn that ends meanwhile moves as an idle chat does,
/// and so does a chat with no turn.
pub(super) async fn begin_move_live(
    src: &Client,
    id: &str,
    watch: Option<Value>,
    wait: std::time::Duration,
) -> Result<Begun> {
    let until = std::time::Instant::now() + wait;
    let mut said = false;
    loop {
        let late = std::time::Instant::now() >= until;
        match begin_with(src, id, watch.clone(), (late, !late, false), None).await {
            Err(e) if !late && waits_for_turn(&e) => {
                if !said {
                    eprintln!(
                        "acpmux: {id}: its turn runs a tool call; the move takes the turn along once \
                         that ends (at most {} min)",
                        wait.as_secs() / 60
                    );
                    said = true;
                }
                tokio::time::sleep(TOOL_POLL).await;
            }
            other => return other,
        }
    }
}

/// Whether a begin refused `e` only until the running turn reaches a point it can stop at: a tool
/// call in flight, or a compaction that a stop would cut (`hub/transfer_out.rs`).
pub(crate) fn waits_for_turn(e: &anyhow::Error) -> bool {
    let text = format!("{e:#}");
    text.contains(&format!("transfer.{}", crate::hub::TOOL_IN_FLIGHT))
        || text.contains("transfer.busy: the chat is compacting")
}

async fn begin_with(
    src: &Client,
    id: &str,
    watch: Option<Value>,
    (interrupt, at_tool_boundary, after_turn): (bool, bool, bool),
    turn_bound: Option<std::time::Duration>,
) -> Result<Begun> {
    // This client hands the bundle on only to a receiver whose own `initialize` listed queue
    // approval when it carries approved prompts that still wait (`receiver_takes`).
    // `afterTurn`: a running turn ends on its own first, the chat unfrozen meanwhile
    // (`hub/transfer_out.rs` `transfer_begin`); an older daemon ignores it and refuses as busy.
    let mut begin_params = json!({
        "sessionId": id,
        "interrupt": interrupt,
        "atToolBoundary": at_tool_boundary,
        "afterTurn": after_turn,
        "gatesQueueApproval": true,
    });
    if let Some(to) = watch {
        begin_params.set("to", to);
    }
    if let Some(bound) = turn_bound.filter(|_| after_turn) {
        begin_params.set("afterTurnTimeoutMs", json!(bound.as_millis() as u64));
    }
    let begin = src.request("_acpmux/transfer_begin", begin_params).await?;
    let transfer_id = begin["transferId"].as_str().unwrap_or_default().to_owned();
    let epoch = match begin.get("epoch") {
        None => 0,
        Some(value) => value
            .as_u64()
            .ok_or_else(|| anyhow!("transfer_begin: epoch must be an unsigned integer"))?,
    };
    Ok(Begun { begin, transfer_id, epoch })
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
    (src_reach, dst_reach): (Option<Reach>, Option<Reach>),
) -> Result<Value> {
    let begun = begin_move(src, id, watch, running, None).await?;
    let mut src_end = MoveEnd::new("source", src, src_reach);
    let mut dst_end = MoveEnd::new("target", dst, dst_reach);
    finish_move(&mut src_end, &mut dst_end, dst_init, id, &begun, cwd, name, to_meta).await
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
///
/// Each end reconnects when its connection drops, and every request has a deadline
/// (`move_end.rs`): on cosmic-gray (2026-11-23) moves through ssh forwards lost their
/// connections mid-page and one waited 30 minutes on a reply that never came. A move whose ends
/// can both be reached again is noted in this machine's move journal until it ends, so that one
/// whose client dies is ended by the next move here, not left frozen.
#[allow(clippy::too_many_arguments)]
pub(super) async fn finish_move(
    src: &mut MoveEnd<'_>,
    dst: &mut MoveEnd<'_>,
    dst_init: &Value,
    id: &str,
    begun: &Begun,
    cwd: Option<String>,
    name: Option<String>,
    to_meta: Value,
) -> Result<Value> {
    let journal = (&journal_dir(), to_meta);
    finish_journaled(src, dst, dst_init, id, begun, cwd, name, journal).await
}

/// [`finish_move`], the move noted in the journal at `dir` while it is under way.
#[allow(clippy::too_many_arguments)]
pub(super) async fn finish_journaled(
    src: &mut MoveEnd<'_>,
    dst: &mut MoveEnd<'_>,
    dst_init: &Value,
    id: &str,
    begun: &Begun,
    cwd: Option<String>,
    name: Option<String>,
    (dir, to_meta): (&std::path::Path, Value),
) -> Result<Value> {
    let journal = match (src.reach(), dst.reach()) {
        (Some(s), Some(d)) => Some(Journal {
            session_id: id.to_owned(),
            transfer_id: begun.transfer_id.clone(),
            epoch: begun.epoch,
            pid: std::process::id(),
            src: s.clone(),
            dst: d.clone(),
            to: to_meta.clone(),
        }),
        _ => None,
    };
    if let Some(j) = &journal {
        j.note(dir);
    }
    let result = finish_noted(src, dst, dst_init, id, begun, cwd, name, to_meta).await;
    if !matches!(result, Err(Unresolved(_))) {
        Journal::done(dir, &begun.transfer_id);
    }
    result.map_err(|Unresolved(e)| Resolved(e) | e)
}

/// How a failed move left the chat: given back or on the target (`Resolved`), or frozen with
/// neither end able to say (`Unresolved`, kept in the journal for the next run).
enum Failed {
    Resolved(anyhow::Error),
    Unresolved(anyhow::Error),
}
use Failed::*;

impl From<anyhow::Error> for Failed {
    fn from(e: anyhow::Error) -> Self {
        Unresolved(e)
    }
}

#[allow(clippy::too_many_arguments)]
async fn finish_noted(
    src: &mut MoveEnd<'_>,
    dst: &mut MoveEnd<'_>,
    dst_init: &Value,
    id: &str,
    begun: &Begun,
    cwd: Option<String>,
    name: Option<String>,
    to_meta: Value,
) -> Result<Value, Failed> {
    let (begin, transfer_id) = (&begun.begin, &begun.transfer_id);
    if let Err(e) = receiver_takes(begin, dst_init) {
        return Err(abort_end(src, id, begun, e).await);
    }
    let receive =
        dst.call("_acpmux/transfer_receive", json!({"manifest": begin}), Wait::Page, false);
    let receive = match receive.await {
        Ok(receive) => receive,
        Err(e) => return Err(abort_end(src, id, begun, e).await),
    };
    let receive_id = receive.get("receiveId").unwrap_or(&Value::Null);
    let moved = match copy(src, dst, begin, receive_id, begun.epoch, cwd, name).await {
        Ok(moved) => moved,
        // A finish whose answer was lost may have landed, and the target runs the queue then:
        // the source commits. Only a target that shows no such move lets the chat come back.
        Err(e) => match landed(dst, id, transfer_id).await {
            Some(true) => {
                dst.call(method::MUX_INFO, json!({"sessionId": id}), Wait::Page, true).await?
            }
            Some(false) => return Err(abort_end(src, id, begun, e).await),
            None => {
                eprintln!(
                    "acpmux: the move failed and the target cannot say whether it took the chat; it stays frozen here until the next move from this machine ends it"
                );
                return Err(Unresolved(e));
            }
        },
    };
    let mut to_meta = to_meta;
    to_meta.set("sessionId", moved.get("sessionId").cloned().unwrap_or(Value::Null));
    // A commit is answered again the same once it is on disk (`transfer_commit_with_epoch`).
    let commit =
        json!({"sessionId": id, "transferId": transfer_id, "to": to_meta, "epoch": begun.epoch});
    src.call("_acpmux/transfer_commit", commit, Wait::Page, true).await?;
    Ok(moved)
}

/// Gives the chat back on the source through `src` (reconnected if its connection dropped):
/// the move failed with `e`.
async fn abort_end(src: &mut MoveEnd<'_>, id: &str, begun: &Begun, e: anyhow::Error) -> Failed {
    let abort = json!({"sessionId": id, "transferId": begun.transfer_id, "epoch": begun.epoch});
    match src.call("_acpmux/transfer_abort", abort, Wait::Page, true).await {
        Ok(_) => Resolved(e),
        Err(why) => {
            eprintln!("acpmux: the move failed and the chat stays frozen here: {why:#}");
            Unresolved(e)
        }
    }
}

/// Whether the target took this move (its log has the `transferred_in` of `transfer_id`); `None`
/// when it cannot say.
async fn landed(dst: &mut MoveEnd<'_>, id: &str, transfer_id: &str) -> Option<bool> {
    let kinds = json!({"sessionId": id, "afterSeq": 0, "kinds": ["transferred_in"]});
    match dst.call(method::MUX_EVENTS, kinds, Wait::Page, true).await {
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

/// How many times one move's copy goes on from the size the target says it has.
const RESUMES: u32 = 32;

/// The size the target has of a file whose page came out of place (`transfer.offset`,
/// `hub/transfer_in.rs`): a page written before its answer was lost, or one lost with it.
fn written_size(e: &anyhow::Error) -> Option<u64> {
    let e = e.downcast_ref::<crate::client::DaemonError>()?;
    e.0.message.starts_with("transfer.offset").then_some(())?;
    e.0.data.as_ref()?.get("size")?.as_u64()
}

/// Pages every bundle file from `src` into the receive on `dst`, and finishes it there. A page
/// whose connection dropped is asked again on the end's new one; a write the target already had
/// (or never got) goes on from the size it says it has.
async fn copy(
    src: &mut MoveEnd<'_>,
    dst: &mut MoveEnd<'_>,
    begin: &Value,
    receive_id: &Value,
    epoch: u64,
    cwd: Option<String>,
    name: Option<String>,
) -> Result<Value> {
    let mut resumes = 0;
    for file in begin["files"].as_array().into_iter().flatten() {
        let path = &file["path"];
        let mut offset = 0u64;
        loop {
            let read = json!({"transferId": begin["transferId"], "path": path, "offset": offset, "epoch": epoch});
            let page = src.call("_acpmux/transfer_read", read, Wait::Page, true).await?;
            let write = json!({"receiveId": receive_id, "path": path, "offset": offset, "data": page["data"], "epoch": epoch});
            if let Err(e) = dst.call("_acpmux/transfer_write", write, Wait::Page, true).await {
                match written_size(&e) {
                    Some(size) if resumes < RESUMES => {
                        resumes += 1;
                        offset = size;
                        continue;
                    }
                    _ => return Err(e),
                }
            }
            offset = page["next"].as_u64().ok_or_else(|| anyhow!("transfer_read: no next"))?;
            if page["eof"] == true {
                break;
            }
        }
    }
    let mut finish =
        json!({"receiveId": receive_id, "from": {"sessionId": begin["sessionId"]}, "epoch": epoch});
    if let Some(cwd) = cwd {
        finish.set("cwd", json!(cwd));
    }
    if let Some(name) = name {
        finish.set("name", json!(name));
    }
    // Not asked again: a finish that landed answers a second one with an error; the caller
    // asks the (reconnected) target whether it landed.
    dst.call("_acpmux/transfer_finish", finish, Wait::Finish, false).await
}
