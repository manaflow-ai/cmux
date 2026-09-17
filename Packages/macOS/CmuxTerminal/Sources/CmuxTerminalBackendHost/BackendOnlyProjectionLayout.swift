internal import CmuxTerminalBackend

/// The visible split tree whose leaves reference stable runtime slots.
nonisolated enum BackendOnlyProjectionLayout: Equatable, Sendable {
    case pane(BackendOnlyProjectionSlotID)
    indirect case split(
        direction: CanonicalSplitDirection,
        ratio: Float,
        first: BackendOnlyProjectionLayout,
        second: BackendOnlyProjectionLayout
    )
}
