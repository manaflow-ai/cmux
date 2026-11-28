//! Store and forward through the relay, the phone's half (PROTOCOL.md "Reply mailbox" and "Store
//! and forward (`mailbox-send-v1`)"; design: the P8 brief). Everything here is pure: the caller
//! does the HTTP and owns the clock and the Secure Enclave key.
//!
//! - [`route`]: link, mailbox, the chat's Cloud inbox (a `vm:` holder) or fail, for one send; the
//!   id is the same on every path.
//! - [`item`]: canonical JSON, identity signature, seal to the Mac's box key.
//! - [`tracker`]: post and poll one item, trusting an outcome only with the Mac's signature.

pub mod canon;
pub mod item;
pub mod route;
pub mod seal;
pub mod tracker;

pub use item::{
    Action, ItemError, ItemSpec, QueueOp, SealedItem, Signer, Target, build, lifetime_cap, mailbox_available,
    new_nonce, trusted_box_key,
};
pub use route::{
    Decision, FailReason, INBOX_ID_MAX, Presence, Route, RouteInput, decide, inbox_id_ok, inbox_post,
    link_failed, route,
};
pub use tracker::{Request, State, Step, Tracker};

#[cfg(test)]
mod tests;
