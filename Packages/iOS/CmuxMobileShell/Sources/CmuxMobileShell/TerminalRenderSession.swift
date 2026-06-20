import CMUXMobileCore

/// Orders render-grid replay and live deltas for one mounted terminal surface.
struct TerminalRenderSession: Sendable {
    enum Phase: Equatable, Sendable {
        case awaitingSnapshot
        case live(baseSeq: UInt64)
    }

    private(set) var phase: Phase = .awaitingSnapshot
    private var bufferedLiveEnvelopes: [MobileTerminalRenderGridEnvelope] = []

    var bufferedLiveCount: Int {
        bufferedLiveEnvelopes.count
    }

    mutating func beginSnapshot() {
        phase = .awaitingSnapshot
        bufferedLiveEnvelopes.removeAll(keepingCapacity: true)
    }

    mutating func cancelSnapshot(baseSeq: UInt64? = nil) {
        phase = .live(baseSeq: baseSeq ?? 0)
        bufferedLiveEnvelopes.removeAll(keepingCapacity: false)
    }

    mutating func receiveSnapshot(
        _ envelope: MobileTerminalRenderGridEnvelope
    ) -> [MobileTerminalRenderGridEnvelope] {
        let baseSeq = envelope.frame.stateSeq
        let buffered = bufferedLiveEnvelopes.filter { liveEnvelope in
            liveEnvelope.frame.stateSeq > baseSeq
        }
        bufferedLiveEnvelopes.removeAll(keepingCapacity: false)
        phase = .live(baseSeq: baseSeq)
        return [envelope] + buffered
    }

    mutating func receiveLive(
        _ envelope: MobileTerminalRenderGridEnvelope
    ) -> [MobileTerminalRenderGridEnvelope] {
        switch phase {
        case .awaitingSnapshot:
            bufferedLiveEnvelopes.append(envelope)
            return []
        case .live(let baseSeq):
            guard envelope.frame.stateSeq > baseSeq else { return [] }
            phase = .live(baseSeq: envelope.frame.stateSeq)
            return [envelope]
        }
    }
}
