//! One at a time in a chat's folder.
//!
//! Three things of Auto mode run git in the chat's folder: the leftover patch being cut, an
//! import that makes the folder the Cloud's copy, and the person settling the kept changes
//! (`_acpmux/auto_session/leftover`). Each takes the chat's turn first, so two Applies never
//! merge one patch at once and an Apply never merges into a folder an import is changing.
//!
//! The holder loop never takes a turn itself: its tasks do, so a renewal never waits for git.

use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex};

use tokio::sync::{Mutex, OwnedMutexGuard};

/// The turns of every chat of one daemon. A chat's entry stays once made: it is one small lock
/// per chat that ever had an import or kept changes.
#[derive(Default)]
pub(crate) struct Turns {
    chats: StdMutex<HashMap<String, Arc<Mutex<()>>>>,
}

/// A chat's turn, held until dropped.
pub(crate) struct Turn {
    _held: OwnedMutexGuard<()>,
}

impl Turns {
    /// Waits for the turn of chat `id`. Whoever asked first goes first.
    pub(crate) async fn take(&self, id: &str) -> Turn {
        let lock = {
            let mut chats = self.chats.lock().unwrap_or_else(|e| e.into_inner());
            chats.entry(id.to_owned()).or_default().clone()
        };
        Turn { _held: lock.lock_owned().await }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[tokio::test]
    async fn a_chat_has_one_turn_and_another_chat_does_not_wait_for_it() {
        let turns = Arc::new(Turns::default());
        let first = turns.take("a").await;
        // Another chat goes at once.
        let _other = turns.take("b").await;
        let (done, mut heard) = tokio::sync::mpsc::unbounded_channel();
        let waiting = turns.clone();
        let second = tokio::spawn(async move {
            let _turn = waiting.take("a").await;
            let _ = done.send(());
        });
        let early = tokio::time::timeout(Duration::from_millis(200), heard.recv()).await;
        assert!(early.is_err(), "the second took the turn while the first held it");
        drop(first);
        tokio::time::timeout(Duration::from_secs(10), heard.recv())
            .await
            .expect("the second goes once the first is done");
        second.await.unwrap();
    }
}
