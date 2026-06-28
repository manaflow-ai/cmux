public import Foundation

/// The same-workspace vs cross-workspace branch of `surface.move`, plus the
/// success payload field set both branches echo.
///
/// Once the app has resolved the destination (window, workspace, pane) for a
/// ``ControlSurfaceMovePlan``, the move splits two ways: when the destination
/// workspace equals the source workspace it is an in-place
/// `Workspace.moveSurface`; otherwise it is a `detachSurface` from the source
/// followed by an `attachDetachedSurface` onto the target, with rollback to the
/// source pane/index if the attach fails. ``decide(sourceWorkspaceID:targetWorkspaceID:)``
/// names that branch purely from the two workspace ids; ``successFields(windowID:workspaceID:paneID:surfaceID:makeRef:)``
/// assembles the identical `{window,workspace,pane,surface}_id`/`_ref` payload
/// both branches return on success (the `_ref` values come from the app's
/// handle-ref minter, passed in as `makeRef`).
public enum ControlSurfaceMoveResolution: Sendable, Equatable {
    /// The destination workspace is the source workspace: an in-place pane move.
    case sameWorkspace
    /// The destination workspace differs: detach from source, attach to target,
    /// roll back on failure.
    case crossWorkspace

    /// Selects the move branch from the source and destination workspace ids.
    ///
    /// - Parameters:
    ///   - sourceWorkspaceID: The workspace the surface currently lives in.
    ///   - targetWorkspaceID: The resolved destination workspace.
    /// - Returns: ``sameWorkspace`` when the ids match, else ``crossWorkspace``.
    public static func decide(
        sourceWorkspaceID: UUID,
        targetWorkspaceID: UUID
    ) -> ControlSurfaceMoveResolution {
        sourceWorkspaceID == targetWorkspaceID ? .sameWorkspace : .crossWorkspace
    }

    /// The success payload field set both move branches echo verbatim.
    ///
    /// - Parameters:
    ///   - windowID: The destination window id.
    ///   - workspaceID: The destination workspace id.
    ///   - paneID: The destination pane id.
    ///   - surfaceID: The moved surface id.
    ///   - makeRef: The app's handle-ref minter (`v2Ref`), producing the `_ref`
    ///     value for each id and kind.
    /// - Returns: The eight-key `{window,workspace,pane,surface}_id`/`_ref`
    ///   payload, byte-identical to the legacy `v2SurfaceMove` `.ok` body.
    public static func successFields(
        windowID: UUID,
        workspaceID: UUID,
        paneID: UUID,
        surfaceID: UUID,
        makeRef: (ControlHandleKind, UUID) -> Any
    ) -> [String: Any] {
        [
            "window_id": windowID.uuidString,
            "window_ref": makeRef(.window, windowID),
            "workspace_id": workspaceID.uuidString,
            "workspace_ref": makeRef(.workspace, workspaceID),
            "pane_id": paneID.uuidString,
            "pane_ref": makeRef(.pane, paneID),
            "surface_id": surfaceID.uuidString,
            "surface_ref": makeRef(.surface, surfaceID),
        ]
    }
}
