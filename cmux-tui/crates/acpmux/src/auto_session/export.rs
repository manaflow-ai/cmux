//! The chat's copy going to the Cloud. Owned by slice B (the laptop daemon).
//!
//! Events: the chat's log records in order, from seq 1, appended in batches of at most 256 and
//! 1 MiB; a gap answer says where to resume. Snapshot: the chat's folder as chunks
//! (`cmux_auto_session::chunks`, `session_move_carry`'s git form or a tar), its queue, draft and
//! open turn in one manifest, posted only after its events and every chunk are stored. It also
//! remembers the last snapshot the store acknowledged, which the leftover patch is cut against.
