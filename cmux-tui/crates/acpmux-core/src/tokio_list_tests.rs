//! `acpmux_client::tokio_list` against the hub in one process: the upgrade and its fallback, a
//! walk that holds at most one page, rows by key, rows as v1 gave them, and a mirror that
//! survives random changes, a drop and a resume.

use crate::conn::{self, HubSource};
use crate::hub::Hub;
use acpmux_book::index::{RowKey, Summary, SummaryIndex};
use acpmux_client::Change;
use acpmux_client::tokio_list::{self, ListConnection, Opened, Read};
use acpmux_client::wire::{Frame, FrameDecoder, ListKey, ListView, OriginState};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream, ReadHalf, WriteHalf};

const WAIT: Duration = Duration::from_secs(10);

type Halves = (ReadHalf<DuplexStream>, WriteHalf<DuplexStream>);

/// A daemon's socket in miniature: it reads the first line, answers the upgrade (or refuses it
/// as a daemon without `list` does), then serves the v2 connection.
fn daemon(hub: Arc<Hub>, upgrade: bool) -> Halves {
    let (client, server) = tokio::io::duplex(64 * 1024);
    tokio::spawn(async move {
        let (mut reader, mut writer) = tokio::io::split(server);
        let mut line = Vec::new();
        loop {
            let Ok(byte) = reader.read_u8().await else { return };
            if byte == b'\n' {
                break;
            }
            line.push(byte);
        }
        let request: Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(request["method"], "_acpmux/v2");
        assert_eq!(request["params"]["surfaces"], json!(["list"]));
        let id = request["id"].clone();
        if !upgrade {
            let refusal = json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"method not found"}});
            let _ = writer.write_all(format!("{refusal}\n").as_bytes()).await;
            return;
        }
        let reply = json!({"jsonrpc":"2.0","id":id,"result":{"upgrade":true}});
        writer.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
        let source = Arc::new(HubSource::new(hub));
        let _ =
            conn::run(reader, writer, source, "test", &["list".into()], conn::Role::Local).await;
    });
    tokio::io::split(client)
}

/// [`daemon`] whose every `page` is refused by an error that names no sid: each page request
/// goes to the hub under a sid it does not hold, and the sid is taken out of the error.
fn refusing_pages(hub: Arc<Hub>) -> Halves {
    let (client, proxy) = tokio::io::duplex(64 * 1024);
    let (inner, server) = daemon(hub, true);
    let (mut from_client, mut to_client) = tokio::io::split(proxy);
    let (mut from_daemon, mut to_daemon) = (inner, server);
    // The upgrade line goes through as it is, then frames, each rewritten.
    tokio::spawn(async move {
        let mut line = Vec::new();
        loop {
            let Ok(byte) = from_client.read_u8().await else { return };
            line.push(byte);
            if byte == b'\n' {
                break;
            }
        }
        to_daemon.write_all(&line).await.unwrap();
        pump(&mut from_client, &mut to_daemon, |value| {
            if value["method"] == "page" {
                value["params"]["sid"] = json!("nobody");
            }
        })
        .await;
    });
    tokio::spawn(async move {
        let mut line = Vec::new();
        loop {
            let Ok(byte) = from_daemon.read_u8().await else { return };
            line.push(byte);
            if byte == b'\n' {
                break;
            }
        }
        to_client.write_all(&line).await.unwrap();
        pump(&mut from_daemon, &mut to_client, |value| {
            if value["method"] == "page"
                && value.get("code").is_some()
                && let Some(error) = value.as_object_mut()
            {
                error.remove("sid");
            }
        })
        .await;
    });
    tokio::io::split(client)
}

/// Copies frames from `from` to `to`, each JSON one through `rewrite`.
async fn pump(
    from: &mut (impl tokio::io::AsyncRead + Unpin),
    to: &mut (impl tokio::io::AsyncWrite + Unpin),
    rewrite: impl Fn(&mut Value),
) {
    let mut decoder = FrameDecoder::default();
    let mut buf = [0_u8; 16 * 1024];
    loop {
        let Ok(n) = from.read(&mut buf).await else { return };
        if n == 0 {
            return;
        }
        for frame in decoder.push(&buf[..n]).unwrap() {
            let frame = match frame.decode_json::<Value>() {
                Ok(mut value) if value.is_object() => {
                    rewrite(&mut value);
                    Frame::json(frame.kind, &value).unwrap()
                }
                _ => frame,
            };
            if to.write_all(&frame.encode()).await.is_err() {
                return;
            }
        }
    }
}

async fn open(hub: &Arc<Hub>) -> ListConnection<ReadHalf<DuplexStream>, WriteHalf<DuplexStream>> {
    let (reader, writer) = daemon(hub.clone(), true);
    match tokio::time::timeout(WAIT, tokio_list::open(reader, writer)).await.unwrap().unwrap() {
        Opened::List(connection) => *connection,
        Opened::Fallback { .. } => panic!("the daemon upgraded"),
    }
}

/// A time this run's rows count from: now, so every row is hot and the index holds it.
fn base() -> u64 {
    static BASE: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    *BASE.get_or_init(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.as_millis() as u64)
    })
}

fn row(id: &str, state: &str, at: u64) -> Summary {
    let mut row = Summary::new(id);
    row.harness = "claude".into();
    row.state = state.into();
    row.last_activity = base() + at;
    row
}

/// Starts the hub's writer and waits until its snapshot holds what `done` asks.
async fn settle(hub: &Arc<Hub>, done: impl Fn(&SummaryIndex) -> bool) {
    tokio::time::timeout(WAIT, async {
        while !done(&hub.snapshot()) {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}

fn live_rows(hub: &Hub) -> HashMap<(String, String), Value> {
    hub.snapshot()
        .iter()
        .filter(|summary| summary.is_live())
        .map(|summary| {
            (
                (summary.origin.clone(), summary.chat_id.clone()),
                serde_json::to_value(summary.as_ref()).unwrap(),
            )
        })
        .collect()
}

#[tokio::test]
async fn a_daemon_without_list_hands_the_transport_back() {
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    let (reader, writer) = daemon(Arc::new(hub), false);
    let opened = tokio::time::timeout(WAIT, tokio_list::open(reader, writer)).await.unwrap();
    assert!(matches!(opened.unwrap(), Opened::Fallback { bytes, .. } if bytes.is_empty()));
}

#[tokio::test]
async fn a_walk_holds_at_most_one_page_it_has_not_handed_out() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    // Long titles cut the walk into many pages by bytes.
    for index in 0..2_000_u64 {
        let mut live = row(&format!("live-{index:04}"), "idle", 1_000 + index);
        live.title = "t".repeat(200);
        writer.apply(live).unwrap();
        writer.apply(row(&format!("closed-{index:04}"), "closed", 5_000 + index)).unwrap();
    }
    let hub = Arc::new(hub);
    let mut connection = open(&hub).await;
    let mut reading =
        connection.read(Read::Walk { view: ListView::Live, filter: None }).await.unwrap();
    let mut rows = Vec::new();
    let mut pages = 0;
    while let Some(page) = tokio::time::timeout(WAIT, reading.next()).await.unwrap().unwrap() {
        pages += 1;
        rows.extend(page.rows);
        // A slow taker: nothing more is asked for while it holds the page.
        tokio::task::yield_now().await;
    }
    drop(reading);
    assert!(pages > 2, "the walk took {pages} pages");
    assert_eq!(connection.unhanded_peak(), 1);
    assert_eq!(connection.pages_asked(), pages);
    assert_eq!(rows.len(), 2_000);
    assert!(rows.iter().all(Summary::is_live));
    assert!(rows.windows(2).all(|pair| pair[0].last_activity >= pair[1].last_activity));
}

#[tokio::test]
async fn a_page_refused_with_no_sid_ends_the_read() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    for index in 0..300_u64 {
        writer.apply(row(&format!("live-{index:04}"), "idle", 1_000 + index)).unwrap();
    }
    let (reader, writer) = refusing_pages(Arc::new(hub));
    let mut connection = match tokio::time::timeout(WAIT, tokio_list::open(reader, writer))
        .await
        .unwrap()
        .unwrap()
    {
        Opened::List(connection) => *connection,
        Opened::Fallback { .. } => panic!("the daemon upgraded"),
    };
    let mut reading =
        connection.read(Read::Walk { view: ListView::Live, filter: None }).await.unwrap();
    // The window comes; the page after it is refused, and the read says so.
    let window = tokio::time::timeout(WAIT, reading.next()).await.unwrap().unwrap().unwrap();
    assert!(!window.rows.is_empty() && window.rows.len() < 300);
    let refused = tokio::time::timeout(WAIT, reading.next()).await.expect("the read ended");
    let error = refused.expect_err("a refused page is an error");
    assert!(error.to_string().contains("page"), "{error}");
}

#[tokio::test]
async fn a_window_reads_the_newest_rows_of_a_view() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    for index in 0..30_u64 {
        writer.apply(row(&format!("chat-{index}"), "idle", index)).unwrap();
    }
    let hub = Arc::new(hub);
    let mut connection = open(&hub).await;
    let mut reading =
        connection.read(Read::Window { view: ListView::All, filter: None, rows: 5 }).await.unwrap();
    let page = reading.next().await.unwrap().unwrap();
    assert_eq!(
        page.rows.iter().map(|row| row.chat_id.as_str()).collect::<Vec<_>>(),
        ["chat-29", "chat-28", "chat-27", "chat-26", "chat-25"]
    );
    assert!(reading.next().await.unwrap().is_none());
}

#[tokio::test]
async fn rows_by_key_go_a_hundred_a_request_and_say_what_is_missing() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    for index in 0..250_u64 {
        writer.apply(row(&format!("chat-{index}"), "closed", index)).unwrap();
    }
    let hub = Arc::new(hub);
    let mut connection = open(&hub).await;
    let key = |origin: &str, id: &str| ListKey {
        last_activity: 0,
        chat_id: id.to_owned(),
        origin: origin.to_owned(),
    };
    let mut keys: Vec<ListKey> =
        (0..250).map(|index| key("local", &format!("chat-{index}"))).collect();
    keys.push(key("local", "nobody"));
    keys.push(key("peer-a", "theirs"));
    let asked_before = connection.pages_asked();
    let mut reading = connection.read(Read::Keys(keys)).await.unwrap();
    let (mut rows, mut missing, mut unknown) = (0, Vec::new(), Vec::new());
    while let Some(page) = reading.next().await.unwrap() {
        rows += page.rows.len();
        missing.extend(page.missing.into_iter().map(|key| key.chat_id));
        unknown.extend(page.unknown.into_iter().map(|key| key.chat_id));
    }
    drop(reading);
    assert_eq!(rows, 250);
    assert_eq!(missing, ["nobody"]);
    assert_eq!(unknown, ["theirs"]);
    // The window, then three keyed pages for 252 keys.
    assert_eq!(connection.pages_asked() - asked_before, 4);
}

#[tokio::test]
async fn rows_as_v1_gave_them_read_a_parent_that_is_not_among_them() {
    let (hub, writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    tokio::spawn(writer.run());
    let mut closed_parent = row("closed-parent", "closed", 1);
    closed_parent.title = "closed parent".into();
    let mut archived_parent = row("archived-parent", "idle", 2);
    archived_parent.archived = true;
    let child = |id: &str, parent: &str, at: u64| {
        let mut child = row(id, "idle", at);
        child.parent = Some(RowKey::new("local", parent));
        child
    };
    hub.submit(closed_parent).unwrap();
    hub.submit(archived_parent).unwrap();
    hub.submit(child("under-closed", "closed-parent", 10)).unwrap();
    hub.submit(child("under-archived", "archived-parent", 11)).unwrap();
    hub.submit(child("under-nobody", "nobody", 12)).unwrap();
    hub.origin("peer-a", OriginState::Stale, 5).unwrap();
    let mut theirs = row("theirs", "idle", 13);
    theirs.origin = "peer-a".into();
    hub.submit(theirs).unwrap();
    settle(&hub, |index| index.iter().count() == 6).await;

    let mut connection = open(&hub).await;
    let mut reading =
        connection.read(Read::Walk { view: ListView::Live, filter: None }).await.unwrap();
    let mut rows = Vec::new();
    while let Some(page) = reading.next().await.unwrap() {
        rows.extend(page.rows);
    }
    drop(reading);
    // The closed parent is not in the live walk: it is read by key.
    assert!(!rows.iter().any(|row| row.chat_id == "closed-parent"));
    let v1 = connection.v1_rows(&rows).await.unwrap();
    let by_id: HashMap<&str, &Value> =
        v1.iter().map(|row| (row["sessionId"].as_str().unwrap(), row)).collect();
    assert_eq!(by_id["under-closed"]["spawnedBy"], "closed-parent");
    assert!(by_id["under-archived"].get("spawnedBy").is_none());
    assert!(by_id["under-nobody"].get("spawnedBy").is_none());
    assert_eq!(by_id["theirs"]["peer"], "peer-a");
    assert_eq!(by_id["theirs"]["stale"], true);
    assert!(by_id["under-closed"].get("stale").is_none());
    // Each crossed through `v1_row` and nothing else.
    for summary in &rows {
        let parent = summary.parent.as_ref().and_then(|parent| {
            hub.snapshot().iter().find(|row| row.key() == *parent).map(|row| row.as_ref().clone())
        });
        assert_eq!(
            by_id[summary.chat_id.as_str()],
            &acpmux_client::v1_row(
                summary,
                connection.origin_state(&summary.origin),
                parent.as_ref()
            )
        );
    }
}

/// A peer whose link is down and who lists only a closed chat: the index keeps no closed row of
/// a peer (`SummaryIndex::apply_summary`), so read by key the chat has no row, where v1's list
/// gives it with `stale: true`. A caller that must print it reads v1.
#[tokio::test]
async fn a_closed_row_of_a_down_peer_has_no_row_by_key() {
    let (hub, writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    tokio::spawn(writer.run());
    hub.origin("peer-b", OriginState::Stale, base()).unwrap();
    let mut old = row("old", "closed", base() + 3);
    old.origin = "peer-b".into();
    hub.submit(old).unwrap();
    hub.submit(row("here", "idle", base() + 20)).unwrap();
    settle(&hub, |index| index.iter().any(|row| row.chat_id == "here")).await;
    assert_eq!(hub.snapshot().iter().count(), 1, "the index keeps no closed row of a peer");

    let mut connection = open(&hub).await;
    let key = ListKey { last_activity: 0, chat_id: "old".into(), origin: "peer-b".into() };
    let mut reading = connection.read(Read::Keys(vec![key])).await.unwrap();
    let mut rows = Vec::new();
    while let Some(page) = tokio::time::timeout(WAIT, reading.next()).await.unwrap().unwrap() {
        rows.extend(page.rows);
    }
    assert!(rows.is_empty(), "{rows:?}");
}

/// Applies a mirror's changes to the rows it holds.
fn apply(change: Change<Summary>, rows: &mut HashMap<(String, String), Value>) {
    let mut put = |summary: Summary| {
        rows.insert(
            (summary.origin.clone(), summary.chat_id.clone()),
            serde_json::to_value(&summary).unwrap(),
        );
    };
    match change {
        Change::Window(window) => window.rows.into_iter().for_each(&mut put),
        Change::Page(page) => page.rows.into_iter().for_each(&mut put),
        Change::Summary { summary, .. } => put(summary),
        Change::Left { summary, .. } => {
            rows.remove(&(summary.origin, summary.chat_id));
        }
        Change::Gone { origin, chat_id, .. } => {
            rows.remove(&(origin, chat_id));
        }
        _ => {}
    }
}

#[tokio::test]
async fn a_follow_holds_the_hubs_live_rows_through_changes_a_drop_and_a_resume() {
    let (hub, writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    tokio::spawn(writer.run());
    for index in 0..40_u64 {
        hub.submit(row(
            &format!("chat-{index}"),
            if index % 3 == 0 { "closed" } else { "idle" },
            index,
        ))
        .unwrap();
    }
    settle(&hub, |index| index.iter().count() == 40).await;

    let mut connection = open(&hub).await;
    let mut following =
        connection.follow(ListView::Live, None, std::iter::empty(), false, None).await.unwrap();
    let mut rows = HashMap::new();
    let mut random = 0x9e37_79b9_7f4a_7c15_u64;
    let mut step = 0_u64;
    for round in 0..3 {
        if round == 1 {
            // The socket drops while changes go on, and the mirror resumes on a new one.
            for _ in 0..10 {
                change(&hub, &mut random, &mut step);
            }
            let (reader, writer) = daemon(hub.clone(), true);
            following.reconnect(reader, writer).await.unwrap();
        }
        for _ in 0..30 {
            change(&hub, &mut random, &mut step);
        }
        // The writer has taken every change; then the mirror shows them.
        let last = base() + 1_000 + step - 1;
        settle(&hub, |index| index.iter().any(|row| row.last_activity == last)).await;
        tokio::time::timeout(WAIT, async {
            loop {
                if rows == live_rows(&hub) {
                    break;
                }
                let next = following.next().await.unwrap();
                apply(next, &mut rows);
            }
        })
        .await
        .unwrap_or_else(|_| panic!("round {round}: the mirror's rows never equalled the hub's"));
    }
}

/// One random change: a chat's activity moves, it closes or opens, or it is deleted.
fn change(hub: &Hub, random: &mut u64, step: &mut u64) {
    *random ^= *random << 13;
    *random ^= *random >> 7;
    *random ^= *random << 17;
    let id = format!("chat-{}", *random % 50);
    let at = 1_000 + *step;
    *step += 1;
    match *random % 5 {
        0 => {
            hub.remove("local", &id).unwrap();
            // A removal carries no time: the step's time goes to another chat.
            hub.submit(row("clock", "closed", at)).unwrap();
        }
        1 => hub.submit(row(&id, "closed", at)).unwrap(),
        _ => hub.submit(row(&id, "idle", at)).unwrap(),
    }
}
