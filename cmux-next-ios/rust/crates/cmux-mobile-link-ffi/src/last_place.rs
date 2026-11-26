//! Where the person was (`cmux-mobile-last-place`): the workspace, the chat or terminal in it,
//! the scroll anchor and the selection, opened again on launch from the phone's own file.
//!
//! One object for the app, opened synchronously at launch (the file read is one small file).
//! Swift reports moves and scroll rests with its monotonic clock in milliseconds and calls
//! `tick` when a returned deadline passes and `flush` when it goes to the background; the
//! debounce and every rule about what is kept are the crate's. A mutex keeps it `Sync` for
//! uniffi and is held only for the call.

use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, PoisonError};

use cmux_mobile_last_place::{LastPlace, Note, Restore, Screen, ScrollAnchor, Store};

/// How long moves and scrolls must stop before the file is written.
const QUIET_MS: u64 = 400;
/// The longest a change waits while changes keep coming (a long scroll).
const MAX_WAIT_MS: u64 = 2_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LastPlaceScreen {
    Chat,
    Terminal,
}

/// The row at the top of the visible part and how far past its top the reader was, in points.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LastPlaceAnchor {
    pub row: String,
    pub offset: f64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LastPlaceRecord {
    pub workspace_id: String,
    pub screen: Option<LastPlaceScreen>,
    pub item_id: Option<String>,
    pub anchor: Option<LastPlaceAnchor>,
    pub selection: Option<String>,
}

fn screen_in(screen: LastPlaceScreen) -> Screen {
    match screen {
        LastPlaceScreen::Chat => Screen::Chat,
        LastPlaceScreen::Terminal => Screen::Terminal,
    }
}

fn screen_out(screen: Screen) -> LastPlaceScreen {
    match screen {
        Screen::Chat => LastPlaceScreen::Chat,
        Screen::Terminal => LastPlaceScreen::Terminal,
    }
}

fn anchor_in(anchor: LastPlaceAnchor) -> ScrollAnchor {
    ScrollAnchor { row: anchor.row, offset: anchor.offset }
}

fn anchor_out(anchor: &ScrollAnchor) -> LastPlaceAnchor {
    LastPlaceAnchor { row: anchor.row.clone(), offset: anchor.offset }
}

fn record_out(place: LastPlace) -> LastPlaceRecord {
    LastPlaceRecord {
        workspace_id: place.workspace,
        screen: place.screen.map(screen_out),
        item_id: place.item,
        anchor: place.scroll.as_ref().map(anchor_out),
        selection: place.selection,
    }
}

/// When to call `tick` next (`None`: nothing is waiting).
fn due(note: Note) -> Option<u64> {
    match note {
        Note::Due { at_ms } | Note::Failed { at_ms } => Some(at_ms),
        Note::Unchanged | Note::Written => None,
    }
}

#[derive(uniffi::Object)]
pub struct LastPlaceStore {
    inner: Mutex<Store>,
}

impl LastPlaceStore {
    fn inner(&self) -> MutexGuard<'_, Store> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl LastPlaceStore {
    /// Reads the file at `path` now. A missing, corrupt or newer file is no place.
    #[uniffi::constructor]
    pub fn open(path: String) -> Self {
        Self { inner: Mutex::new(Store::open(PathBuf::from(path), QUIET_MS, MAX_WAIT_MS)) }
    }

    /// The place to open at launch, checked against the cached workspace ids (and, when the
    /// cache has them, that workspace's tab ids). `None`: the list.
    pub fn restore(
        &self,
        workspace_ids: Vec<String>,
        item_ids: Option<Vec<String>>,
    ) -> Option<LastPlaceRecord> {
        match self.inner().restore(&workspace_ids, item_ids.as_deref()) {
            Restore::List => None,
            Restore::Place(place) => Some(record_out(place)),
        }
    }

    /// The person moved (`workspace_id` `None`: the list). Returns when to call `tick`.
    pub fn note_location(
        &self,
        workspace_id: Option<String>,
        screen: Option<LastPlaceScreen>,
        item_id: Option<String>,
        now_ms: u64,
    ) -> Option<u64> {
        due(self.inner().note_location(workspace_id, screen.map(screen_in), item_id, now_ms))
    }

    /// The reader of a chat or terminal came to rest (`anchor` `None`: on the newest row).
    /// Returns when to call `tick`.
    pub fn note_scroll(
        &self,
        workspace_id: String,
        item_id: String,
        anchor: Option<LastPlaceAnchor>,
        now_ms: u64,
    ) -> Option<u64> {
        due(self.inner().note_scroll(&workspace_id, &item_id, anchor.map(anchor_in), now_ms))
    }

    /// Where that chat or terminal was scrolled, if it is the saved place.
    pub fn scroll_for(&self, workspace_id: String, item_id: String) -> Option<LastPlaceAnchor> {
        self.inner().scroll_for(&workspace_id, &item_id).map(anchor_out)
    }

    /// Writes a waiting change whose time came. Returns when to call again.
    pub fn tick(&self, now_ms: u64) -> Option<u64> {
        due(self.inner().tick(now_ms))
    }

    /// Writes a waiting change now (the app goes to the background). Returns whether it wrote.
    pub fn flush(&self) -> bool {
        self.inner().flush().unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_store_round_trips_through_its_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("last-place.json").to_string_lossy().into_owned();
        let store = LastPlaceStore::open(path.clone());
        assert_eq!(store.restore(vec!["w1".into()], None), None);
        let at =
            store.note_location(Some("w1".into()), Some(LastPlaceScreen::Chat), Some("c1".into()), 1_000);
        assert_eq!(at, Some(1_000 + QUIET_MS));
        let anchor = LastPlaceAnchor { row: "m4".into(), offset: 18.0 };
        store.note_scroll("w1".into(), "c1".into(), Some(anchor.clone()), 1_100);
        assert!(store.flush());

        let store = LastPlaceStore::open(path);
        assert_eq!(store.scroll_for("w1".into(), "c1".into()), Some(anchor.clone()));
        assert_eq!(
            store.restore(vec!["w0".into(), "w1".into()], Some(vec!["c1".into()])),
            Some(LastPlaceRecord {
                workspace_id: "w1".into(),
                screen: Some(LastPlaceScreen::Chat),
                item_id: Some("c1".into()),
                anchor: Some(anchor),
                selection: Some("c1".into()),
            })
        );
        // The workspace closed since: the list.
        assert_eq!(store.restore(vec!["w2".into()], None), None);
    }
}
