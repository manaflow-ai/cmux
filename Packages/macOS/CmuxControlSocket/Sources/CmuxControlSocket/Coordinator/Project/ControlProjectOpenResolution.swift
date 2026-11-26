public import Foundation

/// The outcome of `project.open` (the legacy `v2ProjectOpen` main-actor
/// block; the path validation happens in the coordinator).
public enum ControlProjectOpenResolution: Sendable, Equatable {
    /// The routed workspace was not found.
    case workspaceNotFound
    /// The workspace has no focused pane to open the project in.
    case noFocusedPane
    /// Project panel creation failed.
    case createFailed
    /// The project panel was created.
    ///
    /// - Parameters:
    ///   - windowID: The routed window, if it resolved.
    ///   - workspaceID: The enclosing workspace.
    ///   - paneID: The created panel's pane, if it resolved.
    ///   - surfaceID: The created project panel.
    case opened(windowID: UUID?, workspaceID: UUID, paneID: UUID?, surfaceID: UUID)
}
