//! Bounds NACK resends on the sender, below webrtc-rs's NACK responder.
//!
//! The NACK generator asks for every missing packet again each interval
//! (20 ms here) until it arrives or leaves the window, with no retry limit,
//! and the responder resends each time. On a congested path the resends
//! queue behind the losses they repair and get lost too, so the same packets
//! are asked for again and again: on a 1.5 Mbit/s bottleneck with a 250 ms
//! queue the resends alone kept the queue full and lost half of all packets
//! for four seconds, with the target at its floor. libwebrtc bounds this by
//! RTT and retry count; this interceptor does the same for any carrier: a
//! sequence number goes out again only [`MIN_RESEND_GAP`] after its last
//! send, and at most [`MAX_RESENDS`] times. A packet still missing after
//! that is the receiver's to give up (its deadline, then a keyframe).

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use webrtc::interceptor::stream_info::StreamInfo;
use webrtc::interceptor::{
    Attributes, Interceptor, InterceptorBuilder, RTCPReader, RTCPWriter, RTPReader, RTPWriter,
};

use super::rtp;

/// Shortest time between two sends of one sequence number: about one NACK
/// round on a direct or TURN path, so a resend that is still on its way
/// is not sent again.
pub const MIN_RESEND_GAP: Duration = Duration::from_millis(40);
/// Most resends of one packet.
pub const MAX_RESENDS: u8 = 3;
/// Sequence numbers remembered (about two seconds of video at 2.5 Mbit/s;
/// longer at lower rates). A NACK for an older one is past the generator's
/// 512-packet window anyway.
const REMEMBERED: usize = 4096;

pub(super) struct ResendGuardBuilder;

impl InterceptorBuilder for ResendGuardBuilder {
    fn build(&self, _id: &str) -> Result<Arc<dyn Interceptor + Send + Sync>, webrtc::interceptor::Error> {
        Ok(Arc::new(ResendGuard))
    }
}

struct ResendGuard;

/// When each recent sequence number was last sent, and how often again.
#[derive(Default)]
pub(super) struct Sends {
    last: HashMap<u16, (Instant, u8)>,
    order: VecDeque<u16>,
}

impl Sends {
    /// Whether packet `seq` may go now.
    pub(super) fn allow(&mut self, seq: u16, now: Instant) -> bool {
        match self.last.get_mut(&seq) {
            None => {
                self.last.insert(seq, (now, 0));
                self.order.push_back(seq);
                while self.order.len() > REMEMBERED {
                    if let Some(old) = self.order.pop_front() {
                        self.last.remove(&old);
                    }
                }
                true
            }
            Some((at, resends)) => {
                if *resends >= MAX_RESENDS || now.duration_since(*at) < MIN_RESEND_GAP {
                    return false;
                }
                *at = now;
                *resends += 1;
                true
            }
        }
    }
}

struct GuardWriter {
    next: Arc<dyn RTPWriter + Send + Sync>,
    sends: std::sync::Mutex<Sends>,
}

#[async_trait::async_trait]
impl RTPWriter for GuardWriter {
    async fn write(
        &self,
        packet: &rtp::packet::Packet,
        attributes: &Attributes,
    ) -> Result<usize, webrtc::interceptor::Error> {
        let allowed = self
            .sends
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .allow(packet.header.sequence_number, Instant::now());
        if !allowed {
            return Ok(0);
        }
        self.next.write(packet, attributes).await
    }
}

#[async_trait::async_trait]
impl Interceptor for ResendGuard {
    async fn bind_rtcp_reader(
        &self,
        reader: Arc<dyn RTCPReader + Send + Sync>,
    ) -> Arc<dyn RTCPReader + Send + Sync> {
        reader
    }

    async fn bind_rtcp_writer(
        &self,
        writer: Arc<dyn RTCPWriter + Send + Sync>,
    ) -> Arc<dyn RTCPWriter + Send + Sync> {
        writer
    }

    async fn bind_local_stream(
        &self,
        _info: &StreamInfo,
        writer: Arc<dyn RTPWriter + Send + Sync>,
    ) -> Arc<dyn RTPWriter + Send + Sync> {
        Arc::new(GuardWriter { next: writer, sends: std::sync::Mutex::new(Sends::default()) })
    }

    async fn unbind_local_stream(&self, _info: &StreamInfo) {}

    async fn bind_remote_stream(
        &self,
        _info: &StreamInfo,
        reader: Arc<dyn RTPReader + Send + Sync>,
    ) -> Arc<dyn RTPReader + Send + Sync> {
        reader
    }

    async fn unbind_remote_stream(&self, _info: &StreamInfo) {}

    async fn close(&self) -> Result<(), webrtc::interceptor::Error> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_packet_goes_again_only_after_the_gap_and_at_most_three_times() {
        let mut sends = Sends::default();
        let t0 = Instant::now();
        let ms = |n| t0 + Duration::from_millis(n);
        assert!(sends.allow(7, ms(0)));
        assert!(sends.allow(8, ms(0)));
        // The generator's 20 ms NACK rounds: every other one goes.
        assert!(!sends.allow(7, ms(20)));
        assert!(sends.allow(7, ms(40)));
        assert!(!sends.allow(7, ms(60)));
        assert!(sends.allow(7, ms(80)));
        assert!(sends.allow(7, ms(120)));
        // Three resends: no more.
        assert!(!sends.allow(7, ms(500)));
        assert!(sends.allow(8, ms(500)));
    }

    #[test]
    fn old_sequence_numbers_are_forgotten_so_a_wrap_sends_again() {
        let mut sends = Sends::default();
        let t0 = Instant::now();
        for seq in 0..=u16::MAX {
            assert!(sends.allow(seq, t0));
        }
        // 65536 later the same number is a new packet.
        assert!(sends.allow(0, t0 + Duration::from_secs(2)));
    }
}
