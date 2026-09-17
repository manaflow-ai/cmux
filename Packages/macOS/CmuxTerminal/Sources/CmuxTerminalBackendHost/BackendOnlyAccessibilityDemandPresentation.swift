internal import CmuxTerminalBackend

struct BackendOnlyAccessibilityDemandPresentation: Equatable, Sendable {
    let id: PresentationID
    let generation: UInt64
}
