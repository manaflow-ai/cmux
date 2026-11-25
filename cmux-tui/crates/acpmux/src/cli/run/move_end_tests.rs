//! A move whose connections drop (`move_end.rs`): fake daemons on unix sockets that speak the
//! move protocol as `hub/transfer_out.rs` and `hub/transfer_in.rs` do (pages by offset, a write
//! out of place answered with the size the target has, a commit answered again the same), and
//! cut, lose the answer of, or stall a chosen request, as the ssh forwards of a laptop's moves
//! off a fleet VM did on 2026-11-23.

use super::*;
use crate::cli::run::transfer::{begin_move, finish_journaled};
use crate::rpc::{Message, RpcError};
use base64::Engine as _;
use std::collections::HashMap;
use std::sync::Mutex;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const MIB: usize = 1 << 20;
/// A daemon's page when the client names no limit (`hub/transfer_out.rs`).
const PAGE: usize = MIB;
const BUNDLE_FILE: &str = "events/log.jsonl";
const TID: &str = "0190aaaa-0000-7000-8000-000000000001";
const SHORT: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, PartialEq, Debug)]
enum Fault {
    /// The connection ends before the request is handled.
    Cut,
    /// The request is handled, and the connection ends before its answer.
    AnswerLost,
    /// The request is handled, and its answer never comes.
    Stall,
}

#[derive(Default)]
struct State {
    /// The source's bundle file.
    bundle: Vec<u8>,
    /// What the target has of it.
    received: Vec<u8>,
    finished: bool,
    refuse_receive: bool,
    committed: Option<Value>,
    aborted: bool,
    /// Each method's calls so far, over every connection.
    counts: HashMap<String, usize>,
    /// `(method, nth call, fault)`.
    faults: Vec<(&'static str, usize, Fault)>,
    connections: usize,
}

struct Fake {
    socket: PathBuf,
    state: Arc<Mutex<State>>,
    _dir: tempfile::TempDir,
}

impl Fake {
    fn reach(&self) -> Option<Reach> {
        Some(Reach::Socket { path: self.socket.clone() })
    }
}

fn fake(state: State) -> Fake {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("d.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let state = Arc::new(Mutex::new(state));
    let shared = state.clone();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            shared.lock().unwrap().connections += 1;
            tokio::spawn(serve(stream, shared.clone()));
        }
    });
    Fake { socket, state, _dir: dir }
}

async fn serve(stream: tokio::net::UnixStream, state: Arc<Mutex<State>>) {
    let (rd, mut wr) = stream.into_split();
    let mut lines = BufReader::new(rd).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(Message::Request { id, method, params }) = Message::parse(&line) else { continue };
        let params = params.unwrap_or(Value::Null);
        let (fault, answer) = {
            let mut s = state.lock().unwrap();
            let count = s.counts.entry(method.clone()).or_default();
            *count += 1;
            let n = *count;
            let fault = s.faults.iter().find(|(m, at, _)| *m == method && *at == n).map(|f| f.2);
            if fault == Some(Fault::Cut) {
                return;
            }
            (fault, handle(&mut s, &method, &params))
        };
        match fault {
            Some(Fault::AnswerLost) => return,
            Some(Fault::Stall) => std::future::pending::<()>().await,
            _ => {}
        }
        let reply = match answer {
            Ok(v) => Message::ok(id, v),
            Err(e) => Message::err(id, e),
        };
        if wr.write_all(reply.to_line().as_bytes()).await.is_err() {
            return;
        }
    }
}

fn handle(s: &mut State, m: &str, p: &Value) -> Result<Value, RpcError> {
    let b64 = base64::engine::general_purpose::STANDARD;
    let offset = p["offset"].as_u64().unwrap_or(0) as usize;
    let refuse = |what: &str| Err(RpcError::new(-32000, format!("transfer.{what}")));
    match m {
        "_acpmux/transfer_begin" => Ok(json!({
            "schema": "acpmux.transfer.v1", "transferId": TID, "sessionId": "chat", "epoch": 0,
            "files": [{"path": BUNDLE_FILE, "size": s.bundle.len()}],
        })),
        "_acpmux/transfer_read" => {
            let end = (offset + PAGE).min(s.bundle.len());
            let data = b64.encode(&s.bundle[offset..end]);
            Ok(json!({"data": data, "next": end, "eof": end == s.bundle.len()}))
        }
        "_acpmux/transfer_receive" if s.refuse_receive => refuse("size: refused"),
        "_acpmux/transfer_receive" => Ok(json!({"receiveId": "r1"})),
        "_acpmux/transfer_write" => {
            let have = s.received.len();
            if offset != have {
                let e = RpcError::new(-32000, format!("transfer.offset: has {have}, not {offset}"));
                return Err(e.with_data(json!({"size": have})));
            }
            s.received.extend(b64.decode(p["data"].as_str().unwrap()).unwrap());
            Ok(json!({}))
        }
        "_acpmux/transfer_finish" if s.finished => refuse("unknown: no receive r1"),
        "_acpmux/transfer_finish" => {
            s.finished = true;
            Ok(json!({"sessionId": "chat-there", "name": "Chat"}))
        }
        "_acpmux/transfer_commit" => {
            s.committed = Some(p["to"].clone());
            Ok(json!({"committed": true}))
        }
        "_acpmux/transfer_abort" if s.aborted || s.committed.is_some() => {
            refuse("unknown: the chat is not in this move")
        }
        "_acpmux/transfer_abort" => {
            s.aborted = true;
            Ok(json!({}))
        }
        "_acpmux/transfer_forget" => Ok(json!({"transferId": TID, "landed": s.finished})),
        m if m == method::MUX_EVENTS => {
            let events =
                if s.finished { vec![json!({"msg": {"transferId": TID}})] } else { vec![] };
            Ok(json!({"events": events}))
        }
        m if m == method::MUX_INFO => Ok(json!({"sessionId": "chat-there", "name": "Chat"})),
        // `initialize`, a caller's hello.
        _ => Ok(json!({})),
    }
}

fn bundle(bytes: usize) -> Vec<u8> {
    (0..bytes).map(|i| (i * 31 % 251) as u8).collect()
}

/// Begins the move of `chat` on `src` and finishes it to `dst` through ends that reach them
/// again (`reconnect`) or not, noted in `journal`.
async fn run_move(src: &Fake, dst: &Fake, reconnect: bool, journal: &Path) -> Result<Value> {
    let (s, d) = (Client::connect(&src.socket).await?, Client::connect(&dst.socket).await?);
    let pick = |f: &Fake| if reconnect { f.reach() } else { None };
    let mut s_end = MoveEnd::new("source", &s, pick(src)).with_waits(SHORT, SHORT * 5);
    let mut d_end = MoveEnd::new("target", &d, pick(dst)).with_waits(SHORT, SHORT * 5);
    let begun = begin_move(&mut s_end, "chat", None, (false, false), None).await?;
    let to = json!({"host": "target-host"});
    let moved = finish_journaled(
        &mut s_end,
        &mut d_end,
        &json!({}),
        "chat",
        &begun,
        None,
        None,
        (journal, to),
    )
    .await;
    s_end.close().await;
    d_end.close().await;
    moved
}

fn noted(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    names.sort();
    names
}

/// The faults of a multi-megabyte move: a read cut, a write whose answer is lost after it
/// landed, a write cut before it landed, and a write whose answer never comes.
fn faulty_ends(bytes: usize) -> (Fake, Fake) {
    let src = fake(State {
        bundle: bundle(bytes),
        faults: vec![("_acpmux/transfer_read", 3, Fault::Cut)],
        ..Default::default()
    });
    let dst = fake(State {
        faults: vec![
            ("_acpmux/transfer_write", 2, Fault::AnswerLost),
            ("_acpmux/transfer_write", 4, Fault::Cut),
            ("_acpmux/transfer_write", 6, Fault::Stall),
        ],
        ..Default::default()
    });
    (src, dst)
}

#[tokio::test]
async fn a_dropped_connection_mid_page_used_to_fail_the_move_and_leave_the_chat_frozen() {
    // As before the fix: the first drop ends the move, the target cannot say, and nothing gives
    // the chat back ("it is being moved already" on the next try).
    let (src, dst) = faulty_ends(6 * MIB);
    let journal = tempfile::tempdir().unwrap();
    let e = run_move(&src, &dst, false, journal.path()).await.unwrap_err();
    let text = format!("{e:#}");
    assert!(
        text.contains(
            "daemon connection closed while waiting for the reply to _acpmux/transfer_write"
        ),
        "{text}"
    );
    // Named for the socket it went through, not this machine's own daemon.
    assert!(text.contains(&dst.socket.display().to_string()), "{text}");
    assert!(!text.contains("is still running but dropped"), "{text}");
    let s = src.state.lock().unwrap();
    assert!(s.committed.is_none() && !s.aborted, "left frozen");
}

#[tokio::test]
async fn a_multi_megabyte_move_whose_connections_drop_or_stall_mid_page_resumes_and_commits() {
    let bytes = 6 * MIB + 12_345;
    let (src, dst) = faulty_ends(bytes);
    let journal = tempfile::tempdir().unwrap();
    let moved = run_move(&src, &dst, true, journal.path()).await.unwrap();
    assert_eq!(moved["sessionId"], "chat-there", "{moved}");
    let d = dst.state.lock().unwrap();
    assert_eq!(d.received.len(), bytes);
    assert!(d.received == bundle(bytes), "the target has the bundle byte for byte");
    assert!(d.finished);
    assert_eq!(d.connections, 4, "the first connection and one per drop");
    let s = src.state.lock().unwrap();
    assert_eq!(s.connections, 2);
    assert_eq!(s.committed, Some(json!({"host": "target-host", "sessionId": "chat-there"})));
    assert!(!s.aborted);
    assert!(noted(journal.path()).is_empty(), "the ended move leaves no journal entry");
}

#[tokio::test]
async fn a_finish_whose_answer_is_lost_after_it_landed_commits_on_the_source() {
    let src = fake(State { bundle: bundle(2 * MIB), ..Default::default() });
    let dst = fake(State {
        faults: vec![("_acpmux/transfer_finish", 1, Fault::AnswerLost)],
        ..Default::default()
    });
    let journal = tempfile::tempdir().unwrap();
    let moved = run_move(&src, &dst, true, journal.path()).await.unwrap();
    assert_eq!(moved["sessionId"], "chat-there");
    assert_eq!(
        dst.state.lock().unwrap().counts["_acpmux/transfer_finish"],
        1,
        "never finished twice"
    );
    assert!(src.state.lock().unwrap().committed.is_some());
    assert!(noted(journal.path()).is_empty());
}

#[tokio::test]
async fn a_move_the_target_refuses_gives_the_chat_back_even_when_the_source_connection_dropped() {
    let src = fake(State {
        bundle: bundle(MIB),
        faults: vec![("_acpmux/transfer_abort", 1, Fault::Cut)],
        ..Default::default()
    });
    let dst = fake(State { refuse_receive: true, ..Default::default() });
    let journal = tempfile::tempdir().unwrap();
    let e = run_move(&src, &dst, true, journal.path()).await.unwrap_err();
    assert!(format!("{e:#}").contains("transfer.size"), "{e:#}");
    assert!(src.state.lock().unwrap().aborted, "the abort was asked again on a new connection");
    assert!(noted(journal.path()).is_empty());
}

#[tokio::test]
async fn a_move_neither_end_can_answer_for_stays_in_the_journal_with_its_owner() {
    let src = fake(State { bundle: bundle(2 * MIB), ..Default::default() });
    // Every write after the first is cut: the target drops more often than an end reconnects.
    let faults = (2..=2 + REOPENS as usize + 1).map(|n| ("_acpmux/transfer_write", n, Fault::Cut));
    let dst = fake(State { faults: faults.collect(), ..Default::default() });
    let mut fail_events =
        (1..=REOPENS as usize + 2).map(|n| (method::MUX_EVENTS, n, Fault::Cut)).collect::<Vec<_>>();
    dst.state.lock().unwrap().faults.append(&mut fail_events);
    let journal = tempfile::tempdir().unwrap();
    assert!(run_move(&src, &dst, true, journal.path()).await.is_err());
    assert_eq!(noted(journal.path()), vec![format!("{TID}.json")]);
    let j: Journal =
        serde_json::from_slice(&std::fs::read(journal.path().join(format!("{TID}.json"))).unwrap())
            .unwrap();
    assert_eq!((j.pid, j.session_id.as_str(), j.epoch), (std::process::id(), "chat", 0));
    assert_eq!(j.to, json!({"host": "target-host"}));
}

/// A pid no process has now.
fn dead_pid() -> u32 {
    let mut child = std::process::Command::new("true").spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    pid
}

#[tokio::test]
async fn a_move_whose_client_died_is_ended_by_the_next_run_and_a_live_ones_is_left_alone() {
    for landed in [false, true] {
        let src = fake(State::default());
        let dst = fake(State { finished: landed, ..Default::default() });
        let dir = tempfile::tempdir().unwrap();
        let dead = Journal {
            session_id: "chat".into(),
            transfer_id: TID.into(),
            epoch: 3,
            pid: dead_pid(),
            src: src.reach().unwrap(),
            dst: dst.reach().unwrap(),
            to: json!({"host": "target-host"}),
        };
        dead.note(dir.path());
        let live_id = "0190aaaa-0000-7000-8000-000000000002";
        Journal { transfer_id: live_id.into(), pid: std::process::id(), ..dead.clone() }
            .note(dir.path());
        let ended = reclaim_dead_moves(dir.path()).await;
        let how = if landed { Reclaimed::Committed } else { Reclaimed::Aborted };
        assert_eq!(ended, vec![("chat".to_owned(), how)]);
        let s = src.state.lock().unwrap();
        if landed {
            assert_eq!(s.committed, Some(json!({"host": "target-host"})));
        } else {
            assert!(s.aborted && s.committed.is_none());
        }
        assert_eq!(noted(dir.path()), vec![format!("{live_id}.json")], "the live move is its own");
        assert_eq!(dst.state.lock().unwrap().counts["_acpmux/transfer_forget"], 1);
    }
}

#[tokio::test]
async fn a_dead_move_whose_target_cannot_be_reached_stays_noted_for_the_next_run() {
    let src = fake(State::default());
    let dir = tempfile::tempdir().unwrap();
    let gone = dir.path().join("gone.sock");
    let j = Journal {
        session_id: "chat".into(),
        transfer_id: TID.into(),
        epoch: 0,
        pid: dead_pid(),
        src: src.reach().unwrap(),
        dst: Reach::Socket { path: gone },
        to: json!({}),
    };
    let journal = dir.path().join("moves");
    j.note(&journal);
    assert!(reclaim_dead_moves(&journal).await.is_empty());
    assert_eq!(noted(&journal), vec![format!("{TID}.json")]);
    let s = src.state.lock().unwrap();
    assert!(!s.aborted && s.committed.is_none(), "nothing is given back the target may hold");
}

#[test]
fn a_journal_entry_names_only_a_plain_transfer_id() {
    let dir = tempfile::tempdir().unwrap();
    assert!(journal_path(dir.path(), "../x").is_none());
    assert!(journal_path(dir.path(), "").is_none());
    assert_eq!(journal_path(dir.path(), TID), Some(dir.path().join(format!("{TID}.json"))));
}

/// A daemon swapped mid-move (its first connection drops on the first page) is reached again
/// at the same socket, and the page is asked again there: the move goes on.
#[cfg(unix)]
#[tokio::test]
async fn a_request_whose_daemon_was_swapped_is_sent_again_to_the_new_one() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("d.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let served = tokio::spawn(async move {
        // Each daemon answers what it is asked, the old one until the page: it goes away
        // with that unanswered.
        let mut asked = Vec::new();
        for old in [true, false] {
            let (conn, _) = listener.accept().await.unwrap();
            let (rd, mut wr) = conn.into_split();
            let mut lines = tokio::io::BufReader::new(rd).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let v: Value = serde_json::from_str(&line).unwrap();
                let m = v["method"].as_str().unwrap_or_default().to_owned();
                asked.push(m.clone());
                if old && m == "_acpmux/transfer_read" {
                    break;
                }
                let reply = json!({"jsonrpc": "2.0", "id": v["id"], "result": {"ok": true}});
                wr.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
                if m == "_acpmux/transfer_read" {
                    break;
                }
            }
        }
        asked
    });
    let first = Client::connect(&socket).await.unwrap();
    let mut daemon = MoveEnd::new("source", &first, Some(Reach::Socket { path: socket.clone() }));
    let page = daemon.request("_acpmux/transfer_read", json!({"offset": 0})).await.unwrap();
    assert_eq!(page["ok"], true);
    // A reconnect says hello twice (`Client::connect`, then `connect_reach`): once is enough here.
    let mut asked = served.await.unwrap();
    asked.dedup();
    let (hello, page) = (method::INITIALIZE.to_owned(), "_acpmux/transfer_read".to_owned());
    assert_eq!(asked, vec![hello.clone(), page.clone(), hello, page], "asked again on the new one");
}
