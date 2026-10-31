//! Transport-wide congestion control feedback (draft-holmer-rmcat-
//! transport-wide-cc-extensions-01). The receiver records arrivals with the
//! `interceptor` crate's [`Recorder`]; the sender reads them back here.

use webrtc::rtcp::transport_feedbacks::transport_layer_cc::{
    PacketStatusChunk, SymbolTypeTcc, TransportLayerCc,
};

pub use webrtc::interceptor::twcc::Recorder;

/// One packet's fate in a feedback: its transport sequence number and, when
/// it arrived, the receiver's arrival time in microseconds (the receiver's
/// clock; only differences matter).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacketResult {
    pub seq: u16,
    pub arrival_us: Option<i64>,
}

/// The packets a feedback reports, in sequence order.
pub fn results(feedback: &TransportLayerCc) -> Vec<PacketResult> {
    let mut symbols = Vec::with_capacity(usize::from(feedback.packet_status_count));
    for chunk in &feedback.packet_chunks {
        match chunk {
            PacketStatusChunk::RunLengthChunk(run) => {
                symbols.extend(std::iter::repeat_n(run.packet_status_symbol, usize::from(run.run_length)));
            }
            PacketStatusChunk::StatusVectorChunk(vector) => {
                symbols.extend(vector.symbol_list.iter().copied());
            }
        }
    }
    symbols.truncate(usize::from(feedback.packet_status_count));
    let mut time = i64::from(feedback.reference_time) * 64_000;
    let mut deltas = feedback.recv_deltas.iter();
    let mut out = Vec::with_capacity(symbols.len());
    for (i, symbol) in symbols.into_iter().enumerate() {
        let seq = feedback.base_sequence_number.wrapping_add(i as u16);
        let arrival_us = match symbol {
            SymbolTypeTcc::PacketReceivedSmallDelta | SymbolTypeTcc::PacketReceivedLargeDelta => {
                let Some(delta) = deltas.next() else { break };
                time += delta.delta;
                Some(time)
            }
            SymbolTypeTcc::PacketReceivedWithoutDelta => Some(time),
            SymbolTypeTcc::PacketNotReceived => None,
        };
        out.push(PacketResult { seq, arrival_us });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_recorders_feedback_reads_back() {
        let mut recorder = Recorder::new(1);
        // 10..20 sent; 13 and 17 lost; arrivals 1 ms apart from 5 s.
        let mut expected = Vec::new();
        for seq in 10u16..20 {
            let arrival = 5_000_000 + i64::from(seq) * 1_000;
            if seq == 13 || seq == 17 {
                expected.push(PacketResult { seq, arrival_us: None });
            } else {
                recorder.record(42, seq, arrival);
                expected.push(PacketResult { seq, arrival_us: Some(arrival) });
            }
        }
        let packets = recorder.build_feedback_packet();
        assert_eq!(packets.len(), 1);
        let feedback = packets[0].as_any().downcast_ref::<TransportLayerCc>().unwrap();
        assert_eq!(feedback.media_ssrc, 42);
        let got = results(feedback);
        assert_eq!(got.len(), expected.len());
        for (g, e) in got.iter().zip(&expected) {
            assert_eq!(g.seq, e.seq);
            match (g.arrival_us, e.arrival_us) {
                // 250 us resolution.
                (Some(a), Some(b)) => assert!((a - b).abs() < 250, "{a} vs {b}"),
                (None, None) => {}
                other => panic!("seq {}: {other:?}", g.seq),
            }
        }
    }
}
