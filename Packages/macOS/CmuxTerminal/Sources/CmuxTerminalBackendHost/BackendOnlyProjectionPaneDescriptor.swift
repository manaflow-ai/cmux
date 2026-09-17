internal import CmuxTerminalBackend

/// One visible pane descriptor in canonical layout-leaf order.
nonisolated struct BackendOnlyProjectionPaneDescriptor: Equatable, Sendable {
    let slotID: BackendOnlyProjectionSlotID
    let paneID: PaneID
    let numericPaneID: UInt64
    let paneName: String?
    let isActive: Bool
    let tabs: [BackendOnlyProjectionTabMetadata]
    let content: BackendOnlyProjectionPaneContent
}
