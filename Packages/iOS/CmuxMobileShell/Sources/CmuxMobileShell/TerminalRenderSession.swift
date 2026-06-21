import CMUXMobileCore

/// Orders render-grid replay and live deltas for one mounted terminal surface.
struct TerminalRenderSession: Sendable {
    private static let maxBufferedLiveEnvelopes = 64

    enum Phase: Equatable, Sendable {
        case awaitingSnapshot(bufferValid: Bool)
        case live(baseSeq: UInt64)
    }

    private(set) var phase: Phase = .awaitingSnapshot(bufferValid: true)
    private var bufferedLiveEnvelopes: [MobileTerminalRenderGridEnvelope] = []

    var bufferedLiveCount: Int {
        bufferedLiveEnvelopes.count
    }

    var needsSnapshotReplay: Bool {
        phase == .awaitingSnapshot(bufferValid: false)
    }

    mutating func beginSnapshot() {
        phase = .awaitingSnapshot(bufferValid: true)
        bufferedLiveEnvelopes.removeAll(keepingCapacity: true)
    }

    mutating func cancelSnapshot(baseSeq: UInt64? = nil) {
        phase = .live(baseSeq: baseSeq ?? 0)
        bufferedLiveEnvelopes.removeAll(keepingCapacity: false)
    }

    mutating func invalidateSnapshot() {
        phase = .awaitingSnapshot(bufferValid: false)
        bufferedLiveEnvelopes.removeAll(keepingCapacity: false)
    }

    mutating func receiveSnapshot(
        _ envelope: MobileTerminalRenderGridEnvelope
    ) -> [MobileTerminalRenderGridEnvelope] {
        guard phase != .awaitingSnapshot(bufferValid: false) else {
            bufferedLiveEnvelopes.removeAll(keepingCapacity: false)
            return []
        }
        let baseSeq = envelope.frame.stateSeq
        let buffered = bufferedLiveEnvelopes.filter { liveEnvelope in
            liveEnvelope.frame.stateSeq >= baseSeq
        }
        bufferedLiveEnvelopes.removeAll(keepingCapacity: false)
        phase = .live(baseSeq: baseSeq)
        return [envelope] + buffered
    }

    mutating func receiveLive(
        _ envelope: MobileTerminalRenderGridEnvelope
    ) -> [MobileTerminalRenderGridEnvelope] {
        switch phase {
        case .awaitingSnapshot(bufferValid: false):
            return []
        case .awaitingSnapshot(bufferValid: true):
            bufferedLiveEnvelopes.append(envelope)
            if bufferedLiveEnvelopes.count > Self.maxBufferedLiveEnvelopes {
                bufferedLiveEnvelopes.removeAll(keepingCapacity: false)
                phase = .awaitingSnapshot(bufferValid: false)
            }
            return []
        case .live(let baseSeq):
            guard envelope.frame.stateSeq >= baseSeq else { return [] }
            phase = .live(baseSeq: max(baseSeq, envelope.frame.stateSeq))
            return [envelope]
        }
    }
}
