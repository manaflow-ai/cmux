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

use cmux_chief::rules::{AGENT_MUX, USER_LOCAL, wakes};
use cmux_conversation::{Message, Origin, Part, ParticipantKind, Summary};

/// The participant id prefix of a paired install (the relay's
/// `remote_participant`).
const REMOTE_PREFIX: &str = "remote_";

/// Whether `message` wakes the Chief.
pub fn chief_wakes(
    summary: &Summary,
    message: &Message,
    is_mux_message: impl Fn(&str) -> bool,
) -> bool {
    let author = summary.participants.iter().find(|p| p.id == message.author);
    let remote_author =
        author.is_some_and(|a| a.person.is_some()) || message.author.starts_with(REMOTE_PREFIX);
    if message.origin.is_none() && !remote_author {
        // A local message: the shared rule (which refuses any device).
        return wakes(summary, message, is_mux_message);
    }
    remote_wakes(summary, message, is_mux_message)
}

/// The remote-origin gate (module docs).
fn remote_wakes(
    summary: &Summary,
    message: &Message,
    is_mux_message: impl Fn(&str) -> bool,
) -> bool {
    // 1. Stamped by the owner as relayed from exactly this author.
    let Some(Origin::Remote { install }) = &message.origin else {
        return false;
    };
    if install.is_empty() || message.author != format!("{REMOTE_PREFIX}{install}") {
        return false;
    }
    // 2. The user's own paired device.
    let Some(author) = summary.participants.iter().find(|p| p.id == message.author) else {
        return false;
    };
    if author.kind != ParticipantKind::Human || author.person.as_deref() != Some(USER_LOCAL) {
        return false;
    }
    // 3. Live, and the Chief is here.
    let retracted = message
        .retracted_at
        .as_deref()
        .is_some_and(|at| !at.is_empty());
    if retracted || !summary.participants.iter().any(|p| p.id == AGENT_MUX) {
        return false;
    }
    // 4. The conversation test, persons counted (a device is its person).
    let mut persons: Vec<&str> = summary
        .participants
        .iter()
        .filter(|p| p.kind == ParticipantKind::Human)
        .map(|p| p.person.as_deref().unwrap_or(&p.id))
        .collect();
    persons.sort_unstable();
    persons.dedup();
    let agents = summary
        .participants
        .iter()
        .filter(|p| p.kind == ParticipantKind::Agent)
        .count();
    if persons.len() == 1 && agents == 1 {
        return true;
    }
    if summary.id.starts_with("conv_dm_") && persons.len() + agents == 2 {
        return true;
    }
    let mentioned = message.parts.iter().any(|part| match part {
        Part::Text {
            runs: Some(runs), ..
        } => runs
            .iter()
            .any(|run| run.mention.as_deref() == Some(AGENT_MUX)),
        _ => false,
    });
    mentioned
        || message
            .reply_to
            .as_ref()
            .is_some_and(|r| is_mux_message(&r.message_id))
}
