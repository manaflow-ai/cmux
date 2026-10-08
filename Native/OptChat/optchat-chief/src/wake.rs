//! Which conversation messages wake the Chief (and so are logged): the
//! shared wake rule (`cmux_chief::rules::wakes`, home.md section 5) for local
//! messages, plus the remote-origin gate for messages the user's own paired
//! device sent through the remote relay (README "Remote-origin messages").
//!
//! The gate is default deny. A device message passes only when every check
//! holds:
//!
//! 1. The owner stamped it as relayed: `origin` is `Remote { install }` and
//!    the author is exactly `remote_<install>`. The owner sets `origin` from
//!    the op's actor, never from the request, and only the relay's verified
//!    peer can act as `remote_<install>`.
//! 2. The author is a human participant of this conversation, its id has the
//!    `remote_` prefix, and its `person` is `user_local`: the daemon's pairing
//!    path gives that person only to installs the server owner paired (the
//!    same account); no client request can create or edit such a participant.
//! 3. It is not retracted, and the Chief participates.
//! 4. The shared rule's conversation test, with humans counted as persons:
//!    one person and the Chief, a DM with the Chief, a mention of the Chief or
//!    a reply to one of its messages. A group message without a mention is
//!    not logged (fail closed, as for local messages).
//!
//! Only the message's text parts are read (`message_text`); the relay's gate
//! already lets only text parts through. Nothing in a message is a command
//! or a parameter to the host: its text goes to the log and to the turn as
//! the user's words, exactly as a local message would.

use cmux_chief::rules::wakes;
use cmux_conversation::{Message, Summary};

/// Whether `message` wakes the Chief: the shared rule, remote-origin gate
/// included (`cmux_chief::rules::wakes`, the same as the TypeScript core's
/// `rules.wakes`; the shared behavior corpus checks all three brains).
pub fn chief_wakes(
    summary: &Summary,
    message: &Message,
    is_mux_message: impl Fn(&str) -> bool,
) -> bool {
    wakes(summary, message, is_mux_message)
}
