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
    /// The identity of the panel object that owns the mounted content.
    ///
    /// A restore may replace a lightweight panel with its live counterpart while
    /// preserving ``id``. The canvas uses this value to rebuild that panel's mount
    /// without remounting descriptors whose owning object is unchanged.
    public let contentIdentity: ObjectIdentifier?
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
    /// Applies host-owned content state, such as terminal focus visuals, to
    /// an existing mount. Called after mounting and on every descriptor sync.
    public let updateMount: (any CanvasPaneContentMounting) -> Void

    public init(
        id: UUID,
        contentIdentity: ObjectIdentifier? = nil,
        tab: CanvasTabChrome,
        isFocused: Bool,
        closeActionLabel: String,
        makeMount: @escaping (NSView) -> any CanvasPaneContentMounting,
        updateMount: @escaping (any CanvasPaneContentMounting) -> Void = { _ in }
    ) {
        self.id = id
        self.contentIdentity = contentIdentity
        self.tab = tab
        self.isFocused = isFocused
        self.closeActionLabel = closeActionLabel
        self.makeMount = makeMount
        self.updateMount = updateMount
    }
}
