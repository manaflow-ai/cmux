use super::*;
use serde_json::json;

fn frame(bytes: usize) -> Frame {
    Frame::new(FrameKind::Delta, vec![0; bytes]).unwrap()
}

#[test]
fn queue_is_bounded_and_drops_only_the_overflowing_subscription() {
    let mut state = ConnectionState::new(128);
    state.subscribe("slow", Cursor(7)).unwrap();
    state.subscribe("fast", Cursor(2)).unwrap();
    assert_eq!(state.offer("slow", frame(90), Cursor(8)), Offer::Taken);
    assert!(matches!(state.offer("slow", frame(40), Cursor(9)), Offer::Dropped { .. }));
    assert_eq!(state.subscription_count(), 1);
    assert_eq!(state.offer("fast", frame(16), Cursor(3)), Offer::Taken);
    state.subscribe("slow", Cursor(9)).unwrap();
}

#[test]
fn credit_is_monotonic_and_duplicate_credit_is_free() {
    let mut state = ConnectionState::default();
    state.subscribe("s", Cursor(0)).unwrap();
    assert_eq!(state.offer("s", frame(20), Cursor(1)), Offer::Taken);
    assert!(state.credit(Credit { sid: "s".into(), consumed: 10 }).unwrap().is_none());
    assert!(state.credit(Credit { sid: "s".into(), consumed: 5 }).unwrap().is_none());
}

#[test]
fn request_shape_is_tagged() {
    let request = Request::Credit(Credit { sid: "s".into(), consumed: 4 });
    let value = serde_json::to_value(request).unwrap();
    assert_eq!(value, json!({"method":"credit","params":{"sid":"s","consumed":4}}));
}

#[tokio::test]
async fn interrupted_write_preserves_frame_bytes_and_completed_cursor() {
    let (mut writer, mut reader) = tokio::io::duplex(7);
    let mut state = ConnectionState::default();
    state.subscribe("s", Cursor(3)).unwrap();
    let frame = Frame::json(FrameKind::Delta, &json!({"sid":"s","text":"abcdef"})).unwrap();
    let expected = frame.encode();
    assert_eq!(state.offer("s", frame, Cursor(4)), Offer::Taken);
    let mut writing = WritingFrame::new(state.take().unwrap());
    let mut received = Vec::new();
    loop {
        let complete = write_lease(&mut writer, Some(&mut writing)).await.unwrap();
        assert_eq!(state.subscriptions.get("s").unwrap().cursor, Cursor(3));
        if !complete {
            // The duplex buffer is full. An unrelated ready arm cancels the
            // pending write, exactly as a credit request does in run().
            tokio::select! {
                biased;
                _ = write_lease(&mut writer, Some(&mut writing)) => panic!("buffer was full"),
                _ = std::future::ready(()) => {}
            }
        }
        let mut chunk = [0_u8; 7];
        let count = reader.read(&mut chunk).await.unwrap();
        received.extend_from_slice(chunk.get(..count).unwrap());
        if complete {
            state.written(&writing.lease);
            break;
        }
    }
    assert_eq!(received, expected);
    assert_eq!(state.subscriptions.get("s").unwrap().cursor, Cursor(4));
}

use crate::hub::Hub;
use crate::wire::{CREDIT_WINDOW_BYTES, Credit, DeltaFrame, MAX_FRAME_BYTES, ReplayMark, Window};
use acpmux_book::index::{Summary, SummaryIndex};
use std::time::Duration;
use tokio::io::{AsyncWriteExt, DuplexStream};

async fn receive(reader: &mut (impl AsyncRead + Unpin)) -> Frame {
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut header = [0; 4];
        reader.read_exact(&mut header).await.unwrap();
        let mut bytes = vec![0; u32::from_be_bytes(header) as usize];
        reader.read_exact(&mut bytes).await.unwrap();
        let mut encoded = header.to_vec();
        encoded.extend(bytes);
        Frame::from_encoded(&encoded).unwrap()
    })
    .await
    .unwrap()
}
async fn send(writer: &mut (impl AsyncWrite + Unpin), request: serde_json::Value) {
    writer.write_all(&Frame::json(FrameKind::Request, &request).unwrap().encode()).await.unwrap();
}
type ListPair = (
    DuplexStream,
    tokio::task::JoinHandle<Result<(), ConnError>>,
    Arc<Hub>,
    crate::hub::HubWriter,
    Arc<HubSource>,
);
fn list_pair() -> ListPair {
    let (hub, writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    let source = Arc::new(HubSource::new(hub.clone()));
    let (client, server) = tokio::io::duplex(4096);
    let (rd, wr) = tokio::io::split(server);
    let serving = source.clone();
    let task = tokio::spawn(async move { run(rd, wr, serving, "test", &["list".into()]).await });
    (client, task, hub, writer, source)
}
async fn hello(client: &mut DuplexStream) {
    send(client, json!({"method":"hello","params":{"clientKind":"test","protocol":2}})).await;
    assert_eq!(receive(client).await.kind, FrameKind::Hello);
}
async fn subscribe(client: &mut DuplexStream, sid: &str) -> Frame {
    send(client, json!({"method":"sub","params":{"sid":sid,"stream":"list"}})).await;
    receive(client).await
}
fn summary(at: u64) -> Summary {
    let mut row = Summary::new("chat");
    row.last_activity = at;
    row
}

#[tokio::test]
async fn a_live_offer_wakes_the_connection_and_first_window_precedes_it() {
    let (mut client, task, _hub, mut writer, _source) = list_pair();
    hello(&mut client).await;
    assert_eq!(subscribe(&mut client, "s").await.kind, FrameKind::Window);
    writer.apply(summary(1)).unwrap();
    let frame = receive(&mut client).await;
    assert_eq!(frame.kind, FrameKind::Delta);
    let delta: DeltaFrame<Summary> = frame.decode_json().unwrap();
    assert_eq!(delta.replay, None);
    assert_eq!(delta.ops.len(), 1);
    drop(client);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn origin_transitions_cross_the_connection_and_resume_at_the_advanced_cursor() {
    use crate::wire::DeltaOp;
    use acpmux_book::index::OriginState;

    let (mut client, task, hub, mut writer, _source) = list_pair();
    hello(&mut client).await;
    let first = subscribe(&mut client, "origins").await;
    assert_eq!(first.kind, FrameKind::Window);
    let window: Window<Summary> = first.decode_json().unwrap();
    let mut cursor = window.cursor;
    for (state, since) in
        [(OriginState::Down, 10), (OriginState::Stale, 20), (OriginState::Connected, 30)]
    {
        writer.origin("peer", state, since).unwrap();
        let frame = receive(&mut client).await;
        assert_eq!(frame.kind, FrameKind::Delta);
        let delta: DeltaFrame<Summary> = frame.decode_json().unwrap();
        assert_eq!(delta.sid, "origins");
        assert_eq!(delta.replay, None);
        assert_eq!(delta.ops.len(), 1);
        let DeltaOp::Origin { seq, origin } = delta.ops.into_iter().next().unwrap() else {
            panic!("origin transition was not an origin operation");
        };
        assert_eq!(seq, cursor + 1);
        assert_eq!(origin.id, "peer");
        assert_eq!(origin.state, state);
        assert_eq!(origin.since, since);
        cursor = seq;
    }
    assert_eq!(cursor, hub.snapshot().seq());
    assert_eq!(cursor, window.cursor + 3);

    // Resubscribe at the cursor learned from the three decoded operations.
    // A caught-up replay is empty; the following row must still arrive live.
    send(&mut client, json!({"method":"unsub","params":{"sid":"origins"}})).await;
    send(
        &mut client,
        json!({"method":"sub","params":{
            "sid":"origins","stream":"list","cursor":cursor,"edition":window.edition
        }}),
    )
    .await;
    let caught_up = receive(&mut client).await;
    assert_eq!(caught_up.kind, FrameKind::Delta);
    let caught_up: DeltaFrame<Summary> = caught_up.decode_json().unwrap();
    assert_eq!(caught_up.sid, "origins");
    assert_eq!(caught_up.replay, Some(ReplayMark::End));
    assert!(caught_up.ops.is_empty());
    writer.apply(summary(40)).unwrap();
    let frame = receive(&mut client).await;
    assert_eq!(frame.kind, FrameKind::Delta);
    let delta: DeltaFrame<Summary> = frame.decode_json().unwrap();
    assert_eq!(delta.sid, "origins");
    assert_eq!(delta.replay, None);
    assert_eq!(delta.ops.len(), 1);
    assert!(matches!(
        delta.ops.into_iter().next().unwrap(),
        DeltaOp::Summary { seq, .. } if seq == cursor + 1
    ));
    drop(client);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn errors_name_the_request_and_every_pre_hello_request_is_refused() {
    let (mut client, task, _hub, _writer, _source) = list_pair();
    for method in ["credit", "unsub", "page", "sub"] {
        send(
            &mut client,
            json!({"method":method,"params":{"sid":"s","stream":"list","consumed":1}}),
        )
        .await;
        let error = receive(&mut client).await;
        assert_eq!(error.kind, FrameKind::Error);
        let value: serde_json::Value = error.decode_json().unwrap();
        assert_eq!(value.get("method"), Some(&json!(method)));
        assert_eq!(value.get("sid"), Some(&json!("s")));
        assert!(value.get("code").is_some());
    }
    send(&mut client, json!({"method":"hello","params":{"clientKind":"test","protocol":2}})).await;
    assert_eq!(receive(&mut client).await.kind, FrameKind::Hello);
    assert_eq!(subscribe(&mut client, "s").await.kind, FrameKind::Window);
    assert_eq!(subscribe(&mut client, "s").await.kind, FrameKind::Error);
    send(&mut client, json!({"method":"credit","params":{"sid":"absent","consumed":1}})).await;
    assert_eq!(receive(&mut client).await.kind, FrameKind::Error);
    assert_eq!(subscribe(&mut client, "other").await.kind, FrameKind::Window);
    drop(client);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn unknown_kind_does_not_discard_adjacent_requests_and_oversize_closes() {
    let (mut client, task, hub, _writer, source) = list_pair();
    hello(&mut client).await;
    let sub = Frame::json(
        FrameKind::Request,
        &json!({"method":"sub","params":{"sid":"s","stream":"list"}}),
    )
    .unwrap();
    let mut bytes = sub.encode();
    bytes.extend(Frame::new(FrameKind::Unknown(200), b"{}".to_vec()).unwrap().encode());
    bytes.extend(
        Frame::json(
            FrameKind::Request,
            &json!({"method":"sub","params":{"sid":"t","stream":"list"}}),
        )
        .unwrap()
        .encode(),
    );
    client.write_all(&bytes).await.unwrap();
    assert_eq!(receive(&mut client).await.kind, FrameKind::Window);
    assert_eq!(receive(&mut client).await.kind, FrameKind::Error);
    assert_eq!(receive(&mut client).await.kind, FrameKind::Window);
    client.write_all(&(MAX_FRAME_BYTES as u32).to_be_bytes()).await.unwrap();
    assert!(tokio::time::timeout(Duration::from_secs(10), task).await.unwrap().unwrap().is_err());
    tokio::task::yield_now().await;
    assert_eq!(source.task_count(), 0);
    assert_eq!(hub.subscriber_count(), 0);
}

#[tokio::test]
async fn quiet_unsubscribe_releases_tasks_and_subscribers() {
    let (mut client, task, hub, _writer, source) = list_pair();
    hello(&mut client).await;
    for _ in 0..100 {
        assert_eq!(subscribe(&mut client, "s").await.kind, FrameKind::Window);
        send(&mut client, json!({"method":"unsub","params":{"sid":"s"}})).await;
        // A subsequent failing credit acknowledges that unsub has been processed.
        send(&mut client, json!({"method":"credit","params":{"sid":"s","consumed":1}})).await;
        assert_eq!(receive(&mut client).await.kind, FrameKind::Error);
        tokio::task::yield_now().await;
        assert_eq!(source.task_count(), 0);
        assert_eq!(hub.subscriber_count(), 0);
    }
    drop(client);
    task.await.unwrap().unwrap();
}

#[test]
fn inflight_bytes_stay_counted_and_notice_uses_completed_cursor() {
    let mut state = ConnectionState::new(128);
    state.subscribe("s", Cursor(7)).unwrap();
    let control = state.control("s").unwrap();
    assert_eq!(state.offer("s", frame(90), Cursor(8)), Offer::Taken);
    let writing = state.take().unwrap();
    assert_eq!(state.queued_bytes(), 95);
    assert!(matches!(state.offer("s", frame(40), Cursor(9)), Offer::Dropped { .. }));
    state.subscribe("s", Cursor(10)).unwrap();
    assert_eq!(state.offer_from("s", &control, frame(5), Cursor(11)), Offer::UnknownSubscription);
    state.written(&writing);
    assert_eq!(state.subscriptions.get("s").unwrap().cursor, Cursor(10));
    assert_eq!(state.queued_bytes(), 0);
    let notice = state.take().unwrap();
    let dropped: crate::wire::Dropped =
        Frame::from_encoded(&notice.bytes).unwrap().decode_json().unwrap();
    assert_eq!(dropped.cursor, Some(Cursor(8)));
    state.written(&notice);
}

#[test]
fn credit_resumes_from_last_taken_not_last_written_and_does_not_repeat() {
    let mut state = ConnectionState::default();
    state.subscribe("s", Cursor(0)).unwrap();
    assert_eq!(state.offer("s", frame(CREDIT_WINDOW_BYTES as usize - 10), Cursor(1)), Offer::Taken);
    // A fed subscription may take the frame that crosses the window.
    assert_eq!(state.offer("s", frame(10), Cursor(2)), Offer::Taken);
    assert_eq!(state.offer("s", frame(10), Cursor(3)), Offer::NotFed);
    assert_eq!(state.credit(Credit { sid: "s".into(), consumed: 100 }).unwrap(), Some(Cursor(2)));
    assert_eq!(state.credit(Credit { sid: "s".into(), consumed: 100 }).unwrap(), None);
}

#[tokio::test]
async fn missed_history_returns_window_and_caught_up_resume_has_empty_end() {
    let (mut client, task, _hub, mut writer, _source) = list_pair();
    for at in 0..17000 {
        writer.apply(summary(at)).unwrap();
    }
    hello(&mut client).await;
    send(
        &mut client,
        json!({"method":"sub","params":{"sid":"s","stream":"list","cursor":0,"edition":0}}),
    )
    .await;
    let frame = receive(&mut client).await;
    assert_eq!(frame.kind, FrameKind::Window);
    let window: Window<Summary> = frame.decode_json().unwrap();
    assert_eq!(window.cursor, 17000);
    send(
        &mut client,
        json!({"method":"sub","params":{"sid":"t","stream":"list","cursor":17000,"edition":0}}),
    )
    .await;
    let frame = receive(&mut client).await;
    let delta: DeltaFrame<Summary> = frame.decode_json().unwrap();
    assert_eq!(delta.replay, Some(ReplayMark::End));
    assert!(delta.ops.is_empty());
    writer.apply(summary(17001)).unwrap();
    for _ in 0..2 {
        let delta: DeltaFrame<Summary> = receive(&mut client).await.decode_json().unwrap();
        assert_eq!(delta.replay, None);
        assert_eq!(delta.ops.len(), 1);
    }
    drop(client);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn every_request_checks_the_shared_utf8_identifier_bound() {
    let (mut client, task, _hub, _writer, _source) = list_pair();
    hello(&mut client).await;
    let long = "é".repeat(129); // 258 bytes, only 129 characters.
    for method in ["sub", "page", "credit", "unsub", "blob", "act"] {
        for key in ["sid", "id"] {
            let mut params = json!({"sid":"s","stream":"list","consumed":1});
            params.as_object_mut().unwrap().insert(key.into(), json!(long));
            send(&mut client, json!({"method":method,"params":params})).await;
            let error: serde_json::Value = receive(&mut client).await.decode_json().unwrap();
            assert_eq!(error.get("method"), Some(&json!(method)));
            assert_eq!(error.get("code"), Some(&json!("identifier_too_long")));
            assert!(error.get("sid").is_none());
            assert!(error.get("id").is_none());
        }
    }
    assert_eq!(subscribe(&mut client, &"é".repeat(128)).await.kind, FrameKind::Window);
    drop(client);
    task.await.unwrap().unwrap();
}

#[test]
fn reused_sid_notices_remain_ordered_and_reserve_bounded_slots() {
    let mut state = ConnectionState::new(128);
    state.subscribe("a", Cursor(1)).unwrap();
    assert_eq!(state.offer("a", frame(90), Cursor(2)), Offer::Taken);
    assert!(matches!(state.offer("a", frame(40), Cursor(3)), Offer::Dropped { .. }));
    state.subscribe("a", Cursor(10)).unwrap();
    assert_eq!(state.offer("a", frame(90), Cursor(11)), Offer::Taken);
    assert!(matches!(state.offer("a", frame(40), Cursor(12)), Offer::Dropped { .. }));
    for cursor in [Cursor(1), Cursor(10)] {
        let notice = state.take().unwrap();
        let frame = Frame::from_encoded(&notice.bytes).unwrap();
        assert_eq!(frame.kind, FrameKind::Dropped);
        assert_eq!(frame.decode_json::<crate::wire::Dropped>().unwrap().cursor, Some(cursor));
        state.written(&notice);
    }
    assert!(state.take().is_none());
    for i in 0..MAX_SUBSCRIPTIONS {
        state.subscribe("a", Cursor(i as u64)).unwrap();
        assert!(matches!(state.offer("a", frame(129), Cursor(500)), Offer::Dropped { .. }));
    }
    assert!(matches!(state.subscribe("a", Cursor(500)), Err(ConnError::TooManySubscriptions)));
    let mut count = 0;
    while let Some(notice) = state.take() {
        state.written(&notice);
        count += 1;
    }
    assert_eq!(count, MAX_SUBSCRIPTIONS);
    state.subscribe("a", Cursor(500)).unwrap();
}

#[tokio::test]
async fn dropped_anchor_has_no_cursor_and_unstarted_inflight_frame_is_freed() {
    let mut state = ConnectionState::new(128);
    state.subscribe_at("a", None).unwrap();
    assert_eq!(state.offer("a", frame(90), Cursor(2)), Offer::Taken);
    let mut writing = WritingFrame::new(state.take().unwrap());
    assert!(matches!(state.offer("a", frame(40), Cursor(3)), Offer::Dropped { .. }));
    let (mut writer, mut reader) = tokio::io::duplex(128);
    assert!(write_lease(&mut writer, Some(&mut writing)).await.unwrap());
    assert!(writing.cancelled);
    state.abandon(&writing.lease);
    let notice = state.take().unwrap();
    let frame = Frame::from_encoded(&notice.bytes).unwrap();
    assert_eq!(frame.kind, FrameKind::Dropped);
    assert_eq!(frame.decode_json::<crate::wire::Dropped>().unwrap().cursor, None);
    drop(writer);
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes).await.unwrap();
    assert!(bytes.is_empty());
}

#[tokio::test]
async fn source_resume_sent_before_wait_is_not_lost() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    let source = HubSource::new(hub);
    let state = Arc::new(std::sync::Mutex::new(ConnectionState::default()));
    state.lock().unwrap().subscribe("s", Cursor(0)).unwrap();
    let control = state.lock().unwrap().control("s").unwrap();
    let sink = Arc::new(ConnectionSink { state: state.clone(), control });
    source.subscribe(&Sub::new("s", "list"), None, sink).unwrap();
    // No task has been polled. A resume already sent must be retained.
    writer.apply(summary(1)).unwrap();
    source.resume("s", Cursor(0));
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let next = state.lock().unwrap().take();
            if let Some(lease) = next {
                let frame = Frame::from_encoded(&lease.bytes).unwrap();
                state.lock().unwrap().written(&lease);
                if frame.kind == FrameKind::Delta {
                    let delta: DeltaFrame<Summary> = frame.decode_json().unwrap();
                    assert_eq!(delta.replay, Some(ReplayMark::End));
                    assert_eq!(delta.ops.len(), 1);
                    break;
                }
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    source.end("s");
}

#[tokio::test]
async fn reused_sid_finishes_only_the_started_frame_before_its_notice() {
    let mut state = ConnectionState::new(128);
    state.subscribe("a", Cursor(1)).unwrap();
    assert!(matches!(state.offer("a", frame(129), Cursor(2)), Offer::Dropped { .. }));
    state.subscribe("a", Cursor(10)).unwrap();
    let first = frame(90);
    let expected = first.encode();
    assert_eq!(state.offer("a", first, Cursor(11)), Offer::Taken);
    let (mut writer, mut reader) = tokio::io::duplex(7);
    let old = state.take().unwrap();
    assert_eq!(
        Frame::from_encoded(&old.bytes)
            .unwrap()
            .decode_json::<crate::wire::Dropped>()
            .unwrap()
            .cursor,
        Some(Cursor(1))
    );
    state.written(&old);
    let mut writing = WritingFrame::new(state.take().unwrap());
    assert!(!write_lease(&mut writer, Some(&mut writing)).await.unwrap());
    assert!(matches!(state.offer("a", frame(40), Cursor(12)), Offer::Dropped { .. }));
    let mut bytes = vec![0; 7];
    reader.read_exact(&mut bytes).await.unwrap();
    loop {
        let complete = write_lease(&mut writer, Some(&mut writing)).await.unwrap();
        let mut chunk = [0; 7];
        let count = reader.read(&mut chunk).await.unwrap();
        bytes.extend_from_slice(chunk.get(..count).unwrap());
        if complete {
            break;
        }
    }
    assert!(!writing.cancelled);
    assert_eq!(bytes, expected);
    state.written(&writing.lease);
    let notice = state.take().unwrap();
    assert_eq!(
        Frame::from_encoded(&notice.bytes)
            .unwrap()
            .decode_json::<crate::wire::Dropped>()
            .unwrap()
            .cursor,
        Some(Cursor(11))
    );
    state.written(&notice);
    assert!(state.take().is_none());
    assert_eq!(state.metrics.notices(), 0);
    assert_eq!(state.metrics.outside_budget_bytes(), 0);
}

struct PageSource;
impl Source for PageSource {
    fn subscribe(
        &self,
        _sub: &Sub,
        _person: Option<&[u8]>,
        _sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        Ok(())
    }
    fn resume(&self, _sid: &str, _cursor: Cursor) {}
    fn end(&self, _sid: &str) {}
    fn page(&self, page: &Page, _person: Option<&[u8]>) -> Result<Frame, ConnError> {
        Ok(Frame::json(FrameKind::Page, &json!({"sid":page.sid,"data":"x".repeat(250_000)}))?)
    }
}

#[tokio::test]
async fn sixty_pipelined_page_replies_are_all_written_in_order() {
    let (mut client, server) = tokio::io::duplex(1024);
    let (rd, wr) = tokio::io::split(server);
    let connection =
        tokio::spawn(
            async move { run(rd, wr, Arc::new(PageSource), "test", &["list".into()]).await },
        );
    hello(&mut client).await;
    let (mut rd, mut wr) = tokio::io::split(client);
    let requests = async {
        for n in 0..60 {
            send(&mut wr, json!({"method":"page","params":{"sid":n.to_string(),"stream":"list"}}))
                .await;
        }
    };
    let replies = async {
        for n in 0..60 {
            let frame = receive(&mut rd).await;
            assert_eq!(frame.kind, FrameKind::Page);
            assert_eq!(
                frame.decode_json::<serde_json::Value>().unwrap().get("sid"),
                Some(&json!(n.to_string()))
            );
        }
    };
    tokio::time::timeout(Duration::from_secs(30), async {
        tokio::join!(requests, replies);
    })
    .await
    .unwrap();
    drop(rd);
    drop(wr);
    connection.await.unwrap().unwrap();
}

#[tokio::test]
async fn source_window_is_exact_when_a_summary_changes_after_first_offer() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(summary(1)).unwrap();
    let hub = Arc::new(hub);
    let source = HubSource::new(hub);
    let state = Arc::new(std::sync::Mutex::new(ConnectionState::default()));
    state.lock().unwrap().subscribe_at("s", None).unwrap();
    let control = state.lock().unwrap().control("s").unwrap();
    source
        .subscribe(
            &Sub::new("s", "list"),
            None,
            Arc::new(ConnectionSink { state: state.clone(), control }),
        )
        .unwrap();
    writer.apply(summary(2)).unwrap(); // pump has never been polled
    let first = state.lock().unwrap().take().unwrap();
    let window: Window<Summary> = Frame::from_encoded(&first.bytes).unwrap().decode_json().unwrap();
    assert_eq!(window.cursor, 1);
    state.lock().unwrap().written(&first);
    let next = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if let Some(next) = state.lock().unwrap().take() {
                break next;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let delta: DeltaFrame<Summary> =
        Frame::from_encoded(&next.bytes).unwrap().decode_json().unwrap();
    assert!(matches!(delta.ops.as_slice(), [crate::wire::DeltaOp::Summary { seq: 2, .. }]));
    source.end("s");
    source.close().await;
}

struct ReadThenFail(std::io::Cursor<Vec<u8>>);
impl AsyncRead for ReadThenFail {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        if self.0.position() as usize == self.0.get_ref().len() {
            std::task::Poll::Ready(Err(std::io::Error::from(std::io::ErrorKind::ConnectionReset)))
        } else {
            std::pin::Pin::new(&mut self.0).poll_read(cx, buf)
        }
    }
}
struct WriteThenFail(bool);
impl AsyncWrite for WriteThenFail {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        bytes: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        if self.0 {
            std::task::Poll::Ready(Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe)))
        } else {
            self.0 = true;
            std::task::Poll::Ready(Ok(bytes.len()))
        }
    }
    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}
#[tokio::test]
async fn read_and_write_errors_release_every_source_subscriber() {
    let input: Vec<_> = [
        json!({"method":"hello","params":{"clientKind":"test","protocol":2}}),
        json!({"method":"sub","params":{"sid":"s","stream":"list"}}),
    ]
    .into_iter()
    .flat_map(|r| Frame::json(FrameKind::Request, &r).unwrap().encode())
    .collect();
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    let source = Arc::new(HubSource::new(hub.clone()));
    let result = run(
        ReadThenFail(std::io::Cursor::new(input.clone())),
        tokio::io::sink(),
        source.clone(),
        "test",
        &["list".into()],
    )
    .await;
    assert!(matches!(result, Err(ConnError::Io(_))));
    assert_eq!(source.task_count(), 0);
    assert_eq!(hub.subscriber_count(), 0);
    let source = Arc::new(HubSource::new(hub.clone()));
    // After these requests the reader stays pending, so only the writer can end it.
    let (mut client, server) = tokio::io::duplex(4096);
    client.write_all(&input).await.unwrap();
    let result = run(server, WriteThenFail(false), source.clone(), "test", &["list".into()]).await;
    assert!(matches!(result, Err(ConnError::Io(_))));
    assert_eq!(source.task_count(), 0);
    assert_eq!(hub.subscriber_count(), 0);
}

#[derive(Default)]
struct EditionSource {
    edition: std::sync::atomic::AtomicU32,
    requested: std::sync::atomic::AtomicU32,
    resumed: std::sync::atomic::AtomicU64,
    sink: std::sync::Mutex<Option<Arc<dyn OfferSink>>>,
}
impl EditionSource {
    fn window(&self, sid: &str) -> (Frame, Cursor) {
        let edition = self.edition.load(std::sync::atomic::Ordering::Acquire);
        let cursor = Cursor(u64::from(edition) * 10);
        (
            Frame::json(
                FrameKind::Window,
                &Window::<Summary> {
                    sid: sid.into(),
                    edition,
                    cursor: cursor.0,
                    rows: Vec::new(),
                    has_before: false,
                    has_after: false,
                    origins: Vec::new(),
                    before_key: None,
                    after_key: None,
                },
            )
            .unwrap(),
            cursor,
        )
    }
}
impl Source for EditionSource {
    fn subscribe(
        &self,
        sub: &Sub,
        _person: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        self.requested.store(sub.edition.unwrap_or_default(), std::sync::atomic::Ordering::Release);
        let (frame, cursor) = self.window(&sub.sid);
        assert_eq!(sink.offer(&sub.sid, frame, cursor), Offer::Taken);
        *self.sink.lock().unwrap() = Some(sink);
        Ok(())
    }
    fn resume(&self, sid: &str, cursor: Cursor) {
        self.resumed.store(cursor.0, std::sync::atomic::Ordering::Release);
        let (frame, cursor) = self.window(sid);
        assert_eq!(
            self.sink.lock().unwrap().as_ref().unwrap().offer(sid, frame, cursor),
            Offer::Taken
        );
    }
    fn end(&self, _sid: &str) {
        self.sink.lock().unwrap().take();
    }
}
#[tokio::test]
async fn the_source_decides_editions_and_may_resume_with_a_window() {
    use std::sync::atomic::Ordering;
    let source = Arc::new(EditionSource::default());
    source.edition.store(1, Ordering::Release);
    let (mut client, server) = tokio::io::duplex(4096);
    let (rd, wr) = tokio::io::split(server);
    let driver = source.clone();
    let task = tokio::spawn(async move { run(rd, wr, driver, "test", &["chat".into()]).await });
    hello(&mut client).await;
    send(
        &mut client,
        json!({"method":"sub","params":{"sid":"s","stream":"chat:x","cursor":1,"edition":99}}),
    )
    .await;
    let first = receive(&mut client).await;
    assert_eq!(first.decode_json::<Window<Summary>>().unwrap().edition, 1);
    assert_eq!(source.requested.load(Ordering::Acquire), 99);
    let large = Frame::json(
        FrameKind::Delta,
        &json!({"sid":"s","ops":[],"padding":"x".repeat(MAX_FRAME_BYTES-60)}),
    )
    .unwrap();
    let consumed = (first.encoded_len() + large.encoded_len()) as u64;
    let sink = source.sink.lock().unwrap().clone().unwrap();
    assert_eq!(sink.offer("s", large, Cursor(10)), Offer::Taken);
    assert_eq!(sink.offer("s", frame(100), Cursor(11)), Offer::NotFed);
    source.edition.store(2, Ordering::Release);
    assert_eq!(receive(&mut client).await.kind, FrameKind::Delta);
    send(&mut client, json!({"method":"credit","params":{"sid":"s","consumed":consumed}})).await;
    let window: Window<Summary> = receive(&mut client).await.decode_json().unwrap();
    assert_eq!(window.edition, 2);
    assert_eq!(window.cursor, 20);
    assert_eq!(source.resumed.load(Ordering::Acquire), 10);
    drop(client);
    task.await.unwrap().unwrap();
    assert!(source.sink.lock().unwrap().is_none());
}

#[test]
fn not_ready_keeps_the_subscription_without_establishing_a_cursor() {
    for initial in [None, Some(Cursor(7))] {
        let mut state = ConnectionState::new(1024);
        state.subscribe_at("s", initial).unwrap();
        let not_ready = Frame::json(
            FrameKind::Error,
            &json!({
                "method":"sub", "sid":"s", "code":"not_ready"
            }),
        )
        .unwrap();
        assert_eq!(state.offer("s", not_ready, Cursor(99)), Offer::Taken);
        let lease = state.take().unwrap();
        state.written(&lease);
        assert_eq!(state.subscription_count(), 1);
        assert_eq!(state.subscriptions.get("s").unwrap().taken, initial.unwrap_or_default());
        // Until a window or delta is written, dropped still names the original
        // cursor, or no cursor for an anchor subscription.
        assert!(matches!(state.offer("s", frame(1024), Cursor(100)), Offer::Dropped { .. }));
        let notice = state.take().unwrap();
        let dropped: crate::wire::Dropped =
            Frame::from_encoded(&notice.bytes).unwrap().decode_json().unwrap();
        assert_eq!(dropped.cursor, initial);
    }
}

#[derive(Default)]
struct DeferredSource(std::sync::Mutex<Option<Arc<dyn OfferSink>>>);
impl Source for DeferredSource {
    fn subscribe(
        &self,
        sub: &Sub,
        _person: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        let not_ready = Frame::json(
            FrameKind::Error,
            &json!({
                "method":"sub", "sid":sub.sid, "code":"not_ready"
            }),
        )?;
        assert_eq!(sink.offer(&sub.sid, not_ready, sub.cursor.unwrap_or_default()), Offer::Taken);
        *self.0.lock().unwrap() = Some(sink);
        Ok(())
    }
    fn resume(&self, _: &str, _: Cursor) {}
    fn end(&self, _: &str) {
        self.0.lock().unwrap().take();
    }
}

#[tokio::test]
async fn not_ready_then_window_uses_the_same_subscription_until_unsub() {
    let source = Arc::new(DeferredSource::default());
    let driver = source.clone();
    let (mut client, server) = tokio::io::duplex(4096);
    let (rd, wr) = tokio::io::split(server);
    let task = tokio::spawn(async move { run(rd, wr, driver, "test", &["chat".into()]).await });
    hello(&mut client).await;
    send(&mut client, json!({"method":"sub","params":{"sid":"s","stream":"chat:x"}})).await;
    let reply = receive(&mut client).await;
    assert_eq!(reply.kind, FrameKind::Error);
    assert_eq!(
        reply.decode_json::<serde_json::Value>().unwrap().get("code"),
        Some(&json!("not_ready"))
    );
    let sink = source.0.lock().unwrap().clone().unwrap();
    let (window, cursor) = EditionSource::default().window("s");
    assert_eq!(sink.offer("s", window, cursor), Offer::Taken);
    assert_eq!(receive(&mut client).await.kind, FrameKind::Window);
    send(&mut client, json!({"method":"unsub","params":{"sid":"s"}})).await;
    // A following reply is a barrier proving unsub was handled.
    send(&mut client, json!({"method":"credit","params":{"sid":"s","consumed":0}})).await;
    assert_eq!(receive(&mut client).await.kind, FrameKind::Error);
    assert!(source.0.lock().unwrap().is_none());
    drop(client);
    task.await.unwrap().unwrap();
}

fn fill_to_request_boundary(state: &mut ConnectionState) {
    for i in 0..3 {
        let sid = format!("prefill-{i}");
        state.subscribe(&sid, Cursor(0)).unwrap();
        assert_eq!(state.offer(&sid, frame(MAX_FRAME_BYTES - 5), Cursor(1)), Offer::Taken);
    }
    assert_eq!(state.queued_bytes(), crate::wire::CONNECTION_BUDGET_BYTES - MAX_FRAME_BYTES);
}

#[test]
fn subscription_first_frame_consumes_its_request_reserve() {
    let mut state = ConnectionState::default();
    fill_to_request_boundary(&mut state);
    for i in 0..20 {
        // A reconnect burst waits for one frame's room, then transfers that
        // request's reserve to its own full-sized window without an early drop.
        assert!(state.reserve_reply());
        let sid = format!("reconnect-{i}");
        state.subscribe(&sid, Cursor(0)).unwrap();
        state.begin_subscription_reply(state.control(&sid).unwrap());
        let window = Frame::new(FrameKind::Window, vec![0; MAX_FRAME_BYTES - 5]).unwrap();
        assert_eq!(state.offer(&sid, window, Cursor(1)), Offer::Taken);
        assert_eq!(state.queued_bytes(), crate::wire::CONNECTION_BUDGET_BYTES);
        state.release_reply();
        assert!(!state.reserve_reply());
        let written = state.take().unwrap();
        state.written(&written);
    }
    assert_eq!(state.metrics.notices(), 0);
    assert_eq!(state.subscription_count(), 23);
    while let Some(written) = state.take() {
        state.written(&written);
    }
    assert_eq!(state.queued_bytes(), 0);
}

#[test]
fn other_subscription_still_sees_the_request_reserve() {
    let mut state = ConnectionState::default();
    fill_to_request_boundary(&mut state);
    state.subscribe("s", Cursor(0)).unwrap();
    state.subscribe("other", Cursor(0)).unwrap();
    assert!(state.reserve_reply());
    state.begin_subscription_reply(state.control("s").unwrap());
    assert_eq!(state.offer("s", frame(32), Cursor(1)), Offer::Taken);
    // The own offer consumed 37 reserve bytes. Every other offer must still
    // count the remaining reserve, regardless of its own available credit.
    assert!(matches!(state.offer("other", frame(16), Cursor(2)), Offer::Dropped { .. }));
    state.release_reply();
    state.subscribe("other", Cursor(0)).unwrap();
    assert_eq!(state.offer("other", frame(16), Cursor(2)), Offer::Taken);
}

#[test]
fn subscription_first_frame_past_remaining_budget_drops_with_named_cursor() {
    let mut state = ConnectionState::new(MAX_FRAME_BYTES + 100);
    state.subscribe("s", Cursor(7)).unwrap();
    let control = state.control("s").unwrap();
    assert!(state.reserve_reply());
    state.begin_subscription_reply(control);
    assert_eq!(state.offer("s", frame(MAX_FRAME_BYTES - 8), Cursor(8)), Offer::Taken);
    assert!(matches!(state.offer("s", frame(100), Cursor(9)), Offer::Dropped { .. }));
    assert_eq!(state.subscription_count(), 0);
    assert_eq!(state.queued_bytes(), 0);
    state.release_reply();
    let notice = state.take().unwrap();
    let dropped: crate::wire::Dropped =
        Frame::from_encoded(&notice.bytes).unwrap().decode_json().unwrap();
    assert_eq!(dropped.cursor, Some(Cursor(7)));
    state.written(&notice);
    assert_eq!(state.metrics.notices(), 0);
    state.subscribe("s", Cursor(7)).unwrap();
    assert_eq!(state.offer("s", frame(16), Cursor(8)), Offer::Taken);
}

#[tokio::test]
async fn source_failure_after_first_frame_ends_only_its_generation() {
    let source = Arc::new(DeferredSource::default());
    let driver = source.clone();
    let (mut client, server) = tokio::io::duplex(4096);
    let (rd, wr) = tokio::io::split(server);
    let task = tokio::spawn(async move { run(rd, wr, driver, "test", &["chat".into()]).await });
    hello(&mut client).await;
    let request = json!({"method":"sub","params":{"sid":"s","stream":"chat:x"}});
    send(&mut client, request.clone()).await;
    assert_eq!(receive(&mut client).await.kind, FrameKind::Error); // first: not_ready
    let old_sink = source.0.lock().unwrap().clone().unwrap();
    old_sink.fail("s"); // the source cannot construct its second frame
    let error = receive(&mut client).await;
    assert_eq!(error.kind, FrameKind::Error);
    assert_eq!(
        error.decode_json::<serde_json::Value>().unwrap(),
        json!({
            "method":"sub", "sid":"s", "code":"source_failed"
        })
    );
    assert!(source.0.lock().unwrap().is_none());
    assert_eq!(old_sink.metrics().notices(), 0);
    send(&mut client, request).await;
    assert_eq!(receive(&mut client).await.kind, FrameKind::Error); // new generation
    let new_sink = source.0.lock().unwrap().clone().unwrap();
    old_sink.fail("s"); // stale failure may not end its replacement
    let (window, cursor) = EditionSource::default().window("s");
    assert_eq!(new_sink.offer("s", window, cursor), Offer::Taken);
    assert_eq!(receive(&mut client).await.kind, FrameKind::Window);
    drop(client);
    task.await.unwrap().unwrap();
    assert!(source.0.lock().unwrap().is_none());
}

#[test]
fn source_failure_frees_queued_frames_and_uses_a_bounded_notice_slot() {
    let mut state = ConnectionState::new(128);
    state.subscribe("s", Cursor(7)).unwrap();
    let control = state.control("s").unwrap();
    assert_eq!(state.offer("s", frame(100), Cursor(8)), Offer::Taken);
    state.fail_from("s", &control);
    state.fail_from("s", &control);
    assert_eq!(state.subscription_count(), 0);
    assert_eq!(state.queued_bytes(), 0);
    assert_eq!(state.metrics.notices(), 1);
    assert!(state.metrics.outside_budget_bytes() > 0);
    let notice = state.take().unwrap();
    assert_eq!(Frame::from_encoded(&notice.bytes).unwrap().kind, FrameKind::Error);
    state.written(&notice);
    assert_eq!(state.metrics.notices(), 0);
    assert_eq!(state.metrics.outside_budget_bytes(), 0);
}

#[test]
fn ordinary_reply_consumes_reserve_before_another_thread_offers() {
    let mut state = ConnectionState::default();
    for sid in ["prefill-a", "prefill-b"] {
        state.subscribe(sid, Cursor(0)).unwrap();
        assert_eq!(state.offer(sid, frame(MAX_FRAME_BYTES - 5), Cursor(1)), Offer::Taken);
    }
    state.subscribe("other", Cursor(0)).unwrap();
    assert!(state.reserve_reply());
    state.offer_reply(frame(MAX_FRAME_BYTES - 5)).unwrap();
    // This is the interleaving after process_frame unlocks and before the
    // connection reacquires the lock to release_reply. A source may run on a
    // different thread even though the connection itself has not awaited.
    assert_eq!(state.offer("other", frame(16), Cursor(1)), Offer::Taken);
    assert_eq!(state.metrics.notices(), 0);
    state.release_reply();
}

#[tokio::test]
async fn expired_list_resume_and_live_lag_open_the_head() {
    let (mut client, task, hub, mut writer, source) = list_pair();
    for n in 0..20 {
        let mut row = Summary::new(format!("row-{n}"));
        row.last_activity = n;
        writer.apply(row).unwrap();
    }
    hello(&mut client).await;
    send(
        &mut client,
        json!({"method":"sub","params":{
            "sid":"anchored", "stream":"list", "window":3,
            "anchor":{"key":{"lastActivity":10,"chatId":"row-10","origin":"local"},"side":"after"}
        }}),
    )
    .await;
    let initial: Window<Summary> = receive(&mut client).await.decode_json().unwrap();
    let anchored: Vec<_> = initial.rows.iter().map(|row| row.chat_id.clone()).collect();
    assert_eq!(anchored.len(), 3);
    let mut cursor = initial.cursor;
    for credit_resume in [true, false] {
        // No await lets the source consume this burst. It exceeds retention,
        // forcing a window both via credit/resume and via a live receiver's lag.
        for n in 0..17000 {
            writer.apply(summary(100_000 + n)).unwrap();
        }
        if credit_resume {
            source.resume("anchored", Cursor(cursor));
        }
        let frame = receive(&mut client).await;
        assert_eq!(frame.kind, FrameKind::Window);
        let window: Window<Summary> = frame.decode_json().unwrap();
        let expected: Vec<_> =
            hub.snapshot().page(0, 3).iter().map(|row| row.chat_id.clone()).collect();
        assert_ne!(expected, anchored);
        assert_eq!(window.rows.iter().map(|row| row.chat_id.clone()).collect::<Vec<_>>(), expected);
        assert_eq!(window.cursor, hub.snapshot().seq());
        assert!(window.cursor > cursor);
        cursor = window.cursor;
    }
    drop(client);
    task.await.unwrap().unwrap();
    assert_eq!(source.task_count(), 0);
    assert_eq!(hub.subscriber_count(), 0);
}

#[test]
fn family_cursor_gone_has_a_machine_readable_error_code() {
    let request = Frame::json(FrameKind::Page, &serde_json::json!({"sid":"kin"})).unwrap();
    let frame = error_frame(&request, &ConnError::Hub(HubError::CursorGone)).unwrap();
    let value: serde_json::Value = frame.decode_json().unwrap();
    assert_eq!(value.get("code"), Some(&serde_json::json!("cursor_gone")));
}

#[test]
fn table_filter_on_sub_has_invalid_params_code() {
    let request = Frame::json(FrameKind::Window, &serde_json::json!({"sid":"kin"})).unwrap();
    let frame = error_frame(
        &request,
        &ConnError::Hub(HubError::InvalidParams("table filters are page-only".into())),
    )
    .unwrap();
    let value: serde_json::Value = frame.decode_json().unwrap();
    assert_eq!(value.get("code"), Some(&serde_json::json!("invalid_params")));
}
