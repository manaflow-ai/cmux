import CMUXMobileCore

/// Atomic presentation state for one producer-authored terminal grid.
struct AuthoritativeTerminalGridState {
    private(set) var surfaceID: String
    private(set) var frame: MobileTerminalRenderGridFrame?
    private var orderingFloor: MobileTerminalRenderGridFrame?

    init(surfaceID: String) {
        self.surfaceID = surfaceID
    }

    func classify(
        _ candidate: MobileTerminalRenderGridFrame
    ) -> AuthoritativeGridPresentationResult {
        guard candidate.surfaceID == surfaceID, candidate.full else {
            return .needsFullSnapshot
        }
        if let orderingFloor, isStale(candidate, comparedTo: orderingFloor) {
            return .ignoredStale
        }
        return .presented
    }

    mutating func commit(
        _ candidate: MobileTerminalRenderGridFrame
    ) -> AuthoritativeGridPresentationResult {
        let result = classify(candidate)
        guard result == .presented else { return result }
        frame = candidate
        orderingFloor = candidate
        return result
    }

    mutating func apply(
        _ candidate: MobileTerminalRenderGridFrame
    ) -> AuthoritativeGridPresentationResult {
        commit(candidate)
    }

    /// Starts a replacement stream generation without blanking last-good pixels.
    mutating func beginReplay(surfaceID: String) {
        guard self.surfaceID == surfaceID else {
            replaceSurface(surfaceID: surfaceID)
            return
        }
        orderingFloor = nil
    }

    /// Replaces the logical terminal identity and clears its prior presentation.
    mutating func replaceSurface(surfaceID: String) {
        self.surfaceID = surfaceID
        frame = nil
        orderingFloor = nil
    }

    private func isStale(
        _ candidate: MobileTerminalRenderGridFrame,
        comparedTo current: MobileTerminalRenderGridFrame
    ) -> Bool {
        if candidate.producerEpoch > 0 || current.producerEpoch > 0 {
            if candidate.producerEpoch != current.producerEpoch {
                return candidate.producerEpoch < current.producerEpoch
            }
        }
        if candidate.renderRevision > 0, current.renderRevision > 0 {
            return candidate.renderRevision <= current.renderRevision
        }
        // Legacy v1 producers did not stamp visual revisions. Strictly older
        // byte state is still rejectable; equal-sequence geometry repaints must
        // remain eligible because resizing consumes no PTY bytes.
        return candidate.stateSeq < current.stateSeq
    }
}
