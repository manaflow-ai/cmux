import Foundation

extension MobileWorkspaceHierarchyProjection {
    struct ListValue: Hashable {
        let schemaVersion: Int
        let id: UUID
        let title: String
        let isPinned: Bool
        let groupID: UUID?
        let previewSignature: Int?
        let orderedPanelIDs: [UUID]
        let pinnedPanelIDs: [UUID]
        let panes: [PaneListValue]
        let terminals: [TerminalListValue]
        let surfaces: [SurfaceListValue]
        let currentDirectory: String?
        let panelDirectories: [PanelDirectoryValue]

        /// Hashes fields with an observer invalidation source. Close-confirmation
        /// fallback can change inside Ghostty without a workspace publisher, so
        /// it remains in the payload value but cannot spuriously flip list digest
        /// during an unrelated title or directory wakeup.
        func hashObserverIdentity(into hasher: inout Hasher) {
            hasher.combine(schemaVersion)
            hasher.combine(id)
            hasher.combine(title)
            hasher.combine(isPinned)
            hasher.combine(groupID)
            hasher.combine(previewSignature)
            hasher.combine(orderedPanelIDs)
            hasher.combine(pinnedPanelIDs)
            hasher.combine(panes)
            hasher.combine(terminals.count)
            for terminal in terminals {
                hasher.combine(terminal.id)
                hasher.combine(terminal.title)
                hasher.combine(terminal.currentDirectory)
                hasher.combine(terminal.paneID)
                hasher.combine(terminal.canClose)
                hasher.combine(terminal.isReady)
            }
            hasher.combine(surfaces)
            hasher.combine(currentDirectory)
            hasher.combine(panelDirectories)
        }
    }
}
