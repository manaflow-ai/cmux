public import Foundation

/// The validated caller-location snapshot for `system.identify` (the legacy
/// `v2Identify` `caller` block), produced by ``ControlIdentifyContext`` when a
/// caller-provided `workspace_id` resolves in the live graph.
///
/// A `nil` snapshot from the witness means the caller workspace did not resolve
/// (the legacy `resolvedCaller` staying `nil`). A non-`nil` snapshot with a
/// `nil` ``surface`` means the caller named no valid surface (the legacy
/// all-null surface fields).
public struct ControlIdentifyCallerSnapshot: Sendable {
    /// The caller tab manager's window id (the legacy `v2ResolveWindowId`).
    public let windowID: UUID?

    /// The caller workspace id (echoed from the request).
    public let workspaceID: UUID

    /// The validated caller surface identity, or `nil` when absent/invalid.
    public let surface: Surface?

    /// The caller surface pane/type identity (the legacy `caller` surface
    /// branch), present only when the caller named a surface that exists in the
    /// resolved workspace's panels.
    public struct Surface: Sendable {
        /// The caller surface id.
        public let surfaceID: UUID
        /// The caller surface's pane id (`workspace.paneId(forPanelId:)?.id`).
        public let paneID: UUID?
        /// The caller surface's panel-type raw value, or `nil`.
        public let surfaceTypeRawValue: String?
        /// Whether the caller surface's panel is a browser, or `nil`.
        public let isBrowserSurface: Bool?

        /// Creates a caller surface identity.
        public init(
            surfaceID: UUID,
            paneID: UUID?,
            surfaceTypeRawValue: String?,
            isBrowserSurface: Bool?
        ) {
            self.surfaceID = surfaceID
            self.paneID = paneID
            self.surfaceTypeRawValue = surfaceTypeRawValue
            self.isBrowserSurface = isBrowserSurface
        }
    }

    /// Creates a caller-location snapshot.
    public init(windowID: UUID?, workspaceID: UUID, surface: Surface?) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.surface = surface
    }
}
