use acpmux_book::index::{Summary, SummaryIndex};
use acpmux_client::{Change, Client};
use acpmux_core::conn::{self, ConnError, HubSource, Offer, OfferSink, Source};
use acpmux_core::hub::Hub;
use acpmux_core::wire::{self, Cursor, Frame, FrameKind, Sub, Window};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, DuplexStream};

async fn read_frame(reader: &mut (impl AsyncRead + Unpin)) -> Frame {
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut header = [0_u8; 4];
        reader.read_exact(&mut header).await.unwrap();
        let len = u32::from_be_bytes(header) as usize;
        let mut bytes = header.to_vec();
        bytes.resize(len + 4, 0);
        reader.read_exact(bytes.get_mut(4..).unwrap()).await.unwrap();
        Frame::from_encoded(&bytes).unwrap()
    })
    .await
    .unwrap()
}

async fn send_bytes(writer: &mut (impl AsyncWrite + Unpin), bytes: Vec<u8>) {
    writer.write_all(&bytes).await.unwrap();
}

fn pair(hub: Arc<Hub>) -> (DuplexStream, tokio::task::JoinHandle<Result<(), ConnError>>) {
    let (client, server) = tokio::io::duplex(4096);
    let source = Arc::new(HubSource::new(hub));
    let (reader, writer) = tokio::io::split(server);
    let task =
        tokio::spawn(
            async move { conn::run(reader, writer, source, "test", &["list".into()]).await },
        );
    (client, task)
}

fn source_pair(
    source: Arc<dyn Source>,
    surfaces: &[&str],
) -> (DuplexStream, tokio::task::JoinHandle<Result<(), ConnError>>) {
    let (client, server) = tokio::io::duplex(4096);
    let (reader, writer) = tokio::io::split(server);
    let surfaces = surfaces.iter().map(|surface| (*surface).to_owned()).collect::<Vec<_>>();
    let task =
        tokio::spawn(async move { conn::run(reader, writer, source, "test", &surfaces).await });
    (client, task)
}

fn empty_window(sid: &str, cursor: u64) -> Frame {
    Frame::json(
        FrameKind::Window,
        &Window::<Summary> {
            sid: sid.to_owned(),
            cursor,
            rows: Vec::new(),
            has_before: false,
            has_after: false,
            edition: 1,
            origins: Vec::new(),
            before_key: None,
            after_key: None,
        },
    )
    .unwrap()
}

#[derive(Default)]
struct DeferredWindowSource {
    sink: Mutex<Option<Arc<dyn OfferSink>>>,
}

impl Source for DeferredWindowSource {
    fn subscribe(
        &self,
        sub: &Sub,
        _person: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        let mut held = self.sink.lock().unwrap();
        if held.is_none() {
            let not_ready = Frame::json(
                FrameKind::Error,
                &json!({"method":"sub","sid":sub.sid,"code":"not_ready"}),
            )?;
            assert_eq!(
                sink.offer(&sub.sid, not_ready, sub.cursor.unwrap_or_default()),
                Offer::Taken
            );
            *held = Some(sink);
        } else {
            assert_eq!(sink.offer(&sub.sid, empty_window(&sub.sid, 1), Cursor(1)), Offer::Taken);
        }
        Ok(())
    }

    fn resume(&self, _sid: &str, _cursor: Cursor) {}

    fn end(&self, _sid: &str) {
        self.sink.lock().unwrap().take();
    }
}

struct DropAndReplaceSource {
    generations: Mutex<usize>,
}

#[derive(Default)]
struct CreditSource {
    sink: Mutex<Option<Arc<dyn OfferSink>>>,
    remaining: Mutex<u64>,
    next_seq: Mutex<u64>,
}

impl CreditSource {
    fn feed(&self, sid: &str, sink: Arc<dyn OfferSink>) {
        loop {
            let mut remaining = self.remaining.lock().unwrap();
            if *remaining == 0 {
                return;
            }
            let mut next_seq = self.next_seq.lock().unwrap();
            let seq = *next_seq;
            let mut summary = Summary::new(format!("chat-{seq}"));
            summary.title = "x".repeat(256);
            let frame = Frame::json(
                FrameKind::Delta,
                &json!({
                    "sid": sid,
                    "ops": [{
                        "op": "summary",
                        "seq": seq,
                        "summary": summary,
                        "padding": "x".repeat(100_000)
                    }]
                }),
            )
            .unwrap();
            match sink.offer(sid, frame, Cursor(seq)) {
                Offer::Taken => {
                    *remaining -= 1;
                    *next_seq += 1;
                }
                Offer::NotFed | Offer::Dropped { .. } | Offer::UnknownSubscription => return,
            }
        }
    }
}

impl Source for CreditSource {
    fn subscribe(
        &self,
        sub: &Sub,
        _person: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        *self.remaining.lock().unwrap() = 64;
        *self.sink.lock().unwrap() = Some(sink.clone());
        self.feed(&sub.sid, sink);
        Ok(())
    }

    fn resume(&self, sid: &str, _cursor: Cursor) {
        if let Some(sink) = self.sink.lock().unwrap().clone() {
            self.feed(sid, sink);
        }
    }

    fn end(&self, _sid: &str) {
        self.sink.lock().unwrap().take();
    }
}

impl Default for DropAndReplaceSource {
    fn default() -> Self {
        Self { generations: Mutex::new(0) }
    }
}

impl Source for DropAndReplaceSource {
    fn subscribe(
        &self,
        sub: &Sub,
        _person: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        let mut generations = self.generations.lock().unwrap();
        if *generations < 3 {
            let frame = Frame::new(FrameKind::Unknown(200), vec![b'x'; wire::MAX_FRAME_BYTES - 5])?;
            assert_eq!(sink.offer(&sub.sid, frame, Cursor(1)), Offer::Taken);
        } else if *generations == 3 {
            let first = Frame::new(FrameKind::Unknown(200), vec![b'x'; 900_000])?;
            assert_eq!(sink.offer(&sub.sid, first, Cursor(1)), Offer::Taken);
            let second = Frame::new(FrameKind::Unknown(200), vec![b'x'; 900_000])?;
            assert!(matches!(sink.offer(&sub.sid, second, Cursor(2)), Offer::Dropped { .. }));
            let old = empty_window(&sub.sid, 2);
            assert_eq!(sink.offer(&sub.sid, old, Cursor(2)), Offer::UnknownSubscription);
        } else {
            assert_eq!(sink.offer(&sub.sid, empty_window(&sub.sid, 3), Cursor(3)), Offer::Taken);
        }
        *generations += 1;
        Ok(())
    }

    fn resume(&self, _sid: &str, _cursor: Cursor) {}

    fn end(&self, _sid: &str) {}
}

async fn hello<T>(client: &mut Client<T>, stream: &mut DuplexStream)
where
    T: serde::Serialize + for<'de> serde::Deserialize<'de> + Clone,
{
    send_bytes(stream, client.take_send().unwrap()).await;
    let frame = read_frame(stream).await;
    assert_eq!(frame.kind, FrameKind::Hello);
    let encoded = frame.encode();
    assert_eq!(client.received(&encoded), encoded.len());
}

#[tokio::test]
async fn client_and_daemon_resume_after_a_disconnect() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(Summary::new("chat")).unwrap();
    let hub = Arc::new(hub);
    let mut client = Client::<Summary>::connected_v2();
    let (mut stream, task) = pair(hub.clone());
    hello(&mut client, &mut stream).await;
    client.subscribe(Sub::new("s", "list")).unwrap();
    send_bytes(&mut stream, client.take_send().unwrap()).await;
    let window = read_frame(&mut stream).await;
    let encoded = window.encode();
    client.received(&encoded);
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    drop(stream);
    task.await.unwrap().unwrap();

    writer.apply(Summary::new("chat-2")).unwrap();
    client.disconnected();
    let (mut stream, task) = pair(hub);
    hello(&mut client, &mut stream).await;
    let request = client.take_send().unwrap();
    let frame = Frame::from_encoded(&request).unwrap();
    assert_eq!(frame.kind, FrameKind::Request);
    let value: Value = frame.decode_json().unwrap();
    assert_eq!(value.get("method"), Some(&Value::String("sub".into())));
    assert_eq!(value.pointer("/params/cursor"), Some(&Value::from(1_u64)));
    send_bytes(&mut stream, request).await;
    let first = read_frame(&mut stream).await;
    let first_bytes = first.encode();
    assert_eq!(client.received(&first_bytes), first_bytes.len());
    assert!(client.next_change().is_some());
    drop(stream);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn client_reconnect_before_first_window_keeps_anchor() {
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    let mut client = Client::<Summary>::connected_v2();
    let (mut stream, task) = pair(hub.clone());
    hello(&mut client, &mut stream).await;
    client.subscribe(Sub::new("s", "list").around(wire::Anchor::End, 10)).unwrap();
    let _request = client.take_send().unwrap();
    drop(stream);
    task.await.unwrap().unwrap();
    client.disconnected();
    let (mut stream, task) = pair(hub);
    hello(&mut client, &mut stream).await;
    let request = client.take_send().expect("reconnect must resend the initial subscription");
    let frame = Frame::from_encoded(&request).unwrap();
    let value: Value = frame.decode_json().unwrap();
    assert_eq!(value.pointer("/params/anchor"), Some(&Value::String("end".into())));
    assert!(value.pointer("/params/cursor").is_none());
    drop(stream);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn client_and_daemon_keep_not_ready_subscription_until_window() {
    let source = Arc::new(DeferredWindowSource::default());
    let (mut stream, task) = source_pair(source.clone(), &["chat"]);
    let mut client = Client::<Summary>::connected_v2();
    hello(&mut client, &mut stream).await;
    client.subscribe(Sub::new("s", "chat:x")).unwrap();
    send_bytes(&mut stream, client.take_send().unwrap()).await;

    let not_ready = read_frame(&mut stream).await;
    assert_eq!(not_ready.kind, FrameKind::Error);
    let encoded = not_ready.encode();
    assert_eq!(client.received(&encoded), encoded.len());
    assert!(
        matches!(client.next_change(), Some(Change::Error { code, .. }) if code == "not_ready")
    );

    let sink = source.sink.lock().unwrap().clone().unwrap();
    assert_eq!(sink.offer("s", empty_window("s", 1), Cursor(1)), Offer::Taken);
    let window = read_frame(&mut stream).await;
    assert_eq!(window.kind, FrameKind::Window);
    let encoded = window.encode();
    assert_eq!(client.received(&encoded), encoded.len());
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    drop(stream);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn client_and_daemon_replace_dropped_sid_and_ignore_old_frames() {
    let source = Arc::new(DropAndReplaceSource::default());
    let (mut stream, task) = source_pair(source, &["chat"]);
    let mut client = Client::<Summary>::connected_v2();
    hello(&mut client, &mut stream).await;
    for sid in ["s0", "s1", "s2", "s3"] {
        client.subscribe(Sub::new(sid, "chat:x")).unwrap();
    }
    for _ in 0..4 {
        send_bytes(&mut stream, client.take_send().unwrap()).await;
    }

    let (sid, new_sid) = loop {
        let frame = read_frame(&mut stream).await;
        let encoded = frame.encode();
        assert_eq!(client.received(&encoded), encoded.len());
        if frame.kind != FrameKind::Dropped {
            continue;
        }
        let Some(Change::Dropped { sid, new_sid: Some(new_sid), .. }) = client.next_change() else {
            panic!("expected dropped change");
        };
        break (sid, new_sid);
    };
    assert_eq!(sid, "s3");
    let request = client.take_send().expect("dropped subscription must be resubmitted");
    let request_frame = Frame::from_encoded(&request).unwrap();
    let request_value: Value = request_frame.decode_json().unwrap();
    assert_eq!(request_value.pointer("/params/sid"), Some(&Value::String(new_sid)));
    send_bytes(&mut stream, request).await;

    let window = read_frame(&mut stream).await;
    assert_eq!(window.kind, FrameKind::Window);
    let encoded = window.encode();
    assert_eq!(client.received(&encoded), encoded.len());
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    drop(stream);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn client_and_daemon_credit_a_slow_taker_past_one_window() {
    let source = Arc::new(CreditSource::default());
    let mut client = Client::<Summary>::connected_v2();
    let (mut stream, task) = source_pair(source, &["list"]);
    hello(&mut client, &mut stream).await;
    client.subscribe(Sub::new("s", "list")).unwrap();
    send_bytes(&mut stream, client.take_send().unwrap()).await;
    let mut data_bytes = 0_u64;
    let mut credits = 0_u8;
    for _ in 0..64 {
        let frame = read_frame(&mut stream).await;
        let encoded = frame.encode();
        data_bytes = data_bytes.saturating_add(encoded.len() as u64);
        assert_eq!(client.received(&encoded), encoded.len());
        assert!(matches!(client.next_change(), Some(Change::Summary { .. })));
        while let Some(request) = client.take_send() {
            let request_frame = Frame::from_encoded(&request).unwrap();
            let value: Value = request_frame.decode_json().unwrap();
            if value.get("method") == Some(&Value::String("credit".into())) {
                credits = credits.saturating_add(1);
            }
            send_bytes(&mut stream, request).await;
        }
        if credits >= 2 && data_bytes > wire::CREDIT_WINDOW_BYTES {
            break;
        }
    }
    assert!(data_bytes > wire::CREDIT_WINDOW_BYTES);
    assert!(credits >= 2, "slow taker should be fed past one credit window");
    drop(stream);
    match task.await.unwrap() {
        Ok(()) | Err(ConnError::Io(_)) => {}
        Err(error) => panic!("unexpected connection error: {error}"),
    }
}

#[tokio::test]
async fn folder_move_is_one_live_delta_and_reconnect_starts_with_a_fresh_window() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let mut row = Summary::new("chat");
    row.folder = Some("/old".into());
    writer.apply(row.clone()).unwrap();
    let hub = Arc::new(hub);
    let mut client = Client::<Summary>::connected_v2();
    let (mut stream, task) = pair(hub.clone());
    hello(&mut client, &mut stream).await;
    let mut sub = Sub::new("folders", "list");
    sub.view = Some(wire::ListView::Folders);
    client.subscribe(sub).unwrap();
    send_bytes(&mut stream, client.take_send().unwrap()).await;
    client.received(&read_frame(&mut stream).await.encode());
    let Some(Change::FolderWindow(window)) = client.next_change() else { panic!("folder window") };
    let move_seq = window.cursor.saturating_add(1);
    let mut held: std::collections::BTreeMap<_, _> =
        window.rows.into_iter().map(|row| (row.key(), row)).collect();

    // A live move emits both projections in one frame and shares the writer's
    // sequence number. It is not a replay history for a later reconnect.
    row.folder = Some("/new".into());
    row.last_activity = 2;
    writer.apply(row.clone()).unwrap();
    let frame = read_frame(&mut stream).await;
    assert_eq!(frame.kind, FrameKind::Delta);
    let value: Value = frame.decode_json().unwrap();
    let ops = value.get("ops").and_then(Value::as_array).unwrap();
    assert_eq!(ops.len(), 2);
    assert!(ops.iter().all(|op| op.get("seq").and_then(Value::as_u64) == Some(move_seq)));
    client.received(&frame.encode());
    while let Some(change) = client.next_change() {
        match change {
            Change::Folder { row, .. } => {
                held.insert(row.key(), row);
            }
            Change::FolderGone { origin, folder, .. } => {
                held.remove(&acpmux_book::index::folders::FolderKey::new(origin, folder));
            }
            other => panic!("unexpected live folder change: {other:?}"),
        }
    }
    assert_eq!(client.skip_counters().unknown_op, 0);
    let live_projection: std::collections::BTreeMap<_, _> =
        hub.snapshot().folders().iter().map(|row| (row.key(), row.as_ref().clone())).collect();
    assert_eq!(held, live_projection);

    drop(stream);
    task.await.unwrap().unwrap();

    // Reconnect requests a replacement head with no resume cursor or edition.
    client.disconnected();
    let (mut stream, task) = pair(hub.clone());
    hello(&mut client, &mut stream).await;
    let request = client.take_send().unwrap();
    let request_value: Value = Frame::from_encoded(&request).unwrap().decode_json().unwrap();
    assert!(request_value.pointer("/params/cursor").is_none());
    assert!(request_value.pointer("/params/edition").is_none());
    send_bytes(&mut stream, request).await;
    let frame = read_frame(&mut stream).await;
    assert_eq!(frame.kind, FrameKind::Window);
    client.received(&frame.encode());
    let Some(Change::FolderWindow(window)) = client.next_change() else {
        panic!("fresh folder window")
    };
    let rebuilt: std::collections::BTreeMap<_, _> =
        window.rows.into_iter().map(|row| (row.key(), row)).collect();
    let expected: std::collections::BTreeMap<_, _> =
        hub.snapshot().folders().iter().map(|row| (row.key(), row.as_ref().clone())).collect();
    assert_eq!(rebuilt, expected);
    assert_eq!(client.skip_counters().unknown_op, 0);
    drop(stream);
    task.await.unwrap().unwrap();
}

fn apply_mirror_changes(
    client: &mut Client<Summary>,
    rows: &mut HashMap<(String, String), Summary>,
) {
    while let Some(change) = client.next_change() {
        match change {
            Change::Window(window) => {
                rows.clear();
                rows.extend(
                    window
                        .rows
                        .into_iter()
                        .map(|row| ((row.origin.clone(), row.chat_id.clone()), row)),
                );
            }
            Change::Page(page) => {
                rows.extend(
                    page.rows
                        .into_iter()
                        .map(|row| ((row.origin.clone(), row.chat_id.clone()), row)),
                );
            }
            Change::Summary { summary, .. } => {
                rows.insert((summary.origin.clone(), summary.chat_id.clone()), summary);
            }
            Change::Left { summary, .. } => {
                rows.remove(&(summary.origin.clone(), summary.chat_id.clone()));
            }
            Change::Gone { origin, chat_id, .. } => {
                rows.remove(&(origin, chat_id));
            }
            _ => {}
        }
    }
}

fn feed_cut_bytes(
    client: &mut Client<Summary>,
    bytes: &[u8],
    rows: &mut HashMap<(String, String), Summary>,
    random: &mut u64,
) {
    let mut offset = 0;
    while offset < bytes.len() {
        *random ^= *random << 13;
        *random ^= *random >> 7;
        *random ^= *random << 17;
        let width = ((*random as usize) % 11).saturating_add(1);
        let end = (offset + width).min(bytes.len());
        let mut consumed = client.received(&bytes[offset..end]);
        apply_mirror_changes(client, rows);
        if consumed == 0 {
            apply_mirror_changes(client, rows);
            continue;
        }
        consumed = consumed.min(end - offset);
        offset += consumed;
    }
    apply_mirror_changes(client, rows);
}

#[test]
fn randomized_mirror_runs_against_hub_with_cut_frames() {
    for seed in 1..=128_u64 {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        for index in 0..12 {
            let mut row = Summary::new(format!("chat-{index}"));
            row.state = "idle".into();
            row.last_activity = index;
            writer.apply(row).unwrap();
        }
        let mut client = Client::<Summary>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &wire::HelloReply { daemon_id: "d".into(), limits: wire::Limits::default() },
        )
        .unwrap()
        .encode();
        let mut rows = HashMap::new();
        let mut random = seed;
        feed_cut_bytes(&mut client, &hello, &mut rows, &mut random);
        let mut sub = Sub::new("m", "list");
        sub.view = Some(wire::ListView::Live);
        client.subscribe_mirror(sub.clone(), std::iter::empty(), false).unwrap();
        while client.take_send().is_some() {}

        let window = hub.list_window(&sub).unwrap().encode();
        feed_cut_bytes(&mut client, &window, &mut rows, &mut random);
        while let Some(outbound) = client.take_send() {
            let frame = Frame::from_encoded(&outbound).unwrap();
            let request: wire::Request = frame.decode_json().unwrap();
            if let wire::Request::Page(page) = request {
                let reply = hub.page(&page).unwrap().encode();
                feed_cut_bytes(&mut client, &reply, &mut rows, &mut random);
            }
        }

        for step in 0..64_u64 {
            let index = (random % 20) as usize;
            let mut row = Summary::new(format!("chat-{index}"));
            row.state = if step % 7 == 0 { "closed" } else { "idle" }.into();
            row.last_activity = 100 + step;
            let event = writer.apply(row.clone()).unwrap();
            let delta = Frame::json(
                FrameKind::Delta,
                &serde_json::json!({
                    "sid":"m",
                    "ops":[{"op":"summary","seq":event.seq,"summary":row}]
                }),
            )
            .unwrap()
            .encode();
            feed_cut_bytes(&mut client, &delta, &mut rows, &mut random);
            while client.take_send().is_some() {}
            let actual: HashMap<_, _> = rows
                .iter()
                .map(|(key, summary)| (key.clone(), serde_json::to_value(summary).unwrap()))
                .collect();
            let expected: HashMap<_, _> = hub
                .snapshot()
                .iter()
                .filter(|summary| summary.is_live())
                .map(|summary| {
                    (
                        (summary.origin.clone(), summary.chat_id.clone()),
                        serde_json::to_value(summary.as_ref()).unwrap(),
                    )
                })
                .collect();
            if actual != expected {
                let missing = expected
                    .keys()
                    .filter(|key| !actual.contains_key(*key))
                    .cloned()
                    .collect::<Vec<_>>();
                let extra = actual
                    .keys()
                    .filter(|key| !expected.contains_key(*key))
                    .cloned()
                    .collect::<Vec<_>>();
                panic!(
                    "seed {seed} step {step} row={} state={} missing={missing:?} extra={extra:?}",
                    row.chat_id, row.state
                );
            }
        }
        hub.close();
    }
}
