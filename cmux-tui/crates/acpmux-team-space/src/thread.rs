//! A work thread's client: post into its team-space thread, and read joined spaces from cursors.

use crate::delivery::{Delivery, WakePolicy, classify};
use crate::model::{AgentIdentity, NewPost, PostKind};
use crate::store::{Posted, StoreError, TeamSpaceStore};
use std::collections::BTreeMap;

/// One acpmux inbox thread bound to one thread in one team space.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkThread {
    pub space: String,
    /// The acpmux inbox thread key (`topic:T`, `pr:N`), used as the store's thread key so the
    /// same work thread on two hosts is one thread in the space.
    pub key: String,
}

impl WorkThread {
    pub fn new(space: impl Into<String>, key: impl Into<String>) -> Self {
        Self { space: space.into(), key: key.into() }
    }

    /// Post into this thread as `me`. `prompt_id` is the sender's prompt id, so a resend of the
    /// same prompt is the same post.
    pub fn post(
        &self,
        store: &dyn TeamSpaceStore,
        me: &AgentIdentity,
        kind: PostKind,
        text: &str,
        to: &[&str],
        prompt_id: &str,
    ) -> Result<Posted, StoreError> {
        store.post(&NewPost {
            space: self.space.clone(),
            thread: self.key.clone(),
            kind,
            text: text.to_owned(),
            to: to.iter().map(|s| (*s).to_owned()).collect(),
            idempotency_key: format!("{}:{prompt_id}", me.id),
            dedupe: None,
            areas: Vec::new(),
            reported_session: me.session.clone(),
            reported_host: me.host.clone(),
        })
    }

    /// Ask a teammate's agent a question in this thread. Under the default policy it waits in
    /// that agent's digest.
    pub fn ask(
        &self,
        store: &dyn TeamSpaceStore,
        me: &AgentIdentity,
        to: &str,
        text: &str,
        prompt_id: &str,
    ) -> Result<Posted, StoreError> {
        self.post(store, me, PostKind::Question, text, &[to], prompt_id)
    }
}

/// Feed pages read per space in one [`TeamSpaceReader::pull`], so one busy space cannot hold a
/// pull open.
pub const MAX_PAGES_PER_PULL: usize = 8;
/// Events asked for per page.
pub const PAGE_LIMIT: usize = 100;

/// Reads the team spaces one agent has joined, from a cursor per space.
#[derive(Debug, Clone)]
pub struct TeamSpaceReader {
    pub me: AgentIdentity,
    pub policy: WakePolicy,
    cursors: BTreeMap<String, u64>,
}

/// What one pull read: the deliveries for this agent, oldest first per space, and the spaces it
/// could not read this time (the cursor stays where it was).
#[derive(Debug, Default)]
pub struct Pull {
    pub deliveries: Vec<Delivery>,
    pub failed: Vec<(String, StoreError)>,
    /// Spaces with more events than one pull reads.
    pub behind: Vec<String>,
}

impl TeamSpaceReader {
    /// `spaces` is what the agent has joined, each with the cursor it last saw (0: from the start).
    pub fn new(me: AgentIdentity, policy: WakePolicy, spaces: &[(&str, u64)]) -> Self {
        let cursors = spaces.iter().map(|(s, c)| ((*s).to_owned(), *c)).collect();
        Self { me, policy, cursors }
    }

    pub fn cursor(&self, space: &str) -> Option<u64> {
        self.cursors.get(space).copied()
    }

    /// Read every joined space past its cursor. A cursor advances only past events this pull
    /// returned, so a failed read resumes from the same place.
    pub fn pull(&mut self, store: &dyn TeamSpaceStore) -> Pull {
        let mut out = Pull::default();
        for (space, cursor) in &mut self.cursors {
            let mut pages = 0;
            loop {
                if pages == MAX_PAGES_PER_PULL {
                    out.behind.push(space.clone());
                    break;
                }
                pages += 1;
                let page = match store.feed(space, *cursor, PAGE_LIMIT) {
                    Ok(page) => page,
                    Err(e) => {
                        out.failed.push((space.clone(), e));
                        break;
                    }
                };
                let before = *cursor;
                for event in &page.events {
                    if event.seq <= *cursor {
                        continue;
                    }
                    *cursor = event.seq;
                    let delivery = classify(event, &self.me, self.policy);
                    if delivery != Delivery::Skip {
                        out.deliveries.push(delivery);
                    }
                }
                if *cursor >= page.head || *cursor == before {
                    break;
                }
            }
        }
        out
    }
}
