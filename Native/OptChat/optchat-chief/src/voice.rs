//! The voices of the one Chief (cmuxterm-hq `docs/chief-team.md`). Every
//! message stays the Chief participant's; a voice names who of the Chief's
//! team speaks: `desk` (the front desk), later a subagent's id. It rides in
//! the message's `client_msg_id` as `voice:<name>:<rest>`, so neither the
//! owner nor the wire changes: an old reader shows a plain Chief message,
//! and the app's transcript labels a voiced one with its name.

/// The front desk: the host's own notices, written without a model (the
/// approval relay, `brain/control.rs`).
pub const DESK: &str = "desk";

const PREFIX: &str = "voice:";

/// The client_msg_id of a message in `voice`, unique by `rest`.
pub fn key(voice: &str, rest: &str) -> String {
    format!("{PREFIX}{voice}:{rest}")
}

/// The voice of a message's client_msg_id: None for the Chief's own
/// (`turn:optchat:...`, notices) and for anything not lowercase
/// letters, digits and dashes.
pub fn of(key: &str) -> Option<&str> {
    let (name, _) = key.strip_prefix(PREFIX)?.split_once(':')?;
    (!name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'))
    .then_some(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_voiced_key_names_its_voice_and_others_have_none() {
        let k = key(DESK, "turn:optchat:4:17");
        assert_eq!(k, "voice:desk:turn:optchat:4:17");
        assert_eq!(of(&k), Some("desk"));
        assert_eq!(of("voice:a7:x"), Some("a7"));
        assert_eq!(of("turn:optchat:4:17"), None);
        assert_eq!(of("voice::x"), None);
        assert_eq!(of("voice:Desk:x"), None);
        assert_eq!(of("voice:desk"), None);
    }
}
