use acpmux_book::index::{Summary, SummaryIndex};
use acpmux_client::{Change, Client};
use acpmux_core::conn::{self, ConnError, HubSource, Offer, OfferSink, Source};
use acpmux_core::hub::Hub;
use acpmux_core::wire::{self, Cursor, Frame, FrameKind, Sub, Window};
use serde_json::{Value, json};
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
