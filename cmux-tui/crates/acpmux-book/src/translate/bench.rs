//! One harness for small/god throughput, cold restore and resident-memory gates.
//! Run in release: cargo test -p acpmux-book --release translate::bench::god_vs_small -- --ignored --nocapture
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    reason = "test-only benchmark arithmetic and assertions"
)]
use super::*;
fn t(state: &mut State, harness: Harness, bytes: &[u8]) -> Result<Vec<Op>, Error> {
    translate(state, harness, 0, 1, bytes)
}
use std::hint::black_box;
use std::time::Instant;

// Same event mix at both sizes; 272k JSONL lines and at least 1.1 GB at god size.
// Cold metadata represents request bodies/attachments without retaining a JSON tree.
fn corpus(harness: Harness) -> Vec<String> {
    if harness == Harness::V1 {
        return v1_corpus();
    }
    let padding = "x".repeat(4045);
    [
        r#""type":"user","uuid":"p","message":{"content":"Question"}"#,
        r#""type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Read","input":{"path":"a"}}]}"#,
        r#""type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"output"}]}"#,
        r#""type":"assistant","message":{"content":[{"type":"text","text":"Final reply"}],"stop_reason":"end_turn"}"#,
    ].iter().map(|line|format!("{{{line},\"cold\":\"{padding}\"}}\n")).collect()
}
fn v1_corpus() -> Vec<String> {
    let padding = "x".repeat(2000);
    let update = |body: &str| {
        format!(
            r#""dir":"in","kind":"session/update","msg":{{"method":"session/update","params":{{"update":{body}}}}}"#
        )
    };
    [
        r#""dir":"mux","kind":"user_message","msg":{"text":"Question","turnId":"p"}"#.to_owned(),
        update(r#"{"sessionUpdate":"tool_call","toolCallId":"t","status":"running"}"#),
        update(r#"{"sessionUpdate":"tool_call_update","toolCallId":"t","status":"completed","content":{"type":"text","text":"output"}}"#),
        update(r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Final reply"}}"#),
        r#""dir":"mux","kind":"turn_result","msg":{"turnId":"p"}"#.to_owned(),
    ].iter().map(|body|format!("{{\"seq\":0,\"at\":1000,{body},\"cold\":\"{padding}\"}}\n")).collect()
}
fn line_at(harness: Harness, lines: &[String], n: usize) -> String {
    if harness == Harness::Claude && n > 0 && n.is_multiple_of(1000) {
        return format!(
            "{{\"type\":\"user\",\"message\":{{\"content\":[{{\"type\":\"tool_result\",\"tool_use_id\":\"blob\",\"content\":\"{}\"}}]}}}}\n",
            "b".repeat(5 * 1024 * 1024)
        );
    }
    let line = &lines[n % lines.len()];
    if harness == Harness::V1 {
        line.replacen("\"seq\":0", &format!("\"seq\":{}", n + 1), 1)
    } else {
        line.clone()
    }
}
fn sample_line_at(harness: Harness, lines: &[String], n: usize) -> String {
    if harness == Harness::Claude && n > 0 && n.is_multiple_of(1000) {
        return lines[n % lines.len()].clone();
    }
    line_at(harness, lines, n)
}
fn full_state() -> State {
    let mut state = State::default();
    let prompt = r#"{"seq":1,"at":1000,"dir":"mux","kind":"user_message","msg":{"text":"q"}}"#;
    let _ = t(&mut state, Harness::V1, prompt.as_bytes());
    for n in 0..1024u64 {
        let line = format!(
            r#"{{"seq":{},"at":1000,"dir":"mux","kind":"queued","msg":{{"text":"q-{}","promptId":"q-{}"}}}}"#,
            n + 2,
            n,
            n
        );
        let _ = t(&mut state, Harness::V1, line.as_bytes());
    }
    state
}
fn full_state_p95(harness: Harness, lines: &[String], start: usize, queue: bool) -> u128 {
    let mut state = if queue { full_state() } else { State::default() };
    let mut samples = Vec::with_capacity(200);
    for n in start..start + 200 {
        let line = sample_line_at(harness, lines, n);
        let began = Instant::now();
        black_box(t(&mut state, harness, line.as_bytes()).unwrap());
        samples.push(began.elapsed().as_nanos());
    }
    p95(&mut samples)
}
fn p95(samples: &mut [u128]) -> u128 {
    samples.sort_unstable();
    samples[samples.len() * 95 / 100]
}
fn rss() -> u64 {
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    status
        .lines()
        .find(|l| l.starts_with("VmHWM:"))
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse()
        .unwrap()
}
#[test]
#[ignore = "subprocess measurement, invoked by god_vs_small"]
fn measure_child() {
    let Some(count) =
        std::env::var("BOOK_TRANSLATE_LINES").ok().and_then(|s| s.parse::<usize>().ok())
    else {
        return;
    };
    let harness = if std::env::var("BOOK_TRANSLATE_HARNESS").as_deref() == Ok("v1") {
        Harness::V1
    } else {
        Harness::Claude
    };
    let lines = corpus(harness);
    let mut state = State::default();
    let mut bytes = 0usize;
    for n in 0..count {
        let line = line_at(harness, &lines, n);
        bytes += line.len();
        black_box(t(&mut state, harness, line.as_bytes()).unwrap());
    }
    assert_eq!(state.open_rows().count(), 0);
    for row in state.stored_rows() {
        assert_ne!(row.fields.get("state").map(String::as_str), Some("queued"));
        if matches!(row.kind, RowKind::Text | RowKind::Thinking) {
            assert!(row.fields.contains_key("messageId"));
        }
        if row.kind == RowKind::Tool {
            assert!(row.fields.contains_key("callId"));
        }
    }
    let checkpoint = state.checkpoint().unwrap();
    let mut all = Vec::new();
    let mut best = u128::MAX;
    let mut cold_all = Vec::new();
    let mut cold_best = u128::MAX;
    let mut cursor = count;
    let cold_line = sample_line_at(harness, &lines, count);
    for _ in 0..5 {
        // Same stride, same line mix, and both past their first allocation.
        for _ in &lines {
            let line = sample_line_at(harness, &lines, cursor);
            cursor += 1;
            black_box(t(&mut state, harness, line.as_bytes()).unwrap());
        }
        let mut samples = Vec::new();
        let mut cold = Vec::new();
        for _ in 0..200 {
            for _ in &lines {
                let line = sample_line_at(harness, &lines, cursor);
                cursor += 1;
                let start = Instant::now();
                black_box(t(&mut state, harness, line.as_bytes()).unwrap());
                samples.push(start.elapsed().as_nanos());
            }
            let start = Instant::now();
            let mut restored = State::restore(black_box(&checkpoint)).unwrap();
            black_box(t(&mut restored, harness, cold_line.as_bytes()).unwrap());
            cold.push(start.elapsed().as_nanos());
        }
        best = best.min(p95(&mut samples));
        all.extend(samples);
        cold_best = cold_best.min(p95(&mut cold));
        cold_all.extend(cold);
    }
    let peak = rss();
    let full = full_state_p95(harness, &lines, cursor, true);
    let queue_empty = full_state_p95(harness, &lines, cursor, false);
    println!(
        "MEASURE {count} {bytes} {best} {} {cold_best} {} {peak} {} {full} {queue_empty}",
        p95(&mut all),
        p95(&mut cold_all),
        checkpoint.len()
    );
    assert!(peak * 1024 < 64_000_000, "resident peak {peak} KiB must be under 64 MB");
}
fn child(harness: &str, count: usize) -> Vec<u64> {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "translate::bench::measure_child", "--ignored", "--nocapture"])
        .env("BOOK_TRANSLATE_LINES", count.to_string())
        .env("BOOK_TRANSLATE_HARNESS", harness)
        .env_remove("V2_GATE_OUT")
        .output()
        .unwrap();
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(output.status.success(), "{stdout}\n{}", String::from_utf8_lossy(&output.stderr));
    println!("{stdout}");
    stdout
        .lines()
        .find_map(|l| l.strip_prefix("MEASURE "))
        .unwrap()
        .split_whitespace()
        .map(|s| s.parse().unwrap())
        .collect()
}
#[test]
#[ignore = "1.1 GB Linux release gate"]
#[cfg(target_os = "linux")]
fn god_vs_small() {
    for (harness, count, bytes) in
        [("claude", 272_000, 1_100_000_000), ("v1", 2_000_000, 4_000_000_000)]
    {
        let small = child(harness, 40);
        let god = child(harness, count);
        assert!(god[1] >= bytes, "the god shape must actually translate the specified bytes");
        for (label, i, bound) in [
            ("steady best p95", 2, 1.2),
            ("steady all p95", 3, if small[2].max(god[2]) < 100_000 { 2.0 } else { 1.2 }),
            ("cold best p95", 4, 1.2),
            ("cold all p95", 5, if small[4].max(god[4]) < 100_000 { 2.0 } else { 1.2 }),
        ] {
            let ratio = god[i] as f64 / small[i] as f64;
            println!(
                "{label}: small={} ns god={} ns ratio={ratio:.3} gate={bound}",
                small[i], god[i]
            );
            assert!(ratio <= bound, "{label}: {ratio} exceeds {bound}");
        }
        assert!(god[6] * 1024 < 64_000_000);
        assert!(god[7] <= small[7] + 64, "only varint counter widths may grow with history");
        if harness == "claude"
            && let Ok(path) = std::env::var("V2_GATE_OUT")
        {
            let lines = [
                    format!(
                        "{{\"name\":\"v2.pr02.translate_line\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"ns\"}}\n",
                        small[2], god[3]
                    ),
                    format!(
                        "{{\"name\":\"v2.pr02.translate_line_full_state\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"ns\"}}\n",
                        small[8], god[8]
                    ),
                    format!(
                        "{{\"name\":\"v2.pr02.jsonl_peak_rss\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"KiB\"}}\n",
                        small[6], god[6]
                    ),
                    format!(
                        "{{\"name\":\"v2.pr02b.translate_line_queue_full\",\"small_p95\":{},\"god_p95\":{},\"unit\":\"ns\"}}\n",
                        small[9], god[8]
                    ),
                ]
                .join("");
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .and_then(|mut file| std::io::Write::write_all(&mut file, lines.as_bytes()))
                .unwrap();
        }
    }
}
