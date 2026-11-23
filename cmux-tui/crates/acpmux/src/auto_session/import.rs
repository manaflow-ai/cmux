//! A chat's Cloud copy into a local session. Owned by slice C (the Cloud machine daemon).
//!
//! The [`super::SessionImporter`] both sides call. It reads the events and the newest manifest,
//! fetches and verifies the chunks (`cmux_auto_session::chunks`), and builds the session the way
//! `transfer_in` does. A takeover gets a fresh worktree from the manifest, its open turn settled
//! `outcome_unknown` and the `machine_takeover` continuation at the head of the queue
//! (`hub/restart_resume.rs`'s path). A handback merges the snapshot into the chat's folder, the
//! three-way merge `cmux cloud bring-back` uses. A create makes a worktree of the repository and
//! branch and starts the harness.
