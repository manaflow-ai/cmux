public import Foundation

/// The terminal surface that owns a first responder, identified by its workspace
/// and panel ids. The main-window focus controller resolves a responder to this
/// value through `TerminalSurfaceFocusResolving` instead of reaching the concrete
/// app-target Ghostty view type.
public struct TerminalSurfaceFocusOwner: Sendable, Equatable {
    /// The workspace (tab) the owning terminal surface belongs to.
    public var workspaceId: UUID
    /// The terminal surface (panel) id.
    public var panelId: UUID

    /// Creates a terminal surface focus owner.
    /// - Parameters:
    ///   - workspaceId: The workspace (tab) the surface belongs to.
    ///   - panelId: The terminal surface (panel) id.
    public init(workspaceId: UUID, panelId: UUID) {
        self.workspaceId = workspaceId
        self.panelId = panelId
    }
}
