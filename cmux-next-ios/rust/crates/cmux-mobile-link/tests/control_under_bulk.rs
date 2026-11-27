//! A ping round trip stays bounded while one large write is in flight on the same link.
//!
//! The link's writer sends control frames (ping, pong) before bulk channel data, and bulk
//! data in chunks of `DATA_CHUNK` (link.rs header), so the link's own liveness check is never
//! stuck behind an 8 MB chat prompt with an inline attachment on a slow link. (A request on
//! the *same* channel still queues behind it: channel data keeps its order. The iPhone's
//! acpmux channel recovery accounts for that, `AcpmuxHub+Steady.swift`.)
//!
//! The stream is an in-memory duplex whose writes are rate-limited to 2 MiB/s in both
//! directions, so the 8 MB write takes about 4 s. Prints `CONTROL_UNDER_BULK {json}` with the
//! p50 and max ping RTT idle and during the write.

use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::{ChannelEvent, Link, LinkConfig, Role};
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf};
use tokio::time::{Instant, Sleep};

/// Bytes a second each direction carries.
const RATE: usize = 2 << 20;
/// Refill slice: the budget is `RATE / SLICES_PER_SECOND` bytes each slice.
const SLICES_PER_SECOND: usize = 100;
const BULK: usize = 8 << 20;

/// A duplex stream whose writes take at most `RATE` bytes a second.
struct Throttled {
    inner: DuplexStream,
    budget: usize,
    refill: Pin<Box<Sleep>>,
}

impl Throttled {
    fn new(inner: DuplexStream) -> Self {
        Self { inner, budget: RATE / SLICES_PER_SECOND, refill: Box::pin(tokio::time::sleep(Duration::ZERO)) }
    }
}

impl AsyncRead for Throttled {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for Throttled {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        if self.budget == 0 {
            if self.refill.as_mut().poll(cx).is_pending() {
                return Poll::Pending;
            }
            self.budget = RATE / SLICES_PER_SECOND;
            let next = Instant::now() + Duration::from_secs(1) / SLICES_PER_SECOND as u32;
            self.refill.as_mut().reset(next);
        }
        let take = buf.len().min(self.budget);
        match Pin::new(&mut self.inner).poll_write(cx, &buf[..take]) {
            Poll::Ready(Ok(n)) => {
                self.budget -= n;
                Poll::Ready(Ok(n))
            }
            other => other,
        }
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

fn config() -> LinkConfig {
    // No keepalive pings of its own: only the test's pings are timed.
    LinkConfig { keepalive: None, suspect_after: None, ..LinkConfig::default() }
}

fn millis(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn p50_max(mut samples: Vec<Duration>) -> (f64, f64) {
    samples.sort();
    (millis(samples[samples.len() / 2]), millis(*samples.last().expect("samples")))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pings_stay_bounded_while_an_8mb_write_is_in_flight() {
    let (a, b) = tokio::io::duplex(64 * 1024);
    let phone = Link::new(Throttled::new(a), Role::Phone, config(), None);
    let mac = Link::new(Throttled::new(b), Role::Mac, config(), None);

    // The Mac reads the bulk channel to the end and says how many bytes it got.
    let drain = tokio::spawn(async move {
        let mut incoming = mac.accept().await.expect("incoming");
        let mut got = 0usize;
        while got < BULK {
            match incoming.channel.recv().await {
                Some(ChannelEvent::Data(bytes)) => got += bytes.len(),
                other => panic!("unexpected {other:?}"),
            }
        }
        (mac, got)
    });

    let channel = phone.open("acpmux", serde_json::json!({})).await.expect("open");

    let mut idle = Vec::new();
    for _ in 0..20 {
        idle.push(phone.ping().await.expect("idle ping"));
    }

    let started = Instant::now();
    let write = tokio::spawn(async move {
        channel.send(Bytes::from(vec![b'x'; BULK])).await.expect("bulk write");
        channel
    });
    // Let the write fill the queue and the stream first.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut loaded = Vec::new();
    while !write.is_finished() && loaded.len() < 200 {
        loaded.push(phone.ping().await.expect("ping under load"));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let _channel = write.await.expect("write task");
    let (_mac, got) = drain.await.expect("drain");
    let elapsed = started.elapsed();
    assert_eq!(got, BULK);

    let (idle_p50, idle_max) = p50_max(idle);
    assert!(loaded.len() >= 5, "only {} pings during the write ({elapsed:?})", loaded.len());
    let samples = loaded.len();
    let (load_p50, load_max) = p50_max(loaded);
    println!(
        "CONTROL_UNDER_BULK {{\"rate_bytes_per_s\":{RATE},\"bulk_bytes\":{BULK},\"write_ms\":{:.0},\
         \"idle_p50_ms\":{idle_p50:.2},\"idle_max_ms\":{idle_max:.2},\"loaded_samples\":{samples},\
         \"loaded_p50_ms\":{load_p50:.2},\"loaded_max_ms\":{load_max:.2}}}",
        millis(elapsed)
    );
    // A ping waits at most for the bulk bytes already handed to the stream (the writer's flush
    // batch and the duplex buffer, well under 256 KiB: about 125 ms at 2 MiB/s), never for the
    // 8 MB write (about 4 s).
    assert!(load_max < 500.0, "a ping waited {load_max:.0} ms behind the bulk write");
}
