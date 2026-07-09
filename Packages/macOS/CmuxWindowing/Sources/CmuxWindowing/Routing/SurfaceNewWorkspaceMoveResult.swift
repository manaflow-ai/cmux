public import Foundation

/// The captured outcome of moving one surface (a terminal/browser tab) out into
/// its own new workspace, optionally in another window.
///
/// Produced by the app-side "move tab to new workspace" orchestration (the
/// `AppDelegate` drop/cross-window-move shim and its sibling `TerminalController`
/// socket command). That orchestration reaches live app state (`TabManager`,
/// `Workspace`, `NSWindow` focus) that cannot leave the executable target, so the
/// *decision-and-effect* sequence stays app-side; but the *result* of the move is
/// pure identity, so it lives here in the cross-window-move domain alongside
/// ``MultiWindowRouteResult``. The two consumers (the move shim and the socket
/// command's wire-payload builder) both speak this one value, so no app-target
/// twin of the result exists.
///
/// Every field is a `UUID`/`UUID?` identifier, so the value is trivially
/// `Sendable` and `Equatable` with no app coupling. The optional
/// ``destinationWindowId`` is `nil` when the caller suppressed window resolution
/// (a same-window move that did not request focusing the destination window),
/// matching the legacy `windowId(for:)` lookup that returned `nil` in that case.
public struct SurfaceNewWorkspaceMoveResult: Sendable, Equatable {
    /// The window the surface was moved out of.
    public let sourceWindowId: UUID
    /// The workspace the surface was moved out of.
    public let sourceWorkspaceId: UUID
    /// The window the new workspace ended up in, or `nil` when the destination
    /// window was not resolved (e.g. a same-window move that did not request
    /// focusing the destination window).
    public let destinationWindowId: UUID?
    /// The new workspace the surface was moved into.
    public let destinationWorkspaceId: UUID
    /// The moved surface.
    public let surfaceId: UUID
    /// The pane the moved surface landed in within the new workspace, or `nil`
    /// when no pane could be resolved.
    public let paneId: UUID?

    /// Creates a move result.
    /// - Parameters:
    ///   - sourceWindowId: The window the surface was moved out of.
    ///   - sourceWorkspaceId: The workspace the surface was moved out of.
    ///   - destinationWindowId: The window the new workspace ended up in, or
    ///     `nil` when the destination window was not resolved.
    ///   - destinationWorkspaceId: The new workspace the surface was moved into.
    ///   - surfaceId: The moved surface.
    ///   - paneId: The pane the moved surface landed in, or `nil` when none was
    ///     resolved.
    public init(
        sourceWindowId: UUID,
        sourceWorkspaceId: UUID,
        destinationWindowId: UUID?,
        destinationWorkspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?
    ) {
        self.sourceWindowId = sourceWindowId
        self.sourceWorkspaceId = sourceWorkspaceId
        self.destinationWindowId = destinationWindowId
        self.destinationWorkspaceId = destinationWorkspaceId
        self.surfaceId = surfaceId
        self.paneId = paneId
    }
}
