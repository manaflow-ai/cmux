import Foundation

extension MobileWorkspaceHierarchyProjection {
    struct PanePayloadValue: Hashable {
        let id: UUID
        let spatialIndex: Int
        let isFocused: Bool
        let terminalIDs: [UUID]
    }
}
