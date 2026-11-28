//! What the daemon sends a peer whose ABI hello names an older revision, written down to it by
//! the rules of `spec/acpmux-abi.compat.json` (hq RFD 0178, build 3: "old peers degrade, never
//! error").
//!
//! The wire ABI gate (cmux#55527) makes every breaking change add a revision to that file with
//! a rule per message it changed: rev 2 removed the to-do list (`taskList`, `planStep`). Its
//! rule's `default` is what a reader of the revision before expects in the member's place. A
//! client whose `initialize` said `abi: 1` (`abi_hello.rs`, [`crate::abi_hello::Skew::Older`])
//! is sent each event and reply rewritten down to revision 1, so it reads `taskList: null`
//! where it expects the member, instead of finding it missing.
//!
//! Nothing here can fail a send: a peer at this build's revision, one from before the hello
//! (it names none and is served as it always was), a revision the file does not cover, or a
//! rewrite that does not parse all leave the message as it was. The rules compile per
//! `(message, from, to)` once, in `cmux_api_compat`.
//!
//! Message kinds are the gate's (`cmux_api_compat::json_schema`): `event:<method>` is a
//! notification's or a server request's params, `response:<method>` a request's result under
//! `/data`.

use cmux_api_compat::Compat;
use serde_json::Value;
use std::sync::OnceLock;

/// The compat file, built in: the rules this build was gated against.
const SPEC: &[u8] = include_bytes!("../spec/acpmux-abi.compat.json");

/// The process's compat runtime; none when the built-in file does not parse (the gate's test
/// keeps it parsing), and then nothing is translated.
pub fn compat() -> Option<&'static Compat> {
    static COMPAT: OnceLock<Option<Compat>> = OnceLock::new();
    COMPAT
        .get_or_init(|| {
            let built = cmux_api_compat::Schema::from_json(SPEC).and_then(Compat::new);
            match built {
                Ok(compat) => Some(compat),
                Err(error) => {
                    tracing::warn!(%error, "acpmux-abi.compat.json does not load: older peers are sent this build's messages untranslated");
                    None
                }
            }
        })
        .as_ref()
}

/// The revision to write a peer's messages at, when it is not this build's: the peer's hello
/// named an older revision the compat file covers. `None` for every other peer (same, newer,
/// from before the hello, or older than the file's base): it is sent messages as they are.
pub fn target(peer_abi: Option<u32>) -> Option<u32> {
    let rev = peer_abi.filter(|&rev| rev < crate::protocol::ABI)?;
    compat()?.supports(rev).then_some(rev)
}

/// Rewrites `body`, a `kind` message as the compat file roots it, for a reader at revision `to`.
/// True when it changed.
pub fn down(kind: &str, to: u32, body: &mut Value) -> bool {
    let Some(compat) = compat() else { return false };
    let Ok(program) = compat.program(kind, crate::protocol::ABI, to) else { return false };
    if program.is_identity() {
        return false;
    }
    let Ok(bytes) = serde_json::to_vec(body) else { return false };
    let Ok(out) = program.rewrite(&bytes) else { return false };
    let Ok(rewritten) = serde_json::from_slice::<Value>(&out) else { return false };
    if rewritten == *body {
        return false;
    }
    *body = rewritten;
    true
}

/// [`down`] of a notification's or server request's params.
pub fn down_event(method: &str, to: u32, params: &mut Value) -> bool {
    down(&format!("event:{method}"), to, params)
}

/// [`down`] of a request's result: the gate roots a result under `/data`.
pub fn down_result(method: &str, to: u32, result: &mut Value) -> bool {
    let mut wrapped = serde_json::json!({ "data": result.take() });
    let changed = down(&format!("response:{method}"), to, &mut wrapped);
    *result = match wrapped {
        Value::Object(mut map) => map.remove("data").unwrap_or(Value::Null),
        other => other,
    };
    changed
}

/// Whether a `kind` message changes on its way to a reader at `to`: false lets a caller skip
/// parsing a line it holds already serialized.
pub fn changes(kind: &str, to: u32) -> bool {
    compat()
        .and_then(|compat| compat.program(kind, crate::protocol::ABI, to).ok())
        .is_some_and(|program| !program.is_identity())
}

#[cfg(test)]
#[path = "abi_compat_tests.rs"]
mod tests;
