use acpmux_book::gate_rounds;
use acpmux_book::index::{ReadSide, Summary, SummaryIndex};
use acpmux_client::wire::{Frame, FrameKind, HelloReply, Limits, ListView, Sub};
use acpmux_client::{Change, Client};
use serde_json::Value;

#[test]
#[ignore = "release gate: run once through cmux-ci with --profile gate"]
fn v2_pr04b_mirror_v1_rows_gate() {
    fn prepare(closed_rows: usize) -> Vec<(Client<Value>, Vec<u8>)> {
        let mut samples = Vec::with_capacity(40);
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
            assert_eq!(index.len(), closed_rows + 20, "sample index lost its closed rows");
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
            samples.push((client, frame));
        }
        samples
    }
    fn sample(samples: Vec<(Client<Value>, Vec<u8>)>) -> (Vec<u128>, u64) {
        assert_eq!(samples.len(), 40, "round lost its samples");
        let mut timings = Vec::with_capacity(samples.len());
        let mut received = 0_u64;
        for (mut client, frame) in samples {
            received = received.saturating_add(frame.len() as u64);
            let started = std::time::Instant::now();
            assert_eq!(client.received(&frame), frame.len());
            assert!(matches!(client.next_change(), Some(Change::Window(_))));
            timings.push(started.elapsed().as_nanos());
        }
        (timings, received)
    }
    let mut small_rounds = Vec::with_capacity(5);
    let mut god_rounds = Vec::with_capacity(5);
    let mut small_bytes = Vec::with_capacity(5);
    let mut god_bytes = Vec::with_capacity(5);
    for _ in 0..5 {
        // Finish both sides' setup before timing any frame in this round.
        let small = prepare(0);
        let god = prepare(11_000);
        let (times, bytes) = sample(small);
        small_rounds.push(times);
        small_bytes.push(bytes);
        let (times, bytes) = sample(god);
        god_rounds.push(times);
        god_bytes.push(bytes);
    }
    gate_rounds::report(
        "v2.pr04b.mirror_v1_rows",
        &[("small", &small_rounds), ("god", &god_rounds)],
    );
    let best_small = gate_rounds::best_p95(&small_rounds);
    let best_god = gate_rounds::best_p95(&god_rounds);
    let small_p95_all = gate_rounds::all_p95(&small_rounds);
    let god_p95_all = gate_rounds::all_p95(&god_rounds);
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
