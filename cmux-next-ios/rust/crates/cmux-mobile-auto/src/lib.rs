//! The iPhone's client for Auto chats (`plans/cmux-next/auto-mode/DESIGN.md`, slice E).
//!
//! With the laptop off, the phone lists the person's Auto chats, opens one, sends to it and
//! starts a new one through the Cloud store (`/v1/auto-sessions`) as the signed-in person. The
//! phone never holds a chat: it reads the store's copy and writes only to the inbox, `keep` and
//! `POST /`.
//!
//! - [`http`]: the store's owner routes over the phone's HTTP path ([`http::HttpAutoCloud`]).
//! - [`rows`]: the list, and what the phone says about where a chat is.
//! - [`chat`]: one open chat: its events page by page, the held wait, sending.
//! - [`outbox`]: a sent message until the chat's own records show it.
//! - [`records`]: a stored event as the record the chat view already draws.
//! - [`start`]: a chat started from the phone.
//!
//! Everything takes `impl AutoCloud`, so the tests run against `FakeAutoCloud`. Nothing here
//! sleeps or polls: the only wait is the store's held request, and a failed read answers how
//! long the caller should wait before the next one.

mod backoff;
pub mod chat;
pub mod http;
pub mod outbox;
pub mod records;
pub mod rows;
pub mod start;

pub use backoff::retry_after_ms;
