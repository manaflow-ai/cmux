use super::*;

fn participant(
    id: &str,
    kind: &str,
    name: Option<&str>,
    device: Option<&str>,
    viewport: Option<(u32, u32)>,
) -> SizingParticipant {
    SizingParticipant {
        id: id.into(),
        device_kind: kind.into(),
        device_name: name.map(Into::into),
        display_name: None,
        device_id: device.map(Into::into),
        viewport: viewport.map(|(cols, rows)| SizingGrid { cols, rows }),
    }
}

/// The fixture the Swift TerminalSizingPresentationTests drew: this Mac's
/// pane, this phone, another phone off screen and another Mac.
fn input() -> SizingViewInput {
    SizingViewInput {
        has_state: true,
        reason: "smallest".into(),
        owners: vec!["c2".into()],
        participants: vec![
            participant("c1", "mac", Some("Mac mini"), None, Some((120, 39))),
            participant("c2", "iphone", Some("Aziz's iPhone"), Some("ios-1"), Some((53, 40))),
            participant("c3", "iphone", Some("Test iPhone"), Some("ios-2"), None),
            participant("c4", "mac", None, None, Some((200, 60))),
        ],
        self_participant: Some("c2".into()),
        mac_participants: vec!["c1".into()],
        this_device_id: Some("ios-1".into()),
    }
}

fn tokens(rows: &[SizingOrderRow]) -> Vec<&str> {
    rows.iter().map(|r| r.token.as_str()).collect()
}

#[test]
fn rows_name_each_viewer_and_its_size() {
    let rows = terminal_sizing_rows(input());
    let titles: Vec<_> = rows.iter().map(|r| r.title.as_str()).collect();
    assert_eq!(titles, ["This Mac", "This iPhone", "Test iPhone", "Another Mac"]);
    let details: Vec<_> = rows.iter().map(|r| r.detail.as_str()).collect();
    assert_eq!(details, ["120×39", "53×40", "Not showing it", "200×60"]);
    let owners: Vec<_> = rows.iter().map(|r| r.sets_size).collect();
    assert_eq!(owners, [false, true, false, false]);
    let symbols: Vec<_> = rows.iter().map(|r| r.symbol.as_str()).collect();
    assert_eq!(symbols, ["laptopcomputer", "iphone", "iphone", "laptopcomputer"]);
}

#[test]
fn no_state_draws_nothing() {
    let none = SizingViewInput { has_state: false, ..input() };
    assert!(terminal_sizing_rows(none.clone()).is_empty());
    assert_eq!(terminal_sizing_reason(none.clone()), None);
    assert_eq!(tokens(&terminal_sizing_order_rows(none, vec![])), ["mac", "device:ios-1"]);
}

#[test]
fn this_phone_is_known_by_device_id_but_never_a_desktop() {
    let mut i = input();
    i.self_participant = None;
    assert_eq!(terminal_sizing_title(i.clone(), i.participants[1].clone()), "This iPhone");
    let tui = participant("t", "tui", None, Some("ios-1"), None);
    assert_eq!(terminal_sizing_title(i, tui), "A terminal");
}

#[test]
fn unnamed_viewers_read_as_their_kind() {
    let i = input();
    let title = |kind: &str| terminal_sizing_title(i.clone(), participant("x", kind, None, None, None));
    assert_eq!(title("mac"), "Another Mac");
    assert_eq!(title("iphone"), "An iPhone");
    assert_eq!(title("ipad"), "An iPad");
    assert_eq!(title("tui"), "A terminal");
    assert_eq!(title("unknown"), "Another device");
    let mut shown = participant("x", "iphone", None, None, None);
    shown.display_name = Some("Pixel".into());
    assert_eq!(terminal_sizing_title(i, shown), "Pixel");
}

#[test]
fn reason_names_who_sets_the_grid() {
    assert_eq!(terminal_sizing_reason(input()).as_deref(), Some("Fits the smallest viewer: This iPhone"));
    let with = |reason: &str, owners: &[&str]| {
        terminal_sizing_reason(SizingViewInput {
            reason: reason.into(),
            owners: owners.iter().map(|s| (*s).into()).collect(),
            ..input()
        })
        .unwrap()
    };
    assert_eq!(with("latest", &["c1"]), "Set by This Mac");
    assert_eq!(with("latest", &[]), "Set by the device active last");
    assert_eq!(with("largest", &["c1", "c4"]), "Fits the largest viewer: This Mac and Another Mac");
    assert_eq!(
        with("smallest", &["c1", "c2", "c3"]),
        "Fits the smallest viewer: This Mac, This iPhone, and Test iPhone"
    );
    assert_eq!(with("smallest", &[]), "Fits the smallest viewer");
    assert_eq!(with("fixed", &["c1"]), "Fixed size");
    assert_eq!(with("held", &["c1"]), "Kept from the last viewer");
    assert_eq!(with("priority", &["c3"]), "Set by Test iPhone, first in order");
    assert_eq!(with("priority", &[]), "Set by the first device in order");
    assert_eq!(with("priority-fallback", &["c3"]), "Set by Test iPhone, active last");
    assert_eq!(with("priority-fallback", &[]), "Set by the device active last");
}

#[test]
fn order_keeps_stored_slots_then_adds_everyone_in_sight() {
    let rows = terminal_sizing_order_rows(input(), vec!["device:ios-2".into(), "device:gone".into()]);
    assert_eq!(tokens(&rows), ["device:ios-2", "device:gone", "mac", "device:ios-1"]);
    let titles: Vec<_> = rows.iter().map(|r| r.title.as_str()).collect();
    assert_eq!(titles, ["Test iPhone", "Another device", "This Mac", "This iPhone"]);
    let symbols: Vec<_> = rows.iter().map(|r| r.symbol.as_str()).collect();
    assert_eq!(symbols, ["iphone", "display", "laptopcomputer", "iphone"]);

    // This Mac's own pane never shows as a device row; another Mac does.
    let mut i = input();
    i.participants[0].device_id = Some("mac-1".into());
    i.participants[3].device_id = Some("mac-2".into());
    let rows = terminal_sizing_order_rows(i, vec!["device:mac-1".into()]);
    assert_eq!(tokens(&rows), ["device:mac-1", "mac", "device:ios-1", "device:ios-2", "device:mac-2"]);
    assert_eq!(rows[0].title, "Another device");
    assert_eq!(rows[4].title, "Another Mac");
    assert_eq!(rows[4].symbol, "laptopcomputer");
}

#[test]
fn empty_order_puts_this_mac_and_this_phone_first() {
    let rows = terminal_sizing_order_rows(input(), vec![]);
    assert_eq!(tokens(&rows), ["mac", "device:ios-1", "device:ios-2"]);
}

#[test]
fn order_drops_bad_tokens_and_caps_at_max_with_pins_kept() {
    let mut i = input();
    i.mac_participants = vec!["c1".into()];
    i.self_participant = None;
    i.participants = vec![
        participant("c1", "mac", None, None, None),
        participant("c2", "iphone", None, Some("has space"), None),
        participant("c3", "tui", None, Some("host/name"), None),
        participant("c4", "iphone", None, Some(&"x".repeat(129)), None),
    ];
    for index in 0..40 {
        i.participants.push(participant(
            &format!("p{index}"),
            "iphone",
            None,
            Some(&format!("phone-{index}")),
            None,
        ));
    }
    let rows = terminal_sizing_order_rows(i, vec!["device:bad token".into(), "mac".into()]);
    let t = tokens(&rows);
    assert_eq!(t.len(), MAX_ORDER);
    assert!(t.iter().all(|t| token_valid(t)));
    assert_eq!(t[..2], ["mac", "device:ios-1"]);
    assert!(!t.contains(&"device:has space"));
    assert!(!t.contains(&"device:host/name"));

    // A full stored order still leaves room for this Mac and this phone.
    let full: Vec<String> = (0..40).map(|n| format!("device:old-{n}")).collect();
    let rows = terminal_sizing_order_rows(input(), full);
    let t = tokens(&rows);
    assert_eq!(t.len(), MAX_ORDER);
    assert_eq!(t[MAX_ORDER - 2..], ["mac", "device:ios-1"]);
}

#[test]
fn token_rules() {
    assert!(host_size_token_valid("mac".into()));
    assert!(host_size_token_valid("device:ios-1.a_b:c".into()));
    assert!(host_size_token_valid(format!("device:{}", "x".repeat(128))));
    assert!(!host_size_token_valid(format!("device:{}", "x".repeat(129))));
    assert!(!host_size_token_valid("device:".into()));
    assert!(!host_size_token_valid("device:has space".into()));
    assert!(!host_size_token_valid("device:é".into()));
    assert!(!host_size_token_valid("Mac".into()));
    assert_eq!(host_size_device_token("ios-1".into()), "device:ios-1");
    assert_eq!(host_size_token_device_id("device:ios-1".into()).as_deref(), Some("ios-1"));
    assert_eq!(host_size_token_device_id("device:".into()), None);
    assert_eq!(host_size_token_device_id("mac".into()), None);
    assert_eq!(host_size_max_order(), 32);
}

#[test]
fn desktops_and_labels() {
    for kind in ["mac", "tui", "linux", "windows"] {
        assert!(terminal_sizing_is_desktop(kind.into()));
    }
    for kind in ["iphone", "ipad", "unknown"] {
        assert!(!terminal_sizing_is_desktop(kind.into()));
    }
    assert_eq!(terminal_sizing_grid_label(SizingGrid { cols: 120, rows: 40 }), "120×40");
}

#[test]
fn reorder_moves_like_on_move() {
    let t = |v: &[&str]| v.iter().map(|s| (*s).to_string()).collect::<Vec<_>>();
    let rows = t(&["mac", "device:ios-1", "device:ios-2"]);
    assert_eq!(
        terminal_sizing_reordered(rows.clone(), vec![1], 0),
        t(&["device:ios-1", "mac", "device:ios-2"])
    );
    assert_eq!(
        terminal_sizing_reordered(rows.clone(), vec![0], 3),
        t(&["device:ios-1", "device:ios-2", "mac"])
    );
    assert_eq!(
        terminal_sizing_reordered(rows.clone(), vec![0, 2], 1),
        t(&["mac", "device:ios-2", "device:ios-1"])
    );
    assert_eq!(terminal_sizing_reordered(rows.clone(), vec![2], 2), rows);
    // Out of range never crashes.
    assert_eq!(terminal_sizing_reordered(rows.clone(), vec![9], 99), rows);
    assert_eq!(terminal_sizing_reordered(rows, vec![0], 99), t(&["device:ios-1", "device:ios-2", "mac"]));
}
