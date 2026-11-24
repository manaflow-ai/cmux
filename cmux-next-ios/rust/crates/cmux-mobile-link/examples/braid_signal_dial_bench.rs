//! Sequential signaling TCP dials to one host, timed: the before/after bench for Braid slice B1b
//! (RFD 0164). `CMUX_BRAID_LAST_GOOD=0` is the race with no last-good route; `BENCH_ARM=legacy`
//! is the dial before this slice (`tokio_tungstenite::connect_async`'s `TcpStream::connect` on
//! `host:port`, the resolver's addresses one after the other).
//!
//! `cargo run -p cmux-mobile-link --example braid_signal_dial_bench -- HOST PORT [N]`; prints one
//! line per dial and a JSON summary. Run it inside the netns rig in
//! `cmux-tui/crates/cmux-braid-path/bench/netns-dial.sh`, never against a person's network.

use std::time::{Duration, Instant};

use tokio_tungstenite::tungstenite::client::IntoClientRequest;

/// Each dial's budget; a legacy dial that waits out a black-holed SYN fails here.
const BUDGET: Duration = Duration::from_secs(10);

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    let host = args.next().unwrap_or_else(|| "braid-peer".to_owned());
    let port: u16 = args.next().and_then(|p| p.parse().ok()).unwrap_or(7443);
    let n: usize = args.next().and_then(|p| p.parse().ok()).unwrap_or(20);
    let legacy = std::env::var("BENCH_ARM").is_ok_and(|arm| arm == "legacy");
    let mut times = Vec::with_capacity(n);
    let mut failed = 0_usize;
    for i in 0..n {
        let request = format!("ws://{host}:{port}/v1/teams/t/signal")
            .into_client_request()
            .map_err(std::io::Error::other)?;
        let began = Instant::now();
        let dial = async {
            if legacy {
                tokio::net::TcpStream::connect(format!("{host}:{port}")).await.map_err(std::io::Error::other)
            } else {
                cmux_mobile_link::signal_dial::connect_tcp(&request).await.map_err(std::io::Error::other)
            }
        };
        let outcome = tokio::time::timeout(BUDGET, dial).await;
        let took = began.elapsed();
        match outcome {
            Ok(Ok(stream)) => {
                println!("dial {i}: {:.1} ms via {}", took.as_secs_f64() * 1000.0, stream.peer_addr()?);
            }
            Ok(Err(error)) => {
                failed += 1;
                println!("dial {i}: failed after {:.1} ms: {error}", took.as_secs_f64() * 1000.0);
            }
            Err(_) => {
                failed += 1;
                println!("dial {i}: no connect within {} s", BUDGET.as_secs());
            }
        }
        times.push(took);
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    times.sort();
    let at = |percent: usize| {
        let index = ((times.len() - 1) * percent + 50) / 100;
        times[index.min(times.len() - 1)].as_secs_f64() * 1000.0
    };
    let total: Duration = times.iter().sum();
    let mean = total.as_secs_f64() * 1000.0 / f64::from(u32::try_from(times.len()).unwrap_or(u32::MAX));
    let last_good = std::env::var("CMUX_BRAID_LAST_GOOD").map_or(true, |v| v.trim() != "0");
    let arm = if legacy { "legacy" } else { "braid" };
    println!(
        "{{\"arm\":\"{arm}\",\"last_good\":{last_good},\"n\":{n},\"failed\":{failed},\"p50_ms\":{:.1},\"p95_ms\":{:.1},\"max_ms\":{:.1},\"mean_ms\":{mean:.1}}}",
        at(50),
        at(95),
        at(100)
    );
    Ok(())
}
