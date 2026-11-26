use super::*;
use crate::wire::{ListKey, ListView, Page, PageResult, Window};
use serde_json::Value;

fn row(origin: &str, id: &str, at: u64) -> Summary {
    let mut summary = Summary::new(id);
    summary.origin = origin.into();
    summary.last_activity = at;
    summary
}

fn live_sub(sid: &str, window: u16) -> Sub {
    let mut sub = Sub::new(sid, "list");
    sub.view = Some(ListView::Live);
    sub.window = Some(window);
    sub
}

fn ops(span: &history::RawSpan) -> Vec<Value> {
    if span.bytes.is_empty() {
        return Vec::new();
    }
    let mut array = b"[".to_vec();
    array.extend_from_slice(&span.bytes);
    array.push(b']');
    serde_json::from_slice(&array).unwrap()
}

/// A peer receiver woken after the index is published and before the op is
/// appended reads nothing past the committed seq, and the op reaches it once
/// after the append: for a local summary, a local gone, and through records
/// that are not for a peer.
#[test]
fn a_wake_before_its_append_never_moves_a_peer_cursor_past_the_committed_seq() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let subscription = hub.subscribe_peer(&live_sub("peer", 10)).unwrap();
    subscription.receiver.reposition(subscription.cursor);
    let receiver = Arc::new(subscription.receiver);
    let early = Arc::new(AtomicU64::new(0));
    let woken = Arc::new(AtomicU64::new(0));
    {
        let receiver = receiver.clone();
        let early = early.clone();
        let woken = woken.clone();
        *writer.before_record.lock().unwrap() = Some(Box::new(move |seq| {
            woken.fetch_add(1, Ordering::Relaxed);
            match receiver.try_next_raw(None, usize::MAX) {
                None => {}
                Some(RawRead::Span(span)) if span.last_seq < seq => {}
                Some(_) => {
                    early.fetch_add(1, Ordering::Relaxed);
                }
            }
        }));
    }
    let mut expected = Vec::new();
    let mut delivered = Vec::new();
    let mut n = 0_u64;
    while woken.load(Ordering::Relaxed) < 1_000 {
        n += 1;
        let id = format!("chat-{}", n % 7);
        let at = n + 1;
        match n % 4 {
            0 | 1 => {
                let event = writer.apply(row("local", &id, at)).unwrap();
                expected.push((event.seq, "summary"));
            }
            2 => {
                if writer.remove("local", &id).unwrap() {
                    expected.push((hub.snapshot().seq(), "gone"));
                }
            }
            _ => {
                writer.apply_from(Source::V1, row("other", &id, at)).unwrap();
            }
        }
        while let Some(read) = receiver.try_next_raw(None, usize::MAX) {
            let RawRead::Span(span) = read else { panic!("a peer receiver lagged") };
            for op in ops(&span) {
                delivered
                    .push((op["seq"].as_u64().unwrap(), op["op"].as_str().unwrap().to_owned()));
            }
        }
    }
    assert!(woken.load(Ordering::Relaxed) >= 1_000);
    assert_eq!(early.load(Ordering::Relaxed), 0, "a read went past the committed seq");
    let delivered: Vec<_> = delivered.iter().map(|(seq, op)| (*seq, op.as_str())).collect();
    assert_eq!(delivered, expected, "every local op once, in order, no gap");
    assert_eq!(receiver.subscriber.state.lock().unwrap().cursor, hub.snapshot().seq());
}

/// A list receiver read after the index is published and before the op is in the still empty
/// history waits for that op: it is not told it lagged, which ended it for good (the first op
/// after a start, a summary or a gone; list_tee's tests met it on a loaded runner).
#[test]
fn a_read_before_the_first_append_waits_for_the_op_and_never_lags() {
    for remove in [false, true] {
        let initial = if remove {
            SummaryIndex::new().apply(1, row("local", "chat", 1))
        } else {
            SummaryIndex::new()
        };
        let (hub, mut writer) = Hub::new(initial);
        let subscription = hub.subscribe(&Sub::new("local", "list")).unwrap();
        let cursor = subscription.cursor;
        let receiver = Arc::new(subscription.receiver);
        let early = Arc::new(Mutex::new(Vec::new()));
        {
            let (receiver, early) = (receiver.clone(), early.clone());
            *writer.before_record.lock().unwrap() = Some(Box::new(move |_| {
                if let Some(item) = receiver.try_next() {
                    early.lock().unwrap().push(format!("{item:?}"));
                }
            }));
        }
        if remove {
            assert!(writer.remove("local", "chat").unwrap());
        } else {
            writer.apply(row("local", "chat", 2)).unwrap();
        }
        assert!(early.lock().unwrap().is_empty(), "read before the append: {early:?}");
        match receiver.try_next() {
            Some(ListItem::Summary(event)) if !remove => assert_eq!(event.seq, cursor + 1),
            Some(ListItem::Gone { seq, .. }) if remove => assert_eq!(seq, cursor + 1),
            other => panic!("the op after the append, not {other:?}"),
        }
        assert!(receiver.try_next().is_none());
    }
}

fn keys_of(value: &Value) -> Vec<ListKey> {
    ["beforeKey", "afterKey"]
        .iter()
        .filter_map(|name| value.get(*name).filter(|key| !key.is_null()))
        .chain(value.get("deeper").and_then(Value::as_array).into_iter().flatten())
        .map(|key| serde_json::from_value(key.clone()).unwrap())
        .collect()
}

fn assert_local_only(frame: &Frame, remote: &[String]) {
    let text = std::str::from_utf8(frame.payload()).unwrap();
    for id in remote {
        assert!(!text.contains(id.as_str()), "a remote id reached a peer frame: {text}");
    }
    assert!(!text.contains("\"c-machine\""), "a remote origin reached a peer frame: {text}");
    let value: Value = frame.decode_json().unwrap();
    assert!(value.get("origins").and_then(Value::as_array).is_none_or(Vec::is_empty));
    for key in keys_of(&value) {
        assert_eq!(key.origin, "local", "a continuation key names another origin");
    }
    for row in value["rows"].as_array().unwrap() {
        assert!(row.get("origin").is_none_or(|origin| origin == "local"));
    }
}

/// B holds its own rows and rows of C, with C's rows ahead of, between and
/// after B's. Every window and page B serves A, walked both ways at every
/// page size, names only B's rows: in its rows, its keys and its flags.
#[test]
fn a_peer_window_and_page_name_only_local_rows_at_every_step_of_a_walk() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let mut remote = Vec::new();
    let mut local = Vec::new();
    // Newest first: three of C, then B and C alternating, then three of C.
    let mut at = 1_000;
    let mut add_remote = |writer: &mut HubWriter, at: u64| {
        let id = format!("c-chat-{at}");
        writer.apply_from(Source::V1, row("c-machine", &id, at)).unwrap();
        remote.push(id);
    };
    for _ in 0..3 {
        add_remote(&mut writer, at);
        at -= 1;
    }
    for n in 0..9 {
        let id = format!("b-chat-{n}");
        writer.apply(row("local", &id, at)).unwrap();
        local.push(id);
        at -= 1;
        add_remote(&mut writer, at);
        at -= 1;
    }
    for _ in 0..3 {
        add_remote(&mut writer, at);
        at -= 1;
    }
    writer.origin("c-machine", OriginState::Connected, 1).unwrap();
    let row_bytes =
        u32::try_from(hub.snapshot().get("b-chat-0").unwrap().encoded_len() + 1).unwrap();
    for window in 1..=10_u16 {
        let frame = hub.peer_window(&live_sub("peer", window)).unwrap();
        assert_local_only(&frame, &remote);
        let first: Window<Value> = frame.decode_json().unwrap();
        let mut seen: Vec<String> =
            first.rows.iter().map(|row| row["chatId"].as_str().unwrap().to_owned()).collect();
        let mut next = first.after_key.clone();
        let mut more = first.has_after;
        while more {
            let key = next.clone().expect("has_after with no key");
            let mut page = Page::new_list("peer", "list", PageSide::After, key);
            page.view = Some(ListView::Live);
            page.max_bytes = 8192 + 4 + row_bytes * u32::from(window);
            let frame = hub.peer_page(&page).unwrap();
            assert_local_only(&frame, &remote);
            let result: PageResult<Value> = frame.decode_json().unwrap();
            assert!(!result.rows.is_empty(), "a page with more and no rows would loop");
            seen.extend(result.rows.iter().map(|row| row["chatId"].as_str().unwrap().to_owned()));
            next = result.after_key;
            more = result.has_after;
        }
        assert_eq!(seen, local, "the walk after, window {window}");
        let mut back: Vec<String> = Vec::new();
        let mut key = next;
        loop {
            let mut page =
                Page::new_list("peer", "list", PageSide::Before, key.clone().expect("a key"));
            page.view = Some(ListView::Live);
            page.max_bytes = 8192 + 4 + row_bytes * u32::from(window);
            let frame = hub.peer_page(&page).unwrap();
            assert_local_only(&frame, &remote);
            let result: PageResult<Value> = frame.decode_json().unwrap();
            let rows: Vec<String> =
                result.rows.iter().map(|row| row["chatId"].as_str().unwrap().to_owned()).collect();
            back.splice(0..0, rows);
            if !result.has_before {
                break;
            }
            key = result.before_key;
        }
        assert_eq!(back.len() + 1, local.len(), "the walk before, window {window}");
        assert_eq!(back[..], local[..local.len() - 1]);
    }
    // A key that names a row of C is refused, not answered around.
    let remote_key = ListKey {
        last_activity: 1_000,
        chat_id: remote[0].clone(),
        origin: "c-machine".into(),
        past: false,
    };
    let mut page = Page::new_list("peer", "list", PageSide::After, remote_key);
    page.view = Some(ListView::Live);
    assert!(hub.peer_page(&page).is_err());
}
