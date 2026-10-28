//! The owner's queue of host entries it has read from the socket and not yet
//! logged, bounded by bytes.
//!
//! The host keeps every entry until the owner acknowledges it (up to
//! [`super::DEFAULT_BUFFER_CAP`]), so entries the owner has not logged yet are
//! safe in the host. The owner keeps only enough read ahead to stay busy.
//! Before this bound, the queue held up to 4096 decoded entries per agent:
//! with 100 fake agents streaming faster than the daemon logged, about 3 MB
//! per agent of one-word chunks; 4096 entries of a few KB
//! each are the 24 MB per agent measured with real agents
//! (plans/cmux-next/resource-efficiency-DESIGN.md, offender 6). Chrome bounds
//! a reader the same way: a Mojo data pipe has a fixed byte capacity, and its
//! producer waits for room (`mojo/core/data_pipe_producer_dispatcher.cc`).

use super::Entry;
use std::sync::Arc;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc};

/// Wire bytes of entries one owner holds read ahead of its log, per agent.
pub const QUEUE_BYTES: usize = 64 * 1024;

/// At most this many entries, however small: a decoded entry holds several times its wire
/// bytes as a `Value` tree, so small entries are counted too.
const QUEUE_ENTRIES: usize = 32;

/// The queue's reader is gone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QueueClosed;

type Queued = (u64, Entry, OwnedSemaphorePermit);

/// The socket side: queues each entry once there is room for its bytes.
pub struct EntrySender {
    tx: mpsc::Sender<Queued>,
    room: Arc<Semaphore>,
    budget: usize,
}

/// The log side: entries in the host's order.
pub struct EntryQueue {
    rx: mpsc::Receiver<Queued>,
    room: Arc<Semaphore>,
    budget: usize,
}

/// A queue of `budget` wire bytes ([`QUEUE_BYTES`] for an owner).
pub fn entry_queue(budget: usize) -> (EntrySender, EntryQueue) {
    let budget = budget.clamp(1, Semaphore::MAX_PERMITS);
    let (tx, rx) = mpsc::channel(QUEUE_ENTRIES);
    let room = Arc::new(Semaphore::new(budget));
    (EntrySender { tx, room: room.clone(), budget }, EntryQueue { rx, room, budget })
}

impl EntrySender {
    /// Waits until the queue has room for `bytes`, then queues entry `h`. An
    /// entry larger than the whole budget waits for an empty queue and then
    /// passes alone.
    pub async fn send(&self, h: u64, entry: Entry, bytes: usize) -> Result<(), QueueClosed> {
        let want = u32::try_from(bytes.clamp(1, self.budget)).map_err(|_| QueueClosed)?;
        let permit = self.room.clone().acquire_many_owned(want).await.map_err(|_| QueueClosed)?;
        self.tx.send((h, entry, permit)).await.map_err(|_| QueueClosed)
    }
}

impl EntryQueue {
    /// The next entry; its bytes leave the queue as it is taken. `None` once
    /// the connection ended and every queued entry was taken.
    pub async fn recv(&mut self) -> Option<(u64, Entry)> {
        let (h, entry, _room) = self.rx.recv().await?;
        Some((h, entry))
    }

    /// Wire bytes queued now.
    pub fn queued_bytes(&self) -> usize {
        self.budget - self.room.available_permits()
    }
}

impl Drop for EntryQueue {
    /// A sender waiting for room ends instead of waiting forever.
    fn drop(&mut self) {
        self.room.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::FutureExt;
    use std::time::Duration;

    fn line(bytes: usize) -> Entry {
        Entry::Err { line: "x".repeat(bytes) }
    }

    #[tokio::test]
    async fn the_queue_holds_at_most_its_budget_and_takes_more_as_entries_leave() {
        let (tx, mut rx) = entry_queue(1000);
        for h in 1..=4 {
            tx.send(h, line(250), 250).await.unwrap();
        }
        assert_eq!(rx.queued_bytes(), 1000);
        // Full: the fifth waits for room.
        let fifth = tx.send(5, line(250), 250);
        tokio::pin!(fifth);
        assert!((&mut fifth).now_or_never().is_none());
        assert_eq!(rx.recv().await.map(|(h, _)| h), Some(1));
        tokio::time::timeout(Duration::from_secs(5), fifth).await.unwrap().unwrap();
        assert_eq!(rx.queued_bytes(), 1000);
        for h in 2..=5 {
            assert_eq!(rx.recv().await.map(|(h, _)| h), Some(h));
        }
        assert_eq!(rx.queued_bytes(), 0);
    }

    #[tokio::test]
    async fn an_entry_larger_than_the_budget_passes_alone() {
        let (tx, mut rx) = entry_queue(1000);
        tx.send(1, line(10), 10).await.unwrap();
        let big = tx.send(2, line(5000), 5000);
        tokio::pin!(big);
        assert!((&mut big).now_or_never().is_none());
        assert_eq!(rx.recv().await.map(|(h, _)| h), Some(1));
        tokio::time::timeout(Duration::from_secs(5), big).await.unwrap().unwrap();
        assert_eq!(rx.queued_bytes(), 1000);
        assert_eq!(rx.recv().await.map(|(h, _)| h), Some(2));
        assert_eq!(rx.queued_bytes(), 0);
    }

    #[tokio::test]
    async fn a_sender_waiting_for_room_ends_when_the_reader_goes() {
        let (tx, rx) = entry_queue(100);
        tx.send(1, line(100), 100).await.unwrap();
        let waiting = tx.send(2, line(100), 100);
        tokio::pin!(waiting);
        assert!((&mut waiting).now_or_never().is_none());
        drop(rx);
        let sent = tokio::time::timeout(Duration::from_secs(5), waiting).await.unwrap();
        assert_eq!(sent, Err(QueueClosed));
    }
}
