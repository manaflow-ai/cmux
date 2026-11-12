//! A chat as a book (agent service v2, cmuxterm-hq `docs/design/agent-service-v2.md`, "The book:
//! rows and the log on disk").
//!
//! A chat is an append-only log of rendered rows. A harness line becomes rows once, when it is
//! appended; a settled row never changes; and a reader is handed byte ranges of the stored row
//! text, so no reply is built by parsing history. Every operation here costs what it touches (one
//! row, one window, one checkpoint interval), never the length of the chat: a book of 40 rows and
//! one of 2 million answer in the same time and hold the same memory (`log_bench.rs`).
//!
//! - [`row`]: the row vocabulary and its compact wire text, encoded once ([`row::Row::encode`]).
//!   A row is at most 16 KB inline; a larger body goes to `blobs/<rowId>` and the row keeps a
//!   preview of at most 4 KB.
//! - [`log`]: the files of one book ([`log::Log`]): segments of settled rows, the row index, the
//!   sparse seq index, the checkpoint, and the repair of a torn tail at open.
//!
//! This crate knows nothing about sockets, harnesses, tokio or async, and it never holds a parsed
//! tree of a row (`serde_json` is not a dependency). The chat actor (`acpmux-core`) owns one
//! [`log::Log`] per hydrated chat and is its only writer.

pub mod folds;
mod fsio;
mod json;
pub mod log;
pub mod row;

#[cfg(test)]
mod log_bench;
#[cfg(test)]
mod log_tests;
#[cfg(test)]
mod recover_tests;
#[cfg(test)]
mod row_tests;
#[cfg(test)]
mod testkit;
