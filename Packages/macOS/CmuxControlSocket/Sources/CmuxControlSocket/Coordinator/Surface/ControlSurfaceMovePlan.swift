public import Foundation

/// The pure plan for `surface.move`, lifted from the legacy `v2SurfaceMove`
/// param-decision layer.
///
/// Owns the parts of the move that are decided purely from the parsed request,
/// independent of any live window/workspace/pane lookup:
/// - the at-most-one-anchor validation (``anchorCountExceeded``),
/// - the target-routing precedence (``routing``: anchor → pane → workspace →
///   window → source), and
/// - the destination index for the anchor branch (``anchorDestinationIndex(_:)``,
///   `before` lands at the anchor index, `after` one past it).
///
/// The app builds this from the `surface_id` plus the optional `pane_id` /
/// `workspace_id` / `window_id` / `before_surface_id` / `after_surface_id` /
/// `index` params, then drives the live `AppDelegate.locateSurface` / pane /
/// workspace / window lookups the chosen ``routing`` names inside `v2MainSync`.
public struct ControlSurfaceMovePlan: Sendable, Equatable {
    /// The surface being moved (`surface_id`).
    public let surfaceID: UUID
    /// The requested destination pane (`pane_id`), or `nil`.
    public let requestedPaneID: UUID?
    /// The requested destination workspace (`workspace_id`), or `nil`.
    public let requestedWorkspaceID: UUID?
    /// The requested destination window (`window_id`), or `nil`.
    public let requestedWindowID: UUID?
    /// The `before_surface_id` anchor, or `nil`.
    public let beforeSurfaceID: UUID?
    /// The `after_surface_id` anchor, or `nil`.
    public let afterSurfaceID: UUID?
    /// The explicit destination `index`, or `nil`.
    public let explicitIndex: Int?

    /// Creates a move plan from the parsed `surface.move` params.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface being moved.
    ///   - requestedPaneID: The requested destination pane.
    ///   - requestedWorkspaceID: The requested destination workspace.
    ///   - requestedWindowID: The requested destination window.
    ///   - beforeSurfaceID: The `before_surface_id` anchor.
    ///   - afterSurfaceID: The `after_surface_id` anchor.
    ///   - explicitIndex: The explicit destination index.
    public init(
        surfaceID: UUID,
        requestedPaneID: UUID?,
        requestedWorkspaceID: UUID?,
        requestedWindowID: UUID?,
        beforeSurfaceID: UUID?,
        afterSurfaceID: UUID?,
        explicitIndex: Int?
    ) {
        self.surfaceID = surfaceID
        self.requestedPaneID = requestedPaneID
        self.requestedWorkspaceID = requestedWorkspaceID
        self.requestedWindowID = requestedWindowID
        self.beforeSurfaceID = beforeSurfaceID
        self.afterSurfaceID = afterSurfaceID
        self.explicitIndex = explicitIndex
    }

    /// `true` when both `before_surface_id` and `after_surface_id` were supplied
    /// (legacy `invalid_params` / "Specify at most one of before_surface_id or
    /// after_surface_id").
    public var anchorCountExceeded: Bool {
        (beforeSurfaceID != nil ? 1 : 0) + (afterSurfaceID != nil ? 1 : 0) > 1
    }

    /// The target the legacy precedence selects: an anchor surface wins, then an
    /// explicit pane, workspace, window, and finally the surface's own source
    /// workspace.
    public var routing: ControlSurfaceMoveTargetRouting {
        if let anchor = beforeSurfaceID ?? afterSurfaceID {
            return .anchor(surfaceID: anchor)
        }
        if let pane = requestedPaneID {
            return .pane(pane)
        }
        if let workspace = requestedWorkspaceID {
            return .workspace(workspace)
        }
        if let window = requestedWindowID {
            return .window(window)
        }
        return .source
    }

    /// The destination index for the anchor branch: `before` inserts at the
    /// anchor's index, `after` one past it (legacy
    /// `(beforeSurfaceId != nil) ? anchorIndex : (anchorIndex + 1)`).
    ///
    /// - Parameter anchorIndex: The located anchor surface's index in its pane.
    /// - Returns: The index the moved surface should land at.
    public func anchorDestinationIndex(_ anchorIndex: Int) -> Int {
        beforeSurfaceID != nil ? anchorIndex : anchorIndex + 1
    }
}
