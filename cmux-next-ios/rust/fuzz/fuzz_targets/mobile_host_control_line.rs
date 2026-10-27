//! cmux-mobile-host's app control lines (`control.rs` `Inbound::parse`): what
//! the app writes on hostd's stdin (tokens, the Mac identity, acpmux, browser
//! and surface hosts, device trust, phone credentials), one JSON object per
//! line; a line hostd cannot read is ignored.
//!
//! Invariant past "no panic": a secret the app sends (the Mac's private key,
//! a phone's acpmux credential) never shows in the parsed value's debug text,
//! which is what a log line would print. Each line that is a JSON object is
//! parsed a second time with its secrets set to a marker, which must not show.
#![no_main]

use cmux_mobile_host::control::Inbound;
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

/// The most lines one input feeds.
const MAX_LINES: usize = 64;
/// What every secret of the second parse holds.
const MARKER: &str = "cmux-fuzz-secret-marker";

/// The line with its secret fields set to `MARKER`, if it has any and no
/// other field (a key, an escaped string) holds the marker already.
fn marked(line: &str) -> Option<String> {
    let mut value = serde_json::from_str::<Value>(line.trim()).ok()?;
    if value.to_string().contains(MARKER) {
        return None;
    }
    let mut any = false;
    if let Some(key) = value.get_mut("private_key").filter(|key| key.is_string()) {
        *key = Value::String(MARKER.into());
        any = true;
    }
    if let Some(credentials) = value.get_mut("credentials").and_then(Value::as_object_mut) {
        for credential in credentials.values_mut().filter(|c| c.is_string()) {
            *credential = Value::String(MARKER.into());
            any = true;
        }
    }
    any.then(|| value.to_string())
}

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else { return };
    for line in text.lines().take(MAX_LINES) {
        let parsed = Inbound::parse(line);
        let _ = format!("{parsed:?}");
        if let Some(inbound) = marked(line).as_deref().and_then(Inbound::parse) {
            let debug = format!("{inbound:?}");
            assert!(!debug.contains(MARKER), "a secret shows in {debug}");
        }
    }
});
