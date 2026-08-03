import Foundation

/// A stable route from one sidebar item to the column containing its children.
///
/// `id` identifies this particular parent-to-children relationship. Different
/// parents should use different ids even when they share a renderer. The
/// renderer id describes the content contract and lets a host or extension
/// choose the native view that resolves the route.
public struct CmuxSidebarChildColumn: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// CMUX's shared renderer implementation for a parent-scoped workspace collection.
    public static let sharedWorkspacesRendererID = "cmux.workspaces"

    public var id: String
    public var rendererID: String

    public init(id: String, rendererID: String) {
        self.id = id
        self.rendererID = rendererID
    }

    /// Makes a parent-specific route to CMUX's workspace renderer.
    public static func sharedWorkspaces(parentID: String) -> Self {
        Self(
            id: "\(parentID).children",
            rendererID: sharedWorkspacesRendererID
        )
    }
}
