public import Foundation

/// One surface row of the `system.tree` snapshot (the legacy
/// `v2TreeWorkspaceNode` per-panel dictionary, minus the coordinator-minted
/// refs).
///
/// The app target builds these in the original `orderedPanels` enumeration
/// order and pre-sorts them per pane by `indexInPane ?? index`, exactly as the
/// legacy body sorted its dictionaries.
public struct ControlSystemTreeSurfaceNode: Sendable, Equatable {
    /// The surface's panel identifier.
    public let surfaceID: UUID
    /// The surface's index in the workspace's ordered-panels enumeration.
    public let index: Int
    /// The panel type's raw value.
    public let typeRawValue: String
    /// The resolved display title (custom title, else the panel's own).
    public let title: String
    /// Whether this surface is the workspace's focused panel.
    public let isFocused: Bool
    /// Whether this surface is the selected tab in its pane (`false` when the
    /// pane membership did not resolve, matching the legacy `?? false`).
    public let isSelected: Bool
    /// The raw selected-in-pane lookup (`nil` when the surface's pane
    /// membership did not resolve — emitted as JSON `null`).
    public let selectedInPane: Bool?
    /// The enclosing pane's identifier, if it resolved.
    public let paneID: UUID?
    /// The surface's tab index within its pane, if it resolved.
    public let indexInPane: Int?
    /// The terminal's tty name, if known.
    public let tty: String?
    /// Whether this is a browser surface (drives the `url` emission: browsers
    /// emit a string — empty when no URL — and non-browsers emit JSON `null`).
    public let isBrowser: Bool
    /// For browser surfaces, the current URL string (`nil` encodes as the
    /// legacy empty string).
    public let url: String?

    /// Creates a surface node.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface's panel identifier.
    ///   - index: The ordered-panels enumeration index.
    ///   - typeRawValue: The panel type's raw value.
    ///   - title: The resolved display title.
    ///   - isFocused: Whether this surface is focused in its workspace.
    ///   - isSelected: Whether this surface is selected in its pane.
    ///   - selectedInPane: The raw selected-in-pane lookup.
    ///   - paneID: The enclosing pane's identifier, if resolved.
    ///   - indexInPane: The tab index within the pane, if resolved.
    ///   - tty: The terminal's tty name, if known.
    ///   - isBrowser: Whether this is a browser surface.
    ///   - url: For browsers, the current URL string.
    public init(
        surfaceID: UUID,
        index: Int,
        typeRawValue: String,
        title: String,
        isFocused: Bool,
        isSelected: Bool,
        selectedInPane: Bool?,
        paneID: UUID?,
        indexInPane: Int?,
        tty: String?,
        isBrowser: Bool,
        url: String?
    ) {
        self.surfaceID = surfaceID
        self.index = index
        self.typeRawValue = typeRawValue
        self.title = title
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.selectedInPane = selectedInPane
        self.paneID = paneID
        self.indexInPane = indexInPane
        self.tty = tty
        self.isBrowser = isBrowser
        self.url = url
    }
}
