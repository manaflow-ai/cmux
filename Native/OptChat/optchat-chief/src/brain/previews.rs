//! Link previews on turn replies (crate::link_preview). A reply with URL
//! lines enters the outbox at once, already split into text and link cards
//! and held (`OutboxEntry::previews_until`) while one thread fetches every
//! card's preview concurrently. When the previews arrive, each picture is
//! uploaded to the conversation as an attachment record of the Chief, the
//! cards are filled, and the hold ends. A host that stops while previews
//! are fetched, or fetches that run late, send the cards with their URLs
//! only once the hold ends: the reply is never lost and never waits longer
//! than [`HOLD`].

use std::sync::Arc;
use std::time::Duration;

use cmux_conversation::{Op, Part};

use super::{Brain, Input, now_ms, reply_entry};
use crate::link_preview::{self, Fetched, Fetcher};
use crate::state::OutboxEntry;

/// The longest a reply waits for its previews: the fetch timeout plus room
/// for the uploads.
pub const HOLD: Duration = Duration::from_secs(12);

/// The name of a preview picture's attachment record.
const PICTURE_NAME: &str = "link-preview.jpg";

impl Brain {
    /// Fetches link previews for the Chief's replies (None: replies stay text).
    pub fn set_previewer(&mut self, fetcher: Arc<dyn Fetcher>) {
        self.previewer = Some(fetcher);
    }

    /// A turn reply's outbox entry: link cards in place of the URL lines,
    /// held while their previews are fetched (off the brain thread).
    pub(super) fn reply_with_previews(
        &mut self,
        conversation: String,
        key: &str,
        text: &str,
    ) -> OutboxEntry {
        let mut entry = reply_entry(conversation, key, text);
        let Some(fetcher) = self.previewer.clone() else {
            return entry;
        };
        let Op::MessageSend { parts, .. } = &mut entry.op else {
            return entry;
        };
        let [Part::Text { text, .. }] = parts.as_slice() else {
            return entry;
        };
        let split = link_preview::split::text_parts(text);
        let urls: Vec<(usize, String)> = split
            .iter()
            .enumerate()
            .filter_map(|(index, part)| match part {
                Part::LinkPreview { url, .. } => Some((index, url.clone())),
                _ => None,
            })
            .collect();
        if urls.is_empty() {
            return entry;
        }
        *parts = split;
        entry.previews_until = Some(now_ms() + HOLD.as_millis() as u64);
        let (tx, key) = (self.tx.clone(), key.to_owned());
        let spawned = std::thread::Builder::new()
            .name("optchat-link-previews".into())
            .spawn(move || {
                let fetched = link_preview::fetch_all(fetcher, urls, link_preview::TIMEOUT);
                let _ = tx.send(Input::Previews { key, fetched });
            });
        if let Err(e) = spawned {
            (self.log)(&format!("starting the link previews failed: {e}"));
            entry.previews_until = None;
        }
        entry
    }

    /// The previews of reply `key` arrived: uploads each picture, fills the
    /// cards and ends the hold. A reply already sent keeps what it sent.
    pub(super) fn previews_fetched(&mut self, key: &str, fetched: Vec<(usize, Fetched)>) {
        let Some(at) =
            self.state.outbox.iter().position(|e| {
                e.idempotency_key == key && !e.attempted && e.previews_until.is_some()
            })
        else {
            return;
        };
        let conversation = self.state.outbox[at].conversation.clone();
        for (index, preview) in fetched {
            let image = match (preview.picture, self.daemon.as_mut()) {
                (Some(picture), Some(daemon)) => match daemon.upload_image(
                    &conversation,
                    &picture.jpeg,
                    "image/jpeg",
                    PICTURE_NAME,
                    picture.width,
                    picture.height,
                ) {
                    Ok(image) => Some(image),
                    Err(e) => {
                        (self.log)(&format!("uploading a link preview picture failed: {e}"));
                        None
                    }
                },
                _ => None,
            };
            if let Op::MessageSend { parts, .. } = &mut self.state.outbox[at].op
                && let Some(Part::LinkPreview {
                    title,
                    site,
                    image: slot,
                    ..
                }) = parts.get_mut(index)
            {
                *title = preview.title;
                *site = preview.site;
                *slot = image;
            }
        }
        self.state.outbox[at].previews_until = None;
        self.save();
        self.flush_outbox();
    }
}
