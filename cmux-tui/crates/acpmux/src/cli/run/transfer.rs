//! `acpmux transfer SESSION --to SOCKET`: moves a chat from this daemon to another one (a sibling
//! build's) through `_acpmux/transfer_*` (`hub/transfer_out.rs`). The reference client of the
//! move: it pages the bundle from one daemon to the other, and gives the chat back on a failure.

use super::move_end::{Journal, MoveEnd, Reach, Wait, journal_dir};
use super::*;
use cmux_json::JsonSet as _;

#[path = "transfer_live.rs"]
pub(crate) mod live;
pub(crate) use live::{Live, move_progress_line, move_undecided_line};
use live::{Pager, page_files};

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
        println!("moved {} to {}", field(&moved, "name").as_str().unwrap_or(&id), to.display());
    }
    Ok(())
}

/// A move begun on the source: the chat is frozen there and its bundle made. `stage_id`: the
/// target's staged prefix of a pre-copied move, whose bundle holds only what follows it.
pub(super) struct Begun {
    pub(super) begin: Value,
    pub(super) transfer_id: String,
    pub(super) epoch: u64,
    pub(super) stage_id: Option<String>,
    /// `session move --as`: the target's harness the chat lands on (`hub/transfer_in.rs`).
    pub(super) as_harness: Option<String>,
    /// The last seq of the history that follows the chat (`history_follows`), when the staged
    /// prefix left it behind.
    pub(super) history_after: Option<u64>,
    /// When the source answered the begin: the freeze runs from `frozenMs` before it.
    pub(super) begun_at: std::time::Instant,
}

/// A prefix of the chat staged on the target before the freeze (`hub/transfer_precopy.rs`).
pub(super) struct Staged {
    pub(super) prepare_id: String,
    pub(super) after_seq: u64,
    pub(super) stage_id: String,
    /// The prefix holds no history: it follows the chat (`hub/transfer_history.rs`).
    pub(super) history_later: bool,
}

/// How many of a chat's last turns a move carries in its freeze when its history follows the
/// chat (`hub/transfer_history.rs`): `ACPMUX_MOVE_HISTORY_LATER=<turns>`. Unset (or zero), every
/// move pre-copies the whole history first, as before.
fn history_later_turns() -> Option<u64> {
    std::env::var("ACPMUX_MOVE_HISTORY_LATER").ok()?.trim().parse().ok().filter(|turns| *turns > 0)
}

/// Freezes the chat `id` on `src` and makes its bundle (`_acpmux/transfer_begin`). `watch` is
/// the target as the source's watch reaches it if the move's client goes away
/// (`{socket}`, or `{socket, ssh}` for a daemon on another machine, `hub/transfer_watch.rs`).
/// `turn_bound`: with `after_turn`, the longest the daemon waits for the running turn
/// (`afterTurnTimeoutMs`; a daemon too old to read it waits its own 15 minutes).
pub(super) async fn begin_move(
    src: &mut MoveEnd<'_>,
    id: &str,
    watch: Option<Value>,
    running: (bool, bool),
    turn_bound: Option<std::time::Duration>,
) -> Result<Begun> {
    begin_move_after(src, id, watch, running, None, turn_bound).await
}

/// [`begin_move`] after `staged` (see [`precopy`]), whose bundle then holds only the records
/// past its prefix; a prefix the source no longer holds as it was is moved in full (the refusal
/// gave the chat back first).
pub(super) async fn begin_staged(
    src: &mut MoveEnd<'_>,
    id: &str,
    watch: Option<Value>,
    running: (bool, bool),
    staged: Option<&Staged>,
    turn_bound: Option<std::time::Duration>,
) -> Result<Begun> {
    if let Some(staged) = staged {
        match begin_move_after(src, id, watch.clone(), running, Some(staged), turn_bound).await {
            Err(e) if refused_as(&e, "transfer.diverged") => {}
            begun => return begun,
        }
    }
    begin_move(src, id, watch, running, turn_bound).await
}

/// [`begin_move`]; after `staged`, the bundle holds only the records past its prefix.
async fn begin_move_after(
    src: &mut MoveEnd<'_>,
    id: &str,
    watch: Option<Value>,
    (interrupt, after_turn): (bool, bool),
    staged: Option<&Staged>,
    turn_bound: Option<std::time::Duration>,
) -> Result<Begun> {
    begin_with(src, id, watch, (interrupt, false, after_turn), staged, turn_bound).await
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
    src: &mut MoveEnd<'_>,
    id: &str,
    watch: Option<Value>,
    wait: std::time::Duration,
    staged: Option<&Staged>,
) -> Result<Begun> {
    // A prefix the source no longer holds as it was is moved in full (`begin_staged`).
    let mut staged = staged;
    let until = std::time::Instant::now() + wait;
    let mut said = false;
    loop {
        let late = std::time::Instant::now() >= until;
        match begin_with(src, id, watch.clone(), (late, !late, false), staged, None).await {
            Err(e) if staged.is_some() && refused_as(&e, "transfer.diverged") => staged = None,
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
    src: &mut MoveEnd<'_>,
    id: &str,
    watch: Option<Value>,
    (interrupt, at_tool_boundary, after_turn): (bool, bool, bool),
    staged: Option<&Staged>,
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
    if let Some(staged) = staged {
        begin_params.set("prepareId", json!(staged.prepare_id));
        begin_params.set("afterSeq", json!(staged.after_seq));
    }
    if let Some(bound) = turn_bound.filter(|_| after_turn) {
        begin_params
            .set("afterTurnTimeoutMs", json!(u64::try_from(bound.as_millis()).unwrap_or(u64::MAX)));
    }
    let begin = src.call("_acpmux/transfer_begin", begin_params, Wait::Turn, true).await?;
    let transfer_id = field(&begin, "transferId").as_str().unwrap_or_default().to_owned();
    let epoch = match begin.get("epoch") {
        None => 0,
        Some(value) => value
            .as_u64()
            .ok_or_else(|| anyhow!("transfer_begin: epoch must be an unsigned integer"))?,
    };
    let begun_at = std::time::Instant::now();
    let staged = staged.filter(|_| begin.get("prefix").is_some());
    let stage_id = staged.map(|s| s.stage_id.clone());
    let history_after = staged.filter(|s| s.history_later).map(|s| s.after_seq);
    Ok(Begun { begin, transfer_id, epoch, stage_id, as_harness: None, history_after, begun_at })
}

/// Gives the chat back on the source: the move did not happen.
pub(super) async fn abort_move(src: &mut MoveEnd<'_>, id: &str, begun: &Begun) {
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
    // Pre-copied when both daemons can: the freeze then costs only what changed since. A target
    // that lost its stage refuses the bundle, and the move is made again in full.
    let live = Live { verbose: true, ..Live::default() };
    let mut src_end = MoveEnd::new("source", src, src_reach);
    let mut dst_end = MoveEnd::new("target", dst, dst_reach);
    let (src, dst) = (&mut src_end, &mut dst_end);
    let staged = precopy(src, dst, dst_init, id, &live).await?;
    if staged.is_none() {
        whole_freeze_refusal(src, id).await?;
    }
    let begun = begin_staged(src, id, watch.clone(), running, staged.as_ref(), None).await?;
    if begun.stage_id.is_some() {
        let (cwd, name, meta) = (cwd.clone(), name.clone(), to_meta.clone());
        match finish_move(src, dst, dst_init, id, &begun, cwd, name, meta).await {
            Err(e) if refused_as(&e, "transfer.unstaged") => {}
            moved => return moved,
        }
    } else {
        return finish_move(src, dst, dst_init, id, &begun, cwd, name, to_meta).await;
    }
    whole_freeze_refusal(src, id).await?;
    let begun = begin_move(src, id, watch, running, None).await?;
    finish_move(src, dst, dst_init, id, &begun, cwd, name, to_meta).await
}

/// Refuses a move of chat `id` whole inside its freeze when its log is past
/// `live::WHOLE_FREEZE_LIMIT`: the chat would be frozen for the whole copy (2026-11-22: 6 h
/// over a relay). A source that does not say how big the log is is not refused.
pub(super) async fn whole_freeze_refusal(src: &mut MoveEnd<'_>, id: &str) -> Result<()> {
    let info = src.request(method::MUX_INFO, json!({"sessionId": id, "waitLogs": false})).await?;
    let Some(bytes) = info.get("historyBytes").and_then(Value::as_u64) else { return Ok(()) };
    if bytes > live::WHOLE_FREEZE_LIMIT {
        anyhow::bail!(
            "transfer.whole_freeze: its history is {:.2} GB and could not be pre-copied, so the \
             move would freeze the chat for the whole copy; not moved (both daemons need \
             transfer-precopy-v1: update the target's acpmux)",
            bytes as f64 / 1e9
        );
    }
    Ok(())
}

pub(super) fn refused_as(e: &anyhow::Error, code: &str) -> bool {
    format!("{e:#}").contains(code)
}

/// Whether a daemon's `initialize` or `_acpmux/status` reply lists pre-copy.
pub(super) fn lists_precopy(reply: &Value, pointer: &str) -> bool {
    let ids = reply.pointer(pointer).and_then(Value::as_array);
    ids.is_some_and(|ids| ids.iter().any(|id| id == crate::capabilities::TRANSFER_PRECOPY))
}

/// The chat's history as of now staged on `dst`, with no freeze, when both daemons list
/// pre-copy (`live` module docs: in rounds, resumed, compressed); `Ok(None)` (a full move) when
/// either does not or a step fails; `Err` only when the copy would be too slow
/// (`live::SLOW`), the chat untouched and what was copied kept on the target.
pub(super) async fn precopy(
    src: &mut MoveEnd<'_>,
    dst: &mut MoveEnd<'_>,
    dst_init: &Value,
    id: &str,
    live: &Live,
) -> Result<Option<Staged>> {
    use crate::capabilities::{TRANSFER_HISTORY_LATER, TRANSFER_LIVE, TRANSFER_PRECOPY};
    let target_caps = "/_meta/acpmux/capabilities";
    if !live::lists(dst_init, target_caps, TRANSFER_PRECOPY) {
        return Ok(None);
    }
    let Ok(status) = src.request(method::MUX_STATUS, json!({})).await else { return Ok(None) };
    if !live::lists(&status, "/capabilities", TRANSFER_PRECOPY) {
        return Ok(None);
    }
    let zstd = live::lists(dst_init, target_caps, TRANSFER_LIVE);
    let resume = zstd && live::lists(&status, "/capabilities", TRANSFER_LIVE);
    let mut pager = Pager::new(id, live.clone(), zstd);
    // The copy `dst` still holds from the chat's last move, if any: the source prepares only
    // what came after it. A base either side refuses falls back to a full prefix.
    let base = dst.request("_acpmux/transfer_base", json!({"sessionId": id})).await.ok();
    let base = base.map(|b| field(&b, "base").clone()).filter(|b| !b.is_null());
    let mut staged = None;
    if let Some(base) = base {
        staged = stage_rounds(src, dst, id, Some(base), resume, None, &mut pager).await?;
    }
    // Asked for, and both daemons can: only the chat's last turns are prepared, and its history
    // follows the chat after the move (`history_follows`).
    let later = history_later_turns().filter(|_| {
        live::lists(dst_init, target_caps, TRANSFER_HISTORY_LATER)
            && live::lists(&status, "/capabilities", TRANSFER_HISTORY_LATER)
    });
    if staged.is_none() && later.is_some() {
        staged = stage_rounds(src, dst, id, None, resume, later, &mut pager).await?;
    }
    if staged.is_none() {
        staged = stage_rounds(src, dst, id, None, resume, None, &mut pager).await?;
    }
    if staged.is_some() {
        pager.phase = "freeze";
        let _ = pager.tick(src, true).await;
    } else {
        pager.done(src).await;
    }
    Ok(staged)
}

/// The prefix staged on `dst` in rounds (from `base` when it is given and the source holds it):
/// each round prepares the log as of now and sends what the stage does not hold yet, until one
/// sends little (`live::SMALL_ROUND`); then the stage is finished. With no `resume` (an older
/// daemon) one round, whole.
async fn stage_rounds(
    src: &mut MoveEnd<'_>,
    dst: &mut MoveEnd<'_>,
    id: &str,
    base: Option<Value>,
    resume: bool,
    later: Option<u64>,
    pager: &mut Pager,
) -> Result<Option<Staged>> {
    let mut staged = None;
    for _ in 0..live::MAX_ROUNDS {
        let mut params = json!({"sessionId": id});
        if let Some(keep) = later {
            params.set("historyLater", json!({"keepTurns": keep}));
        }
        if let Some(base) = &base {
            params.set("base", base.clone());
        }
        let Ok(prepared) = src.request("_acpmux/transfer_prepare", params).await else {
            return Ok(None);
        };
        if base.is_some() && field(&prepared, "base").is_null() {
            return Ok(None);
        }
        let ask = json!({"manifest": prepared, "resume": resume});
        let Ok(stage) = dst.request("_acpmux/transfer_stage", ask).await else { return Ok(None) };
        let (Some(stage_id), Some(prepare_id), Some(after_seq)) = (
            field(&stage, "stageId").as_str().map(str::to_owned),
            field(&prepared, "prepareId").as_str().map(str::to_owned),
            field(&prepared, "afterSeq").as_u64(),
        ) else {
            return Ok(None);
        };
        let from = live::resume_offsets(src, &prepare_id, &stage).await;
        pager.begin_round("pre-copy", &prepared);
        let receive_id = json!(stage_id);
        let paged = page_files(
            src,
            dst,
            &prepared,
            field(&prepared, "prepareId"),
            &receive_id,
            None,
            &from,
            pager,
        )
        .await;
        match paged {
            Err(e) if refused_as(&e, live::SLOW) => return Err(e),
            Err(_) => return Ok(None),
            Ok(()) => {}
        }
        let _ = pager.tick(src, true).await;
        let history_later = *field(&prepared, "historyLater") == true;
        staged = Some(Staged { prepare_id, after_seq, stage_id, history_later });
        if !resume || pager.sent <= live::SMALL_ROUND {
            break;
        }
    }
    let Some(staged) = staged else { return Ok(None) };
    let finish = json!({"stageId": staged.stage_id});
    if dst.request("_acpmux/transfer_stage_finish", finish).await.is_err() {
        return Ok(None);
    }
    Ok(Some(staged))
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
/// (`move_end.rs`): on a laptop (2026-11-23) moves through ssh forwards lost their
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
    let dir = journal_dir();
    let journal = (dir.as_path(), to_meta);
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
    result.map_err(|(Unresolved(e) | Resolved(e))| e)
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
    let transfer_id = &begun.transfer_id;
    if let Err(e) = receiver_takes(&begun.begin, dst_init) {
        return Err(abort_end(src, id, begun, e).await);
    }
    // An optional bundle file the target does not list stays here: a target older than it would
    // refuse the whole move for it (`capabilities::OPTIONAL_BUNDLE_FILES`).
    let mut begin = begun.begin.clone();
    let caps = "/_meta/acpmux/capabilities";
    let left =
        crate::capabilities::leave_out_untaken(&mut begin, |c| live::lists(dst_init, caps, c));
    if let Some(line) = crate::capabilities::left_out_line(&left) {
        eprintln!("acpmux: move {transfer_id}: {line}");
    }
    let begin = &begin;
    let mut receive_params = json!({"manifest": begin});
    if let Some(stage_id) = &begun.stage_id {
        receive_params.set("stageId", json!(stage_id));
    }
    if let Some(name) = &begun.as_harness {
        receive_params.set("asHarness", json!(name));
    }
    let receive = dst.call("_acpmux/transfer_receive", receive_params, Wait::Page, false);
    let receive = match receive.await {
        Ok(receive) => receive,
        Err(e) => return Err(abort_end(src, id, begun, e).await),
    };
    // A receive seeded from the stage's native files pages only what they grew by.
    let from = live::resume_offsets(src, transfer_id, &receive).await;
    let receive_id = receive.get("receiveId").unwrap_or(&Value::Null);
    let copied = copy(src, dst, dst_init, &from, begin, receive_id, begun.epoch, cwd, name).await;
    let moved = match copied {
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
    // The freeze: from the chat marked moving on the source (`frozenMs` before its begin
    // answered) to the target's finish, and the bytes the bundle carried in it (less what a
    // stage already held). One line per move, and the source's `transferred` record keeps it.
    let frozen = field(begin, "frozenMs").as_u64().unwrap_or(0);
    let ms = frozen.saturating_add(begun.begun_at.elapsed().as_millis() as u64);
    let bytes: u64 = field(begin, "files")
        .as_array()
        .into_iter()
        .flatten()
        .map(|f| {
            let held = field(f, "path").as_str().and_then(|p| from.get(p)).copied().unwrap_or(0);
            field(f, "size").as_u64().unwrap_or(0).saturating_sub(held)
        })
        .sum();
    let later = if begun.history_after.is_some() { ", history follows" } else { "" };
    eprintln!("acpmux: move {transfer_id}: frozen {ms} ms, {bytes} bytes carried{later}");
    let mut to_meta = to_meta;
    to_meta.set("sessionId", moved.get("sessionId").cloned().unwrap_or(Value::Null));
    // A commit is answered again the same once it is on disk (`transfer_commit_with_epoch`).
    let commit = json!({"sessionId": id, "transferId": transfer_id, "to": to_meta,
                        "epoch": begun.epoch, "freeze": {"ms": ms, "bytes": bytes}});
    src.call("_acpmux/transfer_commit", commit, Wait::Page, true).await?;
    // The chat runs on the target now. Its history follows; a failure leaves it on the source,
    // whose copy keeps the log, and the chat on the target awaiting it.
    if let Some(through) = begun.history_after {
        match history_follows(src, dst, id, through).await {
            Ok(line) => eprintln!("acpmux: move {transfer_id}: {line}"),
            Err(e) => eprintln!(
                "acpmux: the chat moved, but its history through seq {through} did not follow: \
                 {e:#}; it is still on the source"
            ),
        }
    }
    Ok(moved)
}

/// After a move that left the chat's history behind (`hub/transfer_history.rs`): the source
/// packs its log through `through` and bundles the chunks the target lacks, the target stages
/// and unpacks them, and the live chat there takes them as its history. Returns what it cost.
async fn history_follows(
    src: &mut MoveEnd<'_>,
    dst: &mut MoveEnd<'_>,
    id: &str,
    through: u64,
) -> Result<String> {
    let started = std::time::Instant::now();
    let have = dst.request("_acpmux/transfer_history_have", json!({"sessionId": id})).await?;
    let ask = json!({"sessionId": id, "throughSeq": through, "have": field(&have, "have")});
    let export = src.request("_acpmux/transfer_history_export", ask).await?;
    let stage = dst.request("_acpmux/transfer_stage", json!({"manifest": export})).await?;
    let stage_id = field(&stage, "stageId").clone();
    let mut sent = 0u64;
    for file in field(&export, "files").as_array().into_iter().flatten() {
        let (path, mut offset) = (field(file, "path"), 0u64);
        loop {
            let read = json!({"transferId": field(&export, "prepareId"), "path": path,
                              "offset": offset, "limit": live::PAGE});
            let page = src.request("_acpmux/transfer_read", read).await?;
            let next =
                field(&page, "next").as_u64().ok_or_else(|| anyhow!("transfer_read: no next"))?;
            let write = json!({"receiveId": stage_id, "path": path, "offset": offset,
                               "data": field(&page, "data")});
            dst.request("_acpmux/transfer_write", write).await?;
            sent = sent.saturating_add(next.saturating_sub(offset));
            offset = next;
            if *field(&page, "eof") == true {
                break;
            }
        }
    }
    dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage_id})).await?;
    let ask = json!({"sessionId": id, "stageId": stage_id});
    let arrived = dst.request("_acpmux/transfer_history", ask).await?;
    let packed = field(&export, "packed");
    Ok(format!(
        "history arrived: {} records through seq {through}, {sent} bytes sent for {} of log \
         ({} of {} chunks), {} ms",
        field(&arrived, "records").as_u64().unwrap_or(0),
        field(packed, "rawBytes").as_u64().unwrap_or(0),
        field(packed, "chunks").as_u64().unwrap_or(0),
        field(packed, "sessionChunks").as_u64().unwrap_or(0),
        started.elapsed().as_millis(),
    ))
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

/// Pages every bundle file from `src` into the receive on `dst`, and finishes it there. A page
/// whose connection dropped is asked again on the end's new one; a write the target already had
/// (or never got) goes on from the size it says it has (`live::page_files`).
#[allow(clippy::too_many_arguments)]
async fn copy(
    src: &mut MoveEnd<'_>,
    dst: &mut MoveEnd<'_>,
    dst_init: &Value,
    from: &std::collections::HashMap<String, u64>,
    begin: &Value,
    receive_id: &Value,
    epoch: u64,
    cwd: Option<String>,
    name: Option<String>,
) -> Result<Value> {
    let id = field(begin, "sessionId").as_str().unwrap_or_default();
    let zstd =
        live::lists(dst_init, "/_meta/acpmux/capabilities", crate::capabilities::TRANSFER_LIVE);
    let mut pager = Pager::new(id, Live::default(), zstd);
    pager.begin_round("freeze", begin);
    let transfer_id = field(begin, "transferId");
    let paged =
        page_files(src, dst, begin, transfer_id, receive_id, Some(epoch), from, &mut pager).await;
    pager.done(src).await;
    paged?;
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
