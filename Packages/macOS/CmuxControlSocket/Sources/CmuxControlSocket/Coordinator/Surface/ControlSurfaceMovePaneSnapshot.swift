public import Foundation

/// The live pane facts for the `.pane` routing branch of `surface.move`, the
/// Sendable twin of the legacy `v2SurfaceMove` `v2LocatePane` lookup.
///
/// When `pane_id` is supplied (and no anchor), the app locates the pane's
/// window, workspace, and pane id; the coordinator routes the move into them. A
/// `nil` witness result means the pane did not resolve (legacy "Pane not
/// found").
public struct ControlSurfaceMovePaneSnapshot: Sendable, Equatable {
    /// The located pane's window (`located.windowId`).
    public let windowID: UUID
    /// The located pane's workspace (`located.workspace.id`).
    public let workspaceID: UUID
    /// The located pane (`located.paneId.id`).
    public let paneID: UUID

    /// Creates a pane snapshot.
    ///
    /// - Parameters:
    ///   - windowID: The located pane's window.
    ///   - workspaceID: The located pane's workspace.
    ///   - paneID: The located pane.
    public init(windowID: UUID, workspaceID: UUID, paneID: UUID) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.paneID = paneID
    }
}
