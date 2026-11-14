use super::*;
use crate::wire::ListKey;

struct Provider {
    rows: HashMap<RowKey, Arc<Summary>>,
    reads: Mutex<Vec<RowKey>>,
}

impl PageProvider for Provider {
    fn row(&self, key: &RowKey) -> std::io::Result<Option<Arc<Summary>>> {
        self.reads.lock().unwrap().push(key.clone());
        Ok(self.rows.get(key).cloned())
    }
}

fn request(keys: Vec<ListKey>, max: u32) -> Page {
    Page {
        sid: "keys".into(),
        stream: "list".into(),
        before: None,
        after: None,
        keys: Some(keys.into_iter().map(PageKey::Summary).collect()),
        view: None,
        max_bytes: max,
        filter: None,
        edition: None,
        fold: None,
    }
}

#[test]
fn large_keyed_pages_make_progress_without_reading_rest() {
    check_large_keyed_pages(false);
}

#[test]
fn escaped_keyed_rows_keep_the_frame_bound_across_continuations() {
    check_large_keyed_pages(true);
}

fn check_large_keyed_pages(escaped: bool) {
    let mut rows = HashMap::new();
    let mut keys = Vec::new();
    for n in 0..100 {
        let mut row = Summary::new(format!("{n:03}{}", "x".repeat(253)));
        row.parent = Some(RowKey::new(
            if escaped { "\u{1}" } else { "p" }.repeat(256),
            if escaped { "\u{2}" } else { "q" }.repeat(256),
        ));
        row.folder = Some(if escaped { "\u{3}" } else { "f" }.repeat(1024));
        row.title = "t".repeat(256);
        row.extra =
            RawValue::from_string(format!("{{\"preview\":\"{}\"}}", "v".repeat(1300))).unwrap();
        let row = row.prepare().unwrap();
        assert!(serde_json::to_vec(&row).unwrap().len() > 3000);
        keys.push(wire_key(SortKey::of(&row)));
        rows.insert(row.key(), Arc::new(row));
    }
    let expected: Vec<_> = keys.iter().map(|key| book_key(key).row).collect();
    let provider = Arc::new(Provider { rows, reads: Mutex::new(Vec::new()) });
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    hub.set_page_provider(provider.clone());
    let mut seen = Vec::new();
    let mut replies = 0;
    while !keys.is_empty() {
        let before = provider.reads.lock().unwrap().len();
        let frame = hub.page(&request(keys.clone(), 64 * 1024)).unwrap();
        assert!(frame.encoded_len() <= 64 * 1024);
        let page: PageResult<Summary> = frame.decode_json().unwrap();
        assert!(!page.rows.is_empty());
        assert!(page.missing.is_empty() && page.unknown.is_empty());
        assert_eq!(provider.reads.lock().unwrap().len() - before, page.rows.len());
        assert_eq!(page.rest, keys.iter().skip(page.rows.len()).cloned().collect::<Vec<_>>());
        seen.extend(page.rows.iter().map(Summary::key));
        keys = page.rest;
        replies += 1;
        assert!(replies <= 100);
    }
    assert!(replies > 1);
    assert_eq!(seen, expected);
    assert_eq!(*provider.reads.lock().unwrap(), expected);
}

#[test]
fn a_single_row_over_budget_is_invalid_instead_of_a_nonprogressing_rest() {
    let mut row = Summary::new("x".repeat(256));
    row.parent = Some(RowKey::new("\u{1}".repeat(256), "\u{2}".repeat(256)));
    row.fork_of = Some(acpmux_book::index::ForkOf {
        key: RowKey::new("\u{3}".repeat(256), "\u{4}".repeat(256)),
        seq: 1,
    });
    row.folder = Some("\u{5}".repeat(1024));
    let row = row.prepare().unwrap();
    assert!(serde_json::to_vec(&row).unwrap().len() > 9000);
    let key = wire_key(SortKey::of(&row));
    let (hub, _writer) = Hub::new(SummaryIndex::new().apply(1, row));
    assert!(matches!(hub.page(&request(vec![key], 9000)), Err(HubError::InvalidPage)));
}

#[test]
fn missing_and_unknown_are_answered_and_never_repeated_in_rest() {
    let local = wire_key(SortKey::of(&Summary::new("missing")));
    let mut remote = Summary::new("unknown");
    remote.origin = "peer".into();
    let remote = wire_key(SortKey::of(&remote));
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    let page: PageResult<Summary> = hub
        .page(&request(vec![local.clone(), remote.clone()], 64 * 1024))
        .unwrap()
        .decode_json()
        .unwrap();
    assert_eq!(page.missing, vec![local]);
    assert_eq!(page.unknown, vec![remote]);
    assert!(page.rest.is_empty());
}

#[test]
fn folder_keys_are_refused_before_any_summary_provider_read() {
    let provider = Arc::new(Provider { rows: HashMap::new(), reads: Mutex::new(Vec::new()) });
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    hub.set_page_provider(provider.clone());
    for mixed in [false, true] {
        let mut keys = Vec::new();
        if mixed {
            keys.push(PageKey::Summary(wire_key(SortKey::of(&Summary::new("cold")))));
        }
        keys.push(PageKey::Folder(crate::wire::FolderIdentity {
            origin: "local".into(),
            folder: "/work".into(),
        }));
        let mut page = request(Vec::new(), 64 * 1024);
        page.keys = Some(keys);
        assert!(matches!(hub.page(&page), Err(HubError::InvalidPage)));
        assert!(provider.reads.lock().unwrap().is_empty());
    }
}
