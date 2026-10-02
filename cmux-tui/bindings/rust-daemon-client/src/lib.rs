//! cmux2 as a client of the cmux-tui daemon.
//!
//! - [`launcher`]: find the pinned `cmux-tui` binary and run `server ensure`.
//! - [`DaemonClient`]: connect with the cmux Rust SDK (`cmux.protocol/2`),
//!   identify, set client metadata, load `session.snapshot`, follow
//!   `session.events`, reconnect with backoff.
//! - [`Mirror`]: a read-only copy of the session tree with typed deltas.
//! - [`attach`]: the seam terminal byte attachment will plug into (stage 2).
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
//! (bounded by the request and ensure deadlines).
//!
//! The event callback runs **on that worker thread**, sequentially, never
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

pub mod attach;
pub mod client;
pub mod launcher;
pub mod mirror;

#[cfg(test)]
mod fixture;
#[cfg(test)]
mod mirror_tests;

pub use client::{ConnectionInfo, DEFAULT_SESSION, DaemonClient, DaemonConfig, DaemonEvent};
/// The cmux Rust SDK this crate is built on (re-exported so callers use the
/// same IDs and snapshot types).
pub use cmux;
pub use mirror::{Applied, Change, Mirror, MirrorChange, MirrorError};
