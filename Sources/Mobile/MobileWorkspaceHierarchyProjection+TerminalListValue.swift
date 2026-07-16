import Foundation

extension MobileWorkspaceHierarchyProjection {
    struct TerminalListValue: Hashable {
        let id: UUID
        let title: String
        let currentDirectory: String?
        let paneID: UUID?
        let canClose: Bool
        let requiresCloseConfirmation: Bool
        let isReady: Bool
    }
}
