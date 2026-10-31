//! Which tab a lane frame belongs to.
//!
//! One lane carries one tab's video at a time, and a newer tab takes it
//! over (`VideoOut::claim`). The phone cannot tell from RTP when the switch
//! happened: its `open` for the new tab and the Mac's claim race the frames
//! already on the way, and a refused `open` never switches at all. So the
//! phone picks a random tag per `browser` channel (`"video_tag"` in the open
//! args) and hostd appends it to each access unit it sends on the lane, as
//! an H.264 SEI NAL unit (user data unregistered, our UUID) after the
//! slices. Each viewer keeps the frames with its own tag and strips the SEI
//! before decoding. Neither carrier, the packetizer, nor the receiver core
//! looks inside: the first packet of a keyframe is still its parameter sets.
//!
//! The payload has no zero bytes (the UUID is chosen so, and the tag is 8
//! hex digits), so it needs no emulation prevention.

use bytes::{BufMut, Bytes, BytesMut};

/// User data unregistered (H.264 D.1.6).
const SEI_USER_DATA_UNREGISTERED: u8 = 5;
const NAL_SEI: u8 = 6;
/// Our SEI's UUID ("cmux-mobile-vid1", 16 ASCII bytes), no zero bytes.
const UUID: [u8; 16] = *b"cmux-mobile-vid1";
/// UUID plus 8 hex digits.
const PAYLOAD: usize = 16 + 8;
/// Start code, NAL header, payload type, payload size, payload, RBSP stop bit.
const SEI_LEN: usize = 4 + 1 + 1 + 1 + PAYLOAD + 1;

/// `access_unit` (Annex-B) with the tag SEI appended.
pub fn append(access_unit: &[u8], tag: u32) -> Bytes {
    let mut out = BytesMut::with_capacity(access_unit.len() + SEI_LEN);
    out.put_slice(access_unit);
    out.put_slice(&[0, 0, 0, 1, NAL_SEI, SEI_USER_DATA_UNREGISTERED, PAYLOAD as u8]);
    out.put_slice(&UUID);
    out.put_slice(format!("{tag:08x}").as_bytes());
    out.put_u8(0x80);
    out.freeze()
}

/// The tag of `access_unit`, which loses the SEI; `None` (and unchanged)
/// when it has none.
pub fn strip(access_unit: &mut Vec<u8>) -> Option<u32> {
    let tag = peek(access_unit)?;
    access_unit.truncate(access_unit.len() - SEI_LEN);
    Some(tag)
}

/// The tag of `access_unit`, left as it is; `None` when it has none.
pub fn peek(access_unit: &[u8]) -> Option<u32> {
    let start = access_unit.len().checked_sub(SEI_LEN)?;
    let sei = &access_unit[start..];
    let header = [0, 0, 0, 1, NAL_SEI, SEI_USER_DATA_UNREGISTERED, PAYLOAD as u8];
    if sei[..7] != header || sei[7..23] != UUID || sei[SEI_LEN - 1] != 0x80 {
        return None;
    }
    std::str::from_utf8(&sei[23..31]).ok().and_then(|hex| u32::from_str_radix(hex, 16).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::h264;
    use crate::media::h264::tests::access_unit;

    #[test]
    fn a_tag_rides_the_access_unit_and_comes_off_whole() {
        let au = access_unit(true, 3000, 7);
        for tag in [0, 1, 0xdead_beef, u32::MAX] {
            let tagged = append(&au, tag);
            // A NAL unit of its own, after the slices; no zero bytes inside.
            assert_eq!(h264::nal_types(&tagged).last(), Some(&NAL_SEI));
            assert!(!tagged[au.len() + 4..].contains(&0));
            assert_eq!(peek(&tagged), Some(tag));
            let mut back = tagged.to_vec();
            assert_eq!(strip(&mut back), Some(tag));
            assert_eq!(back, au.to_vec());
        }
        let mut plain = au.to_vec();
        assert_eq!(strip(&mut plain), None);
        assert_eq!(plain, au.to_vec());
    }

    /// Through the packetizer and back: the receiver's frame ends with it,
    /// and a keyframe still starts with its parameter sets.
    #[test]
    fn a_tagged_keyframe_still_starts_with_its_parameter_sets() {
        let au = access_unit(true, 5000, 9);
        let tagged = append(&au, 42);
        let mut packetizer = h264::Packetizer::default();
        let payloads = packetizer.payloads(&tagged, 1100);
        let first = payloads[0][0] & 0x1f;
        assert!(first == 24 || first == 7, "first packet NAL type {first}");
        let mut back = h264::depacketize(payloads.iter()).unwrap();
        assert!(h264::is_keyframe(&back));
        assert_eq!(strip(&mut back), Some(42));
    }
}
