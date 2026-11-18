//! One connection's source: `list` goes to the hub's source, `chat:<id>` to that chat's actor.
//! A `sub` hydrates the chat; a `page` or a `blob` reaches only an actor that runs, and is
//! answered at once when none does.

use super::{ConnError, Later, OfferSink, Reply, Source};
use crate::chat::ChatConfig;
use crate::chat::stream::{ChatSub, Ticket, person_id};
use crate::registry::Registry;
use crate::wire::{Anchor, Cursor, Frame, Page, Sub};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// The chat a `chat:<id>` stream names, if the daemon has one by that id.
pub type Resolve = Arc<dyn Fn(&str) -> Option<ChatConfig> + Send + Sync>;

/// A chat subscription's chat id and its sink.
type ChatOf = (String, Arc<dyn OfferSink>);

pub struct RouteSource {
    list: Arc<dyn Source>,
    registry: Registry,
    resolve: Resolve,
    /// This connection, as the actors know its subscriptions.
    conn: u64,
    /// The chat each of this connection's chat subscriptions is of, and its sink.
    chats: Mutex<HashMap<String, ChatOf>>,
}

impl RouteSource {
    pub fn new(list: Arc<dyn Source>, registry: Registry, resolve: Resolve, conn: u64) -> Self {
        Self { list, registry, resolve, conn, chats: Mutex::new(HashMap::new()) }
    }

    fn chat_of(&self, sid: &str) -> Option<ChatOf> {
        self.chats.lock().ok()?.get(sid).cloned()
    }
}

fn chat_id(stream: &str) -> Option<&str> {
    stream.strip_prefix("chat:")
}

fn refused(error: &crate::chat::ChatError) -> ConnError {
    ConnError::coded(error.code(), error.to_string())
}

impl Source for RouteSource {
    fn subscribe(
        &self,
        sub: &Sub,
        person: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<(), ConnError> {
        let Some(id) = chat_id(sub.stream.as_str()) else {
            return self.list.subscribe(sub, person, sink);
        };
        if sub.cursor.is_some() && sub.anchor.is_some() {
            return Err(ConnError::InvalidRequest("a sub names a cursor or an anchor".into()));
        }
        let anchor = match &sub.anchor {
            Some(Anchor::List { .. }) => {
                return Err(ConnError::InvalidRequest("a chat's anchor is a rowId".into()));
            }
            anchor => anchor.clone(),
        };
        let config =
            (self.resolve)(id).ok_or_else(|| ConnError::InvalidRequest("no such stream".into()))?;
        // None: the chat is being purged, so it is no stream to subscribe to.
        let handle = self
            .registry
            .hydrate(config)
            .ok_or_else(|| ConnError::InvalidRequest("no such stream".into()))?;
        let chat = ChatSub {
            sid: sub.sid.clone(),
            conn: self.conn,
            cursor: sub.cursor.map(|cursor| cursor.0),
            edition: sub.edition,
            anchor,
            window: sub.window.unwrap_or(0),
            person: person_id(person),
        };
        handle
            .subscribe(chat, Ticket::new(sub.sid.clone(), sink.clone()))
            .map_err(|error| refused(&error))?;
        if let Ok(mut chats) = self.chats.lock() {
            chats.insert(sub.sid.clone(), (id.to_owned(), sink));
        }
        Ok(())
    }

    fn resume(&self, sid: &str, cursor: Cursor) {
        match self.chat_of(sid) {
            Some((id, sink)) => {
                // An actor that is gone said `dropped` when it went: the client resumes.
                let Some(handle) = self.registry.get(&id) else { return };
                // Refused (a full mailbox): the subscription ends as `dropped`, so the client
                // resumes from its cursor instead of waiting on a resume that never comes.
                if handle.resume(self.conn, sid, cursor.0).is_err() {
                    if let Ok(mut chats) = self.chats.lock() {
                        chats.remove(sid);
                    }
                    sink.dropped(sid);
                }
            }
            None => self.list.resume(sid, cursor),
        }
    }

    fn page(&self, page: &Page, person: Option<&[u8]>) -> Result<Frame, ConnError> {
        self.list.page(page, person)
    }

    fn later(&self, request: Later<'_>, person: Option<&[u8]>, reply: Reply) -> Option<Reply> {
        let stream = match request {
            Later::Page(page) => page.stream.as_str(),
            Later::Blob(blob) => blob.stream.as_str(),
        };
        let Some(id) = chat_id(stream) else {
            return self.list.later(request, person, reply);
        };
        let Some(handle) = self.registry.get(id) else {
            reply.error("not_open", "the chat is not open: subscribe to it first");
            return None;
        };
        let person = person_id(person);
        match request {
            Later::Page(page) => handle.page(page.clone(), person, reply),
            Later::Blob(blob) => handle.blob(blob.clone(), reply),
        }
        None
    }

    fn end(&self, sid: &str) {
        let chat = self.chats.lock().ok().and_then(|mut chats| chats.remove(sid));
        match chat {
            Some((id, _)) => {
                if let Some(handle) = self.registry.get(&id) {
                    let _ = handle.end(self.conn, sid);
                }
            }
            None => self.list.end(sid),
        }
    }

    fn close(&self) -> super::CloseFuture<'_> {
        self.list.close()
    }
}
