use super::*;

/// A round of 200 samples whose p95 is `p95`.
fn round(p95: u128) -> Vec<u128> {
    let mut samples = vec![p95 / 2; 189];
    samples.extend(std::iter::repeat_n(p95, 11));
    samples
}

fn notices(lines: &[String]) -> Vec<&String> {
    lines.iter().filter(|line| line.starts_with("GATE_ROUND_SPREAD")).collect()
}

#[test]
fn the_replay_append_gate_at_a59587e5_is_named() {
    // cmux#43438 at a59587e5: round one did the real append, rounds two to five timed the
    // equal-row return. The best rounds read 2,004 against 1,993 ns (0.995x).
    let foreign = [9_700, 2_004, 2_400, 2_800, 3_100].map(round).to_vec();
    let own = [14_500, 1_993, 2_300, 2_700, 3_000].map(round).to_vec();
    let lines = report_lines("replay-append-at-a59587e5", &[("small", &foreign), ("god", &own)]);
    assert_eq!(best_p95(&foreign), 2_004);
    assert_eq!(best_p95(&own), 1_993);
    assert_eq!(
        notices(&lines),
        [
            "GATE_ROUND_SPREAD row=replay-append-at-a59587e5 side=small round=1 p95=9700 median_round_p95=2800 factor=2",
            "GATE_ROUND_SPREAD row=replay-append-at-a59587e5 side=god round=1 p95=14500 median_round_p95=2700 factor=2",
        ]
    );
}

#[test]
fn rounds_that_did_the_same_work_say_nothing() {
    let small = [10_151, 10_400, 9_900, 11_200, 10_610].map(round).to_vec();
    let god = [10_260, 12_000, 10_900, 11_500, 13_100].map(round).to_vec();
    let lines = report_lines("replay-append-at-a59587e5", &[("small", &small), ("god", &god)]);
    assert!(notices(&lines).is_empty(), "{lines:#?}");
}

#[test]
fn every_round_of_both_sides_is_printed() {
    let small = [100, 110, 120].map(round).to_vec();
    let god = [130, 140, 150].map(round).to_vec();
    let lines = report_lines("row", &[("small", &small), ("god", &god)]);
    assert_eq!(lines.len(), 6);
    assert_eq!(lines[0], "GATE_ROUND row=row side=small round=1 p95=100");
    assert_eq!(lines[5], "GATE_ROUND row=row side=god round=3 p95=150");
}

fn pair_notices(lines: &[String]) -> Vec<&String> {
    lines.iter().filter(|line| line.starts_with("GATE_ROUND_PAIR_SPREAD")).collect()
}

#[test]
fn two_rounds_far_apart_are_compared_with_each_other() {
    // Each round is within 2x of the median round (10,000 ns), so the median check says
    // nothing, yet rounds one and three are 3.7x apart: one of them did different work.
    let small = [5_100, 10_000, 19_000].map(round).to_vec();
    let god = [10_000, 10_100, 10_200].map(round).to_vec();
    let lines = report_lines("row", &[("small", &small), ("god", &god)]);
    assert!(notices(&lines).is_empty(), "{lines:#?}");
    assert_eq!(
        pair_notices(&lines),
        [
            "GATE_ROUND_PAIR_SPREAD row=row side=small fast_round=1 fast_p95=5100 slow_round=3 slow_p95=19000 factor=2"
        ]
    );
}

#[test]
fn the_replay_append_gate_at_a59587e5_names_its_farthest_rounds() {
    let foreign = [9_700, 2_004, 2_400, 2_800, 3_100].map(round).to_vec();
    let own = [14_500, 1_993, 2_300, 2_700, 3_000].map(round).to_vec();
    let lines = report_lines("replay-append-at-a59587e5", &[("small", &foreign), ("god", &own)]);
    assert_eq!(
        pair_notices(&lines),
        [
            "GATE_ROUND_PAIR_SPREAD row=replay-append-at-a59587e5 side=small fast_round=2 fast_p95=2004 slow_round=1 slow_p95=9700 factor=2",
            "GATE_ROUND_PAIR_SPREAD row=replay-append-at-a59587e5 side=god fast_round=2 fast_p95=1993 slow_round=1 slow_p95=14500 factor=2",
        ]
    );
}

#[test]
fn rounds_within_the_factor_of_each_other_make_no_pair_notice() {
    let small = [10_151, 10_400, 9_900, 11_200, 10_610].map(round).to_vec();
    let god = [10_000, 19_999, 12_000].map(round).to_vec();
    let lines = report_lines("row", &[("small", &small), ("god", &god)]);
    assert!(pair_notices(&lines).is_empty(), "{lines:#?}");
}

#[test]
fn a_round_far_below_the_median_is_named_too() {
    let notices = spread_notices("row", "god", &[10_000, 10_500, 2_000, 9_800, 10_200], 2.0);
    assert_eq!(notices.len(), 1);
    assert!(notices[0].contains("round=3 p95=2000"), "{notices:?}");
}

#[test]
#[should_panic(expected = "gate row row: side god round 2 has no samples")]
fn an_empty_round_is_refused_by_name() {
    let small = [100, 110, 120].map(round).to_vec();
    let god = vec![round(100), Vec::new(), round(120)];
    report_lines("row", &[("small", &small), ("god", &god)]);
}

#[test]
#[should_panic(expected = "gate row row: side god has no rounds")]
fn a_side_with_no_rounds_is_refused_by_name() {
    let small = [100, 110, 120].map(round).to_vec();
    report_lines("row", &[("small", &small), ("god", &[])]);
}

#[test]
#[should_panic(expected = "p95 of no samples")]
fn an_empty_god_side_cannot_pass_a_ratio_gate() {
    // `god <= small * 1.2` held when p95 answered 0 for no samples.
    let small = p95(&round(10_000));
    let god = p95(&[]);
    assert!(god > small * 12 / 10, "an empty god side passed: {god} vs {small}");
}

#[test]
#[should_panic(expected = "p95 of no samples")]
fn best_p95_of_an_empty_round_is_refused() {
    best_p95(&[round(100), Vec::new()]);
}

#[test]
#[should_panic(expected = "best p95 of no rounds")]
fn best_p95_of_no_rounds_is_refused() {
    best_p95(&[]);
}
