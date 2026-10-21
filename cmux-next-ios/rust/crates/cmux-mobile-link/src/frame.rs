//! Link framing (PROTOCOL.md "Link"): `u32 BE length | u32 BE channel | u8
//! type | payload`, where `length` counts the channel, type and payload
//! bytes (5 + payload length).

use bytes::{Buf, BufMut, Bytes, BytesMut};
use tokio_util::codec::{Decoder, Encoder};

/// Largest payload one frame carries. Larger channel writes are split.
pub const MAX_PAYLOAD: usize = 256 * 1024;
const HEADER: usize = 4 + 4 + 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameType {
    Open = 0,
    Data = 1,
    Close = 2,
    Ping = 3,
    Pong = 4,
}

impl FrameType {
    fn from_u8(value: u8) -> Option<Self> {
        Some(match value {
            0 => Self::Open,
            1 => Self::Data,
            2 => Self::Close,
            3 => Self::Ping,
            4 => Self::Pong,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub channel: u32,
    pub kind: FrameType,
    pub payload: Bytes,
}

impl Frame {
    pub fn new(channel: u32, kind: FrameType, payload: impl Into<Bytes>) -> Self {
        Self { channel, kind, payload: payload.into() }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    #[error("frame of {0} bytes exceeds the limit")]
    TooLarge(usize),
    #[error("frame length {0} is shorter than the header")]
    TooShort(usize),
    #[error("unknown frame type {0}")]
    UnknownType(u8),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Default, Clone, Copy)]
pub struct FrameCodec;

impl Decoder for FrameCodec {
    type Item = Frame;
    type Error = FrameError;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Frame>, FrameError> {
        if src.len() < 4 {
            return Ok(None);
        }
        let length = u32::from_be_bytes([src[0], src[1], src[2], src[3]]) as usize;
        if length < HEADER - 4 {
            return Err(FrameError::TooShort(length));
        }
        if length > MAX_PAYLOAD + HEADER - 4 {
            return Err(FrameError::TooLarge(length));
        }
        if src.len() < 4 + length {
            src.reserve(4 + length - src.len());
            return Ok(None);
        }
        src.advance(4);
        let channel = src.get_u32();
        let raw_type = src.get_u8();
        let kind = FrameType::from_u8(raw_type).ok_or(FrameError::UnknownType(raw_type))?;
        let payload = src.split_to(length - 5).freeze();
        Ok(Some(Frame { channel, kind, payload }))
    }
}

impl Encoder<Frame> for FrameCodec {
    type Error = FrameError;

    fn encode(&mut self, frame: Frame, dst: &mut BytesMut) -> Result<(), FrameError> {
        if frame.payload.len() > MAX_PAYLOAD {
            return Err(FrameError::TooLarge(frame.payload.len()));
        }
        dst.reserve(HEADER + frame.payload.len());
        dst.put_u32((5 + frame.payload.len()) as u32);
        dst.put_u32(frame.channel);
        dst.put_u8(frame.kind as u8);
        dst.put_slice(&frame.payload);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_partial_input() {
        let mut codec = FrameCodec;
        let mut buffer = BytesMut::new();
        let frame = Frame::new(7, FrameType::Data, Bytes::from_static(b"hello"));
        codec.encode(frame.clone(), &mut buffer).unwrap();
        assert_eq!(&buffer[..9], &[0, 0, 0, 10, 0, 0, 0, 7, 1]);
        let mut partial = buffer.split_to(6);
        assert!(codec.decode(&mut partial).unwrap().is_none());
        partial.unsplit(buffer);
        assert_eq!(codec.decode(&mut partial).unwrap(), Some(frame));
        assert!(partial.is_empty());
    }

    #[test]
    fn rejects_unknown_type_and_oversize() {
        let mut codec = FrameCodec;
        let mut bad = BytesMut::from(&[0u8, 0, 0, 5, 0, 0, 0, 1, 9][..]);
        assert!(matches!(codec.decode(&mut bad), Err(FrameError::UnknownType(9))));
        let mut huge = BytesMut::from(&[0xffu8, 0xff, 0xff, 0xff][..]);
        assert!(matches!(codec.decode(&mut huge), Err(FrameError::TooLarge(_))));
    }
}
