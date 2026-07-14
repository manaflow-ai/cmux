import CMUXMobileCore

/// Atomic presentation state for one producer-authored terminal grid.
struct AuthoritativeTerminalGridState {
    private(set) var surfaceID: String
    private(set) var frame: MobileTerminalRenderGridFrame?

    init(surfaceID: String) {
        self.surfaceID = surfaceID
    }

    mutating func apply(
        _ candidate: MobileTerminalRenderGridFrame
    ) -> AuthoritativeGridPresentationResult {
        guard candidate.surfaceID == surfaceID, candidate.full else {
            return .needsFullSnapshot
        }
        if let frame, isStale(candidate, comparedTo: frame) {
            return .ignoredStale
        }
        frame = candidate
        return .presented
    }

    mutating func reset(surfaceID: String) {
        self.surfaceID = surfaceID
        frame = nil
    }

    private func isStale(
        _ candidate: MobileTerminalRenderGridFrame,
        comparedTo current: MobileTerminalRenderGridFrame
    ) -> Bool {
        if candidate.renderRevision > 0, current.renderRevision > 0 {
            return candidate.renderRevision <= current.renderRevision
        }
        // Legacy v1 producers did not stamp visual revisions. Strictly older
        // byte state is still rejectable; equal-sequence geometry repaints must
        // remain eligible because resizing consumes no PTY bytes.
        return candidate.stateSeq < current.stateSeq
    }
}
