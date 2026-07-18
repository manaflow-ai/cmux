/// Latest-frame-wins state for one presentation generation.
public struct TerminalRenderFrameAcceptance: Equatable, Sendable {
    /// The most recently accepted frame sequence, if any.
    public private(set) var lastFrameSequence: UInt64?

    /// The most recently accepted canonical terminal sequence, if any.
    public private(set) var lastTerminalSequence: UInt64?

    /// The most recently accepted completion-fence value, if any.
    public private(set) var lastCompletionFenceValue: UInt64?

    /// Creates empty acceptance state for a presentation generation.
    public init() {}

    /// Validates and records a frame as the newest accepted metadata.
    ///
    /// Callers that still need to validate an imported IOSurface should invoke
    /// this on a copy, then commit the copy only after the surface descriptor
    /// matches. This keeps rejected surfaces from advancing sequence state.
    ///
    /// - Parameters:
    ///   - metadata: Decoded frame metadata.
    ///   - fence: Current expected presentation state.
    /// - Returns: The first rejection reason, or `nil` after recording the frame.
    public mutating func accept(
        _ metadata: TerminalRenderFrameMetadata,
        against fence: TerminalRenderPresentationFence
    ) -> TerminalRenderFrameRejection? {
        guard metadata.daemonInstanceID == fence.daemonInstanceID else {
            return .daemonInstanceMismatch
        }
        guard metadata.rendererEpoch == fence.rendererEpoch else {
            return .rendererEpochMismatch
        }
        guard metadata.terminalID == fence.terminalID else {
            return .terminalIdentityMismatch
        }
        guard metadata.terminalEpoch == fence.terminalEpoch else {
            return .terminalEpochMismatch
        }
        guard metadata.terminalSequence >= fence.minimumTerminalSequence,
              lastTerminalSequence.map({ metadata.terminalSequence >= $0 }) ?? true else {
            return .staleTerminalSequence
        }
        guard metadata.presentationID == fence.presentationID else {
            return .presentationIdentityMismatch
        }
        guard metadata.presentationGeneration == fence.presentationGeneration else {
            return .presentationGenerationMismatch
        }
        guard metadata.width == fence.width, metadata.height == fence.height else {
            return .dimensionsMismatch
        }
        guard metadata.pixelFormat == fence.pixelFormat else {
            return .pixelFormatMismatch
        }
        guard metadata.colorSpace == fence.colorSpace else {
            return .colorSpaceMismatch
        }
        switch (metadata.completionFence, fence.completionRequirement) {
        case (.producerCompleted, .producerCompleted):
            break
        case let (.sharedEvent(eventID, value), .sharedEvent(expectedEventID, minimumValue)):
            guard eventID == expectedEventID else {
                return .completionFenceIdentityMismatch
            }
            guard value >= minimumValue,
                  lastCompletionFenceValue.map({ value >= $0 }) ?? true else {
                return .staleCompletionFence
            }
        default:
            return .completionModeMismatch
        }
        guard lastFrameSequence.map({ metadata.frameSequence > $0 }) ?? true else {
            return .staleFrameSequence
        }

        lastFrameSequence = metadata.frameSequence
        lastTerminalSequence = metadata.terminalSequence
        if case let .sharedEvent(_, value) = metadata.completionFence {
            lastCompletionFenceValue = value
        } else {
            lastCompletionFenceValue = nil
        }
        return nil
    }

}
