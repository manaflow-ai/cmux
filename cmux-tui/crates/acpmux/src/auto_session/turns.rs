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
#[path = "turns_tests.rs"]
mod tests;
