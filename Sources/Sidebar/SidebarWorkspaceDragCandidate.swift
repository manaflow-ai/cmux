import Foundation

/// A workspace row and its SwiftUI geometry at the start of drag tracking.
struct SidebarWorkspaceDragCandidate {
    let workspaceId: UUID
    let swiftUIFrame: CGRect
}
