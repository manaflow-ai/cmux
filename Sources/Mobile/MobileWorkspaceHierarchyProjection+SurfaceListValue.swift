import Foundation

extension MobileWorkspaceHierarchyProjection {
    struct SurfaceListValue: Hashable {
        let id: UUID
        let title: String?
        let reportedDirectory: String?
    }
}
