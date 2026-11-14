use super::*;
use crate::wire::{ChatDelta, HelloReply, Limits, OpenRow, QueueHead, ReplayMark, blob_frame};
use serde_json::{Value, json};

fn hello(limits: Limits) -> Vec<u8> {
    Frame::json(FrameKind::Hello, &HelloReply { daemon_id: "d".into(), limits }).unwrap().encode()
}

fn ready_with(limits: Limits) -> Client<Value> {
    let mut client = Client::<Value>::connected_v2();
    let hello = hello(limits);
    assert_eq!(client.received(&hello), hello.len());
    while client.take_send().is_some() {}
    client
}

fn ready() -> Client<Value> {
    ready_with(Limits::default())
}

/// The requests the client queued, as JSON.
fn sent(client: &mut Client<Value>) -> Vec<Value> {
    let mut out = Vec::new();
    while let Some(bytes) = client.take_send() {
        out.push(Frame::from_encoded(&bytes).unwrap().decode_json::<Value>().unwrap());
    }
    out
}

fn feed(client: &mut Client<Value>, frame: &Frame) -> Vec<Change<Value>> {
    let bytes = frame.encode();
    assert_eq!(client.received(&bytes), bytes.len());
    std::iter::from_fn(|| client.next_change()).collect()
}

fn chat_changes(changes: Vec<Change<Value>>) -> Vec<ChatChange> {
    changes
        .into_iter()
        .map(|change| match change {
            Change::Chat(change) => change,
            other => panic!("not a chat change: {other:?}"),
        })
        .collect()
}

fn row(id: u64) -> RawJson {
    RawJson::from_bytes(format!(r#"{{"id":{id},"rev":1, "body":{{"text":"r{id}"}}}}"#).as_bytes())
        .unwrap()
}

fn window(sid: &str, cursor: u64, edition: u32, ids: std::ops::Range<u64>) -> Frame {
    Frame::json(
        FrameKind::Window,
        &ChatWindow {
            sid: sid.into(),
            cursor,
            edition,
            rows: ids.map(row).collect(),
            has_before: false,
            has_after: false,
            open: Vec::new(),
            queue: QueueHead::default(),
            seen: None,
            folds: Vec::new(),
            refused: Vec::new(),
        },
    )
    .unwrap()
}

fn delta(sid: &str, replay: Option<ReplayMark>, ops: Vec<ChatOp>) -> Frame {
    Frame::json(FrameKind::Delta, &ChatDelta { sid: sid.into(), replay, ops }).unwrap()
}

fn settled(seq: u64, id: u64) -> ChatOp {
    ChatOp::Row { seq, row: row(id), body_len: None }
}

fn text(seq: u64, row_id: u64) -> ChatOp {
    ChatOp::Text { seq, row_id, text: RawJson::from_bytes(br#""more""#).unwrap() }
}

fn queue_op(seq: u64) -> ChatOp {
    ChatOp::Queue { seq, entry: None, removed: Some("p".into()), count: 0, head: None }
}

fn subscribe(client: &mut Client<Value>, sid: &str) {
    client
        .subscribe_chat(ChatSubRequest {
            sid: sid.into(),
            chat: "c1".into(),
            anchor: None,
            window: None,
        })
        .unwrap();
}

/// A ready client with chat sub `c` past its first window: cursor 10, edition 1.
fn open_chat() -> Client<Value> {
    let mut client = ready();
    subscribe(&mut client, "c");
    sent(&mut client);
    feed(&mut client, &window("c", 10, 1, 1..11));
    client
}

fn cursor(client: &Client<Value>, sid: &str) -> u64 {
    client.chats.get(sid).unwrap().cursor.0
}

/// Disconnects and reconnects, and gives the `sub` sent again.
fn reconnect(client: &mut Client<Value>) -> Value {
    client.disconnected();
    sent(client);
    let hello = hello(Limits::default());
    assert_eq!(client.received(&hello), hello.len());
    let requests = sent(client);
    requests.into_iter().find(|request| request["method"] == "sub").unwrap()
}

#[test]
fn the_first_window_replaces_and_its_rows_stay_as_their_bytes() {
    let mut client = ready();
    subscribe(&mut client, "c");
    let requests = sent(&mut client);
    assert_eq!(
        requests,
        vec![json!({"method":"sub","params":{
            "sid":"c","stream":"chat:c1","anchor":"end","window":100
        }})]
    );
    let stored = br#"{"id":1, "rev":2,"body":{"text":"a\"b\u00e9"}}"#;
    let mut frame = window("c", 10, 1, 0..0);
    let mut value = frame.decode_json::<ChatWindow>().unwrap();
    value.rows = vec![RawJson::from_bytes(stored).unwrap()];
    frame = Frame::json(FrameKind::Window, &value).unwrap();
    let changes = chat_changes(feed(&mut client, &frame));
    let [ChatChange::Window { replaces: true, window }] = changes.as_slice() else {
        panic!("{changes:?}")
    };
    assert_eq!(window.rows.first().unwrap().get().as_bytes(), stored);
    assert_eq!(cursor(&client, "c"), 10);
}

#[test]
fn each_op_is_one_change_and_only_a_record_moves_the_cursor() {
    let mut client = open_chat();
    let changes = chat_changes(feed(&mut client, &delta("c", None, vec![text(10, 11)])));
    assert!(matches!(
        changes.as_slice(),
        [ChatChange::Op { replay: false, op: ChatOp::Text { .. }, .. }]
    ));
    assert_eq!(cursor(&client, "c"), 10);
    // A text or a queue op carrying a later seq still moves nothing.
    feed(&mut client, &delta("c", None, vec![text(12, 11), queue_op(13)]));
    assert_eq!(cursor(&client, "c"), 10);
    let changes = chat_changes(feed(&mut client, &delta("c", None, vec![settled(11, 11)])));
    assert!(matches!(changes.as_slice(), [ChatChange::Op { op: ChatOp::Row { seq: 11, .. }, .. }]));
    assert_eq!(cursor(&client, "c"), 11);
    let patch = ChatOp::Patch { seq: 12, row: row(3) };
    let changes = chat_changes(feed(&mut client, &delta("c", None, vec![patch])));
    assert_eq!(changes.len(), 1);
    assert_eq!(cursor(&client, "c"), 12);
}

#[test]
fn a_resume_goes_from_the_cursor_to_its_end() {
    let mut client = open_chat();
    let sub = reconnect(&mut client);
    assert_eq!(sub["params"]["cursor"], 10);
    assert_eq!(sub["params"]["edition"], 1);
    assert!(sub["params"].get("anchor").is_none());
    let changes = chat_changes(feed(
        &mut client,
        &delta("c", Some(ReplayMark::Replay), vec![settled(11, 11), settled(12, 12)]),
    ));
    assert!(changes.iter().all(|change| matches!(change, ChatChange::Op { replay: true, .. })));
    let open = ChatOp::Row { seq: 12, row: row(13), body_len: Some(1 << 20) };
    let changes = chat_changes(feed(&mut client, &delta("c", Some(ReplayMark::End), vec![open])));
    assert!(matches!(
        changes.as_slice(),
        [
            ChatChange::Op { replay: true, op: ChatOp::Row { body_len: Some(_), .. }, .. },
            ChatChange::ResumeEnd { cursor: 12, .. }
        ]
    ));
    // Live again: an op without the mark.
    let changes = chat_changes(feed(&mut client, &delta("c", None, vec![text(12, 13)])));
    assert!(matches!(changes.as_slice(), [ChatChange::Op { replay: false, .. }]));
}

#[test]
fn a_window_in_place_of_a_resume_adds_in_its_edition_and_replaces_in_another() {
    let mut client = open_chat();
    reconnect(&mut client);
    feed(&mut client, &delta("c", Some(ReplayMark::Replay), vec![settled(11, 11)]));
    let changes = chat_changes(feed(&mut client, &window("c", 500, 1, 400..500)));
    assert!(matches!(
        changes.as_slice(),
        [ChatChange::ResumeEnd { cursor: 11, .. }, ChatChange::Window { replaces: false, .. }]
    ));
    assert_eq!(cursor(&client, "c"), 500);

    reconnect(&mut client);
    let changes = chat_changes(feed(&mut client, &window("c", 20, 2, 0..20)));
    assert!(matches!(
        changes.as_slice(),
        [ChatChange::ResumeEnd { .. }, ChatChange::Window { replaces: true, .. }]
    ));
    assert_eq!(client.chats.get("c").unwrap().edition, Some(2));
}

#[test]
fn a_page_names_its_place_and_the_core_fills_the_rest() {
    let mut client = ready();
    subscribe(&mut client, "c");
    let early = client.chat_page(ChatPageRequest {
        sid: "c".into(),
        before: Some(1),
        ..ChatPageRequest::default()
    });
    assert!(matches!(early, Err(FrameError::Refused(_))));
    sent(&mut client);
    feed(&mut client, &window("c", 10, 1, 1..11));
    let request =
        ChatPageRequest { sid: "c".into(), before: Some(1), fold: Some(4), ..Default::default() };
    client.chat_page(request.clone()).unwrap();
    assert!(matches!(client.chat_page(request), Err(FrameError::RequestInFlight)));
    let page = sent(&mut client).pop().unwrap();
    assert_eq!(page["method"], "page");
    assert_eq!(page["params"]["stream"], "chat:c1");
    assert_eq!(page["params"]["before"], 1);
    assert_eq!(page["params"]["edition"], 1);
    assert_eq!(page["params"]["fold"], 4);
    let reply = ChatPageResult {
        sid: "c".into(),
        edition: 1,
        rows: vec![row(0)],
        has_before: false,
        has_after: true,
        refused: vec![],
    };
    let changes = chat_changes(feed(&mut client, &Frame::json(FrameKind::Page, &reply).unwrap()));
    assert_eq!(changes, vec![ChatChange::Page { page: reply.clone() }]);
    // A reply with no page out is skipped and counted.
    assert!(feed(&mut client, &Frame::json(FrameKind::Page, &reply).unwrap()).is_empty());
    assert_eq!(client.skip_counters().unheld_sid, 1);
}

#[test]
fn a_stale_edition_page_is_a_change_and_the_next_window_replaces() {
    let mut client = open_chat();
    client
        .chat_page(ChatPageRequest { sid: "c".into(), after: Some(10), ..Default::default() })
        .unwrap();
    sent(&mut client);
    let error =
        Frame::json(FrameKind::Error, &json!({"method":"page","sid":"c","code":"stale_edition"}))
            .unwrap();
    let changes = chat_changes(feed(&mut client, &error));
    assert!(matches!(
        changes.as_slice(),
        [ChatChange::Error { code, method, .. }] if code == "stale_edition" && method == "page"
    ));
    // The slot is free again.
    client
        .chat_page(ChatPageRequest { sid: "c".into(), after: Some(10), ..Default::default() })
        .unwrap();
    let changes = chat_changes(feed(&mut client, &window("c", 3, 2, 0..3)));
    assert!(matches!(changes.as_slice(), [ChatChange::Window { replaces: true, .. }]));
}

fn blob_head(id: &str, start: u64, len: u64, total: u64) -> BlobHead {
    BlobHead {
        id: id.into(),
        start,
        len,
        total,
        next: None,
        open: false,
        generation: None,
        fixed: None,
    }
}

#[test]
fn a_blob_reply_ends_on_a_whole_character_and_escape() {
    let mut client = open_chat();
    let id = client
        .chat_blob(ChatBlobRequest {
            sid: "c".into(),
            row_id: Some(7),
            len: 16,
            ..Default::default()
        })
        .unwrap();
    let request = sent(&mut client).pop().unwrap();
    assert_eq!(
        request,
        json!({"method":"blob","params":{"id":id,"stream":"chat:c1","edition":1,"rowId":7,"len":16}})
    );
    let bytes = br#"{"text":"ab\u00"#;
    let reply = blob_frame(&blob_head(&id, 0, bytes.len() as u64, 100), bytes).unwrap();
    let changes = chat_changes(feed(&mut client, &reply));
    let [ChatChange::Blob { next_start, bytes: given, sid, .. }] = changes.as_slice() else {
        panic!("{changes:?}")
    };
    assert_eq!(sid, "c");
    assert_eq!(given.as_slice(), br#"{"text":"ab"#);
    assert_eq!(*next_start, given.len() as u64);

    // An open row's snapshot keeps its head; its last range is given whole.
    let id = client
        .chat_blob(ChatBlobRequest {
            sid: "c".into(),
            row_id: Some(7),
            start: Some(12),
            len: 16,
            ..Default::default()
        })
        .unwrap();
    let mut open = blob_head(&id, 12, 4, 16);
    open.open = true;
    open.generation = Some("0123456789abcdef".into());
    open.fixed = Some(14);
    let changes = chat_changes(feed(&mut client, &blob_frame(&open, br#"e9"}"#).unwrap()));
    let [ChatChange::Blob { head, next_start: 16, bytes, .. }] = changes.as_slice() else {
        panic!("{changes:?}")
    };
    assert_eq!(head, &open);
    assert_eq!(bytes.as_slice(), br#"e9"}"#);

    // A prompt's text is decoded: a `\` is a character, a cut character is not.
    let id = client
        .chat_blob(ChatBlobRequest {
            sid: "c".into(),
            prompt: Some("p".into()),
            len: 8,
            ..Default::default()
        })
        .unwrap();
    let text = "a\\€".as_bytes();
    let cut = text.get(..text.len() - 1).unwrap();
    let changes = chat_changes(feed(
        &mut client,
        &blob_frame(&blob_head(&id, 0, cut.len() as u64, 50), cut).unwrap(),
    ));
    let [ChatChange::Blob { bytes, next_start: 2, .. }] = changes.as_slice() else {
        panic!("{changes:?}")
    };
    assert_eq!(bytes.as_slice(), b"a\\");
    // A blob that answers no request is skipped and counted.
    assert!(feed(&mut client, &reply).is_empty());
    assert_eq!(client.skip_counters().unheld_sid, 1);
}

#[test]
fn a_body_prefix_stops_before_an_unfinished_character_or_escape() {
    let cases: &[(&[u8], usize)] = &[
        (b"ab", 2),
        (b"ab\\", 2),
        (b"ab\\\\", 4),
        (b"ab\\\\\\", 4),
        (b"ab\\n", 4),
        (b"a\\u12", 1),
        (b"a\\u00e9", 7),
        (b"a\\uD83D", 1),
        (b"a\\uD83D\\uDE00", 13),
        (b"a\\uD83D\\uDE", 1),
        (b"a\\uD83D\\", 1),
        (&[b'a', 0xc3], 1),
        ("aé".as_bytes(), 3),
        (&[b'a', 0xe2, 0x82], 1),
        ("a€".as_bytes(), 4),
        (&[0xf0, 0x9f, 0x98], 0),
    ];
    for (bytes, whole) in cases {
        assert_eq!(whole_body_prefix(bytes), *whole, "{:?}", String::from_utf8_lossy(bytes));
    }
}

#[test]
fn a_drop_subscribes_again_under_the_same_sid_from_the_cursor() {
    let mut client = open_chat();
    feed(&mut client, &delta("c", None, vec![settled(11, 11)]));
    client
        .chat_page(ChatPageRequest { sid: "c".into(), before: Some(1), ..Default::default() })
        .unwrap();
    sent(&mut client);
    let dropped = Frame::json(FrameKind::Dropped, &json!({"sid":"c","cursor":11})).unwrap();
    let changes = chat_changes(feed(&mut client, &dropped));
    assert_eq!(changes, vec![ChatChange::Dropped { sid: "c".into(), cursor: Some(11) }]);
    let requests = sent(&mut client);
    assert_eq!(requests.len(), 2, "{requests:?}");
    assert_eq!(requests[0]["method"], "sub");
    assert_eq!(requests[0]["params"]["sid"], "c");
    assert_eq!(requests[0]["params"]["cursor"], 11);
    assert_eq!(requests[1]["method"], "page");
}

#[test]
fn a_sub_error_ends_the_sub_and_not_ready_keeps_it() {
    let mut client = ready();
    subscribe(&mut client, "c");
    let not_ready =
        Frame::json(FrameKind::Error, &json!({"method":"sub","sid":"c","code":"not_ready"}))
            .unwrap();
    assert_eq!(chat_changes(feed(&mut client, &not_ready)).len(), 1);
    assert!(client.chats.contains_key("c"));
    let failed =
        Frame::json(FrameKind::Error, &json!({"method":"sub","sid":"c","code":"source_failed"}))
            .unwrap();
    assert_eq!(chat_changes(feed(&mut client, &failed)).len(), 1);
    assert!(!client.chats.contains_key("c"));
    // Its frames are now another sid's: skipped and counted, never a panic.
    assert!(feed(&mut client, &delta("c", None, vec![settled(1, 1)])).is_empty());
    assert_eq!(client.skip_counters().unheld_sid, 1);
}

#[test]
fn a_reconnect_mid_resume_goes_on_from_the_last_taken_cursor() {
    let mut client = open_chat();
    reconnect(&mut client);
    let mut rows = Vec::new();
    let mut take = |changes: Vec<ChatChange>| {
        for change in changes {
            if let ChatChange::Op { op: ChatOp::Row { seq, .. }, .. } = change {
                rows.push(seq);
            }
        }
    };
    take(chat_changes(feed(
        &mut client,
        &delta("c", Some(ReplayMark::Replay), vec![settled(11, 11), settled(12, 12)]),
    )));
    let sub = reconnect(&mut client);
    assert_eq!(sub["params"]["cursor"], 12);
    // The daemon replays after the cursor named.
    let from = sub["params"]["cursor"].as_u64().unwrap();
    let missed: Vec<ChatOp> = (from + 1..=14).map(|seq| settled(seq, seq)).collect();
    take(chat_changes(feed(&mut client, &delta("c", Some(ReplayMark::Replay), missed))));
    take(chat_changes(feed(&mut client, &delta("c", Some(ReplayMark::End), vec![]))));
    assert_eq!(rows, vec![11, 12, 13, 14]);
}

#[test]
fn a_list_sub_and_a_chat_sub_share_one_handle() {
    let mut client = ready();
    client.subscribe(Sub::new("l", "list")).unwrap();
    subscribe(&mut client, "c");
    assert!(matches!(client.subscribe(Sub::new("c", "list")), Err(FrameError::Refused(_))));
    assert!(matches!(
        client.subscribe_chat(ChatSubRequest {
            sid: "l".into(),
            chat: "x".into(),
            anchor: None,
            window: None
        }),
        Err(FrameError::Refused(_))
    ));
    sent(&mut client);
    let list_window = Frame::json(
        FrameKind::Window,
        &json!({"sid":"l","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
    )
    .unwrap();
    assert!(matches!(feed(&mut client, &list_window).as_slice(), [Change::Window(_)]));
    assert_eq!(chat_changes(feed(&mut client, &window("c", 5, 1, 0..5))).len(), 1);

    client.unsubscribe("l").unwrap();
    assert_eq!(sent(&mut client), vec![json!({"method":"unsub","params":{"sid":"l"}})]);
    assert_eq!(chat_changes(feed(&mut client, &delta("c", None, vec![settled(6, 6)]))).len(), 1);
    let list_delta =
        Frame::json(FrameKind::Delta, &json!({"sid":"l","ops":[{"op":"queue","seq":2,"bytes":1}]}))
            .unwrap();
    assert!(feed(&mut client, &list_delta).is_empty());
    assert_eq!(client.skip_counters().unheld_sid, 1);

    client.subscribe(Sub::new("l2", "list")).unwrap();
    client.unsubscribe("c").unwrap();
    assert!(!client.chats.contains_key("c"));
    assert!(client.subscriptions.contains_key("l2"));
}

#[test]
fn bounds_skip_and_count_and_never_panic() {
    let mut client = open_chat();
    // A window over 400 rows.
    let changes = chat_changes(feed(&mut client, &window("c", 900, 1, 0..401)));
    assert!(matches!(
        changes.as_slice(),
        [ChatChange::Error { code, .. }] if code == "over_bound"
    ));
    assert_eq!(client.skip_counters().over_bound, 1);
    assert_eq!(cursor(&client, "c"), 10);
    // An op the core does not know, one with no seq, and the known ones beside them.
    let frame = Frame::json(
        FrameKind::Delta,
        &json!({"sid":"c","ops":[
            {"op":"later","seq":20},
            {"op":"row","row":{"id":1}},
            {"op":"text","seq":10,"rowId":3,"text":"\"x\""}
        ]}),
    )
    .unwrap();
    let changes = chat_changes(feed(&mut client, &frame));
    assert!(matches!(changes.as_slice(), [ChatChange::Op { op: ChatOp::Text { .. }, .. }]));
    let skips = client.skip_counters();
    assert_eq!((skips.unknown_op, skips.missing_seq), (1, 1));
    assert_eq!(cursor(&client, "c"), 20);
    // A change not taken stops the socket.
    let bytes = delta("c", None, vec![settled(21, 21)]).encode();
    assert_eq!(client.received(&bytes), bytes.len());
    assert_eq!(client.received(&bytes), 0);
    assert!(client.next_change().is_some());
    // A frame over the frame bound ends the connection with an error, not a panic.
    let mut header = ((wire::MAX_FRAME_BYTES + 1) as u32).to_be_bytes().to_vec();
    header.extend_from_slice(&[0; 4]);
    client.received(&header);
    assert!(client.is_closed());
}

#[test]
fn taken_chat_changes_send_credit() {
    let mut client = ready_with(Limits { credit_window: 4, ..Limits::default() });
    subscribe(&mut client, "c");
    sent(&mut client);
    feed(&mut client, &window("c", 1, 1, 0..1));
    let credit = sent(&mut client).pop().unwrap();
    assert_eq!(credit["method"], "credit");
    assert_eq!(credit["params"]["sid"], "c");
}

#[test]
fn chat_changes_are_json_with_their_rows_as_they_arrived() {
    let mut client = open_chat();
    let changes = feed(&mut client, &delta("c", None, vec![settled(11, 11)]));
    let Some(Change::Chat(change)) = changes.into_iter().next() else { panic!() };
    let json = serde_json::to_string(&change).unwrap();
    assert_eq!(
        json,
        r#"{"kind":"chatOp","sid":"c","replay":false,"op":{"op":"row","seq":11,"row":{"id":11,"rev":1, "body":{"text":"r11"}}}}"#
    );
    let window = ChatChange::Window {
        replaces: true,
        window: window("c", 1, 1, 0..1).decode_json().unwrap(),
    };
    let value = serde_json::to_value(&window).unwrap();
    assert_eq!(value["kind"], "chatWindow");
    assert_eq!(value["replaces"], true);
    assert_eq!(value["window"]["cursor"], 1);
    let blob = ChatChange::Blob {
        sid: "c".into(),
        head: blob_head("b1", 0, 1, 1),
        next_start: 1,
        bytes: b"x".to_vec(),
    };
    assert_eq!(
        serde_json::to_value(&blob).unwrap(),
        json!({"kind":"chatBlob","sid":"c","head":{"id":"b1","start":0,"len":1,"total":1},"nextStart":1})
    );
}

fn write_gate_line(line: &Value) {
    println!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT") {
        use std::io::Write as _;
        let mut output = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(output, "{line}").unwrap();
    }
}

/// A chat sub past its first window: a god chat of 100,000 rows whose open row is 1 MB (its body
/// left out of the window, as the daemon leaves out a body past 64 KB), or a small one of 100.
fn gate_client(god: bool) -> Client<Value> {
    let mut client = ready();
    subscribe(&mut client, "c");
    sent(&mut client);
    let (last, rows) = if god { (100_000, 400) } else { (100, 100) };
    let mut frame = window("c", last, 1, last - rows..last).decode_json::<ChatWindow>().unwrap();
    frame.has_before = god;
    let open = if god {
        OpenRow { row: RawJson::from_bytes(b"{}").unwrap(), body_len: Some(1 << 20) }
    } else {
        OpenRow { row: row(last + 1), body_len: None }
    };
    frame.open = vec![open];
    let frame = Frame::json(FrameKind::Window, &frame).unwrap();
    feed_in_chunks(&mut client, &frame.encode());
    client
}

/// Feeds bytes the way a socket reads them, 16 KB at a time, taking each change.
fn feed_in_chunks(client: &mut Client<Value>, bytes: &[u8]) {
    let mut at = 0;
    while at < bytes.len() {
        let end = (at + 16 * 1024).min(bytes.len());
        at += client.received(bytes.get(at..end).unwrap());
        while client.next_change().is_some() {}
        while client.take_send().is_some() {}
    }
}

fn p95(mut samples: Vec<u64>) -> u64 {
    samples.sort_unstable();
    samples[(samples.len() * 95 / 100).min(samples.len() - 1)]
}

#[test]
#[ignore = "release gate: run through cmux-ci with --release"]
fn v2_pr06_client_chat_held_gate() {
    let held = |god: bool| {
        let mut client = gate_client(god);
        let base = if god { 100_000 } else { 100 };
        for step in 0..10_000_u64 {
            let seq = base + 1 + step / 2;
            let op = if step % 2 == 0 { text(seq - 1, base + 1) } else { settled(seq, seq) };
            feed_in_chunks(&mut client, &delta("c", None, vec![op]).encode());
        }
        client.held_bytes() as u64
    };
    let small = held(false);
    let god = held(true);
    write_gate_line(&json!({
        "name":"v2.pr06.client_chat_held","small_p95":small,"god_p95":god,"unit":"bytes"
    }));
    assert!(god as f64 <= small as f64 * 1.2, "god {god} bytes, small {small}");
}

#[test]
#[ignore = "release gate: run through cmux-ci with --release"]
fn v2_pr06_client_chat_change_gate() {
    let mut clients = [gate_client(false), gate_client(true)];
    let mut seqs = [101_u64, 100_001];
    let mut samples = [Vec::new(), Vec::new()];
    let body = "x".repeat(2048);
    for _round in 0..20 {
        for side in 0..2 {
            for _ in 0..250 {
                seqs[side] += 1;
                let seq = seqs[side];
                let row = RawJson::from_bytes(
                    format!(r#"{{"id":{seq},"rev":1,"body":{{"text":"{body}"}}}}"#).as_bytes(),
                )
                .unwrap();
                let bytes =
                    delta("c", None, vec![ChatOp::Row { seq, row, body_len: None }]).encode();
                let client = &mut clients[side];
                let started = std::time::Instant::now();
                assert_eq!(client.received(&bytes), bytes.len());
                let change = client.next_change();
                let elapsed = started.elapsed().as_nanos() as u64;
                assert!(matches!(change, Some(Change::Chat(ChatChange::Op { .. }))));
                while client.take_send().is_some() {}
                samples[side].push(elapsed);
            }
        }
    }
    let [small, god] = samples;
    let (small, god) = (p95(small), p95(god));
    write_gate_line(&json!({
        "name":"v2.pr06.client_chat_change","small_p95":small,"god_p95":god,"unit":"ns"
    }));
    assert!(god as f64 <= small as f64 * 1.2, "god p95 {god} ns, small {small} ns");
}
