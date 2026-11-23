//! The laptop's side of the Cloud. Owned by slice B (the laptop daemon).
//!
//! The owner's transport: `cmux_auto_session::AutoCloud` over the cmux API Worker as the
//! signed-in person (the way `cmux-cloud-api`'s `owner` calls are made). Also what only a laptop
//! does: the wake notice (`_acpmux/auto_session/wake`, and a wall-clock jump the daemon sees
//! itself), stopping a chat's process tree when no renewal was answered for
//! `cmux_auto_session::consts::SELF_STOP_MS`, the kill of a chat the Cloud took, and its leftover
//! patch.
