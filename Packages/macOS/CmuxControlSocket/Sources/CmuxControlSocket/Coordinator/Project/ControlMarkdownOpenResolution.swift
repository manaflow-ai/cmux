public import Foundation

/// The outcome of `markdown.open` (the legacy `v2MarkdownOpen` main-actor
/// block; the path validation happens in the coordinator).
public enum ControlMarkdownOpenResolution: Sendable, Equatable {
    /// The created markdown split's identity.
    public struct Created: Sendable, Equatable {
        /// The routed window, if it resolved.
        public let windowID: UUID?
        /// The enclosing workspace.
        public let workspaceID: UUID
        /// The created panel's pane, if it resolved (also the legacy
        /// `target_pane_id`).
        public let targetPaneID: UUID?
        /// The created markdown panel.
        public let surfaceID: UUID
        /// The split's source surface.
        public let sourceSurfaceID: UUID
        /// The source surface's pane, if it resolved.
        public let sourcePaneID: UUID?

        /// Creates a created-split identity.
        ///
        /// - Parameters:
        ///   - windowID: The routed window, if any.
        ///   - workspaceID: The enclosing workspace.
        ///   - targetPaneID: The created panel's pane, if any.
        ///   - surfaceID: The created markdown panel.
        ///   - sourceSurfaceID: The split's source surface.
        ///   - sourcePaneID: The source surface's pane, if any.
        public init(
            windowID: UUID?,
            workspaceID: UUID,
            targetPaneID: UUID?,
            surfaceID: UUID,
            sourceSurfaceID: UUID,
            sourcePaneID: UUID?
        ) {
            self.windowID = windowID
            self.workspaceID = workspaceID
            self.targetPaneID = targetPaneID
            self.surfaceID = surfaceID
            self.sourceSurfaceID = sourceSurfaceID
            self.sourcePaneID = sourcePaneID
        }
    }

    /// The routed workspace was not found.
    case workspaceNotFound
    /// No explicit surface and the workspace has no focused panel.
    case noFocusedSurface
    /// The targeted source surface is not in the workspace.
    case sourceSurfaceNotFound(UUID)
    /// The `direction` param did not parse.
    case invalidDirection
    /// The `font_size` param was present but non-numeric.
    case invalidFontSize
    /// Markdown panel creation failed.
    case createFailed
    /// The split was created.
    case opened(Created)
}
