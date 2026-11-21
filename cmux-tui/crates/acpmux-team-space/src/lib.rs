//! Teammates' agents in cmux: an acpmux work thread posts to and reads a team space in the hosted
//! store, so a teammate's chat sees the thread, and a question addressed to a teammate's agent
//! waits in that agent's digest. It wakes nobody (ask-first).
//!
//! - [`store::TeamSpaceStore`] is the seam to the hosted store: post into a space, and read a
//!   space's feed after a sequence cursor. The store owns the feed, its cursor and its
//!   permissions. This crate only consumes them, and implements no feed, shared space or bridge.
//!   The store's API is not reachable from the fleet yet: no lane holds a forum credential until
//!   per-org agent keys exist. So the only implementation here is [`fake::FakeStore`]. A
//!   network implementation goes behind the same trait once the store answers an agent key.
//! - [`thread::WorkThread`] binds one acpmux inbox thread (its key: `topic:T`, `pr:N`, as
//!   `hub/inbox.rs` `thread_key` makes them) to one thread in one team space.
//! - [`thread::TeamSpaceReader`] reads the spaces an agent has joined from its cursors, and turns
//!   what it reads into [`delivery::Delivery`] decisions for that agent.
//! - [`delivery::WakePolicy`] is the owner's policy, and it defaults to
//!   [`delivery::WakePolicy::AskFirst`]: an addressed question goes to the digest and never wakes
//!   a model. Whether team-space questions should wake by default is Leo's open question (the
//!   RFD lists it), so wake stays opt-in only, set by the agent's owner.
//!
//! Joining a space is a person's act, so this client has no join call. A space the agent was
//! never admitted to answers [`store::StoreError::Forbidden`].

pub mod delivery;
pub mod fake;
pub mod model;
pub mod store;
pub mod thread;

pub use delivery::{Delivery, DigestItem, WakePolicy};
pub use model::{AgentIdentity, Author, AuthorKind, Event, FeedPage, NewPost, PostKind};
pub use store::{StoreError, TeamSpaceStore};
pub use thread::{TeamSpaceReader, WorkThread};
