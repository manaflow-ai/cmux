//! What a TURN allocation sends next.
//!
//! A TURN allocation over TCP or TLS (PROTOCOL.md "WireGuard over TURN")
//! carries WireGuard datagrams on one ordered stream, so it can be offered
//! far more than it can send: until a route is confirmed every datagram,
//! video included, also goes through TURN. The writer therefore takes, in
//! strict priority:
//!
//! 1. control: handshake messages and keepalives (they confirm and keep
//!    the route);
//! 2. input: what the tunnel's pacer sends as interactive (keystrokes, TCP
//!    ACKs, small requests, and terminal output at a terminal's pace,
//!    full-size segments included, so a keystroke can wait behind a few
//!    such segments);
//! 3. bulk (large transfers) and media (video): they share what is left by
//!    bytes, whichever sent fewer bytes goes next, so neither starves the
//!    other.
//!
//! Classes are bounded by bytes. Past its bound a class drops its oldest
//! datagram: what they carry (TCP in the tunnel, the media lane's RTP with
//! its own resends) already copes with loss, while a stale datagram only
//! delays the fresh ones behind it. Media older than [`MEDIA_MAX_AGE`] is
//! dropped too: a late video packet is worthless. A UDP allocation uses the
//! same queue; its writer rarely waits, so the queue stays empty.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use bytes::Bytes;
use tokio::sync::Notify;
use tokio::time::Instant;

/// How a WireGuard datagram is queued toward a TURN server (highest first).
/// The tunnel names the class of what its pacer sends; otherwise
/// [`send_class`] infers it from the datagram's outer shape, its type and
/// length.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SendClass {
    /// Handshake messages, keepalives.
    Control,
    /// Small data datagrams: keystrokes, TCP ACKs, small requests.
    Input,
    /// Bulk data (large output, files), or full-size data of no known class.
    /// Shares the stream with [`SendClass::Media`] by bytes; both drop.
    Bulk,
    /// Media datagrams (the media lane's RTP: browser and screen video).
    Media,
}

/// Encrypted data datagrams up to this size are [`SendClass::Input`]: a
/// TCP segment with a few hundred bytes of payload, or a pure ACK.
pub const INPUT_MAX: usize = 400;

/// The class of a WireGuard datagram by its shape.
pub fn send_class(datagram: &[u8]) -> SendClass {
    use cmux_transport::classify::WG_DATA_MIN_LEN;
    use cmux_transport::{DatagramClass, classify};
    match classify(datagram) {
        DatagramClass::WireGuardData if datagram.len() > INPUT_MAX => SendClass::Bulk,
        DatagramClass::WireGuardData if datagram.len() > WG_DATA_MIN_LEN => SendClass::Input,
        _ => SendClass::Control,
    }
}

/// Bytes each class may hold. Control datagrams are small (a 148-byte
/// initiation); input is about 200 keystroke datagrams; bulk is about 200
/// full-size datagrams, a fifth of a second of a 10 Mbit/s stream: more
/// only adds latency.
pub(crate) const CONTROL_BYTES: usize = 16 * 1024;
pub(crate) const INPUT_BYTES: usize = 64 * 1024;
pub(crate) const BULK_BYTES: usize = 256 * 1024;
pub(crate) const MEDIA_BYTES: usize = 256 * 1024;
/// Media queued longer than this is dropped (the tunnel's own pacer drops
/// media after 50 ms; a stream allocation adds its own backlog).
pub(crate) const MEDIA_MAX_AGE: Duration = Duration::from_millis(250);

/// One datagram for the TURN server to send on to `to`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Queued {
    pub datagram: Bytes,
    pub to: SocketAddr,
}

#[derive(Default)]
struct Class {
    items: VecDeque<(Instant, Queued)>,
    bytes: usize,
    dropped: u64,
}

impl Class {
    /// Queue `item`, then drop the oldest items while the class is past
    /// `limit` (a single item larger than `limit` is still kept).
    fn push(&mut self, item: Queued, limit: usize) {
        self.bytes += item.datagram.len();
        self.items.push_back((Instant::now(), item));
        while self.bytes > limit && self.items.len() > 1 {
            let (_, oldest) = self.items.pop_front().expect("more than one item");
            self.bytes -= oldest.datagram.len();
            self.dropped += 1;
        }
    }

    fn pop(&mut self) -> Option<Queued> {
        let (_, item) = self.items.pop_front()?;
        self.bytes -= item.datagram.len();
        Some(item)
    }

    /// Drop items queued longer than `max_age`, oldest first.
    fn expire(&mut self, max_age: Duration) {
        let now = Instant::now();
        while let Some((queued_at, item)) = self.items.front()
            && now.saturating_duration_since(*queued_at) > max_age
        {
            self.bytes -= item.datagram.len();
            self.items.pop_front();
            self.dropped += 1;
        }
    }
}

#[derive(Default)]
struct Queues {
    classes: [Class; 4],
    /// Bytes bulk sent minus bytes media sent while both had items queued.
    bulk_lead: i64,
    closed: bool,
}

impl Queues {
    /// Bulk or media, whichever sent fewer bytes while both waited.
    fn pop_bulk_or_media(&mut self) -> Option<Queued> {
        let (bulk, media) = (index(SendClass::Bulk), index(SendClass::Media));
        self.classes[media].expire(MEDIA_MAX_AGE);
        let both = !self.classes[bulk].items.is_empty() && !self.classes[media].items.is_empty();
        let from =
            if self.classes[media].items.is_empty() || (both && self.bulk_lead <= 0) { bulk } else { media };
        let item = self.classes[from].pop()?;
        if both {
            let len = item.datagram.len() as i64;
            self.bulk_lead += if from == bulk { len } else { -len };
        } else {
            self.bulk_lead = 0;
        }
        Some(item)
    }

    fn pop(&mut self) -> Option<Queued> {
        self.classes[..2].iter_mut().find_map(Class::pop).or_else(|| self.pop_bulk_or_media())
    }
}

fn index(class: SendClass) -> usize {
    match class {
        SendClass::Control => 0,
        SendClass::Input => 1,
        SendClass::Bulk => 2,
        SendClass::Media => 3,
    }
}

fn limit(class: SendClass) -> usize {
    match class {
        SendClass::Control => CONTROL_BYTES,
        SendClass::Input => INPUT_BYTES,
        SendClass::Bulk => BULK_BYTES,
        SendClass::Media => MEDIA_BYTES,
    }
}

/// The outgoing side of one TURN allocation.
#[derive(Default)]
pub(crate) struct ClassQueue {
    queues: Mutex<Queues>,
    ready: Notify,
}

impl ClassQueue {
    fn lock(&self) -> std::sync::MutexGuard<'_, Queues> {
        self.queues.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Queue `item` in `class`; `false` once the queue is closed.
    pub(crate) fn push(&self, item: Queued, class: SendClass) -> bool {
        {
            let mut queues = self.lock();
            if queues.closed {
                return false;
            }
            queues.classes[index(class)].push(item, limit(class));
        }
        self.ready.notify_one();
        true
    }

    /// The next datagram by priority, waiting for one; `None` once closed.
    pub(crate) async fn next(&self) -> Option<Queued> {
        loop {
            let ready = self.ready.notified();
            {
                let mut queues = self.lock();
                if queues.closed {
                    return None;
                }
                if let Some(item) = queues.pop() {
                    return Some(item);
                }
            }
            ready.await;
        }
    }

    /// Drop what is queued and refuse more.
    pub(crate) fn close(&self) {
        {
            let mut queues = self.lock();
            queues.closed = true;
            for class in &mut queues.classes {
                class.items.clear();
                class.bytes = 0;
            }
        }
        self.ready.notify_waiters();
        self.ready.notify_one();
    }

    /// Datagrams of `class` dropped so far.
    #[allow(dead_code)]
    pub(crate) fn dropped(&self, class: SendClass) -> u64 {
        self.lock().classes[index(class)].dropped
    }

    /// Bytes of `class` waiting.
    #[cfg(test)]
    pub(crate) fn queued_bytes(&self, class: SendClass) -> usize {
        self.lock().classes[index(class)].bytes
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    fn item(byte: u8, len: usize) -> Queued {
        Queued { datagram: Bytes::from(vec![byte; len]), to: "203.0.113.9:4000".parse().unwrap() }
    }

    /// A stream allocation backs up behind a video burst: the handshake and
    /// the keystroke queued after it still leave first.
    #[tokio::test]
    async fn control_and_input_never_wait_behind_bulk() {
        let queue = Arc::new(ClassQueue::default());
        let permits = Arc::new(tokio::sync::Semaphore::new(0));
        let (sent_tx, mut sent) = tokio::sync::mpsc::unbounded_channel();
        let writer = tokio::spawn({
            let (queue, permits) = (Arc::clone(&queue), Arc::clone(&permits));
            async move {
                while let Some(item) = queue.next().await {
                    let Ok(permit) = permits.acquire().await else { return };
                    permit.forget();
                    let _ = sent_tx.send(item);
                }
            }
        });
        for _ in 0..2000 {
            queue.push(item(0xB0, 1200), SendClass::Bulk);
        }
        queue.push(item(0x1E, 120), SendClass::Input);
        queue.push(item(0x01, 148), SendClass::Control);
        permits.add_permits(4);
        let mut order = Vec::new();
        for _ in 0..4 {
            let got = tokio::time::timeout(Duration::from_secs(5), sent.recv()).await.unwrap().unwrap();
            order.push(got.datagram[0]);
        }
        // The writer may already hold one bulk datagram.
        let position = |byte: u8| order.iter().position(|b| *b == byte).expect("sent");
        assert!(position(0x01) <= 1 && position(0x1E) <= 2, "sent in this order: {order:x?}");
        assert!(position(0x01) < position(0x1E), "{order:x?}");
        queue.close();
        permits.close();
        writer.await.unwrap();
    }

    #[test]
    fn classes_are_bounded_and_drop_their_oldest() {
        let queue = ClassQueue::default();
        for index in 0..2000u32 {
            let mut datagram = vec![0u8; 1200];
            datagram[..4].copy_from_slice(&index.to_be_bytes());
            queue.push(Queued { datagram: datagram.into(), to: item(0, 0).to }, SendClass::Bulk);
        }
        for _ in 0..10 {
            queue.push(item(1, 120), SendClass::Input);
        }
        assert!(queue.queued_bytes(SendClass::Bulk) <= BULK_BYTES);
        assert!(queue.dropped(SendClass::Bulk) > 1500, "{}", queue.dropped(SendClass::Bulk));
        // Bulk never pushes out input.
        assert_eq!(queue.dropped(SendClass::Input), 0);
        assert_eq!(queue.queued_bytes(SendClass::Input), 1200);
        // The newest bulk datagrams are the ones kept.
        let mut last = None;
        while let Some(got) = queue.lock().pop() {
            if got.datagram.len() == 1200 {
                last = Some(u32::from_be_bytes(got.datagram[..4].try_into().unwrap()));
            }
        }
        assert_eq!(last, Some(1999));
    }

    #[test]
    fn bulk_and_media_share_the_stream_by_bytes() {
        let queue = ClassQueue::default();
        for _ in 0..100 {
            queue.push(item(0xB0, 1200), SendClass::Bulk);
            queue.push(item(0x3D, 600), SendClass::Media);
        }
        let (mut bulk, mut media) = (0usize, 0usize);
        for _ in 0..60 {
            let got = queue.lock().pop().expect("queued");
            match got.datagram[0] {
                0xB0 => bulk += got.datagram.len(),
                0x3D => media += got.datagram.len(),
                other => panic!("unexpected {other:x}"),
            }
        }
        assert!(bulk.abs_diff(media) <= 1200, "bulk {bulk} bytes, media {media} bytes");
        for _ in 0..1000 {
            queue.push(item(0x3D, 1200), SendClass::Media);
        }
        assert!(queue.queued_bytes(SendClass::Media) <= MEDIA_BYTES);
        assert!(queue.dropped(SendClass::Media) > 0);
    }

    #[tokio::test(start_paused = true)]
    async fn stale_media_is_dropped() {
        let queue = ClassQueue::default();
        queue.push(item(0x3D, 600), SendClass::Media);
        tokio::time::advance(MEDIA_MAX_AGE + Duration::from_millis(1)).await;
        queue.push(item(0x3E, 600), SendClass::Media);
        assert_eq!(queue.lock().pop(), Some(item(0x3E, 600)));
        assert_eq!(queue.dropped(SendClass::Media), 1);
        assert_eq!(queue.lock().pop(), None);
    }

    #[tokio::test]
    async fn a_closed_queue_refuses_and_ends_the_writer() {
        let queue = Arc::new(ClassQueue::default());
        assert!(queue.push(item(0, 1200), SendClass::Bulk));
        let waiting = tokio::spawn({
            let queue = Arc::clone(&queue);
            async move {
                let _ = queue.next().await;
                queue.next().await
            }
        });
        tokio::task::yield_now().await;
        queue.close();
        assert!(tokio::time::timeout(Duration::from_secs(5), waiting).await.unwrap().unwrap().is_none());
        assert!(!queue.push(item(0, 10), SendClass::Control));
        assert_eq!(queue.queued_bytes(SendClass::Bulk), 0);
    }

    #[test]
    fn classes_follow_the_datagram_shape() {
        let data = |len: usize| {
            let mut datagram = vec![0u8; len];
            datagram[0] = 4;
            datagram
        };
        let mut initiation = vec![0u8; 148];
        initiation[0] = 1;
        assert_eq!(send_class(&initiation), SendClass::Control);
        assert_eq!(send_class(&data(32)), SendClass::Control, "keepalive");
        assert_eq!(send_class(&data(32 + 64)), SendClass::Input, "a TCP ACK");
        assert_eq!(send_class(&data(INPUT_MAX)), SendClass::Input);
        assert_eq!(send_class(&data(INPUT_MAX + 16)), SendClass::Bulk);
        assert_eq!(send_class(&data(1312)), SendClass::Bulk, "a full-size segment or RTP packet");
    }
}
