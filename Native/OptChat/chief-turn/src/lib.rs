//! One Chief turn of Claude Code, shared by the two places a Chief turn runs:
//!
//! - the Mac Chief host (`optchat-chief`, `fold.rs`), which reads Claude
//!   Code's raw stream-json lines through acpmux (`claude.*` events), and
//! - the Cloud Chief's turn machine (`chief-turn-runner`, which replaced
//!   `backend/chief-cc/image/run.mjs`), which runs `claude -p --output-format
//!   stream-json --include-partial-messages` itself and streams the turn to
//!   the Worker (`backend/apps/api/src/chief-brain-cc/turn.ts` `ccNotes`).
//!
//! Both read the same lines with [`stream::Line`] and count tokens with
//! [`Usage`]; the cloud event protocol and the turn's result are
//! [`cloud::TurnStream`].

pub mod cloud;
pub mod stream;
pub mod usage;

pub use usage::Usage;
