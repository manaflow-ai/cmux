//! A session list row may reach a viewer before that session's journal body
//! does: the list and each session's journal are separate streams, and no
//! commit order on the server orders their arrival at the viewer
//! (`spec/session-journal.md`, "Session list rows"). This is the rule every
//! list view follows (desktop sidebar, iOS, Cloud), as one pure value with no
//! clock and no I/O:
//!
//! - a row names its journal head (`extra.journal_head_sequence`);
//! - the viewer reports the journal cursor it holds for that session;
//! - while the cursor is below the head the row is [`RowSync::Syncing`]: it is
//!   never shown as new, and a notification about it is held;
//! - once the cursor reaches the head, held notifications are released in the
//!   order they were offered, each exactly once.

use std::collections::{BTreeMap, VecDeque};

use crate::{SessionId, SessionSnapshot};

/// The `extra` key a session row carries its journal head in.
pub const JOURNAL_HEAD_EXTRA_KEY: &str = "journal_head_sequence";

/// The journal head a row names, if it names one (a daemon that predates the
/// field names none; such a row is never held).
pub fn row_journal_head(row: &SessionSnapshot) -> Option<u64> {
    let raw = row.extra.get(JOURNAL_HEAD_EXTRA_KEY)?.as_str()?;
    // Canonical decimal, like every journal cursor on the wire.
    if raw.is_empty() || (raw.len() > 1 && raw.starts_with('0')) {
        return None;
    }
    if !raw.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    raw.parse().ok()
}

/// Whether the viewer holds a row's body.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowSync {
    /// The local cursor has reached the head the row named.
    Synced,
    /// The row ran ahead of its body: show it as syncing and fetch the tail.
    Syncing { cursor: u64, head: u64 },
}

/// What a list view shows for one row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RowView {
    pub sync: RowSync,
    /// Shown as new (dot, badge, bold): unread and synced, never while syncing.
    pub new: bool,
}

#[derive(Debug)]
struct Entry<N> {
    head: u64,
    cursor: u64,
    held: VecDeque<N>,
}

impl<N> Default for Entry<N> {
    fn default() -> Self {
        Self { head: 0, cursor: 0, held: VecDeque::new() }
    }
}

impl<N> Entry<N> {
    fn sync(&self) -> RowSync {
        if self.cursor >= self.head {
            RowSync::Synced
        } else {
            RowSync::Syncing { cursor: self.cursor, head: self.head }
        }
    }
}

/// The viewer's per-session head and cursor, and the notifications it holds.
/// `N` is the caller's notification value.
#[derive(Debug)]
pub struct SessionListSync<N> {
    sessions: BTreeMap<SessionId, Entry<N>>,
    released: VecDeque<(SessionId, N)>,
}

impl<N> Default for SessionListSync<N> {
    fn default() -> Self {
        Self { sessions: BTreeMap::new(), released: VecDeque::new() }
    }
}

impl<N> SessionListSync<N> {
    pub fn new() -> Self {
        Self::default()
    }

    /// A list row arrived. The head only moves forward: a stale row (an older
    /// list read) never makes a synced session look synced early or late.
    pub fn observe_row(&mut self, row: &SessionSnapshot) {
        if let Some(head) = row_journal_head(row) {
            self.observe_head(&row.id, head);
        }
    }

    /// The head a row named, when the caller decoded it itself.
    pub fn observe_head(&mut self, session: &SessionId, head: u64) {
        let entry = self.sessions.entry(session.clone()).or_default();
        entry.head = entry.head.max(head);
        self.release(session);
    }

    /// The viewer now holds the session's journal through `sequence` (the
    /// last record it received, or the cursor it resumed from).
    pub fn observe_cursor(&mut self, session: &SessionId, sequence: u64) {
        let entry = self.sessions.entry(session.clone()).or_default();
        entry.cursor = entry.cursor.max(sequence);
        self.release(session);
    }

    /// A row left the list: forget it and drop what it held.
    pub fn forget(&mut self, session: &SessionId) {
        self.sessions.remove(session);
    }

    pub fn sync(&self, session: &SessionId) -> RowSync {
        self.sessions.get(session).map_or(RowSync::Synced, Entry::sync)
    }

    /// What to show for a row the caller's own state calls `unread`.
    pub fn row(&self, session: &SessionId, unread: bool) -> RowView {
        let sync = self.sync(session);
        RowView { sync, new: unread && sync == RowSync::Synced }
    }

    /// Offer a notification about `session`. Returns it when it may fire now;
    /// otherwise it is held until the cursor reaches the head, then comes out
    /// of [`Self::take_released`].
    pub fn offer(&mut self, session: &SessionId, notification: N) -> Option<N> {
        let entry = self.sessions.entry(session.clone()).or_default();
        if entry.sync() == RowSync::Synced && entry.held.is_empty() {
            return Some(notification);
        }
        entry.held.push_back(notification);
        None
    }

    /// Notifications released since the last call, in offer order.
    pub fn take_released(&mut self) -> Vec<(SessionId, N)> {
        self.released.drain(..).collect()
    }

    /// How many notifications are held across every session.
    pub fn held_count(&self) -> usize {
        self.sessions.values().map(|entry| entry.held.len()).sum()
    }

    fn release(&mut self, session: &SessionId) {
        let Some(entry) = self.sessions.get_mut(session) else { return };
        if entry.sync() != RowSync::Synced {
            return;
        }
        for notification in entry.held.drain(..) {
            self.released.push_back((session.clone(), notification));
        }
    }
}
