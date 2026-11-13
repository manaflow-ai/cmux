//! The v2 agent service core.
//!
//! The core is split into small modules with explicit ownership boundaries:
//!
//! * [`wire`] owns the bounded frame and generic `sub`/`page` request shapes.
//! * [`hub`] owns the published summary index and its one writer.
//!
//! Chat actors, peer links and lifecycle code build on these modules in later
//! PRs. This crate deliberately has no whole-list reply type.

pub mod chat;
pub mod hub;
pub mod life;
pub mod wire;
