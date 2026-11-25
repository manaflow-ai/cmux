//! The rounds of a best-of-rounds gate, compared with each other (the handoff issue).
//!
//! A v2 gate that reports "best p95 of five rounds" hides a round that did different work
//! from the rest: cmux#43438's replay-append gate at `a59587e5` applied the same rows in
//! every round, so rounds two to five timed the writer's equal-row return (about 2,000 to
//! 3,100 ns) against 9,700 to 14,500 ns in round one, and the best round read 0.995x.
//!
//! [`report`] prints every round's p95 for each side, always, and one notice line for each
//! round whose p95 is more than [`SPREAD_FACTOR`] from the median round's on its side, plus one
//! line when any two rounds on a side are more than that factor from each other. It is a
//! notice, not a failure, until a few runs on the shared CI machines show where a cold first
//! round is real.

/// How far one round's p95 may be from the median round's on the same side, either way,
/// before the gate says so.
pub const SPREAD_FACTOR: f64 = 2.0;

/// The nearest-rank p95 of `samples`.
///
/// Panics on no samples: any number it answered (0 would make an empty god side pass
/// `god <= small * 1.2`) would be a measurement of nothing.
pub fn p95(samples: &[u128]) -> u128 {
    assert!(!samples.is_empty(), "p95 of no samples: the gate measured nothing");
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    sorted[((sorted.len() * 95).saturating_add(99) / 100).saturating_sub(1)]
}

/// The lowest round p95. Panics on no rounds or an empty round, as [`p95`] does.
pub fn best_p95(rounds: &[Vec<u128>]) -> u128 {
    assert!(!rounds.is_empty(), "best p95 of no rounds: the gate measured nothing");
    rounds.iter().map(|round| p95(round)).fold(u128::MAX, u128::min)
}

/// Panics, naming the row, the side and the round, when a side has no rounds or a round has
/// no samples: a best-of-rounds gate with either compares nothing.
fn refuse_empty(row: &str, sides: &[(&str, &[Vec<u128>])]) {
    assert!(!sides.is_empty(), "gate row {row}: no sides to compare");
    for (side, rounds) in sides {
        assert!(!rounds.is_empty(), "gate row {row}: side {side} has no rounds");
        for (round, samples) in rounds.iter().enumerate() {
            assert!(
                !samples.is_empty(),
                "gate row {row}: side {side} round {} has no samples",
                round + 1
            );
        }
    }
}

/// The p95 of every sample of every round.
pub fn all_p95(rounds: &[Vec<u128>]) -> u128 {
    p95(&rounds.iter().flatten().copied().collect::<Vec<_>>())
}

/// The median of the round p95s (the lower one for an even count).
fn median(values: &[u128]) -> u128 {
    let mut sorted = values.to_vec();
    sorted.sort_unstable();
    sorted[(sorted.len() - 1) / 2]
}

/// One line for each round on one side whose p95 is more than `factor` from the side's
/// median round, naming the row, the side, the round and the two numbers.
pub fn spread_notices(row: &str, side: &str, round_p95s: &[u128], factor: f64) -> Vec<String> {
    if round_p95s.len() < 2 {
        return Vec::new();
    }
    let median = median(round_p95s).max(1);
    round_p95s
        .iter()
        .enumerate()
        .filter(|&(_, &p95)| {
            let p95 = p95.max(1) as f64;
            let median = median as f64;
            p95 > median * factor || p95 * factor < median
        })
        .map(|(round, &p95)| {
            format!(
                "GATE_ROUND_SPREAD row={row} side={side} round={} p95={p95} median_round_p95={median} factor={factor}",
                round + 1
            )
        })
        .collect()
}

/// One line when two rounds on one side are more than `factor` from each other, naming the
/// row, the side, the fastest and the slowest round and their two numbers.
///
/// This compares each round with every other one: some pair is more than `factor` apart
/// exactly when the slowest and the fastest round are. The median check alone lets two rounds
/// be up to `factor` squared apart (5,100 and 19,000 ns around a 10,000 ns median) and says
/// nothing.
pub fn pair_spread_notice(
    row: &str,
    side: &str,
    round_p95s: &[u128],
    factor: f64,
) -> Option<String> {
    if round_p95s.len() < 2 {
        return None;
    }
    let (fast_round, &fast) = round_p95s.iter().enumerate().min_by_key(|&(_, p95)| *p95)?;
    let (slow_round, &slow) = round_p95s.iter().enumerate().max_by_key(|&(_, p95)| *p95)?;
    (slow.max(1) as f64 > fast.max(1) as f64 * factor).then(|| {
        format!(
            "GATE_ROUND_PAIR_SPREAD row={row} side={side} fast_round={} fast_p95={fast} slow_round={} slow_p95={slow} factor={factor}",
            fast_round + 1,
            slow_round + 1
        )
    })
}

/// Every round's p95 line for every side, then the spread notices. Returned as well as
/// printed so a gate's test can read them. Panics on an empty side or round
/// ([`refuse_empty`]).
pub fn report_lines(row: &str, sides: &[(&str, &[Vec<u128>])]) -> Vec<String> {
    refuse_empty(row, sides);
    let mut lines = Vec::new();
    let mut notices = Vec::new();
    for (side, rounds) in sides {
        let round_p95s: Vec<u128> = rounds.iter().map(|round| p95(round)).collect();
        for (round, p95) in round_p95s.iter().enumerate() {
            lines.push(format!("GATE_ROUND row={row} side={side} round={} p95={p95}", round + 1));
        }
        notices.extend(spread_notices(row, side, &round_p95s, SPREAD_FACTOR));
        notices.extend(pair_spread_notice(row, side, &round_p95s, SPREAD_FACTOR));
    }
    lines.extend(notices);
    lines
}

/// Print [`report_lines`] to stderr, where every gate's lines go, and return them.
pub fn report(row: &str, sides: &[(&str, &[Vec<u128>])]) -> Vec<String> {
    let lines = report_lines(row, sides);
    for line in &lines {
        eprintln!("{line}");
    }
    lines
}

#[cfg(test)]
mod tests {
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
        let lines =
            report_lines("replay-append-at-a59587e5", &[("small", &foreign), ("god", &own)]);
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
        let lines =
            report_lines("replay-append-at-a59587e5", &[("small", &foreign), ("god", &own)]);
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
}
