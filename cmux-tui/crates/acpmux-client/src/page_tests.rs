use super::*;

#[test]
fn constants_hold_the_page_contract() {
    assert_eq!(MAX_BATCH_BYTES, 64 * 1024);
    assert_eq!(MAX_REPLY_BYTES, 256 * 1024);
    assert_eq!(MAX_WANTED_KEYS, 4096);
    assert_eq!(MAX_QUESTIONS, 16);
    assert_eq!(MAX_ROWS, 200);
}

#[test]
fn page_ids_are_opaque_and_questions_are_bounded() {
    let mut driver = ListDriver::new();
    for index in 0..MAX_QUESTIONS {
        driver.slots.insert(format!("s{index}"), "all".into());
        driver.heads.insert(
            format!("s{index}"),
            Head {
                slot: "all".into(),
                before_key: Some(ListKey {
                    last_activity: index as u64,
                    chat_id: index.to_string(),
                    origin: "local".into(),
                    past: false,
                }),
                edition: 0,
                rows: Vec::new(),
                stopped: false,
            },
        );
    }
    for index in 0..MAX_QUESTIONS {
        let request = PageRequest {
            sid: format!("s{index}"),
            kind: PageKind::Older,
            key: None,
            folder: None,
            cold: false,
        };
        assert!(driver.page(request).is_ok());
    }
    let request = PageRequest {
        sid: "s0".into(),
        kind: PageKind::Older,
        key: None,
        folder: None,
        cold: false,
    };
    assert_eq!(driver.page(request), Err(DriverError::Busy));
}

#[test]
fn a_driver_opens_more_than_sixteen_sids() {
    let mut driver = ListDriver::new();
    for n in 0..40 {
        let request = OpenRequest { sid: format!("s{n}"), view: ListView::All };
        assert_eq!(driver.open(request), Ok(format!("s{n}")), "sid {n}");
    }
    assert_eq!(driver.slots.len(), 40);
}

#[test]
fn wrong_taken_does_not_release_batch() {
    let mut driver = ListDriver::new();
    driver.held = Some(HeldBatch { number: 4, changes: Vec::new() });
    assert!(driver.taken(3).is_err());
    assert!(driver.held.is_some());
    assert!(driver.taken(4).is_ok());
    assert!(driver.held.is_none());
}

#[test]
fn windows_and_whole_report_walk_completion_and_slot_membership() {
    let mut driver = ListDriver::new();
    driver.slots.insert("s".into(), "all".into());
    driver.heads.insert(
        "s".into(),
        Head { slot: "all".into(), before_key: None, edition: 0, rows: Vec::new(), stopped: false },
    );
    let window = crate::wire::Window {
        sid: "s".into(),
        cursor: 1,
        rows: vec![json!({"chatId":"c","origin":"local"})],
        has_before: true,
        has_after: false,
        edition: 1,
        origins: Vec::new(),
        before_key: None,
        after_key: None,
    };
    let event = driver.project(Change::Window(window)).unwrap().unwrap();
    assert!(matches!(&event, ListEvent::Rows { complete: false, slot, .. } if slot == "all"));
    let whole =
        driver.project(Change::Whole { sid: "s".into(), cursor: crate::wire::Cursor(2) }).unwrap();
    assert!(whole.is_none());
    let json = serde_json::to_string(&ListEvent::Page {
        sid: "s".into(),
        id: "q".into(),
        rows: Vec::new(),
        has_before: true,
        has_after: false,
        complete: false,
        cold_unread: false,
        deeper: Vec::new(),
        missing: Vec::new(),
        unknown: Vec::new(),
    })
    .unwrap();
    assert!(json.contains("hasBefore"));
    assert!(!json.contains("has_before"));
}

#[test]
fn question_error_stops_in_flight_question_and_allows_a_new_slot() {
    let mut driver = ListDriver::new();
    driver.questions.insert(
        "q".into(),
        Question {
            sid: "s".into(),
            kind: PageKind::Family,
            request: Page::new("s", "list", crate::wire::PageSide::Before, 1),
            in_flight: true,
            complete: false,
            failed: false,
            closed: false,
            rows: 0,
            created: 1,
        },
    );
    let event = driver
        .project(Change::Error {
            method: "page".into(),
            sid: Some("s".into()),
            id: Some("q".into()),
            code: "list.lost".into(),
        })
        .unwrap()
        .unwrap();
    assert!(matches!(event, ListEvent::Error { id: Some(id), .. } if id == "q"));
    assert!(!driver.questions["q"].in_flight);
    assert!(driver.questions["q"].failed);
}

#[test]
fn closing_in_flight_question_tombstones_until_reply_then_frees_slot() {
    let mut driver = ListDriver::new();
    driver.slots.insert("s".into(), "all".into());
    driver.heads.insert(
        "s".into(),
        Head {
            slot: "all".into(),
            before_key: Some(ListKey {
                last_activity: 1,
                chat_id: "head".into(),
                origin: "local".into(),
                past: false,
            }),
            edition: 0,
            rows: Vec::new(),
            stopped: false,
        },
    );
    driver.questions.insert(
        "q".into(),
        Question {
            sid: "s".into(),
            kind: PageKind::Older,
            request: Page::new("s", "list", crate::wire::PageSide::Before, 1),
            in_flight: true,
            complete: false,
            failed: false,
            closed: false,
            rows: 0,
            created: 1,
        },
    );
    driver.close_question("s", "q").unwrap();
    assert!(driver.questions["q"].closed);
    assert_eq!(
        driver.page(PageRequest {
            sid: "s".into(),
            kind: PageKind::Older,
            key: None,
            folder: None,
            cold: false,
        }),
        Err(DriverError::Busy)
    );
    let page = crate::wire::PageResult {
        sid: "s".into(),
        rows: Vec::new(),
        has_before: false,
        has_after: false,
        cold_unread: false,
        deeper: Vec::new(),
        before_key: None,
        after_key: None,
        missing: Vec::new(),
        unknown: Vec::new(),
        rest: Vec::new(),
    };
    assert!(driver.project(Change::Page(page)).unwrap().is_none());
    assert!(!driver.questions.contains_key("q"));
    assert!(
        driver
            .page(PageRequest {
                sid: "s".into(),
                kind: PageKind::Older,
                key: None,
                folder: None,
                cold: false,
            })
            .is_ok()
    );
}

#[test]
fn reconnect_on_is_emitted_after_window_or_resume_end() {
    let mut driver = ListDriver::new();
    driver.slots.insert("s".into(), "all".into());
    driver.heads.insert(
        "s".into(),
        Head { slot: "all".into(), before_key: None, edition: 0, rows: Vec::new(), stopped: false },
    );
    driver.resuming.insert("s".into());
    let window = crate::wire::Window {
        sid: "s".into(),
        cursor: 1,
        rows: Vec::new(),
        has_before: false,
        has_after: false,
        edition: 1,
        origins: Vec::new(),
        before_key: None,
        after_key: None,
    };
    assert!(matches!(driver.project(Change::Window(window)), Ok(Some(ListEvent::Rows { .. }))));
    assert!(matches!(driver.synthetic.pop_front(), Some(ListEvent::On { sid }) if sid == "s"));

    driver.resuming.insert("s".into());
    assert!(matches!(
        driver.project(Change::ResumeEnd { sid: "s".into(), cursor: crate::wire::Cursor(2) }),
        Ok(Some(ListEvent::On { sid })) if sid == "s"
    ));
}

#[test]
fn deferred_events_cross_batch_without_reprojection() {
    let mut driver = ListDriver::new();
    let row = |chat_id: &str| ListEvent::Rows {
        sid: "s".into(),
        slot: "all".into(),
        upserts: vec![json!({"chatId": chat_id, "body": "x".repeat(40_000)})],
        remove: Vec::new(),
        complete: false,
    };
    for chat_id in ["a", "b"] {
        driver.deferred.push_back(DeferredChange {
            change: QueuedChange {
                change: Change::Whole { sid: "s".into(), cursor: crate::wire::Cursor(1) },
                sid: Some("s".into()),
                bytes: 0,
                charge: false,
            },
            event: row(chat_id),
        });
    }
    let first = driver.next_batch().unwrap().unwrap();
    assert_eq!(first.events.len(), 1);
    driver.taken(first.number).unwrap();
    let second = driver.next_batch().unwrap().unwrap();
    assert_eq!(second.events.len(), 1);
}

#[test]
fn older_head_stops_at_two_hundred_rows() {
    let mut driver = ListDriver::new();
    driver.slots.insert("s".into(), "all".into());
    driver.heads.insert(
        "s".into(),
        Head {
            slot: "all".into(),
            before_key: Some(ListKey {
                last_activity: 1,
                chat_id: "head".into(),
                origin: "local".into(),
                past: false,
            }),
            edition: 0,
            rows: Vec::new(),
            stopped: false,
        },
    );
    driver.questions.insert(
        "q".into(),
        Question {
            sid: "s".into(),
            kind: PageKind::Older,
            request: Page::new("s", "list", crate::wire::PageSide::Before, 1),
            in_flight: true,
            complete: false,
            failed: false,
            closed: false,
            rows: 0,
            created: 1,
        },
    );
    let rows = (0..200)
        .map(|index| json!({"chatId": format!("c{index}"), "origin": "local", "updatedMs": index}))
        .collect();
    let page = crate::wire::PageResult {
        sid: "s".into(),
        rows,
        has_before: true,
        has_after: false,
        cold_unread: false,
        deeper: Vec::new(),
        before_key: Some(ListKey {
            last_activity: 0,
            chat_id: "older".into(),
            origin: "local".into(),
            past: false,
        }),
        after_key: None,
        missing: Vec::new(),
        unknown: Vec::new(),
        rest: Vec::new(),
    };
    let event = driver.project(Change::Page(page)).unwrap().unwrap();
    assert!(matches!(event, ListEvent::Rows { complete: false, .. }));
    assert!(driver.heads["s"].stopped);
    assert_eq!(
        driver.page(PageRequest {
            sid: "s".into(),
            kind: PageKind::Older,
            key: None,
            folder: None,
            cold: false
        }),
        Err(DriverError::Limit("list.limit"))
    );
}
