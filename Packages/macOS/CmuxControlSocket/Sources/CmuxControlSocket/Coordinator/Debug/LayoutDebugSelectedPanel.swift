public import Bonsplit

/// One selected panel's layout state, as the `layout_debug` command reports it
/// for each pane in the active tab.
///
/// The app-side witness resolves the pane's selected tab and panel, then fills
/// these primitive leaves plus Bonsplit ``PixelRect`` frames and the nested
/// ``LayoutDebugSplitView`` ancestry; this value type owns only the wire shape.
/// The declared property order is the wire order: synthesized `Codable` encodes
/// in declaration order, so the emitted JSON is byte-identical to the legacy
/// app-side struct.
public struct LayoutDebugSelectedPanel: Codable, Sendable {
    /// The pane's id (UUID string).
    public let paneId: String
    /// The pane's frame, when known.
    public let paneFrame: PixelRect?
    /// The pane's selected tab id, when known.
    public let selectedTabId: String?
    /// The resolved panel's id (uppercased UUID string), when resolvable.
    public let panelId: String?
    /// The resolved panel's type raw value, when resolvable.
    public let panelType: String?
    /// Whether the panel's view is in a window, when applicable.
    public let inWindow: Bool?
    /// Whether the panel's view is hidden or has a hidden ancestor, when applicable.
    public let hidden: Bool?
    /// The panel view's frame in its window, when applicable.
    public let viewFrame: PixelRect?
    /// The panel view's split-view ancestry, when applicable.
    public let splitViews: [LayoutDebugSplitView]?

    /// Creates a selected-panel debug record from already-read state leaves.
    ///
    /// - Parameters:
    ///   - paneId: The pane's id (UUID string).
    ///   - paneFrame: The pane's frame, when known.
    ///   - selectedTabId: The pane's selected tab id, when known.
    ///   - panelId: The resolved panel's id, when resolvable.
    ///   - panelType: The resolved panel's type raw value, when resolvable.
    ///   - inWindow: Whether the panel's view is in a window, when applicable.
    ///   - hidden: Whether the panel's view is hidden or has a hidden ancestor.
    ///   - viewFrame: The panel view's frame in its window, when applicable.
    ///   - splitViews: The panel view's split-view ancestry, when applicable.
    public init(
        paneId: String,
        paneFrame: PixelRect?,
        selectedTabId: String?,
        panelId: String?,
        panelType: String?,
        inWindow: Bool?,
        hidden: Bool?,
        viewFrame: PixelRect?,
        splitViews: [LayoutDebugSplitView]?
    ) {
        self.paneId = paneId
        self.paneFrame = paneFrame
        self.selectedTabId = selectedTabId
        self.panelId = panelId
        self.panelType = panelType
        self.inWindow = inWindow
        self.hidden = hidden
        self.viewFrame = viewFrame
        self.splitViews = splitViews
    }
}
