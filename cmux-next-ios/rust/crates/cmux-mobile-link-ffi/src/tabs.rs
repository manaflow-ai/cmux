//! The phone side of the `tabs` link service: the Mac's tab manifest, its deltas and the
//! content-hashed blobs (favicon, thumbnail, terminal screen) that fill every card of the tab
//! overview (Leo, 2026-11-22: "if the phone is simply browsing the opened tabs on the mac,
//! there should be no reason for there to be so many blank favicons and blank previews and
//! blank pages").
//!
//! The wire and the apply rules are `cmux-tab-snapshots` (shared with the Mac). This module
//! adds what only the phone decides:
//! - what to say on link-up ([`TabsMirror::link_up`]): `have` for the pictures already on
//!   disk, `resume` for the manifest it last applied, then its card geometry;
//! - which blobs to ask for first ([`want_order`]): every blob of the cards near the open
//!   tab, a whole card at a time, then the other cards' favicons, then their pictures;
//! - which blobs on disk no card shows any more ([`TabsMirror::unreferenced`]).
//!
//! Swift only binds: it writes the frames these return, saves a blob's bytes under its
//! hash and hands the rows to the overview.

use std::collections::HashSet;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use cmux_tab_snapshots::wire::Viewport;
use cmux_tab_snapshots::{Applied, BlobHash, Message, Mirror, MirrorError, Row};

/// The phone's card geometry, so the Mac cuts thumbnails at the card's pixel size.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct TabsViewport {
    pub card_pixel_width: u32,
    pub card_aspect: f64,
    pub display_scale: f64,
    pub screen_pixel_w: u32,
    pub screen_pixel_h: u32,
}

/// One card. Hashes are lowercase sha256 hex, the name a blob is saved under.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct TabsRow {
    pub tab_id: String,
    pub title: String,
    /// `browser`, `terminal`, `agent`, or a kind a newer Mac names.
    pub kind: String,
    pub favicon_hash: Option<String>,
    pub thumb_hash: Option<String>,
    pub thumb_w: u32,
    pub thumb_h: u32,
    /// The thumbnail's mime type (`image/jpeg`, `image/png`).
    pub thumb_mime: String,
    /// A terminal's screen as text (`text/x-cmux-screen`), `screen_cols` by `screen_rows`.
    pub screen_hash: Option<String>,
    pub screen_cols: u32,
    pub screen_rows: u32,
    /// The page-size picture, asked for only when a tab opens.
    pub frame_hash: Option<String>,
    pub captured_at_ms: i64,
    /// Every blob the card shows is on the phone.
    pub filled: bool,
}

/// What one frame from the Mac did. `send` is what to write back, in order.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TabsEvent {
    /// The rows changed (a manifest or a delta): show them. `send` asks for what is missing.
    Rows { rev: u64, rows: Vec<TabsRow>, send: Vec<Vec<u8>> },
    /// A blob whose bytes match its hash: save `bytes` under `hash`. `tab_ids` are the cards
    /// it completes a part of. `fresh` is false when the phone held it already.
    Blob { hash: String, mime: String, bytes: Vec<u8>, fresh: bool, tab_ids: Vec<String> },
    /// A delta that does not start at the phone's rev: nothing changed; `send` asks the Mac
    /// to resume from the phone's rev.
    Gap { send: Vec<Vec<u8>> },
    /// A frame that does not decode, a blob whose bytes do not hash to its name, or a kind a
    /// newer Mac sends: dropped, and the link stays up.
    Dropped { reason: String },
}

fn hex(hash: Option<BlobHash>) -> Option<String> {
    hash.map(|h| h.to_hex())
}

/// The blobs a card shows in the grid: favicon, then thumbnail or terminal screen. The
/// page-size frame is not one of them.
fn card_hashes(row: &Row) -> impl Iterator<Item = BlobHash> {
    [row.favicon_hash, row.thumb_hash, row.screen_hash].into_iter().flatten()
}

/// The order to ask for missing blobs, each hash once:
/// 1. the cards in `near` (nearest the open tab first), every blob of one card before the
///    next, so the cards on screen fill whole;
/// 2. the favicons of the other cards, in tab order (small, and a title row with its icon
///    reads as a tab even before its picture);
/// 3. the pictures of the other cards, in tab order.
pub(crate) fn want_order(rows: &[Row], near: &[String], holds: impl Fn(&BlobHash) -> bool) -> Vec<BlobHash> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    let mut push = |hash: BlobHash| {
        if !holds(&hash) && seen.insert(hash) {
            out.push(hash);
        }
    };
    let near_set: HashSet<&str> = near.iter().map(String::as_str).collect();
    for id in near {
        if let Some(row) = rows.iter().find(|r| &r.tab_id == id) {
            card_hashes(row).for_each(&mut push);
        }
    }
    let rest = || rows.iter().filter(|r| !near_set.contains(r.tab_id.as_str()));
    rest().filter_map(|r| r.favicon_hash).for_each(&mut push);
    rest().flat_map(|r| [r.thumb_hash, r.screen_hash]).flatten().for_each(&mut push);
    out
}

#[derive(Default)]
struct State {
    mirror: Mirror,
    /// Tab ids nearest the open tab first, as the overview last said.
    near: Vec<String>,
    /// The last `want` written, so an unchanged list is not sent again.
    last_want: Vec<BlobHash>,
}

impl State {
    fn rows(&self) -> Vec<TabsRow> {
        self.mirror
            .rows()
            .iter()
            .map(|row| TabsRow {
                tab_id: row.tab_id.clone(),
                title: row.title.clone(),
                kind: row.kind.as_str().to_owned(),
                favicon_hash: hex(row.favicon_hash),
                thumb_hash: hex(row.thumb_hash),
                thumb_w: row.thumb_w,
                thumb_h: row.thumb_h,
                thumb_mime: row.thumb_mime.as_str().to_owned(),
                screen_hash: hex(row.screen_hash),
                screen_cols: row.screen_cols,
                screen_rows: row.screen_rows,
                frame_hash: hex(row.frame_hash),
                captured_at_ms: row.captured_at_ms,
                filled: card_hashes(row).all(|h| self.mirror.holds(&h)),
            })
            .collect()
    }

    /// A `want` for what is missing, or nothing when the list is the one last sent. An
    /// empty list is sent once after a non-empty one, so the Mac stops pushing for it.
    fn want(&mut self) -> Vec<Vec<u8>> {
        let order = want_order(self.mirror.rows(), &self.near, |h| self.mirror.holds(h));
        if order == self.last_want {
            return Vec::new();
        }
        self.last_want.clone_from(&order);
        vec![Message::Want(order).encode()]
    }
}

/// The phone's copy of the Mac's tab list for one link. Make one per Mac; it lives across
/// reconnects so a reconnect resumes from its rev instead of reading the manifest again.
#[derive(uniffi::Object)]
pub struct TabsMirror {
    state: Mutex<State>,
}

impl TabsMirror {
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl TabsMirror {
    /// `held` are the hashes of the blobs on disk from earlier launches (a name that is not
    /// a sha256 hex is skipped).
    #[uniffi::constructor]
    pub fn new(held: Vec<String>) -> Arc<Self> {
        let mut mirror = Mirror::new();
        mirror.import_held(held.iter().filter_map(|h| BlobHash::from_hex(h)));
        Arc::new(Self { state: Mutex::new(State { mirror, ..State::default() }) })
    }

    /// The frames to write when the `tabs` channel opens, in order: `have`, `resume` (after
    /// a first manifest), then `viewport`.
    pub fn link_up(&self, viewport: TabsViewport) -> Vec<Vec<u8>> {
        let mut state = self.state();
        // The Mac forgot the last `want` with the old channel.
        state.last_want.clear();
        let mut frames = state.mirror.link_up_frames();
        frames.push(
            Message::Viewport(Viewport {
                card_pixel_width: viewport.card_pixel_width,
                card_aspect: viewport.card_aspect,
                display_scale: viewport.display_scale,
                screen_pixel_w: viewport.screen_pixel_w,
                screen_pixel_h: viewport.screen_pixel_h,
            })
            .encode(),
        );
        frames
    }

    /// One frame from the Mac.
    pub fn receive(&self, frame: Vec<u8>) -> TabsEvent {
        let msg = match Message::decode(&frame) {
            Ok(msg) => msg,
            Err(err) => return TabsEvent::Dropped { reason: err.to_string() },
        };
        // The mirror keeps hashes, not bytes: the bytes are kept aside for Swift to save.
        let (blob_mime, blob_bytes) = match &msg {
            Message::Blob(blob) => (blob.mime.as_str().to_owned(), blob.bytes.clone()),
            _ => (String::new(), Vec::new()),
        };
        let mut state = self.state();
        match state.mirror.apply(msg) {
            Ok(Applied::Manifest { rev } | Applied::Delta { rev }) => {
                let send = state.want();
                TabsEvent::Rows { rev, rows: state.rows(), send }
            }
            Ok(Applied::Gap { .. }) => {
                TabsEvent::Gap { send: state.mirror.resume_frame().into_iter().collect() }
            }
            Ok(Applied::Blob { hash, fresh, .. }) => {
                let tab_ids = state
                    .mirror
                    .rows()
                    .iter()
                    .filter(|row| row.hashes().any(|h| h == hash))
                    .map(|row| row.tab_id.clone())
                    .collect();
                // What is still missing shrank by this one; the Mac drops it from its own
                // queue, so no new `want` is written for it.
                state.last_want.retain(|h| *h != hash);
                TabsEvent::Blob { hash: hash.to_hex(), mime: blob_mime, bytes: blob_bytes, fresh, tab_ids }
            }
            Err(
                err @ (MirrorError::Wire(_)
                | MirrorError::HashMismatch { .. }
                | MirrorError::WrongDirection(_)),
            ) => TabsEvent::Dropped { reason: err.to_string() },
        }
    }

    /// The overview's cards nearest the open tab, nearest first (the cards on screen). The
    /// frames to write: a reordered `want`, or nothing when the order of what is missing did
    /// not change.
    pub fn set_near(&self, tab_ids: Vec<String>) -> Vec<Vec<u8>> {
        let mut state = self.state();
        state.near = tab_ids;
        state.want()
    }

    /// The rows as last applied, in tab order.
    pub fn rows(&self) -> Vec<TabsRow> {
        self.state().rows()
    }

    /// The rev of the last manifest or delta applied, if any.
    pub fn rev(&self) -> Option<u64> {
        self.state().mirror.rev()
    }

    /// A `want` for one tab's page-size frame, written when the person opens the tab.
    /// Nothing when the row has none or the phone holds it.
    pub fn want_frame(&self, tab_id: String) -> Vec<Vec<u8>> {
        let state = self.state();
        let Some(hash) = state
            .mirror
            .rows()
            .iter()
            .find(|row| row.tab_id == tab_id)
            .and_then(|row| row.frame_hash)
            .filter(|hash| !state.mirror.holds(hash))
        else {
            return Vec::new();
        };
        // The frame first, then what the grid still misses, so asking for a page does not
        // drop the cards from the Mac's list (a `want` replaces the last).
        let mut order = vec![hash];
        order.extend(
            want_order(state.mirror.rows(), &state.near, |h| state.mirror.holds(h))
                .into_iter()
                .filter(|h| *h != hash),
        );
        vec![Message::Want(order).encode()]
    }

    /// Of `on_disk`, the blob names no row shows any more: the ones the phone may delete.
    /// Before a first manifest nothing is known to be unused, so nothing is returned.
    pub fn unreferenced(&self, on_disk: Vec<String>) -> Vec<String> {
        let state = self.state();
        if state.mirror.rev().is_none() {
            return Vec::new();
        }
        let used: HashSet<String> =
            state.mirror.rows().iter().flat_map(Row::hashes).map(|h| h.to_hex()).collect();
        on_disk.into_iter().filter(|name| !used.contains(name)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tab_snapshots::wire::{Delta, Manifest, encode_blob};
    use cmux_tab_snapshots::{Kind, Mime, RowPatch};

    fn h(bytes: &[u8]) -> BlobHash {
        BlobHash::of(bytes)
    }

    fn row(id: &str, favicon: &[u8], thumb: &[u8]) -> Row {
        Row {
            tab_id: id.to_owned(),
            title: id.to_uppercase(),
            kind: Kind::Browser,
            favicon_hash: Some(h(favicon)),
            thumb_hash: Some(h(thumb)),
            thumb_mime: Mime::Jpeg,
            ..Row::default()
        }
    }

    fn manifest(rev: u64, rows: Vec<Row>) -> Vec<u8> {
        Message::Manifest(Manifest { epoch: "e1".into(), rev, rows }).encode()
    }

    fn wants(frames: &[Vec<u8>]) -> Vec<BlobHash> {
        assert_eq!(frames.len(), 1, "one want frame");
        match Message::decode(&frames[0]) {
            Ok(Message::Want(hashes)) => hashes,
            other => panic!("not a want: {other:?}"),
        }
    }

    fn three() -> Vec<Row> {
        vec![row("a", b"f1", b"ta"), row("b", b"f1", b"tb"), row("c", b"f2", b"tc")]
    }

    #[test]
    fn near_cards_fill_whole_then_other_favicons_then_other_pictures() {
        let rows = three();
        let order = want_order(&rows, &["c".to_owned()], |_| false);
        assert_eq!(order, vec![h(b"f2"), h(b"tc"), h(b"f1"), h(b"ta"), h(b"tb")]);
        // What the phone holds is never asked for, and no near card means tab order.
        let held = h(b"f1");
        let order = want_order(&rows, &[], |hash| *hash == held);
        assert_eq!(order, vec![h(b"f2"), h(b"ta"), h(b"tb"), h(b"tc")]);
    }

    #[test]
    fn a_manifest_shows_rows_and_asks_for_what_the_disk_lacks() {
        let mirror = TabsMirror::new(vec![h(b"f1").to_hex(), "not-a-hash".to_owned()]);
        let TabsEvent::Rows { rev, rows, send } = mirror.receive(manifest(7, three())) else {
            panic!("rows expected");
        };
        assert_eq!(rev, 7);
        assert_eq!(rows.iter().map(|r| r.tab_id.as_str()).collect::<Vec<_>>(), ["a", "b", "c"]);
        assert_eq!(rows[0].favicon_hash, Some(h(b"f1").to_hex()));
        assert_eq!(rows[0].thumb_mime, "image/jpeg");
        assert!(rows.iter().all(|r| !r.filled));
        assert_eq!(wants(&send), vec![h(b"f2"), h(b"ta"), h(b"tb"), h(b"tc")]);
    }

    #[test]
    fn a_blob_is_handed_over_with_the_cards_it_fills() {
        let mirror = TabsMirror::new(Vec::new());
        mirror.receive(manifest(1, three()));
        let event = mirror.receive(encode_blob(h(b"f1"), Mime::Png, b"f1"));
        assert_eq!(
            event,
            TabsEvent::Blob {
                hash: h(b"f1").to_hex(),
                mime: "image/png".to_owned(),
                bytes: b"f1".to_vec(),
                fresh: true,
                tab_ids: vec!["a".to_owned(), "b".to_owned()],
            }
        );
        mirror.receive(encode_blob(h(b"ta"), Mime::Jpeg, b"ta"));
        let rows = mirror.rows();
        assert!(rows[0].filled);
        assert!(!rows[1].filled);
    }

    #[test]
    fn a_blob_that_does_not_hash_to_its_name_is_dropped() {
        let mirror = TabsMirror::new(Vec::new());
        mirror.receive(manifest(1, three()));
        let event = mirror.receive(encode_blob(h(b"ta"), Mime::Jpeg, b"other bytes"));
        assert!(matches!(event, TabsEvent::Dropped { .. }), "{event:?}");
        assert!(!mirror.rows()[0].filled);
        assert!(matches!(mirror.receive(Vec::new()), TabsEvent::Dropped { .. }));
        assert!(matches!(mirror.receive(vec![0x7f, b'{', b'}']), TabsEvent::Dropped { .. }));
    }

    #[test]
    fn scrolling_reorders_the_want_and_an_unchanged_order_writes_nothing() {
        let mirror = TabsMirror::new(Vec::new());
        mirror.receive(manifest(1, three()));
        let send = mirror.set_near(vec!["c".to_owned(), "b".to_owned()]);
        assert_eq!(wants(&send), vec![h(b"f2"), h(b"tc"), h(b"f1"), h(b"tb"), h(b"ta")]);
        assert!(mirror.set_near(vec!["c".to_owned(), "b".to_owned()]).is_empty());
        // A blob arriving does not make the phone ask again for the rest.
        mirror.receive(encode_blob(h(b"f2"), Mime::Png, b"f2"));
        assert!(mirror.set_near(vec!["c".to_owned(), "b".to_owned()]).is_empty());
    }

    #[test]
    fn a_delta_off_its_base_is_a_gap_that_resumes_from_the_phones_rev() {
        let mirror = TabsMirror::new(Vec::new());
        mirror.receive(manifest(5, three()));
        let delta = |base_rev, rev| {
            Message::Delta(Delta {
                epoch: "e1".into(),
                rev,
                base_rev,
                changed: vec![RowPatch {
                    tab_id: "a".into(),
                    title: Some("Renamed".into()),
                    ..RowPatch::default()
                }],
                removed: vec!["b".into()],
                order: None,
            })
            .encode()
        };
        let TabsEvent::Gap { send } = mirror.receive(delta(9, 10)) else {
            panic!("gap expected");
        };
        assert_eq!(send.len(), 1);
        assert!(matches!(Message::decode(&send[0]), Ok(Message::Resume(r)) if r.rev == 5));
        assert_eq!(mirror.rev(), Some(5));
        let TabsEvent::Rows { rev, rows, .. } = mirror.receive(delta(5, 6)) else {
            panic!("rows expected");
        };
        assert_eq!(rev, 6);
        assert_eq!(rows.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(), ["Renamed", "C"]);
    }

    #[test]
    fn link_up_says_have_then_resume_then_viewport() {
        let viewport = TabsViewport { card_pixel_width: 576, ..TabsViewport::default() };
        let fresh = TabsMirror::new(Vec::new());
        let frames = fresh.link_up(viewport.clone());
        assert_eq!(frames.len(), 1, "a first launch sends only its viewport");
        assert!(matches!(
            Message::decode(&frames[0]),
            Ok(Message::Viewport(v)) if v.card_pixel_width == 576
        ));

        let mirror = TabsMirror::new(vec![h(b"f1").to_hex()]);
        mirror.receive(manifest(3, three()));
        let kinds: Vec<u8> = mirror.link_up(viewport).iter().map(|f| f[0]).collect();
        assert_eq!(kinds, [0x03, 0x04, 0x01]);
        // After a reconnect the Mac has no want of this phone's: the next one is written
        // even though the list did not change.
        assert_eq!(mirror.set_near(Vec::new()).len(), 1);
    }

    #[test]
    fn a_page_frame_is_asked_first_and_keeps_the_cards_in_the_list() {
        let mut rows = three();
        rows[1].frame_hash = Some(h(b"page-b"));
        let mirror = TabsMirror::new(Vec::new());
        mirror.receive(manifest(1, rows));
        assert!(mirror.want_frame("a".to_owned()).is_empty(), "no frame on that row");
        let order = wants(&mirror.want_frame("b".to_owned()));
        assert_eq!(order[0], h(b"page-b"));
        assert_eq!(order.len(), 6);
    }

    #[test]
    fn only_blobs_no_row_shows_may_be_deleted() {
        let mirror = TabsMirror::new(Vec::new());
        let old = h(b"closed tab").to_hex();
        let names = vec![old.clone(), h(b"ta").to_hex(), h(b"f1").to_hex()];
        assert!(mirror.unreferenced(names.clone()).is_empty(), "nothing known before a manifest");
        mirror.receive(manifest(1, three()));
        assert_eq!(mirror.unreferenced(names), vec![old]);
    }
}
