use super::*;

fn raw(events: Vec<(f64, &str, serde_json::Value)>, tail: f64) -> RawSession {
    RawSession {
        id: "a0".into(),
        kind: "main".into(),
        tail,
        events: events.into_iter().map(|(t, c, v)| (t, c.to_string(), v)).collect(),
    }
}

fn one_gap_session(gap: f64) -> Session {
    use serde_json::json;
    build(&raw(
        vec![
            (0.0, "in", json!("person")),
            (1.0, "t", json!("bash")),
            (3.0, "r", json!("")),
            (4.0, "a", json!("")),
            (4.0 + gap, "in", json!("agent")),
            (5.0 + gap, "a", json!("")),
        ],
        0.0,
    ))
}

#[test]
fn segments_busy_and_idle() {
    let s = one_gap_session(100.0);
    assert_eq!(s.idles.len(), 1);
    assert_eq!(s.idles[0].secs, 100.0);
    assert_eq!(s.idles[0].last_tool, "bash");
    assert_eq!(s.busy, 5.0);
}

#[test]
fn background_task_holds_the_gap_awake() {
    use serde_json::json;
    let s = build(&raw(
        vec![
            (0.0, "in", json!("person")),
            (1.0, "bg", json!(1)),
            (500.0, "in", json!("bg")),
            (501.0, "bg", json!(0)),
            (502.0, "a", json!("")),
        ],
        0.0,
    ));
    assert!(s.idles.is_empty());
    assert_eq!(s.held, 499.0);
}

#[test]
fn an_open_tool_call_is_busy_not_idle() {
    use serde_json::json;
    let s = build(&raw(
        vec![
            (0.0, "in", json!("person")),
            (1.0, "t", json!("bash")),
            (300.0, "in", json!("agent")),
        ],
        0.0,
    ));
    assert!(s.idles.is_empty());
    assert_eq!(s.busy, 300.0);
}

#[test]
fn fixed_timeout_charges_timeout_and_resume() {
    let s = vec![one_gap_session(100.0)];
    let cost = ResumeCost::Samples(vec![500.0]);
    let short = replay(&s, &mut Fixed(30.0), &cost, 1, Mode::default());
    assert_eq!(short.resumes, 1);
    assert!((short.awake_s - (5.0 + 30.0 + 0.5)).abs() < 1e-9);
    let long = replay(&s, &mut Fixed(900.0), &cost, 1, Mode::default());
    assert_eq!(long.resumes, 0);
    assert!((long.awake_s - 105.0).abs() < 1e-9);
}

#[test]
fn turn_end_keeps_a_pending_message_awake() {
    let s = vec![one_gap_session(0.5), one_gap_session(60.0)];
    let cost = ResumeCost::Samples(vec![500.0]);
    let r = replay(&s, &mut TurnEnd { grace: 0.0 }, &cost, 1, Mode::default());
    assert_eq!(r.resumes, 1);
}

#[test]
fn ski_rental_picks_zero_for_long_gaps_and_stays_for_short() {
    assert_eq!(best_timeout(&[3600.0; 10], 30.0), 0.0);
    assert_eq!(best_timeout(&[3.0; 10], 30.0), 5.0);
}

#[test]
fn tail_counts_awake_until_the_timeout_without_a_resume() {
    use serde_json::json;
    let s = vec![build(&raw(vec![(0.0, "in", json!("person")), (2.0, "a", json!(""))], 3600.0))];
    let r = replay(&s, &mut Fixed(900.0), &ResumeCost::Samples(vec![500.0]), 1, Mode::default());
    assert_eq!(r.resumes, 0);
    assert!((r.awake_s - 902.0).abs() < 1e-9);
}

#[test]
fn lognormal_hits_its_median() {
    let c = ResumeCost::LogNormal { p50: 662.0, p95: 834.0 };
    let mut rng = Rng(3);
    let mut v: Vec<f64> = (0..20000).map(|_| c.draw(&mut rng)).collect();
    assert!((pct(&mut v, 0.5) - 662.0).abs() < 10.0);
    assert!((pct(&mut v, 0.95) - 834.0).abs() < 15.0);
}

#[test]
fn a_wait_only_gap_is_awake_today_and_pausable_with_pause_waits() {
    use serde_json::json;
    let s = vec![build(&raw(
        vec![
            (0.0, "in", json!("person")),
            (1.0, "bg", json!([1, 1])),
            (601.0, "in", json!("bg")),
            (601.0, "bg", json!([0, 0])),
            (602.0, "t", json!("wait")),
            (1202.0, "r", json!("")),
            (1203.0, "a", json!("")),
        ],
        0.0,
    ))];
    assert_eq!(s[0].waits, 1200.0);
    let cost = ResumeCost::Samples(vec![500.0]);
    let today = replay(&s, &mut Fixed(0.0), &cost, 1, Mode::default());
    assert_eq!(today.resumes, 0);
    assert!((today.awake_s - 1203.0).abs() < 1e-9);
    let waits = replay(&s, &mut Fixed(0.0), &cost, 1, Mode { pause_waits: true, no_tail: false });
    assert_eq!((waits.resumes, waits.wait_resumes), (2, 2));
    assert!((waits.awake_s - 4.0).abs() < 1e-9);
}

#[test]
fn a_computing_background_task_stays_held_even_with_pause_waits() {
    use serde_json::json;
    let s = vec![build(&raw(
        vec![(0.0, "in", json!("person")), (1.0, "bg", json!([2, 1])), (601.0, "in", json!("bg"))],
        0.0,
    ))];
    assert_eq!(s[0].held, 600.0);
    let r = replay(
        &s,
        &mut Fixed(0.0),
        &ResumeCost::Samples(vec![500.0]),
        1,
        Mode { pause_waits: true, no_tail: false },
    );
    assert_eq!(r.resumes, 0);
}
