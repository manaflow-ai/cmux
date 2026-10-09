//! The I/O half of OptChat for the placements that run on one machine (the
//! user's MacBook or an always-on Mac mini): the SQLite store (with its
//! JSONL text export and the import of the older JSONL store), the
//! single-writer lock, the compactor runner and a thread-safe facade over
//! `optchat-core`. Section numbers in comments refer to Victor Taelin's
//! OptChat specification, which the core follows.

mod anthropic;
mod cap;
mod chat;
mod clock;
mod compactor;
mod config;
pub mod db;
mod fault;
mod lines;
mod lock;
mod model;
mod report;

pub use anthropic::{AnthropicModel, AGENT_HEADER};
pub use cap::cap_tool_result;
pub use chat::{Cancel, Error, Failure, OptChat, Status, DB_FILE};
pub use clock::{Clock, ManualClock, SystemClock};
pub use compactor::{probe, run_node, PROBE_NODE};
pub use config::{
    api_key, Config, API_KEY_ENV, BASE_URL_ENV, DEFAULT_BASE_URL, DEFAULT_FALLBACK_MODEL,
    DEFAULT_EFFORT, DEFAULT_MODEL, SUBROUTER_KEY,
};
pub use db::{Appended, NewMessage, StateWrite};
pub use fault::{fault, FAULT_ENV};
pub use model::{CompactModel, Followup, ModelError, Reply};
pub use report::{Report, Reporter};

pub use optchat_core::{CompactPrompt, CompactRequest, Kind, NodeId, RenderedView, ZoomError};

use std::time::Duration;

/// Wait before a failed compactor node is tried again: fixed, never
/// exponential, because the next turn waits on the compactor (section 4.1).
pub const RETRY: Duration = Duration::from_secs(10);
