//! Link framing (PROTOCOL.md "Link"): `u32 BE length | u32 BE channel | u8
//! type | payload`, where `length` counts the channel, type and payload
//! bytes (5 + payload length).

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

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
    DeflatedData = 5,
    /// A chunk of a numbered message on a channel whose messages also travel
    /// as datagrams (`crate::classes`): sent only to a peer that listed
    /// [`crate::classes::CLASSES_LANE`].
    Sequenced = 6,
    /// A sequenced channel frame (reliable links only, both sides offered
    /// `reliable`): `u64 seq | u8 inner type | inner payload`.
    Seq = 7,
    /// Channel 0, reliable links only: `u32 count | (u32 channel, u64 seq)*`.
    Ack = 8,
    /// Channel 0, reliable links only: a carrier's opening (new or resume).
    Hello = 9,
    /// Channel 0, reliable links only: the link ends on purpose (a carrier
    /// that just drops is resumed instead).
    Bye = 10,
}

impl FrameType {
    pub(crate) fn from_u8(value: u8) -> Option<Self> {
        Some(match value {
            0 => Self::Open,
            1 => Self::Data,
            2 => Self::Close,
            3 => Self::Ping,
            4 => Self::Pong,
            5 => Self::DeflatedData,
            6 => Self::Sequenced,
            7 => Self::Seq,
            8 => Self::Ack,
            9 => Self::Hello,
            10 => Self::Bye,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub channel: u32,
    pub kind: FrameType,
    pub payload: Bytes,
    /// Set when the link's writer has handed this frame to its transport
    /// (`ChannelSender::send_marked`); never on the wire.
    pub flushed: Option<FlushMark>,
    /// When the link's outbox took this frame, for its outbox wait
    /// ([`crate::outbox_wait`]); never on the wire.
    pub queued_at: Option<tokio::time::Instant>,
}

impl Frame {
    pub fn new(channel: u32, kind: FrameType, payload: impl Into<Bytes>) -> Self {
        Self { channel, kind, payload: payload.into(), flushed: None, queued_at: None }
    }

    /// Compress a held write independently. The four-byte size keeps queue
    /// accounting and the receiver's allocation in terms of original bytes.
    pub(crate) fn deflate_if_smaller(&mut self) {
        use flate2::{Compress, Compression, FlushCompress, Status};
        let size = self.payload.len();
        if size <= 4 {
            return;
        }
        let mut packed = Vec::with_capacity(size);
        packed.extend_from_slice(&(size as u32).to_be_bytes());
        let mut encoder = Compress::new(Compression::fast(), false);
        if matches!(
            encoder.compress_vec(&self.payload, &mut packed, FlushCompress::Finish),
            Ok(Status::StreamEnd)
        ) && packed.len() < size
        {
            self.kind = FrameType::DeflatedData;
            self.payload = Bytes::from(packed);
        }
    }

    pub(crate) fn queue_bytes(&self) -> usize {
        // Only locally created frames enter an outbox.
        if self.kind == FrameType::DeflatedData {
            self.payload.as_ref().get_u32() as usize
        } else {
            self.payload.len()
        }
    }

    /// Restore exactly one data event. Both the input and output are bounded
    /// before inflating, including for a corrupt length or deflate stream.
    pub(crate) fn into_data(mut self) -> Result<Bytes, FrameError> {
        if self.kind == FrameType::Data {
            return Ok(self.payload);
        }
        use flate2::{Decompress, FlushDecompress, Status};
        if self.payload.len() < 4 {
            return Err(FrameError::InvalidDeflate);
        }
        let size = self.payload.get_u32() as usize;
        if size > crate::link::DATA_CHUNK {
            return Err(FrameError::TooLarge(size));
        }
        let mut plain = vec![0; size];
        let mut decoder = Decompress::new(false);
        if !matches!(
            decoder.decompress(&self.payload, &mut plain, FlushDecompress::Finish),
            Ok(Status::StreamEnd)
        ) || decoder.total_in() != self.payload.len() as u64
            || decoder.total_out() != size as u64
        {
            return Err(FrameError::InvalidDeflate);
        }
        Ok(Bytes::from(plain))
    }
}

/// When a frame's bytes were handed to the transport (the link writer's flush
/// after it): wall clock, Unix epoch microseconds, 0 until then. Clones share
/// it. Two marks are equal only when they are the same mark.
#[derive(Clone, Default)]
pub struct FlushMark(Arc<AtomicI64>);

impl FlushMark {
    pub fn new() -> Self {
        Self::default()
    }

    /// Epoch microseconds of the flush, or `None` while the frame waits.
    pub fn flushed_us(&self) -> Option<i64> {
        Some(self.0.load(Ordering::Acquire)).filter(|us| *us > 0)
    }

    /// Marks the flush at `us` (epoch microseconds); the first one stays.
    pub fn set(&self, us: i64) {
        let _ = self.0.compare_exchange(0, us.max(1), Ordering::AcqRel, Ordering::Acquire);
    }
}

impl PartialEq for FlushMark {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

impl Eq for FlushMark {}

impl std::fmt::Debug for FlushMark {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "FlushMark({:?})", self.flushed_us())
    }
}

/// The wall clock in Unix epoch microseconds.
pub fn epoch_us() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_micros() as i64)
}

#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    #[error("frame of {0} bytes exceeds the limit")]
    TooLarge(usize),
    #[error("frame length {0} is shorter than the header")]
    TooShort(usize),
    #[error("unknown frame type {0}")]
    UnknownType(u8),
    #[error("invalid deflated data frame")]
    InvalidDeflate,
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
        Ok(Some(Frame::new(channel, kind, payload)))
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
    fn held_data_round_trips_with_its_original_queue_charge() {
        let plain = Bytes::from("a terminal row / another chat delta\n".repeat(200));
        let mut frame = Frame::new(9, FrameType::Data, plain.clone());
        frame.deflate_if_smaller();
        assert_eq!(frame.kind, FrameType::DeflatedData);
        assert!(frame.payload.len() < plain.len());
        assert_eq!(frame.queue_bytes(), plain.len());
        let mut wire = BytesMut::new();
        FrameCodec.encode(frame.clone(), &mut wire).unwrap();
        assert_eq!(FrameCodec.decode(&mut wire).unwrap().unwrap().into_data().unwrap(), plain);

        let mut trailing = frame.payload.to_vec();
        trailing.push(0);
        assert!(Frame::new(9, frame.kind, trailing).into_data().is_err());
        for size in [0, plain.len() - 1, plain.len() + 1, MAX_PAYLOAD + 1] {
            let mut corrupt = frame.payload.to_vec();
            corrupt[..4].copy_from_slice(&(size as u32).to_be_bytes());
            assert!(Frame::new(9, frame.kind, corrupt).into_data().is_err());
        }
        let end = frame.payload.len() - 1;
        assert!(Frame::new(9, frame.kind, frame.payload.slice(..end)).into_data().is_err());

        let mut small = Frame::new(9, FrameType::Data, Bytes::from_static(b"abcde"));
        small.deflate_if_smaller();
        assert_eq!(small.kind, FrameType::Data);
        assert_eq!(small.payload.as_ref(), b"abcde");
    }

    #[test]
    fn rejects_unknown_type_and_oversize() {
        let mut codec = FrameCodec;
        let mut bad = BytesMut::from(&[0u8, 0, 0, 5, 0, 0, 0, 1, 11][..]);
        assert!(matches!(codec.decode(&mut bad), Err(FrameError::UnknownType(11))));
        let mut huge = BytesMut::from(&[0xffu8, 0xff, 0xff, 0xff][..]);
        assert!(matches!(codec.decode(&mut huge), Err(FrameError::TooLarge(_))));
    }

    /// Base shipped wire type 5 as the parked link's deflated data and 6 as
    /// classes' sequenced chunk, so the reliable link's frames sit above them.
    #[test]
    fn types_5_and_6_are_base_frames_and_the_reliable_frames_are_7_to_10() {
        let wire = [
            (5u8, FrameType::DeflatedData),
            (6, FrameType::Sequenced),
            (7, FrameType::Seq),
            (8, FrameType::Ack),
            (9, FrameType::Hello),
            (10, FrameType::Bye),
        ];
        for (byte, kind) in wire {
            assert_eq!(FrameType::from_u8(byte), Some(kind), "type {byte}");
            assert_eq!(kind as u8, byte, "{kind:?}");
            let mut buffer = BytesMut::from(&[0u8, 0, 0, 5, 0, 0, 0, 1, byte][..]);
            let frame = FrameCodec.decode(&mut buffer).unwrap().expect("a whole frame");
            assert_eq!(frame.kind, kind, "type {byte} decodes as {kind:?}");
        }
        assert_ne!(FrameType::from_u8(5), Some(FrameType::Seq));
        assert_ne!(FrameType::from_u8(6), Some(FrameType::Seq));
    }
}
