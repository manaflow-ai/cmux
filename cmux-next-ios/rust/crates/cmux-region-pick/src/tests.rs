use super::*;
use crate::wasm::{BY_CALIBRATED, BY_FALLBACK, BY_MEASURED, IO_LEN, observe_ms, run};

const WNAM: usize = 0;
const ENAM: usize = 1;
const WEUR: usize = 3;
const APAC: usize = 5;

fn est(pairs: &[(usize, f64)]) -> [Option<f64>; N] {
    let mut e = [None; N];
    for &(r, ms) in pairs {
        e[r] = Some(ms);
    }
    e
}

fn learned(pairs: &[(usize, f64)]) -> [Option<Learned>; N] {
    let mut l = [None; N];
    for &(r, ms) in pairs {
        l[r] = Some(Learned { ms, n: 5 });
    }
    l
}

#[test]
fn region_order_matches_placement_ts() {
    let ts = include_str!("../../../../backend/src/placement.ts");
    let line = ts.lines().find(|l| l.contains("export const REGIONS")).expect("REGIONS in placement.ts");
    let quoted: Vec<&str> = line.split('"').skip(1).step_by(2).collect();
    assert_eq!(quoted, REGIONS);
}

#[test]
fn observe_seeds_then_averages() {
    let a = observe(None, 100.0).unwrap();
    assert_eq!(a, Learned { ms: 100.0, n: 1 });
    let b = observe(Some(a), 200.0).unwrap();
    assert_eq!(b, Learned { ms: 125.0, n: 2 });
}

#[test]
fn observe_refuses_junk() {
    let a = Some(Learned { ms: 80.0, n: 3 });
    for bad in [f64::NAN, f64::INFINITY, -1.0, MAX_MS + 1.0] {
        assert_eq!(observe(a, bad), a);
        assert_eq!(observe(None, bad), None);
    }
}

#[test]
fn nothing_learned_keeps_the_placement() {
    let e = est(&[(WNAM, 40.0), (ENAM, 90.0)]);
    let p = pick(&e, &[None; N], None, Some(ENAM));
    assert_eq!(p, Pick { region: Some(ENAM), by: By::Fallback, ms: None });
    assert_eq!(pick(&e, &[None; N], None, None).region, None);
}

#[test]
fn a_measured_detour_moves_the_pair() {
    // Geo says wnam (40 ms), but the pair's carrier detours there: 200 ms measured.
    let e = est(&[(WNAM, 40.0), (ENAM, 70.0), (WEUR, 150.0)]);
    let l = learned(&[(WNAM, 200.0)]);
    // The last mile guess is capped at 60: enam scores 130, 70 ms better, so enam gets a session.
    let p = pick(&e, &l, None, Some(WNAM));
    assert_eq!(p, Pick { region: Some(ENAM), by: By::Calibrated, ms: Some(130.0) });
    // Measured at 85 ms there, the pair stays.
    let l = learned(&[(WNAM, 200.0), (ENAM, 85.0)]);
    let p = pick(&e, &l, Some(ENAM), Some(WNAM));
    assert_eq!(p, Pick { region: Some(ENAM), by: By::Measured, ms: Some(85.0) });
}

#[test]
fn a_slow_last_mile_alone_does_not_wander() {
    // 160 measured on a 40 estimate, enam's 70 + 60 = 130 is within the 20 % margin: stay.
    let e = est(&[(WNAM, 40.0), (ENAM, 70.0)]);
    let l = learned(&[(WNAM, 160.0)]);
    assert_eq!(pick(&e, &l, None, Some(WNAM)).region, Some(WNAM));
    // Once a second region is measured, a region measured slower never takes the pair back.
    let l = learned(&[(WNAM, 150.0), (ENAM, 175.0)]);
    assert_eq!(pick(&e, &l, Some(WNAM), Some(WNAM)).region, Some(WNAM));
}

#[test]
fn offset_is_the_least_gap_capped() {
    let e = est(&[(WNAM, 10.0), (ENAM, 20.0), (WEUR, 30.0)]);
    let l = learned(&[(WNAM, 40.0), (ENAM, 50.0), (WEUR, 1000.0)]);
    assert_eq!(offset(&e, &l), 30.0);
    let l = learned(&[(WNAM, 140.0), (ENAM, 250.0)]);
    assert_eq!(offset(&e, &l), LAST_MILE_PRIOR_MS);
    let l = learned(&[(WNAM, 5.0)]);
    assert_eq!(offset(&e, &l), 0.0);
    assert_eq!(offset(&e, &[None; N]), 0.0);
}

#[test]
fn calibrated_region_can_win() {
    // wnam measured 120 on a 30 estimate (offset capped at 60); apac estimated 5 scores 65.
    let e = est(&[(WNAM, 30.0), (APAC, 5.0)]);
    let l = learned(&[(WNAM, 120.0)]);
    let p = pick(&e, &l, Some(WNAM), Some(WNAM));
    assert_eq!(p, Pick { region: Some(APAC), by: By::Calibrated, ms: Some(65.0) });
}

#[test]
fn hysteresis_keeps_the_incumbent_by_the_margin() {
    let e = est(&[(WNAM, 50.0), (ENAM, 50.0)]);
    // 100 vs 85: 15 < max(10, 20) keeps wnam.
    let l = learned(&[(WNAM, 100.0), (ENAM, 85.0)]);
    assert_eq!(pick(&e, &l, Some(WNAM), None).region, Some(WNAM));
    // 100 vs 79: 21 >= 20 moves.
    let l = learned(&[(WNAM, 100.0), (ENAM, 79.0)]);
    assert_eq!(pick(&e, &l, Some(WNAM), None).region, Some(ENAM));
    // Small round trips: the 10 ms floor. 30 vs 21 keeps, 30 vs 19 moves.
    let l = learned(&[(WNAM, 30.0), (ENAM, 21.0)]);
    assert_eq!(pick(&e, &l, Some(WNAM), None).region, Some(WNAM));
    let l = learned(&[(WNAM, 30.0), (ENAM, 19.0)]);
    assert_eq!(pick(&e, &l, Some(WNAM), None).region, Some(ENAM));
    // With no current pick the placement's pick is the incumbent.
    let l = learned(&[(WNAM, 100.0), (ENAM, 85.0)]);
    assert_eq!(pick(&e, &l, None, Some(WNAM)).region, Some(WNAM));
}

#[test]
fn ties_prefer_measured_then_order() {
    let e = est(&[(WNAM, 50.0), (ENAM, 60.0)]);
    // offset = 0 (wnam 50 vs 50), enam measured 50 too: wnam first in order, both measured.
    let l = learned(&[(WNAM, 50.0), (ENAM, 50.0)]);
    assert_eq!(pick(&e, &l, None, None).region, Some(WNAM));
    // enam measured 60, wnam estimated: offset from enam is 0, wnam scores 50 < 60.
    let l = learned(&[(ENAM, 60.0)]);
    assert_eq!(pick(&e, &l, None, None), Pick { region: Some(WNAM), by: By::Calibrated, ms: Some(50.0) });
}

#[test]
fn unknown_estimates_score_only_what_was_measured() {
    let l = learned(&[(WEUR, 70.0)]);
    let p = pick(&[None; N], &l, None, None);
    assert_eq!(p, Pick { region: Some(WEUR), by: By::Measured, ms: Some(70.0) });
}

#[test]
fn out_of_range_indexes_are_ignored() {
    let e = est(&[(WNAM, 50.0)]);
    assert_eq!(pick(&e, &[None; N], Some(99), Some(99)).region, None);
}

fn io_with(e: &[(usize, f64)], l: &[(usize, f64, f64)], current: f64, fallback: f64) -> [f64; IO_LEN] {
    let mut io = [f64::NAN; IO_LEN];
    for r in 0..N {
        io[2 * N + r] = 0.0;
    }
    for &(r, ms) in e {
        io[r] = ms;
    }
    for &(r, ms, n) in l {
        io[N + r] = ms;
        io[2 * N + r] = n;
    }
    io[3 * N] = current;
    io[3 * N + 1] = fallback;
    io
}

#[test]
fn wasm_layout_round_trips() {
    let mut io = io_with(&[(WNAM, 40.0), (ENAM, 70.0)], &[(WNAM, 160.0, 4.0), (ENAM, 85.0, 2.0)], -1.0, 0.0);
    run(&mut io);
    assert_eq!((io[29], io[30], io[31]), (ENAM as f64, BY_MEASURED, 85.0));

    let mut io = io_with(&[(WNAM, 30.0), (APAC, 5.0)], &[(WNAM, 120.0, 1.0)], 0.0, 0.0);
    run(&mut io);
    assert_eq!((io[29], io[30], io[31]), (APAC as f64, BY_CALIBRATED, 65.0));

    let mut io = io_with(&[(WNAM, 30.0)], &[], -1.0, 3.0);
    run(&mut io);
    assert_eq!((io[29], io[30]), (3.0, BY_FALLBACK));
    assert!(io[31].is_nan());

    // A count below one is nothing learned; a fractional or huge index is none.
    let mut io = io_with(&[(WNAM, 30.0)], &[(ENAM, 1.0, 0.0)], 1.5, 1e9);
    run(&mut io);
    assert_eq!((io[29], io[30]), (-1.0, BY_FALLBACK));
}

#[test]
fn observe_ms_matches_observe() {
    assert_eq!(observe_ms(f64::NAN, 0.0, 100.0), 100.0);
    assert_eq!(observe_ms(100.0, 1.0, 200.0), 125.0);
    assert!(observe_ms(100.0, 1.0, -5.0).is_nan());
    assert!(observe_ms(f64::NAN, 0.0, f64::NAN).is_nan());
    // A stale ms with no count starts over.
    assert_eq!(observe_ms(500.0, 0.0, 100.0), 100.0);
}
