/// One Herdr tab as a tmux window: base layout, optional zoomed visible tree, focus.
public struct RemoteHerdrWindow: Hashable, Sendable {
    /// Herdr tab id (`w2:t11`).
    public var tabID: String
    /// Display title (tab label). Inner pane-border labels must not override this.
    public var title: String
    /// Sibling order (Herdr tab number).
    public var orderIndex: Int
    /// Full pane tree even while zoomed (tmux BASE layout).
    public var layout: RemoteHerdrLayoutNode
    /// Layout Herdr is displaying while zoomed; nil when not zoomed.
    public var visibleLayout: RemoteHerdrLayoutNode?
    /// Whether a pane is zoomed right now.
    public var zoomed: Bool
    /// Herdr's active pane id in this tab, if known.
    public var activePaneID: String?

    /// Creates a mirrored Herdr tab.
    public init(
        tabID: String,
        title: String,
        orderIndex: Int,
        layout: RemoteHerdrLayoutNode,
        visibleLayout: RemoteHerdrLayoutNode? = nil,
        zoomed: Bool = false,
        activePaneID: String? = nil
    ) {
        self.tabID = tabID
        self.title = title
        self.orderIndex = orderIndex
        self.layout = layout
        self.visibleLayout = zoomed ? visibleLayout : nil
        self.zoomed = zoomed
        self.activePaneID = activePaneID
    }

    /// Tree actually rendered (zoomed leaf or base).
    public var renderedLayout: RemoteHerdrLayoutNode {
        visibleLayout ?? layout
    }

    /// Pane ids that must keep surfaces (base tree — zoom must not destroy them).
    public var basePaneIDs: [String] {
        layout.paneIDsInOrder
    }
}
