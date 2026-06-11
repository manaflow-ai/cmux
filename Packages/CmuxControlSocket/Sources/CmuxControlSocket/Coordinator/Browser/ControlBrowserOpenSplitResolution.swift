public import Foundation

/// The outcome of the app-side `browser.open_split` perform step, mirroring
/// the legacy `v2BrowserOpenSplit` main-sync block's distinct results.
public enum ControlBrowserOpenSplitResolution: Sendable, Equatable {
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// The external-open path failed (legacy `external_open_failed`).
    case externalOpenFailed(url: String)
    /// The URL opened externally per the link-open rules (legacy `.ok` with
    /// `placement_strategy: "external"`).
    case openedExternally(windowID: UUID?, workspaceID: UUID, url: String)
    /// No focused surface to split (legacy `not_found`).
    case noFocusedSurface
    /// The explicit source surface does not exist (legacy `not_found`,
    /// `data: {"surface_id": …}`).
    case sourceSurfaceNotFound(surfaceID: UUID)
    /// Browser creation failed (legacy `internal_error`).
    case createFailed
    /// The browser surface was created.
    case created(Snapshot)

    /// The created-browser payload fields, byte-faithful to the legacy result.
    public struct Snapshot: Sendable, Equatable {
        /// The enclosing window id, if resolved.
        public let windowID: UUID?
        /// The owning workspace id.
        public let workspaceID: UUID
        /// The created surface's pane id, if resolved.
        public let paneID: UUID?
        /// The created browser surface id.
        public let surfaceID: UUID
        /// The split-source surface id.
        public let sourceSurfaceID: UUID
        /// The split-source surface's pane id, if resolved.
        public let sourcePaneID: UUID?
        /// Whether a new split was created (vs reusing a right sibling pane).
        public let createdSplit: Bool
        /// `"split_right"` or `"reuse_right_sibling"`.
        public let placementStrategy: String
        /// The effective omnibar visibility of the created panel.
        public let showOmnibar: Bool
        /// The `transparent_background` value used.
        public let transparentBackground: Bool
        /// The effective `bypass_remote_proxy` value used.
        public let bypassRemoteProxy: Bool

        /// Creates an open-split snapshot.
        ///
        /// - Parameters:
        ///   - windowID: The enclosing window id, if resolved.
        ///   - workspaceID: The owning workspace id.
        ///   - paneID: The created surface's pane id, if resolved.
        ///   - surfaceID: The created browser surface id.
        ///   - sourceSurfaceID: The split-source surface id.
        ///   - sourcePaneID: The source surface's pane id, if resolved.
        ///   - createdSplit: Whether a new split was created.
        ///   - placementStrategy: The placement strategy string.
        ///   - showOmnibar: The effective omnibar visibility.
        ///   - transparentBackground: The transparent-background value used.
        ///   - bypassRemoteProxy: The effective bypass value used.
        public init(
            windowID: UUID?,
            workspaceID: UUID,
            paneID: UUID?,
            surfaceID: UUID,
            sourceSurfaceID: UUID,
            sourcePaneID: UUID?,
            createdSplit: Bool,
            placementStrategy: String,
            showOmnibar: Bool,
            transparentBackground: Bool,
            bypassRemoteProxy: Bool
        ) {
            self.windowID = windowID
            self.workspaceID = workspaceID
            self.paneID = paneID
            self.surfaceID = surfaceID
            self.sourceSurfaceID = sourceSurfaceID
            self.sourcePaneID = sourcePaneID
            self.createdSplit = createdSplit
            self.placementStrategy = placementStrategy
            self.showOmnibar = showOmnibar
            self.transparentBackground = transparentBackground
            self.bypassRemoteProxy = bypassRemoteProxy
        }
    }
}
