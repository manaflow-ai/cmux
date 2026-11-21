//! Compressed acpmux messages on the phone link (CMUX-563). A phone on a slow network sat on
//! its loading screen while the Mac's chat list (about 2.7 KB a chat, megabytes on a busy Mac)
//! crossed the link as JSON text. acpmux already compresses for a WebSocket client that asks
//! (acpmux `frame_compress.rs`), but this host reads every acpmux message to apply the phone's
//! exposure rules (`acpmux_policy`), so it keeps acpmux's text on loopback and compresses on
//! the link hop instead, where the bytes cost time.
//!
//! A phone that reads them opens the `acpmux` channel with `args.compression = "deflate"`.
//! Each message of [`MIN_BYTES`] or more then goes as one envelope, smaller ones as text:
//!
//! ```text
//! 0x00 | text length (u32 BE) | deflate length (u32 BE) | raw deflate (RFC 1951) of the JSON text
//! ```
//!
//! JSON never starts with 0x00, so the phone tells the two apart by the first byte, and the
//! lengths say where an envelope ends among the link's 16 KiB chunks and bound its inflate
//! (cmux-next-ios `DeflatedMessage.swift`). A phone that never asks, and every phone before
//! this host, gets text as before; a host before this one ignores the arg, so the phone reads
//! text from it.

use bytes::Bytes;
use flate2::Compression;
use flate2::write::DeflateEncoder;
use serde_json::Value;
use std::io::Write as _;

/// The `args.compression` a phone sends to read envelopes.
pub const DEFLATE: &str = "deflate";

/// The first byte of an envelope (never the first byte of JSON text).
pub const MARKER: u8 = 0x00;

/// Messages shorter than this stay text: little to save, and a copy to make (acpmux's own bound).
pub const MIN_BYTES: usize = 16 << 10;

/// Past this, a message is compressed on a blocking thread (megabytes take milliseconds).
const BLOCKING_BYTES: usize = 1 << 20;

/// Whether the channel's `args` ask for envelopes.
pub fn asked(args: &Value) -> bool {
    args.get("compression").and_then(Value::as_str) == Some(DEFLATE)
}

/// `text` as the link frame for a phone that asked (`on`): an envelope when it is
/// [`MIN_BYTES`] or more and shrinks, else the text.
pub async fn frame(on: bool, text: &str) -> Bytes {
    if !on || text.len() < MIN_BYTES {
        return Bytes::copy_from_slice(text.as_bytes());
    }
    if text.len() < BLOCKING_BYTES {
        return envelope(text).unwrap_or_else(|| Bytes::copy_from_slice(text.as_bytes()));
    }
    let owned = text.to_owned();
    let made = tokio::task::spawn_blocking(move || {
        let made = envelope(&owned);
        made.unwrap_or_else(|| Bytes::from(owned.into_bytes()))
    });
    made.await.unwrap_or_else(|_| Bytes::copy_from_slice(text.as_bytes()))
}

/// The envelope of `text`, at deflate's fastest level (most of the ratio, twice the speed of
/// the default on a session list); None when it would not be smaller or a length passes u32.
pub fn envelope(text: &str) -> Option<Bytes> {
    let text_len = u32::try_from(text.len()).ok()?;
    let mut out = Vec::with_capacity(9 + text.len() / 4);
    out.push(MARKER);
    out.extend_from_slice(&text_len.to_be_bytes());
    out.extend_from_slice(&[0; 4]);
    let mut encoder = DeflateEncoder::new(out, Compression::fast());
    encoder.write_all(text.as_bytes()).ok()?;
    let mut out = encoder.finish().ok()?;
    let deflated = u32::try_from(out.len().checked_sub(9)?).ok()?;
    if out.len() >= text.len() {
        return None;
    }
    out.get_mut(5..9)?.copy_from_slice(&deflated.to_be_bytes());
    Some(Bytes::from(out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::read::DeflateDecoder;
    use std::io::Read as _;

    fn session_list(rows: usize) -> String {
        let rows: Vec<Value> = (0..rows)
            .map(|i| {
                serde_json::json!({"sessionId": format!("s-{i}"), "name": format!("chat {i}"),
                "harness": "claude", "cwd": "/Users/me/work/project", "status": "idle",
                "preview": "The tests pass and the change is ready for review. ".repeat(3)})
            })
            .collect();
        serde_json::json!({"jsonrpc": "2.0", "id": 3, "result": {"sessions": rows}}).to_string()
    }

    #[test]
    fn a_large_list_goes_as_an_envelope_the_phone_can_read() {
        let text = session_list(500);
        let bytes = envelope(&text).expect("a session list shrinks");
        assert_eq!(bytes[0], MARKER);
        let text_len = u32::from_be_bytes(bytes[1..5].try_into().unwrap()) as usize;
        let deflated = u32::from_be_bytes(bytes[5..9].try_into().unwrap()) as usize;
        assert_eq!(text_len, text.len());
        assert_eq!(deflated + 9, bytes.len());
        assert!(bytes.len() * 4 < text.len(), "{} of {}", bytes.len(), text.len());
        let mut back = String::new();
        DeflateDecoder::new(&bytes[9..]).read_to_string(&mut back).unwrap();
        assert_eq!(back, text);
    }

    #[tokio::test]
    async fn small_messages_and_phones_that_did_not_ask_get_text() {
        let small = r#"{"jsonrpc":"2.0","id":1,"result":{}}"#;
        assert_eq!(&frame(true, small).await[..], small.as_bytes());
        let large = session_list(500);
        assert_eq!(&frame(false, &large).await[..], large.as_bytes());
        assert_eq!(frame(true, &large).await[0], MARKER);
    }

    #[test]
    fn only_deflate_is_asked_for() {
        assert!(asked(&serde_json::json!({"compression": "deflate"})));
        assert!(!asked(&serde_json::json!({})));
        assert!(!asked(&serde_json::json!({"compression": "zlib"})));
        assert!(!asked(&Value::Null));
    }
}
