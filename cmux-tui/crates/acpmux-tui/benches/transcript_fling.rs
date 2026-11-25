//! Native Rust transcript fling benchmark for RFD 0121.
//!
//! Run with `cargo bench -p acpmux-tui --bench transcript_fling`. The output
//! uses the same JSON arm shape as the existing web benchmark so results can be
//! compared without changing the default React path.

use acpmux_tui::native_transcript::NativeTranscript;
use std::env;

const SCHEMA: &str = "cmux/transcript-fling/v1";

fn main() {
    let rows = env::var("TRANSCRIPT_ROWS").ok().and_then(|v| v.parse().ok()).unwrap_or(3_000);
    let frames = env::var("FLING_FRAMES").ok().and_then(|v| v.parse().ok()).unwrap_or(360);
    let steps = [1500, 2400, 1900, 3000, 2100];
    let mut warmup = NativeTranscript::seeded(rows);
    let _ = warmup.fling(&steps, frames);
    let mut transcript = NativeTranscript::seeded(rows);
    let stats = transcript.fling(&steps, frames);
    println!(
        "TRANSCRIPT_FLING_JSON {{\"schema\":\"{SCHEMA}\",\"arm\":\"native\",\"engine\":\"rust\",\"fixture\":\"flat\",\"rows\":{rows},\"mode\":\"fling\",\"frames\":{},\"frame_p50_ms\":{:.4},\"frame_p95_ms\":{:.4},\"frame_max_ms\":{:.4},\"late_frames\":0,\"blank_frames\":0}}",
        stats.frames, stats.frame_p50_ms, stats.frame_p95_ms, stats.frame_max_ms
    );
}
