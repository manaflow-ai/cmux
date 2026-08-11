internal import CmuxTerminalBackend

/// One pointer gesture expressed as a single ordered daemon action.
nonisolated struct BackendOnlyFocusAction: Equatable, Sendable {
    let actionID: UInt64
    let targetSlotID: BackendOnlyProjectionSlotID
    let desiredSurfaceID: SurfaceID
    let intents: [BackendOnlyProjectionAbsoluteIntent]
}
