public import Foundation

/// The live focused-location snapshot for `system.identify` (the legacy
/// `v2Identify` `focused` block), produced by ``ControlIdentifyContext`` and
/// shaped into the payload dictionary by
/// ``ControlCommandCoordinator/identify(params:)``.
///
/// A `nil` snapshot from the witness means no tab manager resolved (the legacy
/// early-return with null `focused` / `caller`). A non-`nil` snapshot with a
/// `nil` ``selected`` means a tab manager resolved but no workspace is selected
/// (the legacy window-only `focused` dict).
public struct ControlIdentifyFocusedSnapshot: Sendable {
    /// The window id of the resolved tab manager (the legacy
    /// `v2ResolveWindowId`).
    public let windowID: UUID?

    /// The selected-workspace identity, or `nil` when no workspace is selected.
    public let selected: Selected?

    /// The selected-workspace pane/surface identity (the legacy `focused`
    /// selected branch). `surfaceTypeRawValue` / `isBrowserSurface` are derived
    /// from the focused surface's panel and are `nil` when no surface is focused
    /// or its panel no longer resolves.
    public struct Selected: Sendable {
        /// The selected workspace id (`tabManager.selectedTabId`).
        public let workspaceID: UUID
        /// The focused pane id (`bonsplitController.focusedPaneId?.id`).
        public let paneID: UUID?
        /// The focused surface id (`workspace.focusedPanelId`).
        public let surfaceID: UUID?
        /// The focused surface's panel-type raw value, or `nil`.
        public let surfaceTypeRawValue: String?
        /// Whether the focused surface's panel is a browser, or `nil`.
        public let isBrowserSurface: Bool?

        /// Creates a selected-workspace identity.
        public init(
            workspaceID: UUID,
            paneID: UUID?,
            surfaceID: UUID?,
            surfaceTypeRawValue: String?,
            isBrowserSurface: Bool?
        ) {
            self.workspaceID = workspaceID
            self.paneID = paneID
            self.surfaceID = surfaceID
            self.surfaceTypeRawValue = surfaceTypeRawValue
            self.isBrowserSurface = isBrowserSurface
        }
    }

    /// Creates a focused-location snapshot.
    public init(windowID: UUID?, selected: Selected?) {
        self.windowID = windowID
        self.selected = selected
    }
}
