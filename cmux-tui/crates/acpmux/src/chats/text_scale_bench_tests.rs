//! The chat text index (`text.rs`, what `_acpmux/chats_window`'s query searches) at 1x and at
//! scale: the first fill, one chat with one new message (the text thread's pass after each index
//! change), and query p50/p95 (a prefix, a phrase, a word no chat holds, a one-character query)
//! at 1k, 50k and 500k chats, plus degenerate text (one chat of 50 MB, emoji and other non-Latin
//! text, one very long line).
//!
//! Leo, 2026-11-17: "we should be stress testing everything that isn't already stress tested".
//! The bar: one changed chat and every query cost the same at every size, within [`GROWTH`]
//! times the 1k p95 (plus [`FLOOR_MS`] for timer noise), so cost that grows with the chats fails.
//! The index holds at most [`TOTAL_BYTES`], so past that a query costs what the bound holds.
//! Manual (a few minutes):
//! `cargo test -p acpmux --release --lib text_scale_bench -- --ignored --nocapture --test-threads=1`.
//! `TEXT_SCALE_SIZES=1000,50000` picks other sizes; the first is the 1x.

use std::cell::Cell;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_chat_index::{AdapterKind, ChatEntry, IndexedChat, Resume};

use super::*;

/// Scale p95 over 1x p95 that fails the bench.
const GROWTH: f64 = 3.0;
/// Added to every bound: below it, a p95 is timer and scheduler noise.
const FLOOR_MS: f64 = 1.0;
const ROUNDS: usize = 40;
const TURNS: usize = 4;
/// A word no chat holds.
const ABSENT: &str = "zqxjvkw";
/// Between two timed queries: a query the next one does not narrow, so each is answered anew.
const RESET: &str = "qqqqreset";

fn sizes() -> Vec<usize> {
    std::env::var("TEXT_SCALE_SIZES")
        .ok()
        .map(|v| v.split(',').filter_map(|n| n.trim().parse().ok()).collect())
        .filter(|v: &Vec<usize>| !v.is_empty())
        .unwrap_or_else(|| vec![1_000, 50_000, 500_000])
}

const COMMON: &[&str] = &[
    "the", "and", "that", "this", "with", "for", "from", "sidebar", "deploy", "build", "test",
    "fix", "error", "chat", "window", "terminal", "branch", "merge", "review", "index", "query",
];

/// About 100 bytes of words per message: chat `c`'s turn `t`, the same on every run.
fn words(c: usize, t: usize, salt: usize) -> String {
    let mut seed = (c as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15) ^ ((t * 31 + salt) as u64 + 1);
    let mut out = String::new();
    for _ in 0..16 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(COMMON[(seed % COMMON.len() as u64) as usize]);
    }
    out
}

fn turns_of(c: usize, extra: usize) -> Vec<Turn> {
    (0..TURNS + extra)
        .map(|t| Turn {
            prompt: words(c, t, 0),
            answer: words(c, t, 1),
            prompt_at: None,
            answer_at: None,
        })
        .collect()
}

fn chat(c: usize, updated_ms: i64, messages: u64) -> IndexedChat {
    IndexedChat {
        entry: ChatEntry {
            harness: AdapterKind::Codex,
            session_id: format!("{c:07}"),
            title: Some(format!("chat {c}")),
            title_source: None,
            cwd: None,
            created_ms: None,
            updated_ms,
            message_count: Some(messages),
            source_path: PathBuf::from(format!("/nonexistent/{c}.jsonl")),
            originator: None,
            archived: false,
            resume: Resume::ReadOnly,
        },
        accounts: Vec::new(),
        roots: Vec::new(),
    }
}

fn index() -> ChatText {
    ChatText::new(std::env::temp_dir().join(format!("acpmux-text-{}.json", uuid::Uuid::now_v7())))
}

#[derive(Clone, Copy, Debug)]
struct Stats {
    p50: f64,
    p95: f64,
}

fn stats(mut samples: Vec<Duration>) -> Stats {
    samples.sort_unstable();
    let at = |q: f64| {
        let i = ((samples.len() as f64 - 1.0) * q).round() as usize;
        samples[i].as_secs_f64() * 1e3
    };
    Stats { p50: at(0.50), p95: at(0.95) }
}

const QUERIES: &[(&str, &str)] =
    &[("prefix", "sideb"), ("phrase", "deploy the sidebar"), ("no-hit", ABSENT), ("1-char", "s")];

struct Size {
    n: usize,
    fill_us_per_chat: f64,
    held: usize,
    one_changed: Stats,
    queries: Vec<Stats>,
}

fn run(n: usize) -> Size {
    let text = index();
    // Newest first, as the text thread lists them.
    let mut chats: Vec<IndexedChat> =
        (0..n).map(|c| chat(c, (n - c) as i64 * 1_000, (TURNS * 2) as u64)).collect();
    let extra = Cell::new(0_usize);
    let read = |entry: &ChatEntry| {
        let c: usize = entry.session_id.parse().ok()?;
        Some(turns_of(c, if c == 0 { extra.get() } else { 0 }))
    };
    let started = Instant::now();
    text.update(&chats, &read);
    let fill_us_per_chat = started.elapsed().as_secs_f64() * 1e6 / n as f64;
    let (held, _) = text.held();

    // The newest chat gets one message; the pass reads it again and every other chat is as held.
    let mut samples = Vec::new();
    for round in 0..ROUNDS {
        extra.set(round + 1);
        let entry = &mut chats[0].entry;
        entry.updated_ms += 1;
        entry.message_count = Some(((TURNS + round + 1) * 2) as u64);
        let started = Instant::now();
        text.update(&chats, &read);
        samples.push(started.elapsed());
    }
    let one_changed = stats(samples);

    let queries = QUERIES
        .iter()
        .map(|(label, query)| {
            let needle = Needle::parse(query).expect("words");
            let reset = Needle::parse(RESET).expect("words");
            let found = text.search(&needle).len();
            let samples = (0..ROUNDS)
                .map(|_| {
                    text.search(&reset);
                    let started = Instant::now();
                    let found = text.search(&needle);
                    let rows: Vec<Value> =
                        found.values().take(50).filter_map(|f| ChatText::hit(f, &needle)).collect();
                    std::hint::black_box(rows);
                    started.elapsed()
                })
                .collect();
            let stats = stats(samples);
            println!(
                "N={n:>7} query {label:<8} found={found:>7} p50={:>9.3} ms p95={:>9.3} ms",
                stats.p50, stats.p95
            );
            stats
        })
        .collect();
    println!(
        "N={n:>7} held {held}; fill {fill_us_per_chat:.1} us/chat; one changed p50={:.3} p95={:.3} ms",
        one_changed.p50, one_changed.p95
    );
    Size { n, fill_us_per_chat, held, one_changed, queries }
}

fn bound(base: f64) -> f64 {
    base * GROWTH + FLOOR_MS
}

#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn text_scale_bench_cost_is_flat_as_chats_grow() {
    let sizes: Vec<Size> = sizes().into_iter().map(run).collect();
    let base = &sizes[0];
    let mut failures = Vec::new();
    println!("\n| N chats | held | what | p50 ms | p95 ms |\n|---|---|---|---|---|");
    for size in &sizes {
        let mut rows = vec![("one changed", size.one_changed, base.one_changed)];
        for (i, (label, _)) in QUERIES.iter().enumerate() {
            rows.push((label, size.queries[i], base.queries[i]));
        }
        for (label, stats, base_stats) in rows {
            println!(
                "| {} | {} | {label} | {:.3} | {:.3} |",
                size.n, size.held, stats.p50, stats.p95
            );
            if stats.p95 > bound(base_stats.p95) {
                failures.push(format!(
                    "{label} at {}: p95 {:.3} ms > {:.3} ms ({GROWTH}x the {} p95 {:.3} ms + {FLOOR_MS})",
                    size.n,
                    stats.p95,
                    bound(base_stats.p95),
                    base.n,
                    base_stats.p95
                ));
            }
        }
        if size.fill_us_per_chat > base.fill_us_per_chat * GROWTH {
            failures.push(format!(
                "fill at {}: {:.1} us/chat > {GROWTH}x the {} {:.1} us/chat",
                size.n, size.fill_us_per_chat, base.n, base.fill_us_per_chat
            ));
        }
    }
    assert!(failures.is_empty(), "cost grew with the chats:\n{}", failures.join("\n"));
}

/// A chat of 50 MB (held to its newest [`CHAT_BYTES`]), emoji and other non-Latin text, and
/// one line of 1 MB without a space: each is read, its words found, and a query stays in budget.
#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn text_scale_bench_degenerate_text() {
    let text = index();
    let mut huge = String::with_capacity(50 << 20);
    while huge.len() < 50 << 20 {
        huge.push_str(&words(huge.len(), 0, 0));
        huge.push('\n');
    }
    huge.push_str(" hugeneedle");
    let emoji = "🚀 déploiement réussi ✅ 部署成功 развёртывание 🎉 ΟΣ İstanbul ".repeat(2_000);
    let long = format!("{}longneedle", "x".repeat(1 << 20));
    let bodies = [huge, emoji, long];
    let mut chats: Vec<IndexedChat> = (0..1_000).map(|c| chat(c, -(c as i64), 8)).collect();
    chats.extend((0..bodies.len()).map(|i| chat(9_000_000 + i, 10 + i as i64, 2)));
    chats.sort_by_key(|c| std::cmp::Reverse(c.entry.updated_ms));
    let started = Instant::now();
    text.update(&chats, &|entry| {
        let c: usize = entry.session_id.parse().ok()?;
        match c.checked_sub(9_000_000) {
            Some(i) => Some(vec![Turn {
                prompt: "start".into(),
                answer: bodies[i].clone(),
                prompt_at: None,
                answer_at: None,
            }]),
            None => Some(turns_of(c, 0)),
        }
    });
    println!("degenerate fill: {:?}, held {:?}", started.elapsed(), text.held());
    let budget_ms = 50.0;
    for (query, chat) in [
        ("hugeneedle", "9000000"),
        ("部署成功", "9000001"),
        ("réussi", "9000001"),
        // `İ` lowercases to `i̇` (two characters): its own spelling finds it, `istanbul` does not.
        ("İstanbul", "9000001"),
        ("🚀", "9000001"),
        ("longneedle", "9000002"),
    ] {
        let needle = Needle::parse(query).expect("words");
        let found = text.search(&needle);
        let key = format!("codex:{chat}");
        assert!(found.contains_key(&key), "{query} finds {key}: {:?}", found.keys());
        let reset = Needle::parse(RESET).expect("words");
        let samples = (0..ROUNDS)
            .map(|_| {
                text.search(&reset);
                let started = Instant::now();
                let found = text.search(&needle);
                std::hint::black_box(found.get(&key).and_then(|f| ChatText::hit(f, &needle)));
                started.elapsed()
            })
            .collect();
        let stats = stats(samples);
        println!("degenerate query {query}: p50={:.3} ms p95={:.3} ms", stats.p50, stats.p95);
        assert!(stats.p95 <= budget_ms, "{query}: p95 {:.3} ms > {budget_ms} ms", stats.p95);
    }
}
