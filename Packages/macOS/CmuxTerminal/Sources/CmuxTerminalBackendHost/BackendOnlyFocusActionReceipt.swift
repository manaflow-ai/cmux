internal import CmuxTerminalBackend

/// Authoritative daemon result for one exact focus action.
nonisolated struct BackendOnlyFocusActionReceipt: Equatable, Sendable {
    let actionID: UInt64
    let fence: BackendOnlyProjectionRuntimeFence
    let outcome: BackendOnlyFocusActionReceiptOutcome
    let activeSlotID: BackendOnlyProjectionSlotID
    let selectedSurfaceID: SurfaceID
}
