use super::*;

#[test]
fn a_fleet_hold_line_names_who_why_and_when_it_lifts() {
    let hold = FleetHold {
        on: true,
        allow: vec!["coord*".into()],
        reason: Some("triage".into()),
        at: 1_000_000,
        until: Some(1_000_000 + 12 * 3_600_000),
        by: Some("interim-coord".into()),
        thaw_order: Vec::new(),
    };
    let line = fleet_hold_line_at(&hold, Some(7), 1_000_000 + 2 * 3_600_000);
    assert_eq!(
        line,
        "fleet hold on (7 chats held), set by interim-coord 2h00m ago: triage; lifts in \
             10h00m (`acpmux session release --fleet` lifts it now)"
    );
    let old = FleetHold { until: None, by: None, reason: None, ..hold };
    let line = fleet_hold_line_at(&old, None, 1_000_000 + 3 * 86_400_000);
    assert!(line.contains("set by an unnamed caller 3d00h ago; never lifts by itself"), "{line}");
    let ordered = FleetHold { thaw_order: vec!["*coord*".into(), "lane-*".into()], ..old };
    let line = fleet_hold_line_at(&ordered, None, 1_000_000);
    assert!(line.contains("; thaws *coord*, lane-* first ("), "{line}");
}
