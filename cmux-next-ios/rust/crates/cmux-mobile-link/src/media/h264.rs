//! H.264 over RTP (RFC 6184) with the `rtp` crate: single NAL units, STAP-A
//! for the parameter sets in front of an IDR, FU-A for large slices.

use bytes::Bytes;
use webrtc::rtp::codecs::h264::{H264Packet, H264Payloader};
use webrtc::rtp::packetizer::Depacketizer as _;
use webrtc::rtp::packetizer::Payloader as _;

/// NAL unit types (RFC 6184 / H.264 table 7-1).
const NAL_IDR: u8 = 5;
const NAL_SPS: u8 = 7;

/// Splits Annex-B access units into RTP payloads. Keeps the parameter sets
/// across calls, as the `rtp` crate's payloader does (it sends them in one
/// STAP-A in front of the next slice).
#[derive(Debug, Default)]
pub struct Packetizer {
    payloader: H264Payloader,
}

impl Packetizer {
    /// The RTP payloads of one access unit, in order. The last one ends the
    /// frame (RTP marker bit).
    pub fn payloads(&mut self, access_unit: &Bytes, mtu: usize) -> Vec<Bytes> {
        self.payloader.payload(mtu, access_unit).unwrap_or_default()
    }
}

/// Rebuilds one Annex-B access unit from the RTP payloads of a frame, in
/// sequence order. `None` when a payload does not parse (a corrupt frame is
/// dropped like a lost one).
pub fn depacketize<'a>(payloads: impl IntoIterator<Item = &'a Bytes>) -> Option<Vec<u8>> {
    let mut packet = H264Packet::default();
    let mut out = Vec::new();
    for payload in payloads {
        let nal = packet.depacketize(payload).ok()?;
        out.extend_from_slice(&nal);
    }
    (!out.is_empty()).then_some(out)
}

/// The NAL unit types of an Annex-B access unit.
pub fn nal_types(access_unit: &[u8]) -> Vec<u8> {
    let mut types = Vec::new();
    let mut i = 0;
    while i + 3 < access_unit.len() {
        let start3 = access_unit[i] == 0 && access_unit[i + 1] == 0 && access_unit[i + 2] == 1;
        let start4 = i + 4 < access_unit.len()
            && access_unit[i] == 0
            && access_unit[i + 1] == 0
            && access_unit[i + 2] == 0
            && access_unit[i + 3] == 1;
        if start4 {
            types.push(access_unit[i + 4] & 0x1f);
            i += 5;
        } else if start3 {
            types.push(access_unit[i + 3] & 0x1f);
            i += 4;
        } else {
            i += 1;
        }
    }
    types
}

/// Whether a decoder can start at this access unit (it carries an IDR slice
/// and the sequence parameter set).
pub fn is_keyframe(access_unit: &[u8]) -> bool {
    let types = nal_types(access_unit);
    types.contains(&NAL_IDR) && types.contains(&NAL_SPS)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A fake Annex-B access unit: SPS, PPS and an IDR slice of `slice` bytes,
    /// or one non-IDR slice.
    pub(crate) fn access_unit(keyframe: bool, slice: usize, fill: u8) -> Bytes {
        let mut au = Vec::new();
        if keyframe {
            au.extend_from_slice(&[0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x1f, 0xda, 0x01]);
            au.extend_from_slice(&[0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80]);
            au.extend_from_slice(&[0, 0, 0, 1, 0x65]);
        } else {
            au.extend_from_slice(&[0, 0, 0, 1, 0x41]);
        }
        // Avoid start-code emulation in the filler.
        au.extend(std::iter::repeat_n(fill.max(2), slice));
        Bytes::from(au)
    }

    #[test]
    fn a_keyframe_round_trips_through_stap_a_and_fu_a() {
        let au = access_unit(true, 5000, 7);
        let mut packetizer = Packetizer::default();
        let payloads = packetizer.payloads(&au, 1100);
        // STAP-A (SPS+PPS) then FU-A fragments of the IDR slice.
        assert_eq!(payloads[0][0] & 0x1f, 24);
        assert!(payloads.len() >= 6);
        assert!(payloads.iter().all(|p| p.len() <= 1100));
        let back = depacketize(&payloads).unwrap();
        assert_eq!(nal_types(&back), [7, 8, 5]);
        assert!(is_keyframe(&back));
        // Same bytes after the start codes are normalized to 4 bytes.
        assert_eq!(back, au.to_vec());
    }

    #[test]
    fn a_small_p_frame_is_one_packet() {
        let au = access_unit(false, 300, 9);
        let mut packetizer = Packetizer::default();
        let payloads = packetizer.payloads(&au, 1100);
        assert_eq!(payloads.len(), 1);
        let back = depacketize(&payloads).unwrap();
        assert_eq!(back, au.to_vec());
        assert!(!is_keyframe(&back));
    }
}
