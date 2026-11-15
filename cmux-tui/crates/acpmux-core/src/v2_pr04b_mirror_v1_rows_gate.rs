use acpmux_book::index::{ReadSide, Summary, SummaryIndex};
use acpmux_client::wire::{Frame, FrameKind, HelloReply, Limits, ListView, Sub};
use acpmux_client::{Change, Client};
use serde_json::Value;

#[test]
#[ignore = "release gate: run once through cmux-ci with --profile gate"]
fn v2_pr04b_mirror_v1_rows_gate() {
    fn sample(closed_rows: usize) -> (Vec<u64>, u64) {
        let mut timings = Vec::with_capacity(40);
        let mut received = 0_u64;
        for _ in 0..40 {
            let mut client = Client::<Value>::connected_v2();
            let hello = Frame::json(
                FrameKind::Hello,
                &HelloReply { daemon_id: "d".into(), limits: Limits::default() },
            )
            .unwrap()
            .encode();
            client.received(&hello);
            while client.take_send().is_some() {}
            let mut sub = Sub::new("m", "list");
            sub.rows = Some("v1".into());
            sub.view = Some(ListView::Live);
            client.subscribe_mirror(sub, std::iter::empty(), false).unwrap();
            let _ = client.take_send();
            let mut index = SummaryIndex::new();
            for row_id in 0..closed_rows {
                let mut row = Summary::new(format!("closed-{row_id}"));
                row.state = "closed".into();
                row.last_activity = row_id as u64;
                index = index.apply(row_id as u64 + 1, row);
            }
            for row_id in 0..20 {
                let mut row = Summary::new(format!("live-{row_id}"));
                row.state = "idle".into();
                row.last_activity = 11_000 + row_id as u64;
                index = index.apply((closed_rows + row_id) as u64 + 1, row);
            }
            assert_eq!(index.len(), closed_rows + 20, "god index lost its closed rows");
            let page = index
                .read_live_page(
                    None,
                    ReadSide::After,
                    false,
                    100,
                    acpmux_client::wire::MAX_PAGE_BYTES,
                    None,
                )
                .unwrap();
            assert_eq!(page.rows.len(), 20);
            let rows: Vec<Value> =
                page.rows.iter().map(|row| serde_json::to_value(row.as_ref()).unwrap()).collect();
            drop(page);
            drop(index);
            let frame = Frame::json(
                FrameKind::Window,
                &serde_json::json!({"sid":"m","cursor":1,"rows":rows,"hasBefore":false,"hasAfter":false,"edition":1}),
            )
            .unwrap()
            .encode();
            received = received.saturating_add(frame.len() as u64);
            let started = std::time::Instant::now();
            assert_eq!(client.received(&frame), frame.len());
            assert!(matches!(client.next_change(), Some(Change::Window(_))));
            timings.push(started.elapsed().as_nanos() as u64);
        }
        (timings, received)
    }
    fn p95(values: &[u64]) -> u64 {
        let mut values = values.to_vec();
        values.sort_unstable();
        let index = (values.len() * 95).div_ceil(100).saturating_sub(1);
        values[index]
    }
    let mut small_rounds = Vec::with_capacity(5);
    let mut god_rounds = Vec::with_capacity(5);
    let mut small_all = Vec::with_capacity(200);
    let mut god_all = Vec::with_capacity(200);
    let mut small_bytes = Vec::with_capacity(5);
    let mut god_bytes = Vec::with_capacity(5);
    for _ in 0..5 {
        let (times, bytes) = sample(0);
        small_all.extend(times.iter().copied());
        small_rounds.push(times);
        small_bytes.push(bytes);
        let (times, bytes) = sample(11_000);
        god_all.extend(times.iter().copied());
        god_rounds.push(times);
        god_bytes.push(bytes);
    }
    let best = |rounds: &[Vec<u64>]| rounds.iter().map(|round| p95(round)).min().unwrap_or(0);
    let best_small = best(&small_rounds);
    let best_god = best(&god_rounds);
    let small_p95_all = p95(&small_all);
    let god_p95_all = p95(&god_all);
    let small_bytes = small_bytes.into_iter().min().unwrap_or(0);
    let god_bytes = god_bytes.into_iter().min().unwrap_or(0);
    assert!(
        god_bytes.saturating_mul(10) <= small_bytes.saturating_mul(12),
        "received bytes exceed the 1.2x bound: god={god_bytes}, small={small_bytes}"
    );
    let line = serde_json::json!({
        "name":"v2.pr04b.mirror_v1_rows",
        "small_p95":best_small,
        "god_p95":best_god,
        "small_p95_all":small_p95_all,
        "god_p95_all":god_p95_all,
        "unit":"ns",
        "small_bytes":small_bytes,
        "god_bytes":god_bytes
    });
    println!("{line}");
    if let Ok(path) = std::env::var("V2_GATE_OUT") {
        use std::io::Write as _;
        let mut output = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(output, "{line}").unwrap();
    }
}
