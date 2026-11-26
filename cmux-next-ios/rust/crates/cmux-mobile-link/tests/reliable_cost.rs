//! What the reliable link costs: bytes on an idle link (acks and
//! keepalives) against today's link, and the replay log's memory, which is
//! bounded per channel however long a stream runs.

use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::{Accepted, ChannelEvent, Link, LinkConfig, ReliableConfig, ResumeRegistry, Role};
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf};

/// A duplex end that counts the bytes written through it.
struct Counted {
    inner: DuplexStream,
    written: Arc<AtomicU64>,
}

impl AsyncRead for Counted {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for Counted {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let poll = Pin::new(&mut self.inner).poll_write(cx, buf);
        if let Poll::Ready(Ok(n)) = &poll {
            self.written.fetch_add(*n as u64, Ordering::Relaxed);
        }
        poll
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

/// A phone and a Mac link over one in-memory carrier, with the bytes each
/// side wrote.
async fn pair(config: LinkConfig) -> (Link, Link, Arc<AtomicU64>, Arc<AtomicU64>) {
    let (a, b) = tokio::io::duplex(4 * 1024 * 1024);
    let up = Arc::new(AtomicU64::new(0));
    let down = Arc::new(AtomicU64::new(0));
    let phone_end = Counted { inner: a, written: Arc::clone(&up) };
    let mac_end = Counted { inner: b, written: Arc::clone(&down) };
    let phone = Link::new(phone_end, Role::Phone, config.clone(), None);
    let mac = if config.reliable.is_some() {
        match Link::accept_reliable(mac_end, config, None).await.expect("accept") {
            Accepted::New(mac) => mac,
            Accepted::Resumed(_) => panic!("a new link"),
        }
    } else {
        Link::new(mac_end, Role::Mac, config, None)
    };
    (phone, mac, up, down)
}

fn reliable(config: LinkConfig) -> LinkConfig {
    LinkConfig {
        reliable: Some(ReliableConfig {
            registry: Some(Arc::new(ResumeRegistry::default())),
            ..ReliableConfig::default()
        }),
        ..config
    }
}

/// An hour of an idle link (one open channel after one exchange), on the
/// default keepalive: bytes per hour, today's link against the reliable one.
#[tokio::test(start_paused = true)]
async fn idle_reliable_link_costs_what_todays_does() {
    let mut per_hour = Vec::new();
    for (name, config) in [("before", LinkConfig::default()), ("after", reliable(LinkConfig::default()))] {
        let (phone, mac, up, down) = pair(config).await;
        let echo = tokio::spawn(async move {
            let mut incoming = mac.accept().await.expect("incoming");
            while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                incoming.channel.send(bytes).await.unwrap();
            }
            mac
        });
        let mut channel = phone.open("echo", serde_json::json!({})).await.unwrap();
        channel.send(Bytes::from_static(b"hello")).await.unwrap();
        assert!(matches!(channel.recv().await, Some(ChannelEvent::Data(_))));
        // Let the exchange's acks go out, then count only the idle hour.
        tokio::time::sleep(Duration::from_secs(1)).await;
        let (up0, down0) = (up.load(Ordering::Relaxed), down.load(Ordering::Relaxed));
        tokio::time::sleep(Duration::from_secs(3600)).await;
        assert!(!phone.is_closed(), "{name}: the idle link stays up");
        let up_hour = up.load(Ordering::Relaxed) - up0;
        let down_hour = down.load(Ordering::Relaxed) - down0;
        println!(
            "{name} NETCOND profile=idle@1 scale=1x run=0 surface=link phase=idle metric=bytes_per_hour \
             up={up_hour} down={down_hour} total={}",
            up_hour + down_hour
        );
        per_hour.push(up_hour + down_hour);
        phone.close("done");
        drop(echo);
    }
    assert_eq!(per_hour[0], per_hour[1], "an idle reliable link sends no more than today's: {per_hour:?}");
}

/// One channel streams 1x, 10x, 100x and 1000x the replay bound to a Mac
/// that reads everything: the replay log's peak stays at the bound (plus one
/// chunk), whatever the stream's length.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "streams about 1.1 GB; run in release: cargo test --release --test reliable_cost -- --ignored"]
async fn replay_log_is_flat_at_its_bound() {
    let config = reliable(LinkConfig { keepalive: None, ..LinkConfig::default() });
    let cap = ReliableConfig::default().replay_bytes_per_channel as u64;
    let mut peaks = Vec::new();
    for scale in [1u64, 10, 100, 1000] {
        for channels in [1u64, 4] {
            let (phone, mac, _up, _down) = pair(config.clone()).await;
            let total = scale * cap;
            let sink = tokio::spawn(async move {
                let mut readers = Vec::new();
                for _ in 0..channels {
                    let mut incoming = mac.accept().await.expect("incoming");
                    readers.push(tokio::spawn(async move {
                        let mut got = 0u64;
                        while got < total {
                            match incoming.channel.recv().await {
                                Some(ChannelEvent::Data(bytes)) => got += bytes.len() as u64,
                                other => panic!("unexpected {other:?}"),
                            }
                        }
                        got
                    }));
                }
                for reader in readers {
                    assert_eq!(reader.await.unwrap(), total);
                }
                mac
            });
            let peak = Arc::new(AtomicU64::new(0));
            let sampler = {
                let phone = phone.clone();
                let peak = Arc::clone(&peak);
                tokio::spawn(async move {
                    loop {
                        let held = phone.reliable_stats().unwrap().unacked_bytes;
                        peak.fetch_max(held, Ordering::Relaxed);
                        tokio::time::sleep(Duration::from_micros(200)).await;
                    }
                })
            };
            let chunk = Bytes::from(vec![7u8; 64 * 1024]);
            let mut writers = Vec::new();
            for _ in 0..channels {
                let channel = phone.open("sink", serde_json::json!({})).await.unwrap();
                let chunk = chunk.clone();
                writers.push(tokio::spawn(async move {
                    let mut sent = 0u64;
                    while sent < total {
                        channel.send(chunk.clone()).await.unwrap();
                        sent += chunk.len() as u64;
                    }
                    channel
                }));
            }
            let started = std::time::Instant::now();
            let mut open = Vec::new();
            for writer in writers {
                open.push(writer.await.unwrap());
            }
            let _mac = sink.await.unwrap();
            sampler.abort();
            let peak = peak.load(Ordering::Relaxed);
            let per_channel_bound = cap + 64 * 1024;
            println!(
                "after NETCOND profile=ring@1 scale={scale}x run=0 surface=link phase=stream metric=replay_peak_bytes \
                 channels={channels} stream_bytes_per_channel={total} peak={peak} bound={} took_ms={}",
                channels * per_channel_bound,
                started.elapsed().as_millis()
            );
            assert!(peak <= channels * per_channel_bound, "{scale}x x{channels}: {peak} over the bound");
            peaks.push((scale, channels, peak));
            phone.close("done");
        }
    }
    for channels in [1u64, 4] {
        let at: Vec<u64> = peaks.iter().filter(|p| p.1 == channels).map(|p| p.2).collect();
        let (lo, hi) = (*at.iter().min().unwrap(), *at.iter().max().unwrap());
        println!("replay peak x{channels}: min {lo} max {hi} over 1x..1000x");
    }
}
