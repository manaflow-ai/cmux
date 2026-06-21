import CMUXMobileCore

/// Orders render-grid replay and live deltas for one mounted terminal surface.
struct TerminalRenderSession: Sendable {
    private static let maxBufferedLiveEnvelopes = 64

    enum Phase: Equatable, Sendable {
        case awaitingSnapshot(bufferValid: Bool)
        case live(baseSeq: UInt64, lastFrame: MobileTerminalRenderGridFrame?)
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
        phase = .live(baseSeq: baseSeq ?? 0, lastFrame: nil)
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
        var latestSeq = envelope.frame.stateSeq
        var latestFrame: MobileTerminalRenderGridFrame? = envelope.frame
        var delivered = [envelope]
        for liveEnvelope in bufferedLiveEnvelopes where Self.shouldDeliver(
            liveEnvelope.frame,
            afterSeq: latestSeq,
            lastFrame: latestFrame
        ) {
            delivered.append(liveEnvelope)
            latestSeq = max(latestSeq, liveEnvelope.frame.stateSeq)
            latestFrame = liveEnvelope.frame
        }
        bufferedLiveEnvelopes.removeAll(keepingCapacity: false)
        phase = .live(baseSeq: latestSeq, lastFrame: latestFrame)
        return delivered
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
        case .live(let baseSeq, let lastFrame):
            guard Self.shouldDeliver(envelope.frame, afterSeq: baseSeq, lastFrame: lastFrame) else { return [] }
            phase = .live(baseSeq: max(baseSeq, envelope.frame.stateSeq), lastFrame: envelope.frame)
            return [envelope]
        }
    }

    private static func shouldDeliver(
        _ frame: MobileTerminalRenderGridFrame,
        afterSeq baseSeq: UInt64,
        lastFrame: MobileTerminalRenderGridFrame?
    ) -> Bool {
        if frame.stateSeq > baseSeq {
            return true
        }
        guard frame.stateSeq == baseSeq else { return false }
        guard let lastFrame else { return true }
        return !isVisibleDuplicate(frame, of: lastFrame)
    }

    private static func isVisibleDuplicate(
        _ frame: MobileTerminalRenderGridFrame,
        of lastFrame: MobileTerminalRenderGridFrame
    ) -> Bool {
        frame.surfaceID == lastFrame.surfaceID &&
            frame.stateSeq == lastFrame.stateSeq &&
            frame.columns == lastFrame.columns &&
            frame.rows == lastFrame.rows &&
            frame.cursor == lastFrame.cursor &&
            frame.activeScreen == lastFrame.activeScreen &&
            frame.rowSignatures() == lastFrame.rowSignatures() &&
            preservesOrMatches(
                incoming: frame.terminalForeground,
                incomingIsPresent: frame.terminalForegroundIsPresent,
                previous: lastFrame.terminalForeground
            ) &&
            preservesOrMatches(
                incoming: frame.terminalBackground,
                incomingIsPresent: frame.terminalBackgroundIsPresent,
                previous: lastFrame.terminalBackground
            ) &&
            preservesOrMatches(
                incoming: frame.terminalCursorColor,
                incomingIsPresent: frame.terminalCursorColorIsPresent,
                previous: lastFrame.terminalCursorColor
            )
    }

    private static func preservesOrMatches(
        incoming: String?,
        incomingIsPresent: Bool,
        previous: String?
    ) -> Bool {
        !incomingIsPresent || incoming == previous
    }
}
