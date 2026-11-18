//! The relay seam with a fake relay (row 8b PR 2): a page that names another origin goes to
//! that origin once, comes back renamed and in order, fails by its deadline, is `busy` past
//! RELAY_IN_FLIGHT, and writes nothing here.

use super::*;
use crate::wire::{ListFilter, ListKey, ListView, Page, PageKey, PageResult};

const PEER: &str = "peer-a";

/// What the fake relay does with a request.
#[derive(Clone, Copy)]
enum Answer {
    /// The peer hub's serve side answers it, as a link would carry it.
    Peer,
    /// Nothing ever comes back.
    Silent,
    /// The origin answers `error` with this code.
    Fails(&'static str),
}

struct FakeRelay {
    peer: Arc<Hub>,
    takes: Vec<String>,
    answer: Answer,
    /// A row of a third machine put into every answer, which the seam must drop.
    foreign: bool,
    /// The sid the relay sends under, in place of the asker's.
    sid: Option<String>,
    asked: Mutex<Vec<(String, Page)>>,
}

impl FakeRelay {
    fn new(peer: Arc<Hub>, answer: Answer) -> Arc<Self> {
        Arc::new(Self {
            peer,
            takes: vec![PEER.into(), "peer-b".into()],
            answer,
            foreign: false,
            sid: None,
            asked: Mutex::new(Vec::new()),
        })
    }

    fn asked(&self) -> Vec<(String, Page)> {
        self.asked.lock().unwrap().clone()
    }
}

impl PageRelay for FakeRelay {
    fn relays(&self, origin: &str) -> bool {
        self.takes.iter().any(|taken| taken == origin)
    }

    fn page(&self, origin: &str, mut request: Page) -> RelayFuture {
        self.asked.lock().unwrap().push((origin.to_owned(), request.clone()));
        if let Some(sid) = &self.sid {
            request.sid = sid.clone();
        }
        match self.answer {
            Answer::Silent => Box::pin(std::future::pending()),
            Answer::Fails(code) => {
                let failed = RelayFailed { code: code.into(), message: "refused".into() };
                Box::pin(std::future::ready(Err(failed)))
            }
            Answer::Peer => {
                let frame = self.peer.peer_page(&request).expect("the serve side answers");
                let mut page: PageResult<Summary> = frame.decode_json().expect("a page");
                if self.foreign {
                    let mut row = Summary::new("third-row");
                    row.origin = "c-machine".into();
                    page.rows.push(row);
                }
                Box::pin(std::future::ready(Ok(page)))
            }
        }
    }
}

fn row(id: &str, origin: &str, at: u64, closed: bool) -> Summary {
    let mut row = Summary::new(id);
    row.origin = origin.into();
    row.last_activity = at;
    row.title = "a row of fixed width".into();
    if closed {
        row.state = "closed".into();
    }
    row
}

fn hub_of(rows: Vec<Summary>) -> Arc<Hub> {
    let mut index = SummaryIndex::new();
    for (seq, row) in rows.into_iter().enumerate() {
        index = index.apply(seq as u64 + 1, row);
    }
    Arc::new(Hub::new(index).0)
}

/// A hub holding 50 live rows of PEER (even chat ids), and the peer, holding all 100 of them
/// as its own rows: the 50 odd ones closed, so only it has them.
fn pair() -> (Arc<Hub>, Arc<Hub>) {
    let held = (0..100u64)
        .filter(|n| n % 2 == 0)
        .map(|n| row(&format!("a-{n:03}"), PEER, 10_000 - n, false))
        .collect();
    let owned =
        (0..100u64).map(|n| row(&format!("a-{n:03}"), "local", 10_000 - n, n % 2 == 1)).collect();
    (hub_of(held), hub_of(owned))
}

fn key(n: u64) -> ListKey {
    ListKey {
        last_activity: 10_000 - n,
        chat_id: format!("a-{n:03}"),
        origin: PEER.into(),
        past: false,
    }
}

fn keys_page(keys: impl IntoIterator<Item = ListKey>, max: u32) -> Page {
    let mut page = Page::new("s", "list", PageSide::After, 0);
    page.after = None;
    page.keys = Some(keys.into_iter().map(PageKey::Summary).collect());
    page.max_bytes = max;
    page
}

fn view_page(origin: &str, after: Option<ListKey>, max: u32) -> Page {
    let mut page = Page::new("s", "list", PageSide::After, 0);
    page.after = after.map(Position::List);
    page.view = Some(ListView::All);
    page.filter = Some(ListFilter { origin: Some(origin.into()), ..ListFilter::default() });
    page.max_bytes = max;
    page
}

fn sent(hub: &Hub, page: &Page) -> RelayedPage {
    match hub.relayed_page(page).expect("the relay takes it").expect("a relayed page") {
        Relayed::Sent(relayed) => *relayed,
        Relayed::Done(_) => panic!("answered at once"),
        Relayed::Busy => panic!("busy"),
    }
}

fn ids(page: &PageResult<Summary>) -> Vec<String> {
    page.rows.iter().map(|row| row.chat_id.clone()).collect()
}

#[tokio::test]
async fn keys_the_index_lacks_go_to_their_origin_once_and_come_back_in_the_order_asked() {
    let (hub, peer) = pair();
    let relay = FakeRelay::new(peer, Answer::Peer);
    hub.set_page_relay(relay.clone());
    let seq = hub.snapshot().seq();
    let asked = (0..100).map(key).collect::<Vec<_>>();
    let frame = sent(&hub, &keys_page(asked.clone(), 256 * 1024)).answer().await.unwrap();
    let page: PageResult<Summary> = frame.decode_json().unwrap();
    // Every key answered, in the order asked, each row of the origin it names.
    assert_eq!(ids(&page), asked.iter().map(|key| key.chat_id.clone()).collect::<Vec<_>>());
    assert!(page.rows.iter().all(|row| row.origin == PEER));
    assert!(page.missing.is_empty() && page.unknown.is_empty() && page.rest.is_empty());
    // One request, carrying exactly the 50 keys this hub lacks, each named `local`.
    let requests = relay.asked();
    assert_eq!(requests.len(), 1);
    let (origin, request) = &requests[0];
    assert_eq!(origin, PEER);
    let carried = request.keys.clone().unwrap();
    assert_eq!(carried.len(), 50);
    assert!(carried.iter().enumerate().all(|(n, carried)| matches!(
        carried,
        PageKey::Summary(key) if key.origin == "local" && key.chat_id == format!("a-{:03}", 2 * n + 1)
    )));
    assert_eq!(hub.snapshot().seq(), seq, "a relayed page writes nothing");
    assert_eq!(hub.relay_in_flight(PEER), 0);
}

#[tokio::test]
async fn keys_past_the_budget_are_rest_in_order_and_are_not_asked() {
    let (hub, peer) = pair();
    let relay = FakeRelay::new(peer, Answer::Peer);
    hub.set_page_relay(relay.clone());
    let asked = (0..100).map(key).collect::<Vec<_>>();
    // A page charges every key up front and keeps room for one more row of the widest size;
    // past both, 2,500 bytes of rows: the plan cuts partway through the held keys.
    let keys_bytes = asked
        .iter()
        .map(|key| serde_json::to_vec(&PageKey::Summary(key.clone())).unwrap().len() + 1)
        .sum::<usize>();
    let max = 6 * acpmux_book::index::MAX_INDEX_RECORD_BYTES + keys_bytes + 64 + 300 + 2_500;
    let frame = sent(&hub, &keys_page(asked.clone(), max as u32)).answer().await.unwrap();
    assert!(frame.encoded_len() <= max);
    let page: PageResult<Summary> = frame.decode_json().unwrap();
    assert!(page.missing.is_empty() && page.unknown.is_empty());
    assert!(!page.rows.is_empty() && !page.rest.is_empty(), "{} rows", page.rows.len());
    // Every key is answered once: a row in the order asked, or `rest` in the order asked.
    let rows = ids(&page);
    let rest = page.rest.iter().map(|key| key.chat_id.clone()).collect::<Vec<_>>();
    let mut merged = asked.iter().map(|key| key.chat_id.clone()).collect::<Vec<_>>();
    merged.retain(|id| rows.contains(id));
    assert_eq!(rows, merged, "rows in the order asked");
    assert!(page.rest.iter().all(|key| key.origin == PEER), "rest in the asker's terms");
    let mut order = asked.iter().map(|key| key.chat_id.clone()).collect::<Vec<_>>();
    order.retain(|id| rest.contains(id));
    assert_eq!(rest, order, "rest in the order asked");
    assert_eq!(rows.len() + rest.len(), 100);
    // Only keys this hub lacks are carried, and none past the plan's own cut. The first held
    // (even) key in `rest` is at the cut or just after it, so the key before it is carried
    // only if the cut is that held key.
    let held = page.rest.iter().find(|key| key.chat_id.ends_with(['0', '2', '4', '6', '8']));
    let held = held.map_or(100, |key| asked.iter().position(|asked| asked == key).unwrap());
    assert!(held < 100, "the plan cuts before the last key");
    let carried = relay.asked()[0].1.keys.clone().unwrap();
    let lacking = |below: usize| {
        (1..below as u64)
            .step_by(2)
            .map(|n| PageKey::Summary(ListKey { origin: "local".into(), ..key(n) }))
            .collect::<Vec<_>>()
    };
    assert!(carried == lacking(held - 1) || carried == lacking(held), "{} carried", carried.len());
}

#[tokio::test]
async fn a_relayed_view_page_walks_the_origin_renamed_and_drops_a_third_machines_row() {
    let (hub, peer) = pair();
    let mut relay = FakeRelay::new(peer, Answer::Peer);
    Arc::get_mut(&mut relay).unwrap().foreign = true;
    hub.set_page_relay(relay.clone());
    let seq = hub.snapshot().seq();
    let mut walked = Vec::new();
    let mut after = None;
    loop {
        let frame = sent(&hub, &view_page(PEER, after.clone(), 12_000)).answer().await.unwrap();
        assert!(frame.encoded_len() <= 12_000);
        let page: PageResult<Summary> = frame.decode_json().unwrap();
        assert!(page.rows.iter().all(|row| row.origin == PEER), "renamed, no third machine");
        walked.extend(ids(&page));
        if !page.has_after {
            break;
        }
        let key = page.after_key.expect("a key to go on from");
        assert_eq!(key.origin, PEER);
        after = Some(key);
    }
    assert_eq!(walked, (0..100).map(|n| format!("a-{n:03}")).collect::<Vec<_>>());
    let requests = relay.asked();
    assert!(requests.len() > 1);
    for (_, request) in &requests {
        assert_eq!(request.filter.as_ref().unwrap().origin.as_deref(), Some("local"));
        if let Some(Position::List(key)) = &request.after {
            assert_eq!(key.origin, "local", "the anchor goes in the peer's terms");
        }
    }
    assert_eq!(hub.relay_foreign_rows(), requests.len() as u64);
    assert_eq!(hub.snapshot().seq(), seq);
}

#[tokio::test(start_paused = true)]
async fn silence_answers_error_for_a_view_and_unknown_for_keys_at_the_deadline() {
    let (hub, peer) = pair();
    hub.set_page_relay(FakeRelay::new(peer, Answer::Silent));
    let started = tokio::time::Instant::now();
    let error = sent(&hub, &view_page(PEER, None, 12_000)).answer().await.unwrap_err();
    assert_eq!(error.code, RELAY_FAILED);
    assert_eq!(started.elapsed(), RELAY_PAGE_DEADLINE);
    let started = tokio::time::Instant::now();
    let frame =
        sent(&hub, &keys_page([key(0), key(1), key(3)], 256 * 1024)).answer().await.unwrap();
    assert_eq!(started.elapsed(), RELAY_PAGE_DEADLINE);
    let page: PageResult<Summary> = frame.decode_json().unwrap();
    assert_eq!(ids(&page), ["a-000"], "the held row still comes back");
    assert_eq!(page.unknown, vec![key(1), key(3)]);
    assert_eq!(hub.relay_in_flight(PEER), 0);
}

#[tokio::test]
async fn an_origins_error_is_the_view_pages_error_and_unknown_for_its_keys() {
    let (hub, peer) = pair();
    hub.set_page_relay(FakeRelay::new(peer, Answer::Fails("invalid_params")));
    let error = sent(&hub, &view_page(PEER, None, 12_000)).answer().await.unwrap_err();
    assert_eq!(error.code, "invalid_params");
    let frame = sent(&hub, &keys_page([key(1)], 256 * 1024)).answer().await.unwrap();
    let page: PageResult<Summary> = frame.decode_json().unwrap();
    assert!(page.rows.is_empty());
    assert_eq!(page.unknown, vec![key(1)]);
}

#[tokio::test]
async fn the_seventeenth_request_to_an_origin_is_busy_and_a_slot_comes_back_when_one_ends() {
    let (hub, peer) = pair();
    hub.set_page_relay(FakeRelay::new(peer, Answer::Silent));
    let mut held = (0..RELAY_IN_FLIGHT)
        .map(|_| sent(&hub, &view_page(PEER, None, 12_000)))
        .collect::<Vec<_>>();
    assert_eq!(hub.relay_in_flight(PEER), RELAY_IN_FLIGHT);
    for page in [view_page(PEER, None, 12_000), keys_page([key(1)], 256 * 1024)] {
        assert!(matches!(hub.relayed_page(&page), Some(Ok(Relayed::Busy))));
    }
    // Another origin has its own slots.
    let other = sent(&hub, &view_page("peer-b", None, 12_000));
    held.pop();
    assert!(matches!(hub.relayed_page(&view_page(PEER, None, 12_000)), Some(Ok(Relayed::Sent(_)))));
    drop((held, other));
    assert_eq!(hub.relay_in_flight(PEER), 0);
    assert_eq!(hub.relay_in_flight("peer-b"), 0);
}

#[derive(Default)]
struct FakeProvider;

impl PageProvider for FakeProvider {
    fn row(&self, _key: &RowKey) -> std::io::Result<Option<Arc<Summary>>> {
        Ok(None)
    }

    fn view_page(
        &self,
        origin: &str,
        request: &Page,
    ) -> std::io::Result<Option<PageResult<Arc<Summary>>>> {
        Ok(Some(PageResult {
            sid: request.sid.clone(),
            rows: vec![Arc::new(row("from-v1", origin, 5, true))],
            has_before: false,
            has_after: false,
            cold_unread: false,
            deeper: Vec::new(),
            before_key: None,
            after_key: None,
            missing: Vec::new(),
            unknown: Vec::new(),
            rest: Vec::new(),
        }))
    }
}

#[test]
fn a_page_the_relay_does_not_take_is_answered_at_once_as_before() {
    let (hub, peer) = pair();
    // No relay: the index answers, its live rows of the origin only.
    assert!(hub.relayed_page(&view_page(PEER, None, 12_000)).is_none());
    let page: PageResult<Summary> =
        hub.page(&view_page(PEER, None, 12_000)).unwrap().decode_json().unwrap();
    assert!(
        !page.rows.is_empty() && page.rows.iter().all(|row| row.origin == PEER && row.is_live())
    );
    // A relay that does not take the origin, and pages that name no other origin.
    hub.set_page_relay(FakeRelay::new(peer, Answer::Peer));
    for page in [
        view_page("peer-z", None, 12_000),
        view_page("local", None, 12_000),
        keys_page([ListKey { origin: "peer-z".into(), ..key(1) }], 256 * 1024),
    ] {
        assert!(hub.relayed_page(&page).is_none());
    }
    // A key this hub holds is answered here, with no request.
    assert!(matches!(
        hub.relayed_page(&keys_page([key(0)], 256 * 1024)),
        Some(Ok(Relayed::Done(_)))
    ));
    // The provider's view read answers a view page the relay does not take (decision 265).
    hub.set_page_provider(Arc::new(FakeProvider));
    let page: PageResult<Summary> =
        hub.page(&view_page("peer-z", None, 12_000)).unwrap().decode_json().unwrap();
    assert_eq!(ids(&page), ["from-v1"]);
}

/// A local connection: a page that names another origin is answered by the relay through the
/// connection's later reply, and one past RELAY_IN_FLIGHT answers `busy`.
#[tokio::test]
async fn a_local_connection_gets_the_relayed_page_on_its_held_sub() {
    use crate::conn::{HubSource, Role, run};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    async fn send(writer: &mut tokio::io::DuplexStream, request: serde_json::Value) {
        let frame = Frame::json(FrameKind::Request, &request).unwrap();
        writer.write_all(&frame.encode()).await.unwrap();
    }
    async fn receive(reader: &mut tokio::io::DuplexStream) -> Frame {
        let mut header = [0; 4];
        reader.read_exact(&mut header).await.unwrap();
        let mut bytes = vec![0; u32::from_be_bytes(header) as usize];
        reader.read_exact(&mut bytes).await.unwrap();
        let mut encoded = header.to_vec();
        encoded.extend(bytes);
        Frame::from_encoded(&encoded).unwrap()
    }

    let (hub, peer) = pair();
    let relay = FakeRelay::new(peer, Answer::Peer);
    hub.set_page_relay(relay.clone());
    let source = Arc::new(HubSource::new(hub.clone()));
    let (mut client, server) = tokio::io::duplex(1 << 20);
    let (rd, wr) = tokio::io::split(server);
    let task =
        tokio::spawn(
            async move { run(rd, wr, source, "test", &["list".into()], Role::Local).await },
        );
    send(
        &mut client,
        serde_json::json!({"method":"hello","params":{"clientKind":"test","protocol":2}}),
    )
    .await;
    assert_eq!(receive(&mut client).await.kind, FrameKind::Hello);
    send(
        &mut client,
        serde_json::json!({"method":"sub","params":{"sid":"s","stream":"list","view":"all"}}),
    )
    .await;
    assert_eq!(receive(&mut client).await.kind, FrameKind::Window);
    let page = view_page(PEER, None, 12_000);
    send(&mut client, serde_json::json!({"method":"page","params":page})).await;
    let frame = receive(&mut client).await;
    assert_eq!(frame.kind, FrameKind::Page);
    let answered: PageResult<Summary> = frame.decode_json().unwrap();
    assert_eq!(answered.rows.first().map(|row| row.chat_id.as_str()), Some("a-000"));
    assert!(answered.rows.iter().all(|row| row.origin == PEER));
    assert_eq!(relay.asked().len(), 1);
    // An unheld sid is refused before anything is asked.
    let mut unheld = view_page(PEER, None, 12_000);
    unheld.sid = "other".into();
    send(&mut client, serde_json::json!({"method":"page","params":unheld})).await;
    let frame = receive(&mut client).await;
    assert_eq!(frame.kind, FrameKind::Error);
    assert_eq!(frame.decode_json::<serde_json::Value>().unwrap()["code"], "unknown_sid");
    assert_eq!(relay.asked().len(), 1);
    drop(client);
    task.await.unwrap().unwrap();
}

use crate::conn::Source as ConnSource;

/// A list source that also answers a chat's `page` through its later reply at once, and
/// records the sids its connection ends.
struct ChatAndList {
    list: crate::conn::HubSource,
    ended: Mutex<Vec<String>>,
}

impl ConnSource for ChatAndList {
    fn subscribe(
        &self,
        sub: &Sub,
        person: Option<&[u8]>,
        sink: Arc<dyn crate::conn::OfferSink>,
    ) -> Result<(), crate::conn::ConnError> {
        self.list.subscribe(sub, person, sink)
    }
    fn resume(&self, sid: &str, cursor: crate::wire::Cursor) {
        self.list.resume(sid, cursor);
    }
    fn page(&self, page: &Page, person: Option<&[u8]>) -> Result<Frame, crate::conn::ConnError> {
        self.list.page(page, person)
    }
    fn later(
        &self,
        request: crate::conn::Later<'_>,
        person: Option<&[u8]>,
        reply: crate::conn::Reply,
    ) -> Option<crate::conn::Reply> {
        if let crate::conn::Later::Page(page) = &request
            && page.stream.as_str().starts_with("chat:")
        {
            let rows: Vec<serde_json::Value> = Vec::new();
            let answer = serde_json::json!({"sid": page.sid, "rows": rows});
            reply.answer(Frame::json(FrameKind::Page, &answer).unwrap());
            return None;
        }
        self.list.later(request, person, reply)
    }
    fn end(&self, sid: &str) {
        self.ended.lock().unwrap().push(sid.to_owned());
        self.list.end(sid);
    }
}

/// Decision 299: a relayed page waiting on a silent origin holds the connection up for
/// nothing. A chat `page`, a `credit` and an `unsub` sent after it are served at once, and a
/// second relayed page answers `busy` at once.
#[tokio::test]
async fn a_relayed_page_waiting_on_its_origin_holds_up_no_other_request() {
    use crate::conn::{HubSource, Role, run};
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    async fn send(writer: &mut tokio::io::DuplexStream, request: serde_json::Value) {
        let frame = Frame::json(FrameKind::Request, &request).unwrap();
        writer.write_all(&frame.encode()).await.unwrap();
    }
    // Well inside RELAY_PAGE_DEADLINE: an answer that waits for the relayed page misses it.
    async fn receive(reader: &mut tokio::io::DuplexStream) -> Frame {
        tokio::time::timeout(Duration::from_secs(3), async {
            let mut header = [0; 4];
            reader.read_exact(&mut header).await.unwrap();
            let mut bytes = vec![0; u32::from_be_bytes(header) as usize];
            reader.read_exact(&mut bytes).await.unwrap();
            let mut encoded = header.to_vec();
            encoded.extend(bytes);
            Frame::from_encoded(&encoded).unwrap()
        })
        .await
        .expect("answered before the relayed page's deadline")
    }

    let (hub, peer) = pair();
    let relay = FakeRelay::new(peer, Answer::Silent);
    hub.set_page_relay(relay.clone());
    let source =
        Arc::new(ChatAndList { list: HubSource::new(hub.clone()), ended: Mutex::new(Vec::new()) });
    let serving = source.clone();
    let (mut client, server) = tokio::io::duplex(1 << 20);
    let (rd, wr) = tokio::io::split(server);
    let surfaces = ["list".to_owned(), "chat".to_owned()];
    let task =
        tokio::spawn(async move { run(rd, wr, serving, "test", &surfaces, Role::Local).await });
    send(
        &mut client,
        serde_json::json!({"method":"hello","params":{"clientKind":"test","protocol":2}}),
    )
    .await;
    assert_eq!(receive(&mut client).await.kind, FrameKind::Hello);
    for sid in ["s", "t"] {
        send(
            &mut client,
            serde_json::json!({"method":"sub","params":{"sid":sid,"stream":"list","view":"all"}}),
        )
        .await;
        assert_eq!(receive(&mut client).await.kind, FrameKind::Window);
    }
    // One relayed page, which its silent origin never answers.
    send(&mut client, serde_json::json!({"method":"page","params":view_page(PEER, None, 12_000)}))
        .await;
    // Behind it: a chat's page, a credit, an unsub, and a second relayed page.
    send(
        &mut client,
        serde_json::json!({"method":"page","params":{"sid":"c","stream":"chat:one"}}),
    )
    .await;
    send(&mut client, serde_json::json!({"method":"credit","params":{"sid":"s","consumed":0}}))
        .await;
    send(&mut client, serde_json::json!({"method":"unsub","params":{"sid":"t"}})).await;
    let mut second = view_page(PEER, None, 12_000);
    second.sid = "s".into();
    send(&mut client, serde_json::json!({"method":"page","params":second})).await;
    let chat = receive(&mut client).await;
    assert_eq!(chat.kind, FrameKind::Page);
    assert_eq!(chat.decode_json::<serde_json::Value>().unwrap()["sid"], "c");
    let busy = receive(&mut client).await;
    assert_eq!(busy.kind, FrameKind::Error);
    assert_eq!(busy.decode_json::<serde_json::Value>().unwrap()["code"], RELAY_BUSY);
    assert!(source.ended.lock().unwrap().iter().any(|sid| sid == "t"), "the unsub was served");
    assert_eq!(relay.asked().len(), 1, "the second relayed page asked nothing");
    assert_eq!(hub.relay_in_flight(PEER), 1, "the first still waits on its origin");
    drop(client);
    task.await.unwrap().unwrap();
}

/// The keys progress rule: with more origins than a page has room to ask, the first ones
/// that fit are asked in the order asked, and only the others' keys are `rest`; a page with
/// no room even for the first, and nothing else to answer, is `invalid_params`.
#[tokio::test]
async fn more_origins_than_fit_ask_the_first_ones_and_rest_the_others() {
    let (hub, peer) = pair();
    let origins = (0..40).map(|n| format!("o-{n:02}")).collect::<Vec<_>>();
    let mut relay = FakeRelay::new(peer, Answer::Peer);
    Arc::get_mut(&mut relay).unwrap().takes = origins.clone();
    hub.set_page_relay(relay.clone());
    let keys = origins
        .iter()
        .enumerate()
        .map(|(n, origin)| ListKey { origin: origin.clone(), ..key(n as u64) })
        .collect::<Vec<_>>();
    let frame = sent(&hub, &keys_page(keys.clone(), 256 * 1024)).answer().await.unwrap();
    let page: PageResult<Summary> = frame.decode_json().unwrap();
    let answered = page.rows.len();
    assert!(answered > 0 && answered < 40, "{answered} answered");
    assert_eq!(
        page.rows.iter().map(|row| (row.origin.clone(), row.chat_id.clone())).collect::<Vec<_>>(),
        keys[..answered]
            .iter()
            .map(|key| (key.origin.clone(), key.chat_id.clone()))
            .collect::<Vec<_>>(),
    );
    assert_eq!(page.rest, keys[answered..].to_vec());
    let asked = relay.asked().into_iter().map(|(origin, _)| origin).collect::<Vec<_>>();
    assert_eq!(asked, origins[..answered].to_vec(), "the first ones, in the order asked");
    // No room for even the first origin, and nothing else to answer: the page leaves less
    // than a page's least budget once the key is charged.
    let tight = keys_page([keys[0].clone()], 8192 + 1 + 50);
    assert!(matches!(hub.relayed_page(&tight), Some(Err(HubError::InvalidPage))));
}

/// A relay that sends a view page under a shorter sid than the asker's (1 byte against 200):
/// the origin's page is sized so the asker's frame, under the asker's sid, still fits its `max_bytes`.
#[tokio::test]
async fn a_relay_sending_under_a_shorter_sid_still_fits_the_askers_budget() {
    // An origin as long as `local`: renaming adds nothing, so the page keeps no room for it.
    const SAME: &str = "peer5";
    let (hub, peer) = pair();
    let mut relay = FakeRelay::new(peer, Answer::Peer);
    let fake = Arc::get_mut(&mut relay).unwrap();
    fake.sid = Some("r".into());
    fake.takes = vec![SAME.into()];
    hub.set_page_relay(relay.clone());
    let sid = "s".repeat(200);
    let mut walked = Vec::new();
    let mut after = None;
    loop {
        let mut request = view_page(SAME, after.clone(), 12_000);
        request.sid = sid.clone();
        let frame = sent(&hub, &request).answer().await.expect("fits the asker's budget");
        assert!(frame.encoded_len() <= 12_000);
        let page: PageResult<Summary> = frame.decode_json().unwrap();
        assert_eq!(page.sid, sid);
        walked.extend(ids(&page));
        if !page.has_after {
            break;
        }
        after = page.after_key;
    }
    assert_eq!(walked.len(), 100);
    // The origin's page leaves room for the asker's sid, whatever sid the relay sends under.
    let asked = relay.asked();
    assert!(!asked.is_empty());
    for (_, page) in asked {
        assert_eq!(page.max_bytes as usize, 12_000 - sid.len());
    }
}
