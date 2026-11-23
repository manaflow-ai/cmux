//! [`HostedStore`]: the team space store over the hosted forum (`cmux-forum-hosted`).
//!
//! It lives in this crate, behind the client crate's dependency, because that crate does no I/O
//! itself (every request goes through its `Transport`), so this crate stays network-free: the
//! daemon hands in the reqwest transport, tests hand in a fake.
//!
//! - **feed**: `GET /v1/forum/feed?after=<seq>&space=<space>` read through [`ForumClient`]; each
//!   hosted event becomes one [`Event`] carrying its seq. An unchanged feed (`304`) is an empty
//!   page at the cursor. Hosted events carry a title and a comment excerpt, not a post type or
//!   an addressee, so [`map_event`] reads the type from the event (a thread opened with a
//!   question mark is a question, a comment is a status) and addressing from @mentions in the
//!   text.
//! - **post**: a new thread in the space, or a comment when the thread key is `forum:<number>`.
//!   The hosted forum does not dedupe, so a repeated idempotency key is answered from this
//!   store's memory for as long as it lives.
//! - **records**: the hosted forum keeps no digest log yet, so a person's records go to the
//!   [`RecordLog`] given at construction.
//!
//! The client is async and [`TeamSpaceStore`] is not: calls block on the runtime handle given at
//! construction, so call them from outside the runtime's own threads (`spawn_blocking`).

use crate::log::RecordLog;
use crate::model::{Author, AuthorKind, Event, FeedPage, NewPost, PostKind};
use crate::record::PersonRecord;
use crate::store::{Posted, StoreError, TeamSpaceStore};
use cmux_forum_hosted::{EventKind, FeedEvent, FeedResponse, ForumClient, ForumError, Transport};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use tokio::runtime::Handle;

/// Longest title a post's first line makes.
const TITLE_CHARS: usize = 80;
/// Most events one hosted feed request asks for.
const MAX_PAGE: usize = 500;

/// The thread key that names an existing hosted thread by number.
pub const THREAD_KEY_PREFIX: &str = "forum:";

pub struct HostedStore<T: Transport> {
    client: Arc<ForumClient<T>>,
    handle: Handle,
    log: Arc<dyn RecordLog>,
    /// The last etag and page the feed answered for `(space, after)`, so a `304` repeats it.
    etags: Mutex<HashMap<(String, u64), (String, FeedPage)>>,
    posted: Mutex<HashMap<String, Posted>>,
}

impl<T: Transport> HostedStore<T> {
    pub fn new(client: Arc<ForumClient<T>>, handle: Handle, log: Arc<dyn RecordLog>) -> Self {
        Self { client, handle, log, etags: Mutex::default(), posted: Mutex::default() }
    }
}

fn store_error(space: &str, e: &ForumError) -> StoreError {
    match e {
        ForumError::Forbidden { .. } | ForumError::Unauthorized { .. } => {
            StoreError::Forbidden { space: space.to_owned() }
        }
        ForumError::NotFound { .. } => StoreError::NotFound { space: space.to_owned() },
        other => StoreError::Unavailable(other.to_string()),
    }
}

fn cut(text: &str, chars: usize) -> String {
    text.chars().take(chars).collect()
}

/// One hosted feed event as a feed entry of this crate.
///
/// The post id is `t<thread>` for a thread's opening, `t<thread>/c<comment>` for a comment and
/// `t<thread>@<seq>` for any other change of a thread, so each event of a thread is its own item.
pub fn map_event(e: &FeedEvent) -> Event {
    let (post_id, kind, text) = match (&e.kind, &e.comment) {
        (EventKind::CommentCreated, Some(c)) => (
            format!("t{}/c{}", e.thread, c.id),
            PostKind::Status,
            format!("Re: {}: {}", e.title, c.excerpt),
        ),
        (EventKind::ThreadCreated | EventKind::ThreadImported, _) => {
            let kind =
                if e.title.trim_end().ends_with('?') { PostKind::Question } else { PostKind::Fyi };
            (format!("t{}", e.thread), kind, e.title.clone())
        }
        (EventKind::ThreadClosed, _) => {
            (format!("t{}@{}", e.thread, e.seq), PostKind::Status, format!("Closed: {}", e.title))
        }
        (EventKind::ThreadReopened, _) => {
            (format!("t{}@{}", e.thread, e.seq), PostKind::Status, format!("Reopened: {}", e.title))
        }
        _ => (format!("t{}@{}", e.thread, e.seq), PostKind::Other, e.title.clone()),
    };
    let kind_of_author = match e.actor.kind.as_str() {
        "agent" => AuthorKind::Agent,
        _ => AuthorKind::Person,
    };
    Event {
        seq: e.seq,
        space: e.space.clone(),
        thread: e.thread.to_string(),
        post_id,
        kind,
        author: Author {
            kind: kind_of_author,
            id: e.actor.id.clone(),
            team_address: None,
            on_behalf_of: None,
            session: None,
            host: None,
        },
        text,
        to: Vec::new(),
        dedupe: None,
        areas: Vec::new(),
    }
}

impl<T: Transport> TeamSpaceStore for HostedStore<T> {
    fn post(&self, post: &NewPost) -> Result<Posted, StoreError> {
        if let Some(first) =
            self.posted.lock().unwrap_or_else(PoisonError::into_inner).get(&post.idempotency_key)
        {
            return Ok(first.clone());
        }
        let posted = match post.thread.strip_prefix(THREAD_KEY_PREFIX).map(str::parse::<u64>) {
            Some(Ok(number)) => {
                let comment = self
                    .handle
                    .block_on(self.client.reply(number, &post.text))
                    .map_err(|e| store_error(&post.space, &e))?;
                Posted { post_id: format!("t{number}/c{}", comment.id), seq: 0 }
            }
            _ => {
                let title = cut(post.text.lines().next().unwrap_or(""), TITLE_CHARS);
                let mut labels = vec![post.kind.as_str().to_owned()];
                labels.extend(post.areas.iter().cloned());
                let body = format!("{}\n\nthread: {}", post.text, post.thread);
                let thread = self
                    .handle
                    .block_on(self.client.post_thread(&post.space, &title, &body, &labels))
                    .map_err(|e| store_error(&post.space, &e))?;
                Posted { post_id: format!("t{}", thread.number), seq: 0 }
            }
        };
        self.posted
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(post.idempotency_key.clone(), posted.clone());
        Ok(posted)
    }

    fn feed(&self, space: &str, after: u64, limit: usize) -> Result<FeedPage, StoreError> {
        let mut known = self
            .etags
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&(space.to_owned(), after))
            .cloned();
        let limit = u32::try_from(limit.clamp(1, MAX_PAGE)).unwrap_or(500);
        let answer = self
            .handle
            .block_on(self.client.feed(
                after,
                Some(space),
                limit,
                known.as_ref().map(|(etag, _)| etag.as_str()),
            ))
            .map_err(|e| store_error(space, &e))?;
        match answer {
            FeedResponse::NotModified => Ok(known
                .take()
                .map_or(FeedPage { events: Vec::new(), head: after }, |(_, page)| page)),
            FeedResponse::Page { page, etag } => {
                let mut events: Vec<Event> = page
                    .events
                    .iter()
                    .filter(|e| e.seq > after && (e.space.is_empty() || e.space == space))
                    .map(map_event)
                    .collect();
                events.sort_by_key(|e| e.seq);
                events.dedup_by_key(|e| e.seq);
                for event in &mut events {
                    if event.space.is_empty() {
                        event.space = space.to_owned();
                    }
                }
                let mapped = FeedPage { events, head: page.head.max(after) };
                if let Some(etag) = etag {
                    self.etags
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .insert((space.to_owned(), after), (etag, mapped.clone()));
                }
                Ok(mapped)
            }
        }
    }

    fn append_record(&self, record: &PersonRecord) -> Result<(), StoreError> {
        self.log.append(record)
    }

    fn records(&self, person: &str, since: u64) -> Result<Vec<PersonRecord>, StoreError> {
        self.log.records(person, since)
    }
}
