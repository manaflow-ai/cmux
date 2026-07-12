import Foundation

extension MobileWorkspaceHierarchyProjection {
    struct PaneFocusValue: Hashable {
        let id: UUID
        let selectedTerminalID: UUID?
    }
}
