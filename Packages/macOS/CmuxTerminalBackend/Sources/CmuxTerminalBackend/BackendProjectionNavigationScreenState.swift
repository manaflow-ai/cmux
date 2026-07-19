/// One screen's active pane, zoom, and selected-surface preferences.
public struct BackendProjectionNavigationScreenState: Codable, Equatable, Sendable {
    /// The canonical screen identifier.
    public let screenID: ScreenID

    /// The canonical pane receiving focus in the screen.
    public let activePaneID: PaneID

    /// The canonical pane expanded over the screen, when one is zoomed.
    public let zoomedPaneID: PaneID?

    /// Selected-surface preferences in canonical layout-leaf order.
    public let panes: [BackendProjectionNavigationPaneState]

    /// Creates one screen preference.
    ///
    /// - Parameters:
    ///   - screenID: The canonical screen identifier.
    ///   - activePaneID: The pane receiving focus.
    ///   - zoomedPaneID: The pane expanded over the screen, if any.
    ///   - panes: Selected-surface preferences in canonical order.
    public init(
        screenID: ScreenID,
        activePaneID: PaneID,
        zoomedPaneID: PaneID?,
        panes: [BackendProjectionNavigationPaneState]
    ) {
        self.screenID = screenID
        self.activePaneID = activePaneID
        self.zoomedPaneID = zoomedPaneID
        self.panes = panes
    }

    private enum CodingKeys: String, CodingKey {
        case screenID = "screen_uuid"
        case activePaneID = "active_pane_uuid"
        case zoomedPaneID = "zoomed_pane_uuid"
        case panes
    }
}
