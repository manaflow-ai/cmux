//! Link previews on turn replies (crate::link_preview). A reply with URL
//! lines enters the outbox at once as its text, held
//! (`OutboxEntry::previews_until`) while one thread does the rest off the
//! brain thread, on its own connection (`PreviewPort`): it reads the
//! conversation, keeps the URL lines a person wrote, fetches every card's
//! preview concurrently, uploads each picture as an attachment record of the
//! Chief, and answers with the filled parts. A reply never waits longer than
//! [`HOLD`]: when the hold ends first (or the host stops), it goes as its
//! text.
//!
//! Which URLs: only a line whose URL equals, exactly, a URL token a person
//! wrote in a recent message of the same conversation (its text parts or the
//! URL of its own link card, never a card's title) becomes a card. A URL only
//! the agent wrote, or a prefix of a person's URL, stays text and is never
//! fetched, so a model cannot be talked into making the host request an
//! address of its choosing. Only an owner that advertises `link-preview-v1`
//! gets cards; when it still refuses them, the reply goes as its original
//! text (`OutboxEntry::plain_text`, outbox.rs).

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use cmux_conversation::{Message, Op, Part, ParticipantKind, Summary};

use super::{Brain, Input, now_ms};
use crate::daemon::{LINK_PREVIEW_CAPABILITY, PreviewPort};
use crate::link_preview::{self, Fetcher};
use crate::state::OutboxEntry;

/// The longest a reply waits for its previews: the read, the fetch timeout
/// and room for the uploads.
pub const HOLD: Duration = Duration::from_secs(12);

/// The longest a reply with pictures or videos waits for their uploads.
pub const MEDIA_HOLD: Duration = Duration::from_secs(60);

/// The name of a preview picture's attachment record.
const PICTURE_NAME: &str = "link-preview.jpg";

/// How many recent messages are searched for a person's URL.
const PROVENANCE_TAIL: u32 = 200;

impl Brain {
    /// Fetches link previews for the Chief's replies (None: replies stay text).
    pub fn set_previewer(&mut self, fetcher: Arc<dyn Fetcher>) {
        self.previewer = Some(fetcher);
    }

    /// A turn reply's outbox entry (`answer_entry`): its text, held while the
    /// preview thread works when it has URL lines and the owner takes cards.
    /// Every other reply is returned unchanged and not held.
    pub(super) fn reply_with_previews(&mut self, entry: OutboxEntry) -> OutboxEntry {
        self.reply_with_media(entry, Vec::new())
    }

    /// `reply_with_previews`, plus `extra` files to upload (send.rs's
    /// attachments) after the ones the text names.
    pub(super) fn reply_with_media(
        &mut self,
        mut entry: OutboxEntry,
        extra: Vec<super::media::MediaRef>,
    ) -> OutboxEntry {
        let conversation = entry.conversation.clone();
        let Some(daemon) = self.daemon.as_ref() else {
            return entry;
        };
        let reply = match &entry.op {
            Op::MessageSend { parts, .. } => match parts.as_slice() {
                [Part::Text { text, .. }] => text.clone(),
                _ => return entry,
            },
            _ => return entry,
        };
        // Pictures and videos the reply names (media.rs) go whether or not the owner takes cards.
        let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
        let mut media = super::media::media_refs(&reply, home.as_deref());
        for file in extra {
            if !media.iter().any(|m| m.path == file.path) {
                media.push(file);
            }
        }
        let fetcher = self.previewer.clone().filter(|_| {
            daemon.supports(LINK_PREVIEW_CAPABILITY)
                && link_preview::split::text_parts(&reply)
                    .iter()
                    .any(|part| matches!(part, Part::LinkPreview { .. }))
        });
        if media.is_empty() && fetcher.is_none() {
            return entry;
        }
        let Some(port) = daemon.preview_port() else {
            return entry;
        };
        let (tx, owned_key, log) = (
            self.tx.clone(),
            entry.idempotency_key.clone(),
            self.log.clone(),
        );
        let thread_reply = reply.clone();
        let hold = if media.is_empty() { HOLD } else { MEDIA_HOLD };
        let spawned = std::thread::Builder::new()
            .name("optchat-link-previews".into())
            .spawn(move || {
                let parts = filled(port, fetcher, &conversation, &thread_reply, &media, &log);
                let _ = tx.send(Input::Previews {
                    key: owned_key,
                    parts,
                });
            });
        match spawned {
            Ok(_) => {
                entry.plain_text = Some(reply);
                entry.previews_until = Some(now_ms() + hold.as_millis() as u64);
            }
            Err(e) => (self.log)(&format!("starting the link previews failed: {e}")),
        }
        entry
    }

    /// The preview thread answered for reply `key`: the filled parts replace
    /// its text (which stays as the fallback), or it stays text; the hold
    /// ends. A reply already sent keeps what it sent.
    pub(super) fn previews_fetched(&mut self, key: &str, parts: Option<Vec<Part>>) {
        let Some(at) =
            self.state.outbox.iter().position(|e| {
                e.idempotency_key == key && !e.attempted && e.previews_until.is_some()
            })
        else {
            return;
        };
        let entry = &mut self.state.outbox[at];
        match parts {
            Some(parts) => {
                if let Op::MessageSend { parts: sent, .. } = &mut entry.op {
                    *sent = parts;
                }
            }
            None => entry.plain_text = None,
        }
        entry.previews_until = None;
        self.save();
        self.flush_outbox();
    }
}

/// The preview thread's whole answer: the files the reply names uploaded
/// (media.rs: their image syntax leaves the text, an attachment part each
/// follows it), then the cards (`previews`) of what text is left. None: the
/// reply goes as its text.
fn filled(
    mut port: Box<dyn PreviewPort>,
    fetcher: Option<Arc<dyn Fetcher>>,
    conversation: &str,
    reply: &str,
    media: &[super::media::MediaRef],
    log: &super::Log,
) -> Option<Vec<Part>> {
    let files = super::media::upload(&mut *port, conversation, media, log);
    let refs: Vec<&super::media::MediaRef> = files.iter().map(|(media, _)| media).collect();
    let failed: Vec<&super::media::MediaRef> = media
        .iter()
        .filter(|m| m.image_syntax.is_some() && !refs.iter().any(|r| r.path == m.path))
        .collect();
    let text = super::media::settled(reply, &refs, &failed);
    let cards = fetcher.and_then(|fetcher| previews(&mut *port, fetcher, conversation, &text, log));
    if files.is_empty() {
        // A failed upload still changes the text: its image syntax is a link now.
        return cards.or_else(|| {
            (text != reply).then(|| {
                vec![Part::Text {
                    text: text.clone(),
                    runs: None,
                }]
            })
        });
    }
    let mut parts = cards.unwrap_or_else(|| {
        vec![Part::Text {
            text: text.clone(),
            runs: None,
        }]
    });
    parts.retain(|part| !matches!(part, Part::Text { text, .. } if text.trim().is_empty()));
    parts.extend(files.into_iter().map(|(_, part)| part));
    Some(parts)
}

/// The cards of the reply: its parts with a card for each URL line a
/// person wrote, filled with the fetched preview and its uploaded picture;
/// None when no line qualifies or the conversation cannot be read.
fn previews(
    port: &mut dyn PreviewPort,
    fetcher: Arc<dyn Fetcher>,
    conversation: &str,
    reply: &str,
    log: &super::Log,
) -> Option<Vec<Part>> {
    let said = match port.snapshot(conversation, PROVENANCE_TAIL) {
        Ok((summary, messages)) => people_urls(&summary, &messages),
        Err(e) => {
            log(&format!(
                "link previews: reading the conversation failed: {e}"
            ));
            return None;
        }
    };
    let mut parts = link_preview::split::text_parts_where(reply, |url| said.contains(url));
    let urls: Vec<(usize, String)> = parts
        .iter()
        .enumerate()
        .filter_map(|(index, part)| match part {
            Part::LinkPreview { url, .. } => Some((index, url.clone())),
            _ => None,
        })
        .collect();
    if urls.is_empty() {
        return None;
    }
    for (index, preview) in link_preview::fetch_all(fetcher, urls, link_preview::TIMEOUT) {
        let image = preview.picture.and_then(|picture| {
            port.upload_image(
                conversation,
                &picture.jpeg,
                "image/jpeg",
                PICTURE_NAME,
                picture.width,
                picture.height,
            )
            .map_err(|e| log(&format!("uploading a link preview picture failed: {e}")))
            .ok()
        });
        if let Some(Part::LinkPreview {
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
    Some(parts)
}

/// Every URL token the people of the conversation wrote: in their text parts
/// and the URLs of their own link cards (never a card's title or site).
fn people_urls(summary: &Summary, messages: &[Message]) -> HashSet<String> {
    let people: HashSet<&str> = summary
        .participants
        .iter()
        .filter(|p| p.kind == ParticipantKind::Human)
        .map(|p| p.id.as_str())
        .collect();
    let mut urls = HashSet::new();
    for message in messages
        .iter()
        .filter(|m| people.contains(m.author.as_str()))
    {
        for part in &message.parts {
            match part {
                Part::Text { text, .. } => {
                    urls.extend(link_preview::split::url_tokens(text).map(str::to_owned));
                }
                Part::LinkPreview { url, .. } => {
                    urls.insert(url.clone());
                }
                _ => {}
            }
        }
    }
    urls
}
