/// Layout coordinates for one placement in a remote workspace snapshot.
public struct RemoteWorkspacePlacement: Sendable {
    /// Stable daemon screen identity; nil and empty values fall back to the screen index.
    public let screenID: String?
    /// Stable daemon pane identity; nil and empty values denote pane-less placements.
    public let paneID: String?
    /// Position of the screen within its workspace.
    public let screenIndex: Int?
    /// Depth-first position of the pane within its screen layout.
    public let paneIndex: Int?
    /// Position of the tab within its pane.
    public let tabIndex: Int?
    /// Whether this is the tab shown by its pane, independent of pane focus.
    public let focused: Bool
    /// Ordering rank for pane-less resource kinds; equal ranks retain arrival order.
    public let kindOrder: Int

    /// Keeps missing coordinates distinct from real positions for legacy snapshots.
    public nonisolated init(
        screenID: String? = nil,
        paneID: String? = nil,
        screenIndex: Int? = nil,
        paneIndex: Int? = nil,
        tabIndex: Int? = nil,
        focused: Bool = false,
        kindOrder: Int = 0
    ) {
        self.screenID = screenID
        self.paneID = paneID
        self.screenIndex = screenIndex
        self.paneIndex = paneIndex
        self.tabIndex = tabIndex
        self.focused = focused
        self.kindOrder = kindOrder
    }
}
