//! Pure removal of model-sized copies from log values.
use base64::Engine;
use serde_json::Value;

/// PNG mark shared by the encoder and log scrubber.
pub const MARK: &[u8] = b"acpmux\0model-copy";
/// Replacement for a model copy in a log value.
pub const OMITTED: &str = "(acpmux model-sized copy, not logged)";

/// `record` (what acpmux wrote to an agent, before it is logged) with the base64 of every
/// model-sized copy in it, in the ACP prompt or a harness's own line, replaced by a note.
pub fn scrub_logged(record: &mut Value) {
    match record {
        Value::String(s) if is_copy(s) => *s = OMITTED.to_owned(),
        Value::Array(items) => items.iter_mut().for_each(scrub_logged),
        Value::Object(map) => map.values_mut().for_each(scrub_logged),
        _ => {}
    }
}

/// Whether `s` is the base64 of a copy: a PNG whose first chunk after its header is [`MARK`].
pub fn is_copy(s: &str) -> bool {
    // The signature, IHDR (25 bytes) and the mark's chunk head, in whole base64 quanta.
    const HEAD: usize = (8 + 25 + 8 + MARK.len()).div_ceil(3) * 4;
    if s.len() < HEAD || !s.starts_with("iVBORw0KGgo") {
        return false;
    }
    let Ok(head) = base64::engine::general_purpose::STANDARD
        .decode(s.as_bytes().get(..HEAD).unwrap_or_default())
    else {
        return false;
    };
    head.get(33 + 4..33 + 8) == Some(b"tEXt") && head.get(41..41 + MARK.len()) == Some(MARK)
}
