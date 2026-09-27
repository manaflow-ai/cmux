import Foundation

/// A sidebar drag identity and its SwiftUI geometry at the start of tracking.
struct SidebarWorkspaceDragCandidate {
    let workspaceId: UUID
    let swiftUIFrame: CGRect
}
