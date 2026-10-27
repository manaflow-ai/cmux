//! Bench harness (not part of the PR): three cmux-tui servers' chat-notices
//! watchers, the real `watch()`, on one acpmux socket for HB_BENCH_SECS.
use super::*;

#[test]
#[ignore = "bench harness"]
fn hb_bench_watchers() {
    let socket = PathBuf::from(std::env::var("HB_BENCH_SOCKET").expect("HB_BENCH_SOCKET"));
    let secs: u64 = std::env::var("HB_BENCH_SECS").expect("HB_BENCH_SECS").parse().expect("secs");
    let muxes: Vec<_> = (0..3)
        .map(|n| Mux::new_for_test(format!("hb-bench-{n}"), crate::SurfaceOptions::default()))
        .collect();
    for mux in &muxes {
        let weak = Arc::downgrade(mux);
        let socket = socket.clone();
        std::thread::spawn(move || watch(&weak, &socket));
    }
    std::thread::sleep(Duration::from_secs(secs));
    eprintln!("hb-bench: watchers ran {secs} s");
}
