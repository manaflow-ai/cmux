//! What the signaling socket sends next: JSON text (offers, answers, ICE,
//! `wg-*`, `bye`) and WebSocket pings, in order. WireGuard datagrams never
//! ride this socket (PROTOCOL.md: the backend relay frames are retired; a
//! tunnel without a UDP path uses TURN over TLS).

use std::collections::VecDeque;
use std::sync::{Mutex, PoisonError};

use futures_util::{Sink, SinkExt};
use tokio::sync::Notify;
use tokio_tungstenite::tungstenite::Message;

use crate::signaling::SignalingError;

/// What the writer sends.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Signal {
    Text(String),
    Ping,
}

#[derive(Default)]
struct Queues {
    signals: VecDeque<Signal>,
    /// Close requested: what is queued already still goes out.
    closing: bool,
    /// The writer is gone: nothing is accepted any more.
    closed: bool,
}

/// The outgoing side of one signaling socket.
#[derive(Default)]
pub(crate) struct SendQueue {
    queues: Mutex<Queues>,
    ready: Notify,
}

impl SendQueue {
    fn lock(&self) -> std::sync::MutexGuard<'_, Queues> {
        self.queues.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn push_signal(&self, signal: Signal) -> Result<(), SignalingError> {
        {
            let mut queues = self.lock();
            if queues.closed || queues.closing {
                return Err(SignalingError::Closed);
            }
            queues.signals.push_back(signal);
        }
        self.ready.notify_one();
        Ok(())
    }

    /// Ask the writer to close the socket once the signals already queued
    /// are sent.
    pub(crate) fn close(&self) {
        self.lock().closing = true;
        self.ready.notify_one();
    }

    /// The next message; `Some(None)` once closing and the queue is empty.
    fn pop(&self) -> Option<Option<Message>> {
        let mut queues = self.lock();
        if let Some(signal) = queues.signals.pop_front() {
            return Some(Some(match signal {
                Signal::Text(text) => Message::Text(text.into()),
                Signal::Ping => Message::Ping(Vec::new().into()),
            }));
        }
        queues.closing.then_some(None)
    }

    fn finish(&self) {
        let mut queues = self.lock();
        queues.closed = true;
        queues.signals.clear();
    }

    /// Send what is queued on `sink`, in order, until a close or a send
    /// fails; then close the sink.
    pub(crate) async fn write_out<S>(&self, mut sink: S)
    where
        S: Sink<Message> + Unpin,
    {
        loop {
            let message = loop {
                let ready = self.ready.notified();
                if let Some(message) = self.pop() {
                    break message;
                }
                ready.await;
            };
            let Some(message) = message else { break };
            if sink.send(message).await.is_err() {
                break;
            }
        }
        self.finish();
        let _ = sink.close().await;
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::*;

    #[tokio::test]
    async fn signals_go_out_in_order_then_the_queue_closes() {
        let queue = Arc::new(SendQueue::default());
        let (sent_tx, mut sent) = tokio::sync::mpsc::unbounded_channel::<Message>();
        let sink = Box::pin(futures_util::sink::unfold(sent_tx, |sent, message: Message| async move {
            sent.send(message).map_err(|_| ())?;
            Ok::<_, ()>(sent)
        }));
        queue.push_signal(Signal::Text("offer".into())).unwrap();
        queue.push_signal(Signal::Ping).unwrap();
        queue.push_signal(Signal::Text("bye".into())).unwrap();
        queue.close();
        tokio::time::timeout(Duration::from_secs(5), queue.write_out(sink)).await.unwrap();
        let mut order = Vec::new();
        while let Ok(message) = sent.try_recv() {
            order.push(message);
        }
        assert_eq!(
            order,
            vec![
                Message::Text("offer".into()),
                Message::Ping(Vec::new().into()),
                Message::Text("bye".into())
            ]
        );
        assert!(queue.push_signal(Signal::Ping).is_err());
    }
}
