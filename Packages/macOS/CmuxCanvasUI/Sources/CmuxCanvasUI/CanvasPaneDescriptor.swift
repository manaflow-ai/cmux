public import AppKit

/// A value snapshot describing one panel the canvas should display.
///
/// Built by the host's SwiftUI container on every update pass, one per
/// panel; the canvas root view groups descriptors into panes using the
/// model's tab state and diffs against its current pane views, so host
/// state changes flow into AppKit without the canvas observing any store.
@MainActor
public struct CanvasPaneDescriptor: Identifiable {
    /// The panel id.
    public let id: UUID
    /// The panel's tab chrome (title + icon).
    public let tab: CanvasTabChrome
    /// Whether this panel has keyboard focus.
    public let isFocused: Bool
    /// Localized label for the close action.
    public let closeActionLabel: String
    /// Mounts the panel's content into a pane's content container and
    /// returns the lifecycle handle. Called once per mount; a panel mounts
    /// only while it is its pane's selected tab.
    public let makeMount: (NSView) -> any CanvasPaneContentMounting

    public init(
        id: UUID,
        tab: CanvasTabChrome,
        isFocused: Bool,
        closeActionLabel: String,
        makeMount: @escaping (NSView) -> any CanvasPaneContentMounting
    ) {
        self.id = id
        self.tab = tab
        self.isFocused = isFocused
        self.closeActionLabel = closeActionLabel
        self.makeMount = makeMount
    }
}
