//! cmux2 as a client of the cmux-tui daemon.
//!
//! - [`launcher`]: find the pinned `cmux-tui` binary and run `server ensure`.
//! - [`DaemonClient`]: connect with the cmux Rust SDK (`cmux.protocol/2`),
//!   identify, set client metadata, load `session.snapshot`, follow
//!   `session.events`, reconnect with backoff.
//! - [`Mirror`]: a read-only copy of the session tree with typed deltas,
//!   plus the personal workspace groups and sidebar order and the session's
//!   tab groups.
//! - [`DaemonEvent::BookmarksChanged`]: `bookmarks-changed` from a
//!   protocol-12 `subscribe` stream, when the daemon has `bookmarks-v1`.
//! - [`attach`]: the terminal byte attachment seam; [`DaemonAttacher`]
//!   implements it on protocol-12 byte mode (`cmux::raw::ByteAttachment`),
//!   one reader thread per attached view.
//! - [`reattach`]: reconnect after an attachment ended ([`MirrorWatch`]
//!   resolves the terminal's generation after a daemon restart).
//!
//! No async runtime, GPUI or CEF: plain owned Rust types, so other frontends
//! (and a later C ABI) can reuse it.
//!
//! # Thread contract
//!
//! [`DaemonClient::spawn`] starts one owned OS thread named
//! `cmux-daemon-client`. All blocking I/O (process launch, socket requests,
//! the event stream) happens on it; the caller's thread never blocks except
//! in [`DaemonClient::stop`] / `Drop`, which wait for the worker to exit
//! (bounded by the request and ensure deadlines). While connected to a daemon
//! with `bookmarks-v1` (and `DaemonConfig::bookmark_events`), the worker owns
//! a second thread, `cmux-daemon-client-bookmarks`, that reads the
//! `bookmarks-changed` stream; the worker closes and joins it before it
//! reports the connection's `Disconnected`.
//!
//! The event callback runs **on the worker thread** (or, for
//! `BookmarksChanged`, on its bookmark thread), sequentially, never
//! concurrently, once per [`DaemonEvent`] in order, with a borrow of the
//! mirror as of that event. The worker holds the mirror lock while the
//! callback runs, so the callback must return quickly: post the event to the
//! UI thread (GPUI executor, Chromium task runner, channel) and return. A
//! slow callback delays the stream, and a stream that falls 256 items behind
//! ends with a gap and the worker resyncs from a fresh snapshot. Do not call
//! [`DaemonClient::with_mirror`] or [`DaemonClient::mirror`] from inside the
//! callback (the lock is held); use the borrowed mirror instead.
//! [`DaemonClient::stop`] from inside the callback only signals.
//!
//! Every request has a deadline (`DaemonConfig::request_timeout`, `server
//! ensure` has `ensure_timeout`). The event stream itself waits without a
//! deadline: it is event-driven, not polled, and ends when the daemon closes
//! the socket or `stop` cancels it.
//!
//! Attachments have their own thread contract (see [`attach`]): one reader
//! thread per attachment calls its sink; the attachment itself is
//! `Send + Sync` and never reads.

pub mod attach;
pub mod client;
mod daemon_attach;
pub mod launcher;
pub mod mirror;
mod mirror_state;
pub mod reattach;

#[cfg(test)]
mod fixture;
#[cfg(test)]
mod mirror_state_tests;
#[cfg(test)]
mod mirror_tab_groups_tests;
#[cfg(test)]
mod mirror_tests;

pub use attach::{
    AttachEnd, AttachError, AttachRequest, TerminalAttacher, TerminalAttachment, TerminalByteSink,
};
pub use client::{
    BOOKMARKS_CAPABILITY, ConnectionInfo, DEFAULT_SESSION, DaemonClient, DaemonConfig, DaemonEvent,
};
/// The cmux Rust SDK this crate is built on (re-exported so callers use the
/// same IDs and snapshot types).
pub use cmux;
pub use daemon_attach::{DaemonAttacher, DaemonAttachment};
pub use mirror::{Applied, Change, Mirror, MirrorChange, MirrorError};
pub use reattach::{GenerationWait, MirrorWatch, reattach};
