//! An in-memory hosted store for tests, until the real one answers an agent key. It keeps the
//! rules this client relies on: a caller reads and posts only in spaces it was admitted to, the
//! feed is ordered by one seq per space, and a repeated idempotency key is the first post.

use crate::model::{Author, AuthorKind, Event, FeedPage, NewPost};
use crate::record::PersonRecord;
use crate::store::{Posted, StoreError, TeamSpaceStore};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

#[derive(Default)]
struct Space {
    members: BTreeSet<String>,
    events: Vec<Event>,
    /// The last seq given out. Compaction drops events but never lowers it.
    head: u64,
    seen: BTreeMap<String, Posted>,
}

#[derive(Default)]
struct State {
    spaces: BTreeMap<String, Space>,
    next_post: u64,
    feed_calls: usize,
    unavailable: bool,
    records: Vec<PersonRecord>,
}

/// The fake store. Clone it to share one state between clients.
#[derive(Clone, Default)]
pub struct FakeStore {
    state: Arc<Mutex<State>>,
}

impl FakeStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// A test that panicked while holding the lock leaves the state as it was; keep using it.
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A person admits `member` (an agent or person id) to `space`, creating the space if needed.
    pub fn admit(&self, space: &str, member: &str) {
        let mut state = self.lock();
        state.spaces.entry(space.to_owned()).or_default().members.insert(member.to_owned());
    }

    /// The store answers every call with [`StoreError::Unavailable`] while set.
    pub fn set_unavailable(&self, unavailable: bool) {
        self.lock().unavailable = unavailable;
    }

    /// The store compacts `space`'s log: events at or below `through` are gone from the feed.
    /// Seqs are not reused, so a reader whose cursor is behind sees a gap.
    pub fn compact(&self, space: &str, through: u64) {
        let mut state = self.lock();
        if let Some(found) = state.spaces.get_mut(space) {
            found.events.retain(|e| e.seq > through);
        }
    }

    /// How many feed reads the store has answered (to bound a reader's calls in tests).
    pub fn feed_calls(&self) -> usize {
        self.lock().feed_calls
    }

    /// A client authenticated as `author`, as the real store would be from its credential.
    pub fn client(&self, author: Author) -> FakeClient {
        FakeClient { store: self.clone(), author }
    }
}

/// One caller's view of the fake store.
pub struct FakeClient {
    store: FakeStore,
    author: Author,
}

impl FakeClient {
    /// The authenticated author of an agent, with the session and host it reports.
    pub fn agent_author(
        id: &str,
        team_address: &str,
        on_behalf_of: &str,
        session: Option<&str>,
        host: Option<&str>,
    ) -> Author {
        Author {
            kind: AuthorKind::Agent,
            id: id.to_owned(),
            team_address: Some(team_address.to_owned()),
            on_behalf_of: Some(on_behalf_of.to_owned()),
            session: session.map(str::to_owned),
            host: host.map(str::to_owned),
        }
    }
}

impl TeamSpaceStore for FakeClient {
    fn post(&self, post: &NewPost) -> Result<Posted, StoreError> {
        let mut state = self.store.lock();
        if state.unavailable {
            return Err(StoreError::Unavailable("fake store is down".to_owned()));
        }
        let next_post = state.next_post + 1;
        let space = state
            .spaces
            .get_mut(&post.space)
            .ok_or_else(|| StoreError::NotFound { space: post.space.clone() })?;
        if !space.members.contains(&self.author.id) {
            return Err(StoreError::Forbidden { space: post.space.clone() });
        }
        if let Some(first) = space.seen.get(&post.idempotency_key) {
            return Ok(first.clone());
        }
        let post_id = format!("p{next_post}");
        let seq = space.head + 1;
        space.head = seq;
        let mut author = self.author.clone();
        // Session and host are the caller's report, kept as reported.
        author.session = post.reported_session.clone().or(author.session);
        author.host = post.reported_host.clone().or(author.host);
        space.events.push(Event {
            seq,
            space: post.space.clone(),
            thread: post.thread.clone(),
            post_id: post_id.clone(),
            kind: post.kind,
            author,
            text: post.text.clone(),
            to: post.to.clone(),
            dedupe: post.dedupe.clone(),
            areas: post.areas.clone(),
        });
        let posted = Posted { post_id, seq };
        space.seen.insert(post.idempotency_key.clone(), posted.clone());
        state.next_post = next_post;
        Ok(posted)
    }

    fn feed(&self, space: &str, after: u64, limit: usize) -> Result<FeedPage, StoreError> {
        let mut state = self.store.lock();
        state.feed_calls += 1;
        if state.unavailable {
            return Err(StoreError::Unavailable("fake store is down".to_owned()));
        }
        let found = state
            .spaces
            .get(space)
            .ok_or_else(|| StoreError::NotFound { space: space.to_owned() })?;
        if !found.members.contains(&self.author.id) {
            return Err(StoreError::Forbidden { space: space.to_owned() });
        }
        let events: Vec<Event> =
            found.events.iter().filter(|e| e.seq > after).take(limit).cloned().collect();
        Ok(FeedPage { events, head: found.head })
    }

    fn append_record(&self, record: &PersonRecord) -> Result<(), StoreError> {
        let mut state = self.store.lock();
        if state.unavailable {
            return Err(StoreError::Unavailable("fake store is down".to_owned()));
        }
        let space = record.space();
        let found = state
            .spaces
            .get(space)
            .ok_or_else(|| StoreError::NotFound { space: space.to_owned() })?;
        if !found.members.contains(&self.author.id) || !self.speaks_for(record.person()) {
            return Err(StoreError::Forbidden { space: space.to_owned() });
        }
        state.records.push(record.clone());
        Ok(())
    }

    fn records(&self, person: &str, since: u64) -> Result<Vec<PersonRecord>, StoreError> {
        let state = self.store.lock();
        if state.unavailable {
            return Err(StoreError::Unavailable("fake store is down".to_owned()));
        }
        if !self.speaks_for(person) {
            return Err(StoreError::Forbidden { space: format!("records of {person}") });
        }
        Ok(state
            .records
            .iter()
            .filter(|r| r.person() == person && r.at() >= since)
            .cloned()
            .collect())
    }
}

impl FakeClient {
    /// The caller is `person`, or an agent acting on their behalf.
    fn speaks_for(&self, person: &str) -> bool {
        self.author.id == person || self.author.on_behalf_of.as_deref() == Some(person)
    }
}
