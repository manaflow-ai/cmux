internal import CmuxTerminalRenderProtocol

struct BackendOnlyScheduledFrameDrain: Sendable {
    let metadata: TerminalRenderFrameMetadata
    let accessibilityDemanded: Bool
}
