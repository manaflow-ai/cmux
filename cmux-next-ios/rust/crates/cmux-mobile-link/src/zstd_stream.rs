//! `zstd-stream-v1`: every acpmux message on the phone link through one zstd stream kept for
//! the life of the channel (cmux-mobile-host `link_zstd.rs` writes it, the phone reads it
//! through cmux-mobile-link-ffi's `ZstdStreamDecoder`).
//!
//! Each message, any size, is written to the channel's one encoder and flushed, and goes as
//! one envelope:
//!
//! ```text
//! 0x01 | text length (u32 BE) | zstd length (u32 BE) | the flushed zstd bytes
//! ```
//!
//! JSON never starts with 0x01. The bytes of one envelope only decode after every earlier
//! envelope of the channel, in order: the encoder keeps up to [`WINDOW_LOG`] (1 MiB) of
//! earlier messages as context, which is where the ratio comes from (chat events repeat their
//! keys, ids and paths: about 15 % of raw on real sessions, against 94–98 % for today's
//! per-message deflate of messages of 16 KiB or more only). A decoder that fails has lost the
//! context: the channel must reopen.

use zstd::zstd_safe::{self, CCtx, CParameter, DCtx, DParameter, InBuffer, OutBuffer, zstd_sys};

/// The `args.compressions` entry a phone sends to read these envelopes, and the host capability.
pub const NAME: &str = crate::names::ZSTD_STREAM;

/// The first byte of an envelope (never the first byte of JSON text).
pub const MARKER: u8 = 0x01;

/// The envelope's header: marker, text length, zstd length.
pub const HEADER_BYTES: usize = 9;

/// The encoder's level: most of the ratio at a few microseconds a chat message.
pub const LEVEL: i32 = 3;

/// The context window, 1 MiB; the decoder refuses a stream that needs more.
pub const WINDOW_LOG: u32 = 20;

/// The longest message text a decoder accepts (the phone's `MessageJoiner.maxMessage`).
pub const MAX_TEXT: usize = 64 << 20;

/// Why an envelope could not be made or read. Either way the stream is lost.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum StreamError {
    #[error("zstd stream: {0}")]
    Zstd(&'static str),
    #[error("zstd stream: text of {0} bytes is over the limit")]
    TooLong(usize),
    #[error("zstd stream: decoded {got} bytes, header says {want}")]
    Length { got: usize, want: usize },
    #[error("zstd stream: an earlier envelope failed; the channel must reopen")]
    Lost,
}

fn zstd_error(code: usize) -> StreamError {
    StreamError::Zstd(zstd_safe::get_error_name(code))
}

/// One channel's encoder: every message of the channel goes through it, in the order sent.
pub struct StreamEncoder {
    cctx: Option<CCtx<'static>>,
}

impl StreamEncoder {
    pub fn new() -> Self {
        let mut cctx = CCtx::create();
        let ok = cctx.set_parameter(CParameter::CompressionLevel(LEVEL)).is_ok()
            && cctx.set_parameter(CParameter::WindowLog(WINDOW_LOG)).is_ok()
            && cctx.set_parameter(CParameter::ChecksumFlag(false)).is_ok();
        Self { cctx: ok.then_some(cctx) }
    }

    /// `text` as one envelope, written and flushed. An error loses the stream (every later
    /// call fails too): the channel must end.
    pub fn envelope(&mut self, text: &[u8]) -> Result<Vec<u8>, StreamError> {
        let result = self.write(text);
        if result.is_err() {
            self.cctx = None;
        }
        result
    }

    fn write(&mut self, text: &[u8]) -> Result<Vec<u8>, StreamError> {
        let cctx = self.cctx.as_mut().ok_or(StreamError::Lost)?;
        let text_len = u32::try_from(text.len()).map_err(|_| StreamError::TooLong(text.len()))?;
        let mut out = Vec::with_capacity(HEADER_BYTES + 64 + text.len() / 4);
        out.push(MARKER);
        out.extend_from_slice(&text_len.to_be_bytes());
        out.extend_from_slice(&[0; 4]);
        let mut input = InBuffer::around(text);
        loop {
            if out.capacity() - out.len() < 64 {
                out.reserve(out.capacity().max(4096));
            }
            let pos = out.len();
            let mut output = OutBuffer::around_pos(&mut out, pos);
            let left = cctx
                .compress_stream2(&mut output, &mut input, zstd_sys::ZSTD_EndDirective::ZSTD_e_flush)
                .map_err(zstd_error)?;
            if left == 0 && input.pos() == text.len() {
                break;
            }
        }
        let zstd_len =
            u32::try_from(out.len() - HEADER_BYTES).map_err(|_| StreamError::TooLong(out.len()))?;
        out[5..9].copy_from_slice(&zstd_len.to_be_bytes());
        Ok(out)
    }
}

impl Default for StreamEncoder {
    fn default() -> Self {
        Self::new()
    }
}

/// An envelope's header: the text length and zstd length, once its nine bytes are in.
pub fn header(bytes: &[u8]) -> Option<(usize, usize)> {
    if bytes.len() < HEADER_BYTES || bytes[0] != MARKER {
        return None;
    }
    let u32_at =
        |at: usize| u32::from_be_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]]) as usize;
    Some((u32_at(1), u32_at(5)))
}

/// One channel's decoder: every envelope of the channel, in the order received.
pub struct StreamDecoder {
    dctx: Option<DCtx<'static>>,
}

impl StreamDecoder {
    pub fn new() -> Self {
        let mut dctx = DCtx::create();
        let ok = dctx.set_parameter(DParameter::WindowLogMax(WINDOW_LOG)).is_ok();
        Self { dctx: ok.then_some(dctx) }
    }

    /// The text of `body`, an envelope's zstd bytes (after the header): exactly `text_len`
    /// bytes, at most [`MAX_TEXT`]. An error loses the context: every later call fails and
    /// the channel must reopen.
    pub fn decode(&mut self, body: &[u8], text_len: usize) -> Result<Vec<u8>, StreamError> {
        let result = self.read(body, text_len);
        if result.is_err() {
            self.dctx = None;
        }
        result
    }

    fn read(&mut self, body: &[u8], text_len: usize) -> Result<Vec<u8>, StreamError> {
        let dctx = self.dctx.as_mut().ok_or(StreamError::Lost)?;
        if text_len > MAX_TEXT {
            return Err(StreamError::TooLong(text_len));
        }
        // One byte of room past the length: a body that decodes longer is refused.
        let mut out = Vec::with_capacity(text_len + 1);
        let mut input = InBuffer::around(body);
        loop {
            let before = (input.pos(), out.len());
            let mut output = OutBuffer::around_pos(&mut out, before.1);
            dctx.decompress_stream(&mut output, &mut input).map_err(zstd_error)?;
            if out.len() > text_len {
                return Err(StreamError::Length { got: out.len(), want: text_len });
            }
            // Done once every byte is in and the decoder had room left (it holds nothing back).
            if input.pos() == body.len() && out.len() < out.capacity() {
                break;
            }
            if (input.pos(), out.len()) == before {
                return Err(StreamError::Zstd("no progress"));
            }
        }
        if out.len() != text_len {
            return Err(StreamError::Length { got: out.len(), want: text_len });
        }
        Ok(out)
    }
}

impl Default for StreamDecoder {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(i: usize) -> String {
        serde_json::json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "0b6a4c1e-7d2f-4f39-9a51-2c8e5d7f1a30",
            "update": {"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": format!("Step {i}: the tests pass and the change is ready.")}}}})
        .to_string()
    }

    #[test]
    fn a_stream_of_messages_decodes_in_order() {
        let mut encoder = StreamEncoder::new();
        let mut decoder = StreamDecoder::new();
        for i in 0..200 {
            let text = event(i);
            let envelope = encoder.envelope(text.as_bytes()).unwrap();
            let (text_len, zstd_len) = header(&envelope).unwrap();
            assert_eq!((text_len, zstd_len + HEADER_BYTES), (text.len(), envelope.len()));
            assert_eq!(decoder.decode(&envelope[HEADER_BYTES..], text_len).unwrap(), text.as_bytes());
        }
    }

    #[test]
    fn a_large_message_and_an_empty_one_round_trip() {
        let mut encoder = StreamEncoder::new();
        let mut decoder = StreamDecoder::new();
        let large: String = (0..40_000).map(|i| format!("{{\"row\":{i}}},")).collect();
        for text in [large.as_str(), "", "{}"] {
            let envelope = encoder.envelope(text.as_bytes()).unwrap();
            let (text_len, _) = header(&envelope).unwrap();
            assert_eq!(decoder.decode(&envelope[HEADER_BYTES..], text_len).unwrap(), text.as_bytes());
        }
    }

    #[test]
    fn a_wrong_length_is_refused_and_the_stream_is_lost() {
        let mut encoder = StreamEncoder::new();
        let mut decoder = StreamDecoder::new();
        let text = event(1);
        let envelope = encoder.envelope(text.as_bytes()).unwrap();
        let body = &envelope[HEADER_BYTES..];
        assert!(matches!(decoder.decode(body, text.len() - 1), Err(StreamError::Length { .. })));
        assert_eq!(decoder.decode(body, text.len()), Err(StreamError::Lost));
        let mut decoder = StreamDecoder::new();
        assert!(matches!(decoder.decode(body, text.len() + 1), Err(StreamError::Length { .. })));
        assert!(matches!(StreamDecoder::new().decode(body, MAX_TEXT + 1), Err(StreamError::TooLong(_))));
    }

    #[test]
    fn a_window_over_one_mib_is_refused() {
        let mut cctx = CCtx::create();
        cctx.set_parameter(CParameter::WindowLog(23)).unwrap();
        let text = event(1);
        let mut out = Vec::with_capacity(4096);
        let mut input = InBuffer::around(text.as_bytes());
        let mut output = OutBuffer::around(&mut out);
        while cctx
            .compress_stream2(&mut output, &mut input, zstd_sys::ZSTD_EndDirective::ZSTD_e_flush)
            .unwrap()
            > 0
        {}
        assert!(matches!(StreamDecoder::new().decode(&out, text.len()), Err(StreamError::Zstd(_))));
    }

    #[test]
    fn garbage_is_refused() {
        let garbage: Vec<u8> = (0..300u32).map(|i| (i * 37 % 251) as u8).collect();
        assert!(StreamDecoder::new().decode(&garbage, 1000).is_err());
        assert!(StreamDecoder::new().decode(&[], 10).is_err());
    }

    #[test]
    fn a_message_out_of_order_does_not_decode_to_its_text() {
        let mut encoder = StreamEncoder::new();
        let first = encoder.envelope(event(1).as_bytes()).unwrap();
        let second = encoder.envelope(event(2).as_bytes()).unwrap();
        let mut decoder = StreamDecoder::new();
        let skipped = decoder.decode(&second[HEADER_BYTES..], event(2).len());
        assert_ne!(skipped.ok(), Some(event(2).into_bytes()));
        let _ = first;
    }
}
