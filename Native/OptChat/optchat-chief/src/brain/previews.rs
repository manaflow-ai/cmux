//! Link previews on turn replies (crate::link_preview). A reply with URL
//! lines enters the outbox at once, already split into text and link cards
//! and held (`OutboxEntry::previews_until`) while one thread fetches every
//! card's preview concurrently and uploads each picture as an attachment
//! record of the Chief (its own connection, never the brain's). When the
//! previews arrive the cards are filled and the hold ends. A host that stops
//! while previews are fetched, or fetches that run late, send the cards with
//! their URLs only once the hold ends: the reply is never lost and never
//! waits longer than [`HOLD`].
//!
//! Which URLs: only a line whose URL a person wrote verbatim in a recent
//! message of the same conversation becomes a card. A URL only the agent
//! wrote stays text and is never fetched, so a model cannot be talked into
//! making the host request an address of its choosing. Only an owner that
//! advertises `link-preview-v1` gets cards; when it still refuses them, the
//! reply goes as its original text (`OutboxEntry::plain_text`, outbox.rs).

use std::sync::Arc;
use std::time::Duration;

use cmux_conversation::{Message, Part, ParticipantKind, message_text};

use super::{Brain, Input, now_ms, reply_entry};
use crate::daemon::LINK_PREVIEW_CAPABILITY;
use crate::link_preview::{self, Fetcher, Filled};
use crate::state::OutboxEntry;

/// The longest a reply waits for its previews: the fetch timeout plus room
/// for the uploads.
pub const HOLD: Duration = Duration::from_secs(12);

/// The name of a preview picture's attachment record.
const PICTURE_NAME: &str = "link-preview.jpg";

/// How many recent messages are searched for a person's URL.
const PROVENANCE_TAIL: u32 = 200;

impl Brain {
    /// Fetches link previews for the Chief's replies (None: replies stay text).
    pub fn set_previewer(&mut self, fetcher: Arc<dyn Fetcher>) {
        self.previewer = Some(fetcher);
    }

    /// A turn reply's outbox entry: link cards in place of the URL lines a
    /// person wrote, held while their previews are fetched (off the brain
    /// thread). Every other reply is its text, unchanged.
    pub(super) fn reply_with_previews(
        &mut self,
        conversation: String,
        key: &str,
        text: &str,
    ) -> OutboxEntry {
        let mut entry = reply_entry(conversation.clone(), key, text);
        let Some(fetcher) = self.previewer.clone() else {
            return entry;
        };
        let Some(daemon) = self.daemon.as_mut() else {
            return entry;
        };
        if !daemon.supports(LINK_PREVIEW_CAPABILITY) {
            return entry;
        }
        let Some(Part::Text { text: reply, .. }) = (match &entry.op {
            cmux_conversation::Op::MessageSend { parts, .. } if parts.len() == 1 => parts.first(),
            _ => None,
        }) else {
            return entry;
        };
        let reply = reply.clone();
        if !link_preview::split::text_parts(&reply)
            .iter()
            .any(|part| matches!(part, Part::LinkPreview { .. }))
        {
            return entry;
        }
        // The people's recent words in this conversation (no read, no cards).
        let said = match daemon.snapshot(&conversation, PROVENANCE_TAIL) {
            Ok((summary, messages)) => {
                let people: Vec<&str> = summary
                    .participants
                    .iter()
                    .filter(|p| p.kind == ParticipantKind::Human)
                    .map(|p| p.id.as_str())
                    .collect();
                messages
                    .iter()
                    .filter(|m| people.contains(&m.author.as_str()))
                    .flat_map(person_words)
                    .collect::<Vec<String>>()
            }
            Err(e) => {
                (self.log)(&format!(
                    "link previews: reading the conversation failed: {e}"
                ));
                return entry;
            }
        };
        let split = link_preview::split::text_parts_where(&reply, |url| {
            said.iter().any(|words| words.contains(url))
        });
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
        let uploader = daemon.image_uploader();
        if let cmux_conversation::Op::MessageSend { parts, .. } = &mut entry.op {
            *parts = split;
        }
        entry.plain_text = Some(reply);
        entry.previews_until = Some(now_ms() + HOLD.as_millis() as u64);
        let (tx, key, log) = (self.tx.clone(), key.to_owned(), self.log.clone());
        let spawned = std::thread::Builder::new()
            .name("optchat-link-previews".into())
            .spawn(move || {
                let mut uploader = uploader;
                let fetched = link_preview::fetch_all(fetcher, urls, link_preview::TIMEOUT);
                let filled = fetched
                    .into_iter()
                    .map(|(index, preview)| {
                        let image = preview.picture.and_then(|picture| {
                            let uploader = uploader.as_mut()?;
                            uploader
                                .upload_image(
                                    &conversation,
                                    &picture.jpeg,
                                    "image/jpeg",
                                    PICTURE_NAME,
                                    picture.width,
                                    picture.height,
                                )
                                .map_err(|e| {
                                    log(&format!("uploading a link preview picture failed: {e}"))
                                })
                                .ok()
                        });
                        let filled = Filled {
                            title: preview.title,
                            site: preview.site,
                            image,
                        };
                        (index, filled)
                    })
                    .collect();
                let _ = tx.send(Input::Previews {
                    key,
                    fetched: filled,
                });
            });
        if let Err(e) = spawned {
            (self.log)(&format!("starting the link previews failed: {e}"));
            return reply_entry(entry.conversation, key, text);
        }
        entry
    }

    /// The previews of reply `key` arrived (pictures already uploaded):
    /// fills the cards and ends the hold. A reply already sent keeps what it
    /// sent.
    pub(super) fn previews_fetched(&mut self, key: &str, fetched: Vec<(usize, Filled)>) {
        let Some(at) =
            self.state.outbox.iter().position(|e| {
                e.idempotency_key == key && !e.attempted && e.previews_until.is_some()
            })
        else {
            return;
        };
        for (index, preview) in fetched {
            if let cmux_conversation::Op::MessageSend { parts, .. } = &mut self.state.outbox[at].op
                && let Some(Part::LinkPreview {
                    title, site, image, ..
                }) = parts.get_mut(index)
            {
                *title = preview.title;
                *site = preview.site;
                *image = preview.image;
            }
        }
        self.state.outbox[at].previews_until = None;
        self.save();
        self.flush_outbox();
    }
}

/// What a person's message says, for the URL check: its text and the URLs
/// of its own link cards.
fn person_words(message: &Message) -> Vec<String> {
    let mut words = vec![message_text(message)];
    words.extend(message.parts.iter().filter_map(|part| match part {
        Part::LinkPreview { url, .. } => Some(url.clone()),
        _ => None,
    }));
    words
}
