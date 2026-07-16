import Foundation

extension MobileWorkspaceHierarchyProjection {
    struct PaneListValue: Hashable {
        let id: UUID
        let spatialIndex: Int
        let terminalIDs: [UUID]
    }
}
