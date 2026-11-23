use super::*;
use crate::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use std::collections::BTreeMap;

/// A hub with the fake agent behind a real Unix socket, and a client.
async fn daemon() -> (Arc<crate::hub::Hub>, Arc<Client>, cmux_unix_socket::TestDir) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let harnesses = BTreeMap::from([("fake".to_owned(), profile)]);
    let mut cfg = Config { harnesses, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let dir = cmux_unix_socket::short_test_dir("acpmux-tail");
    let path = dir.path().join("d.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub.clone(), listener));
    let client = Client::connect(&path).await.unwrap();
    (hub, client, dir)
}

/// A chat with `records` tool outputs of `bytes` each after its own start records.
async fn chat_with_output(
    hub: &Arc<crate::hub::Hub>,
    client: &Arc<Client>,
    records: usize,
    bytes: usize,
) -> String {
    let s = client
        .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    for n in 0..records {
        hub.append(
            &session,
            "in",
            "tool_call_update",
            json!({"jsonrpc": "2.0", "method": method::SESSION_UPDATE, "params": {"sessionId": "agent-1",
                "update": {"sessionUpdate": "tool_call_update", "toolCallId": format!("call-{n}"), "status": "completed",
                    "content": [{"type": "content", "content": {"type": "text", "text": "x".repeat(bytes)}}]}}}),
        );
    }
    id
}

/// The buffer bound: `session tail --since` hands out the log one daemon page at a time, each
/// within `hub::DEFAULT_PAGE_BYTES` plus the one record a page always carries, and reads the
/// next page only after the last is written. Before, it read all 48 MiB here into one list.
#[tokio::test]
async fn session_tail_holds_at_most_one_page_of_the_log() {
    let (hub, client, dir) = daemon().await;
    let record = 512 << 10;
    let id = chat_with_output(&hub, &client, 96, record).await;
    let last_seq = hub.resolve(&id).unwrap().meta().last_seq;
    let (mut pages, mut seen, mut largest, mut next) = (0, 0u64, 0usize, 1u64);
    let flow = stream_after(&client, &id, 0, None, |page| {
        pages += 1;
        largest = largest.max(page.iter().map(|e| e.to_string().len()).sum());
        for e in &page {
            assert_eq!(e["seq"].as_u64().unwrap(), next, "a page skipped or repeated a record");
            next += 1;
        }
        seen += page.len() as u64;
        Ok(Flow::Go)
    })
    .await
    .unwrap();
    assert_eq!(flow, Flow::Go);
    assert_eq!(seen, last_seq, "every record once");
    assert!(pages >= 24, "{pages} pages for 48 MiB");
    let bound = crate::hub::DEFAULT_PAGE_BYTES + record + (64 << 10);
    assert!(largest <= bound, "a page held {largest} bytes (bound {bound})");

    // A reader gone after the first page: nothing more is read.
    let mut pages = 0;
    let flow = stream_after(&client, &id, 0, None, |_| {
        pages += 1;
        Ok(Flow::Stop)
    })
    .await
    .unwrap();
    assert_eq!((flow, pages), (Flow::Stop, 1));

    // `--since` through a bound (`--last`'s older part) ends at it.
    let mut got = Vec::new();
    stream_after(&client, &id, 3, Some(9), |page| {
        got.extend(page.iter().map(|e| e["seq"].as_u64().unwrap()));
        Ok(Flow::Go)
    })
    .await
    .unwrap();
    assert_eq!(got, (4..=9).collect::<Vec<_>>());
    drop(dir);
}

/// `--last N` past one attach page: the newest N, oldest first, read forward in pages.
#[tokio::test]
async fn session_tail_last_reads_older_pages_forward() {
    let (hub, client, dir) = daemon().await;
    let id = chat_with_output(&hub, &client, 12, 256 << 10).await;
    let last_seq = hub.resolve(&id).unwrap().meta().last_seq;
    let mut buf = Vec::new();
    let mut out = Out::new(&id, false, &mut buf);
    assert_eq!(stream_last(&client, &id, 10, &mut out).await.unwrap(), Flow::Go);
    let seqs: Vec<u64> = String::from_utf8(buf)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str::<Value>(l).unwrap()["seq"].as_u64().unwrap())
        .collect();
    assert_eq!(seqs, (last_seq - 9..=last_seq).collect::<Vec<_>>());
    drop(dir);
}

struct ClosedPipe;

impl Write for ClosedPipe {
    fn write(&mut self, _: &[u8]) -> io::Result<usize> {
        Err(io::ErrorKind::BrokenPipe.into())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// A closed stdout ends the tail at the first line, quietly.
#[test]
fn session_tail_stops_on_a_closed_pipe() {
    let mut out = Out::new("s", false, ClosedPipe);
    let events = vec![json!({"seq": 1}), json!({"seq": 2})];
    assert_eq!(out.events(events).unwrap(), Flow::Stop);
}

/// The unread watch sees a pipe whose reader closed, and only that.
#[cfg(unix)]
#[test]
fn session_tail_sees_a_pipe_whose_reader_closed() {
    use std::os::fd::AsRawFd as _;
    // `std::io::pipe` opens both ends close-on-exec: a child another test spawns keeps no copy of
    // the read end past its exec (a bare `libc::pipe` kept one for the child's whole life).
    let (read, write) = std::io::pipe().unwrap();
    let fd = write.as_raw_fd();
    assert_eq!(fd_kind(fd), Stdout::Read);
    assert!(!fd_reader_gone(fd, Duration::from_millis(50)), "an open pipe");
    drop(read);
    // Between its fork and its exec, a child another test spawns still holds a copy of the read
    // end, and on a loaded runner that window outlasted a 50 ms poll. The watch's job is to wake
    // when the last reader goes, so wait for that event: poll returns as soon as it arrives, and
    // the bound only keeps a watch that never wakes from hanging the suite.
    assert!(fd_reader_gone(fd, Duration::from_secs(60)), "a pipe with no reader");
    drop(write);
    assert!(!parent_gone(crate::parent_watch::parent_pid()));
    let null = std::fs::OpenOptions::new().write(true).open("/dev/null").unwrap();
    assert_eq!(fd_kind(std::os::fd::AsRawFd::as_raw_fd(&null)), Stdout::Unread);
    let file = tempfile::tempfile().unwrap();
    assert_eq!(fd_kind(std::os::fd::AsRawFd::as_raw_fd(&file)), Stdout::File);
}
