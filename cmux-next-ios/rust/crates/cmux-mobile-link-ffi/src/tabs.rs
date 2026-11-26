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
//! and the stream framing: a link channel splits writes, so every frame travels behind a
//! 4-byte length (`cmux_tab_snapshots::stream`). What this returns to write is already
//! prefixed, and [`TabsMirror::receive`] takes the channel's chunks as they come.
//!
//! Swift only binds: it writes the bytes these return, saves a blob's bytes under its
//! hash and hands the rows to the overview.

use std::collections::HashSet;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use cmux_tab_snapshots::wire::Viewport;
use cmux_tab_snapshots::{Applied, BlobHash, Deframer, Message, Mirror, MirrorError, Row, length_prefixed};

/// The longest frame taken from the Mac: a page-size picture with room to spare. A longer
/// one cannot be skipped on a stream, so it ends the channel ([`TabsEvent::Broken`]).
const MAC_FRAME_CAP: usize = 32 << 20;

/// `frame` behind its length, as it is written to the channel.
fn framed(frame: &[u8]) -> Vec<u8> {
    // The phone's frames are a hash list or a few numbers: never near `u32::MAX`.
    length_prefixed(frame).unwrap_or_default()
}

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

/// What one frame from the Mac did. `send` is what to write back, in order, each already
/// behind its length.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TabsEvent {
    /// The rows changed (a manifest or a delta): show them. `send` asks for what is missing.
    /// `epoch` names the Mac's run that handed out the tab ids: under another epoch the same
    /// id is another tab, so what was kept by id under the old one is void.
    Rows { epoch: String, rev: u64, rows: Vec<TabsRow>, send: Vec<Vec<u8>> },
    /// A blob whose bytes match its hash: save `bytes` under `hash`. `tab_ids` are the cards
    /// it completes a part of. `fresh` is false when the phone held it already.
    Blob { hash: String, mime: String, bytes: Vec<u8>, fresh: bool, tab_ids: Vec<String> },
    /// A delta that does not start at the phone's rev: nothing changed; `send` asks the Mac
    /// to resume from the phone's rev.
    Gap { send: Vec<Vec<u8>> },
    /// A frame that does not decode, a blob whose bytes do not hash to its name, or a kind a
    /// newer Mac sends: dropped, and the link stays up.
    Dropped { reason: String },
    /// The stream cannot be read further (a frame announced longer than the cap): close the
    /// channel. The next link-up resumes from the phone's rev.
    Broken { reason: String },
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

struct State {
    mirror: Mirror,
    /// The channel's bytes that are not a whole frame yet.
    deframer: Deframer,
    /// Tab ids nearest the open tab first, as the overview last said.
    near: Vec<String>,
    /// The last `want` written, so an unchanged list is not sent again.
    last_want: Vec<BlobHash>,
}

impl Default for State {
    fn default() -> Self {
        Self {
            mirror: Mirror::new(),
            deframer: Deframer::new(MAC_FRAME_CAP),
            near: Vec::new(),
            last_want: Vec::new(),
        }
    }
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
        vec![framed(&Message::Want(order).encode())]
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

    /// One whole frame from the Mac.
    fn apply(state: &mut State, frame: &[u8]) -> TabsEvent {
        let msg = match Message::decode(frame) {
            Ok(msg) => msg,
            Err(err) => return TabsEvent::Dropped { reason: err.to_string() },
        };
        // The mirror keeps hashes, not bytes: the bytes are kept aside for Swift to save.
        let (blob_mime, blob_bytes) = match &msg {
            Message::Blob(blob) => (blob.mime.as_str().to_owned(), blob.bytes.clone()),
            _ => (String::new(), Vec::new()),
        };
        match state.mirror.apply(msg) {
            Ok(Applied::Manifest { rev } | Applied::Delta { rev }) => {
                let send = state.want();
                TabsEvent::Rows { epoch: state.mirror.epoch().to_owned(), rev, rows: state.rows(), send }
            }
            Ok(Applied::Gap { .. }) => {
                TabsEvent::Gap { send: state.mirror.resume_frame().iter().map(|f| framed(f)).collect() }
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
        // Half a frame of the old channel means nothing on the new one.
        state.deframer = Deframer::new(MAC_FRAME_CAP);
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
        frames.iter().map(|frame| framed(frame)).collect()
    }

    /// Bytes read from the channel, cut wherever the link cut them. One event per frame
    /// they complete, in order; none when a frame is still arriving.
    pub fn receive(&self, chunk: Vec<u8>) -> Vec<TabsEvent> {
        let mut state = self.state();
        state.deframer.push(&chunk);
        let mut events = Vec::new();
        loop {
            match state.deframer.next_frame() {
                Ok(Some(frame)) => events.push(Self::apply(&mut state, &frame)),
                Ok(None) => return events,
                Err(err) => {
                    events.push(TabsEvent::Broken { reason: err.to_string() });
                    return events;
                }
            }
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
        vec![framed(&Message::Want(order).encode())]
    }

    /// Of `on_disk`, the blob names no row shows any more: the ones the phone deletes.
    /// Before a first manifest nothing is known to be unused, so nothing is returned.
    /// The mirror stops holding them: the mirror lives across reconnects, and a `have` that
    /// still named a deleted blob would keep the Mac from sending it when a row names it again
    /// (a page reopened shows its old favicon hash).
    pub fn unreferenced(&self, on_disk: Vec<String>) -> Vec<String> {
        let mut state = self.state();
        if state.mirror.rev().is_none() {
            return Vec::new();
        }
        let used: HashSet<String> =
            state.mirror.rows().iter().flat_map(Row::hashes).map(|h| h.to_hex()).collect();
        let gone: Vec<String> = on_disk.into_iter().filter(|name| !used.contains(name)).collect();
        state.mirror.forget(gone.iter().filter_map(|name| BlobHash::from_hex(name)));
        gone
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

    /// A written frame without its length, which must be the whole write.
    fn unframed(written: &[u8]) -> Vec<u8> {
        let mut deframer = Deframer::new(1 << 20);
        deframer.push(written);
        let frame = deframer.next_frame().expect("under the cap").expect("a whole frame");
        assert_eq!(deframer.pending(), 0, "one frame per write");
        frame
    }

    /// One whole frame from the Mac, read in one piece.
    fn recv(mirror: &TabsMirror, frame: Vec<u8>) -> TabsEvent {
        let mut events = mirror.receive(framed(&frame));
        assert_eq!(events.len(), 1, "one event per frame");
        events.remove(0)
    }

    fn wants(frames: &[Vec<u8>]) -> Vec<BlobHash> {
        assert_eq!(frames.len(), 1, "one want frame");
        match Message::decode(&unframed(&frames[0])) {
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
        let TabsEvent::Rows { epoch, rev, rows, send } = recv(&mirror, manifest(7, three())) else {
            panic!("rows expected");
        };
        assert_eq!(epoch, "e1", "the rows say which run named their tabs");
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
        recv(&mirror, manifest(1, three()));
        let event = recv(&mirror, encode_blob(h(b"f1"), Mime::Png, b"f1"));
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
        recv(&mirror, encode_blob(h(b"ta"), Mime::Jpeg, b"ta"));
        let rows = mirror.rows();
        assert!(rows[0].filled);
        assert!(!rows[1].filled);
    }

    #[test]
    fn a_blob_that_does_not_hash_to_its_name_is_dropped() {
        let mirror = TabsMirror::new(Vec::new());
        recv(&mirror, manifest(1, three()));
        let event = recv(&mirror, encode_blob(h(b"ta"), Mime::Jpeg, b"other bytes"));
        assert!(matches!(event, TabsEvent::Dropped { .. }), "{event:?}");
        assert!(!mirror.rows()[0].filled);
        assert!(matches!(recv(&mirror, Vec::new()), TabsEvent::Dropped { .. }));
        assert!(matches!(recv(&mirror, vec![0x7f, b'{', b'}']), TabsEvent::Dropped { .. }));
    }

    #[test]
    fn scrolling_reorders_the_want_and_an_unchanged_order_writes_nothing() {
        let mirror = TabsMirror::new(Vec::new());
        recv(&mirror, manifest(1, three()));
        let send = mirror.set_near(vec!["c".to_owned(), "b".to_owned()]);
        assert_eq!(wants(&send), vec![h(b"f2"), h(b"tc"), h(b"f1"), h(b"tb"), h(b"ta")]);
        assert!(mirror.set_near(vec!["c".to_owned(), "b".to_owned()]).is_empty());
        // A blob arriving does not make the phone ask again for the rest.
        recv(&mirror, encode_blob(h(b"f2"), Mime::Png, b"f2"));
        assert!(mirror.set_near(vec!["c".to_owned(), "b".to_owned()]).is_empty());
    }

    #[test]
    fn a_delta_off_its_base_is_a_gap_that_resumes_from_the_phones_rev() {
        let mirror = TabsMirror::new(Vec::new());
        recv(&mirror, manifest(5, three()));
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
        let TabsEvent::Gap { send } = recv(&mirror, delta(9, 10)) else {
            panic!("gap expected");
        };
        assert_eq!(send.len(), 1);
        assert!(matches!(Message::decode(&unframed(&send[0])), Ok(Message::Resume(r)) if r.rev == 5));
        assert_eq!(mirror.rev(), Some(5));
        let TabsEvent::Rows { rev, rows, .. } = recv(&mirror, delta(5, 6)) else {
            panic!("rows expected");
        };
        assert_eq!(rev, 6);
        assert_eq!(rows.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(), ["Renamed", "C"]);
    }

    #[test]
    fn frames_cut_anywhere_by_the_link_give_the_same_events() {
        let stream: Vec<u8> = [
            manifest(1, three()),
            encode_blob(h(b"f1"), Mime::Png, b"f1"),
            encode_blob(h(b"ta"), Mime::Jpeg, b"ta"),
        ]
        .iter()
        .flat_map(|frame| framed(frame))
        .collect();
        let whole = TabsMirror::new(Vec::new()).receive(stream.clone());
        assert_eq!(whole.len(), 3);
        for size in [1, 3, 5, 64] {
            let mirror = TabsMirror::new(Vec::new());
            let events: Vec<TabsEvent> =
                stream.chunks(size).flat_map(|piece| mirror.receive(piece.to_vec())).collect();
            assert_eq!(events, whole, "chunks of {size}");
            assert!(mirror.rows()[0].filled);
        }
    }

    #[test]
    fn a_frame_over_the_cap_breaks_the_channel_and_link_up_starts_clean() {
        let mirror = TabsMirror::new(Vec::new());
        recv(&mirror, manifest(1, three()));
        let over = u32::try_from(MAC_FRAME_CAP.saturating_add(1)).expect("fits").to_be_bytes().to_vec();
        let events = mirror.receive(over);
        assert!(matches!(events.as_slice(), [TabsEvent::Broken { .. }]), "{events:?}");
        // The next channel does not read the old one's bytes.
        mirror.link_up(TabsViewport::default());
        let event = recv(&mirror, encode_blob(h(b"f1"), Mime::Png, b"f1"));
        assert!(matches!(event, TabsEvent::Blob { fresh: true, .. }), "{event:?}");
        assert_eq!(mirror.rev(), Some(1));
    }

    #[test]
    fn link_up_says_have_then_resume_then_viewport() {
        let viewport = TabsViewport { card_pixel_width: 576, ..TabsViewport::default() };
        let fresh = TabsMirror::new(Vec::new());
        let frames = fresh.link_up(viewport.clone());
        assert_eq!(frames.len(), 1, "a first launch sends only its viewport");
        assert!(matches!(
            Message::decode(&unframed(&frames[0])),
            Ok(Message::Viewport(v)) if v.card_pixel_width == 576
        ));

        let mirror = TabsMirror::new(vec![h(b"f1").to_hex()]);
        recv(&mirror, manifest(3, three()));
        let kinds: Vec<u8> = mirror.link_up(viewport).iter().map(|f| unframed(f)[0]).collect();
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
        recv(&mirror, manifest(1, rows));
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
        recv(&mirror, manifest(1, three()));
        assert_eq!(mirror.unreferenced(names), vec![old]);
    }

    /// The mirror lives across reconnects: a blob the phone deleted is not in the next
    /// `have`, and a row naming it again (a closed page reopened) asks for it.
    #[test]
    fn a_deleted_blob_is_not_claimed_on_reconnect_and_is_asked_for_again() {
        let gone = row("d", b"f-reopened", b"td");
        let mirror = TabsMirror::new(vec![h(b"f-reopened").to_hex(), h(b"td").to_hex()]);
        recv(&mirror, manifest(1, three()));
        let deleted = mirror.unreferenced(vec![h(b"f-reopened").to_hex(), h(b"td").to_hex()]);
        assert_eq!(deleted.len(), 2);
        let frames = mirror.link_up(TabsViewport::default());
        let have = frames.iter().find_map(|f| match Message::decode(&unframed(f)) {
            Ok(Message::Have(hashes)) => Some(hashes),
            _ => None,
        });
        assert!(have.is_none(), "nothing held any more: {have:?}");
        let mut rows = three();
        rows.push(gone);
        let TabsEvent::Rows { rows, send, .. } = recv(&mirror, manifest(2, rows)) else {
            panic!("rows expected");
        };
        assert!(!rows[3].filled, "a deleted blob does not fill its card");
        let wanted = wants(&send);
        assert!(wanted.contains(&h(b"f-reopened")) && wanted.contains(&h(b"td")), "{wanted:?}");
    }

    /// What the phone needs on the wire to paint the overview of 29 tabs: the cold manifest,
    /// one tab's delta, and nothing when nothing visible changed. Frames come from the real
    /// `Producer` and `Session` (no push, so blobs are not counted here: they are separate
    /// frames, sized by the Mac's encoder). Bytes are framed (4-byte length included), before
    /// any link compression. Run with `--nocapture` to see the numbers.
    #[test]
    fn wire_bytes_the_phone_needs_for_29_tabs() {
        use cmux_tab_snapshots::{FaviconInput, ImageInput, Observation, Producer, ScreenInput, Session};

        const SITES: [(&str, &str); 20] = [
            ("Pull requests · manaflow-ai/cmux", "https://github.com/manaflow-ai/cmux/pulls"),
            ("Inbox (14) - leo@example.com - Gmail", "https://mail.google.com/mail/u/0/#inbox"),
            (
                "Linear - CMUX-4821 Tab overview blank previews",
                "https://linear.app/manaflow/issue/CMUX-4821/tab-overview-blank-previews",
            ),
            ("Slack | #cmux-leo | Manaflow", "https://app.slack.com/client/T01ABCDEF/C02GHIJKL"),
            (
                "Rust std::collections::HashMap - Rust",
                "https://doc.rust-lang.org/std/collections/struct.HashMap.html",
            ),
            ("Vercel - cmux-web - Deployments", "https://vercel.com/manaflow/cmux-web/deployments"),
            (
                "Google Calendar - Week of 22 Nov 2026",
                "https://calendar.google.com/calendar/u/0/r/week/2026/11/22",
            ),
            ("Hacker News", "https://news.ycombinator.com/"),
            (
                "Stack Overflow - Where developers learn, share, & build careers",
                "https://stackoverflow.com/questions/tagged/rust",
            ),
            ("Apple Developer Documentation - UIKit", "https://developer.apple.com/documentation/uikit"),
            (
                "Figma - cmux next iPhone overview",
                "https://www.figma.com/design/AbCdEf123456/cmux-next-iPhone-overview",
            ),
            (
                "Notion - Roadmap Q4",
                "https://www.notion.so/manaflow/Roadmap-Q4-0123456789abcdef0123456789abcdef",
            ),
            (
                "Sentry - Issues - cmux-mobile-host",
                "https://sentry.io/organizations/manaflow/issues/?project=4501234567",
            ),
            (
                "PostHog - Insights - Weekly active devices",
                "https://us.posthog.com/project/12345/insights/AbCdEfGh",
            ),
            ("Anthropic Console - Usage", "https://console.anthropic.com/settings/usage"),
            (
                "Wikipedia - Content-addressable storage",
                "https://en.wikipedia.org/wiki/Content-addressable_storage",
            ),
            ("YouTube - Rust in 100 Seconds", "https://www.youtube.com/watch?v=5C_HPTJg5ek"),
            (
                "Cloudflare Dashboard - manaflow.com - DNS",
                "https://dash.cloudflare.com/0123456789abcdef/manaflow.com/dns",
            ),
            (
                "MDN Web Docs - IntersectionObserver",
                "https://developer.mozilla.org/en-US/docs/Web/API/IntersectionObserver",
            ),
            ("Stripe Dashboard - Payments", "https://dashboard.stripe.com/payments"),
        ];

        // Realistic size classes for the blobs, only so the hashes differ; their bytes are
        // never sent in this test.
        let browser = |i: usize, title: &str, thumb_rev: u32| Observation {
            tab_id: format!("{}", 1000 + i),
            title: title.to_owned(),
            kind: Kind::Browser,
            favicon: Some(FaviconInput {
                mime: Mime::Png,
                bytes: format!("favicon-{}", i % 12).into_bytes(),
            }),
            thumb: Some(ImageInput {
                mime: Mime::Jpeg,
                bytes: format!("thumb-{i}-{thumb_rev}").into_bytes(),
                width: 576,
                height: 768,
            }),
            screen: None,
            frame: None,
            captured_at_ms: 1_763_900_000_000 + i64::from(thumb_rev),
        };
        let terminal = |i: usize, title: &str| Observation {
            tab_id: format!("{}", 1000 + i),
            title: title.to_owned(),
            kind: if i.is_multiple_of(2) { Kind::Terminal } else { Kind::Agent },
            favicon: None,
            thumb: None,
            screen: Some(ScreenInput { text: format!("$ cargo test {i}\n"), cols: 120, rows: 40 }),
            frame: None,
            captured_at_ms: 1_763_900_000_000,
        };

        let mut producer = Producer::new("0f3a9c1e7b2d4c58", 0, 256, 64);
        for i in 0..29 {
            if i < 20 {
                let (title, _url) = SITES[i];
                producer.observe(browser(i, title, 0));
            } else {
                let title = [
                    "~/Projects/cmux — zsh",
                    "cargo test -p cmux-mobile-link-ffi",
                    "claude — ios-tabs-phone-mirror",
                    "codex — lane review",
                    "htop",
                    "ssh cosmic-gray",
                    "claude — perf lane",
                    "tail -f host.log",
                    "git log --oneline",
                ][i - 20];
                producer.observe(terminal(i, title));
            }
        }
        // 20 browser tabs plus 9 terminals and agents.
        assert_eq!(producer.rows().len(), 29);

        let mut session = Session::without_push();
        session.on_message(Message::Viewport(Viewport::default())).expect("viewport");
        let cold = session.next_frame(&producer).expect("a cold manifest");
        assert_eq!(cold[0], 0x11, "a manifest");
        assert!(session.next_frame(&producer).is_none(), "no push: no blobs, no second frame");
        let cold_framed = framed(&cold).len();

        // One tab's page loads: new title and a new thumbnail.
        assert!(producer.observe(browser(3, "Slack | #cmux-leo | Manaflow (2 new)", 1)));
        let one = session.next_frame(&producer).expect("one delta");
        assert_eq!(one[0], 0x12, "a delta");
        assert!(session.next_frame(&producer).is_none());
        let delta_framed = framed(&one).len();

        // The same content again, only recaptured later: no rev, no frame.
        assert!(!producer.observe(browser(3, "Slack | #cmux-leo | Manaflow (2 new)", 1)));
        let mut again = browser(3, "Slack | #cmux-leo | Manaflow (2 new)", 1);
        again.captured_at_ms += 60_000;
        assert!(!producer.observe(again));
        let idle_frames = std::iter::from_fn(|| session.next_frame(&producer)).count();

        println!(
            "tabs wire: cold manifest, 29 tabs (20 browser, 9 terminal/agent): {cold_framed} framed bytes, {} bytes per row",
            cold_framed / 29
        );
        println!("tabs wire: one-tab delta (title + thumbnail hash): {delta_framed} framed bytes");
        println!("tabs wire: nothing visible changed: {idle_frames} frames, 0 framed bytes");
        println!(
            "tabs wire: one-tab delta is {:.1}% of the manifest",
            100.0 * delta_framed as f64 / cold_framed as f64
        );

        // The property: a change costs a small slice of the manifest, a non-change costs nothing.
        assert!(cold_framed / 29 < 600, "a row stays a few hundred bytes: {}", cold_framed / 29);
        assert!(delta_framed * 10 < cold_framed, "one-tab delta {delta_framed} vs manifest {cold_framed}");
        assert_eq!(idle_frames, 0);
        // And the phone paints from it: the delta applies on the mirror.
        let mirror = TabsMirror::new(Vec::new());
        recv(&mirror, cold);
        let TabsEvent::Rows { rows, .. } = recv(&mirror, one) else { panic!("rows expected") };
        assert_eq!(rows.len(), 29);
        assert_eq!(rows[3].title, "Slack | #cmux-leo | Manaflow (2 new)");
    }
}
