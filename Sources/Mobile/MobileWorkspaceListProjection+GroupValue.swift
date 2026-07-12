import Foundation

extension MobileWorkspaceListProjection {
    struct GroupValue: Hashable {
        let id: UUID
        let name: String
        let isCollapsed: Bool
        let isPinned: Bool
        let anchorWorkspaceID: UUID?
    }
}
