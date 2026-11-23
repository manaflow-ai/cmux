//! The holder loop. Owned by slice B (the laptop daemon).
//!
//! One task per daemon behind [`super::spawn_holder`]. For every Auto chat it keeps a
//! `cmux_auto_session::holder::Chat`, feeds it events (a tick at the time the machine asked for,
//! the app's wake notice, a turn's start and end, the store's answers) with `now` in
//! milliseconds, and runs the effects `step` returns: renew the lease, stop, continue or kill the
//! chat's process tree, write the leftover patch, upload events and a snapshot
//! ([`super::export`]), drain the inbox, import ([`super::SessionImporter`]) and ack an
//! assignment. A Cloud machine runs the same loop with its own transport ([`super::machine`]).
