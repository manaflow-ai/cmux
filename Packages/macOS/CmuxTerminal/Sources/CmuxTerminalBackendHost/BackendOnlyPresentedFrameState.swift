internal import CmuxTerminalRenderProtocol

@MainActor
final class BackendOnlyPresentedFrameState {
    private var metadata: TerminalRenderFrameMetadata?
    private var semanticFrameKey: BackendOnlySemanticFrameKey?
    private var drainScheduled = false
    private var accessibilityDemanded = false

    func record(_ value: TerminalRenderFrameMetadata) -> Bool {
        metadata = value
        let key = BackendOnlySemanticFrameKey(
            presentationID: value.presentationID,
            presentationGeneration: value.presentationGeneration,
            terminalSequence: value.terminalSequence
        )
        guard semanticFrameKey != key else { return false }
        semanticFrameKey = key
        guard accessibilityDemanded, !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    func takeScheduledDrain() -> BackendOnlyScheduledFrameDrain? {
        guard drainScheduled, let metadata else { return nil }
        drainScheduled = false
        return BackendOnlyScheduledFrameDrain(
            metadata: metadata,
            accessibilityDemanded: accessibilityDemanded
        )
    }

    func latest() -> TerminalRenderFrameMetadata? {
        metadata
    }

    func demandAccessibility() -> TerminalRenderFrameMetadata? {
        guard !accessibilityDemanded else { return nil }
        accessibilityDemanded = true
        return drainScheduled ? nil : metadata
    }

    func releaseAccessibilityDemand() {
        accessibilityDemanded = false
        drainScheduled = false
    }

    func reset() {
        metadata = nil
        semanticFrameKey = nil
        drainScheduled = false
    }
}
