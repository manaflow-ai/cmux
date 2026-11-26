//! The phone's reader of `zstd-stream-v1` (cmux-mobile-link `zstd_stream.rs`): one decoder per
//! `acpmux` channel, fed every 0x01 envelope's zstd bytes in the order they arrive.
//! `AcpmuxConnection.swift` joins an envelope's frames and calls [`ZstdStreamDecoder::decode`].

use std::sync::{Mutex, PoisonError};

use cmux_mobile_link::zstd_stream::{MAX_TEXT, StreamDecoder};

use crate::CmuxMobileError;

/// One channel's decoder. It keeps the stream's context across messages, so a failure loses
/// it: every later call fails too and the channel must reopen.
#[derive(uniffi::Object)]
pub struct ZstdStreamDecoder {
    inner: Mutex<StreamDecoder>,
}

#[uniffi::export]
impl ZstdStreamDecoder {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self { inner: Mutex::new(StreamDecoder::new()) }
    }

    /// The text of one envelope: `body` is its zstd bytes (after the 9-byte header) and
    /// `text_len` the header's text length. Refused unless it decodes to exactly `text_len`
    /// bytes, at most 64 MiB (the joiner's `maxMessage`), within a 1 MiB window.
    pub fn decode(&self, body: Vec<u8>, text_len: u32) -> Result<Vec<u8>, CmuxMobileError> {
        let text_len = text_len as usize;
        if text_len > MAX_TEXT {
            return Err(CmuxMobileError::InvalidArgument {
                message: format!("zstd stream: {text_len} bytes"),
            });
        }
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        inner
            .decode(&body, text_len)
            .map_err(|error| CmuxMobileError::InvalidArgument { message: error.to_string() })
    }
}

impl Default for ZstdStreamDecoder {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_mobile_link::zstd_stream::{HEADER_BYTES, StreamEncoder, header};

    #[test]
    fn decodes_a_stream_and_refuses_a_wrong_length() {
        let mut encoder = StreamEncoder::new();
        let decoder = ZstdStreamDecoder::new();
        for i in 0..50 {
            let text = format!(r#"{{"jsonrpc":"2.0","method":"session/update","params":{{"n":{i}}}}}"#);
            let envelope = encoder.envelope(text.as_bytes()).unwrap();
            let (text_len, _) = header(&envelope).unwrap();
            let out = decoder.decode(envelope[HEADER_BYTES..].to_vec(), text_len as u32).unwrap();
            assert_eq!(out, text.as_bytes());
        }
        let envelope = encoder.envelope(b"{\"a\":1}").unwrap();
        assert!(decoder.decode(envelope[HEADER_BYTES..].to_vec(), 6).is_err());
        // The context is lost: the right length fails now too.
        assert!(decoder.decode(envelope[HEADER_BYTES..].to_vec(), 7).is_err());
        assert!(ZstdStreamDecoder::new().decode(vec![1, 2, 3, 4, 5], 10).is_err());
        assert!(ZstdStreamDecoder::new().decode(Vec::new(), u32::MAX).is_err());
    }
}
