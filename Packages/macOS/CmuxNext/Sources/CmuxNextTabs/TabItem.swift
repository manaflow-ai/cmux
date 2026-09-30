/// One tab as the strip displays it. The App fills these from daemon state.
public struct TabItem: Identifiable, Hashable, Sendable {
    public var id: TabID
    public var title: String
    /// Working directory or URL. Shown in the hover card.
    public var subtitle: String?
    public var icon: TabIcon
    public var isPinned: Bool
    /// Neutral notification dot (new output, unread notification).
    public var isUnread: Bool
    /// Replaces the icon with a spinner (process running, page loading).
    public var isBusy: Bool
    public var status: TabStatus
    /// The page hibernated (released to save memory; reloads when
    /// selected): the icon and title are drawn dimmed.
    public var isDormant = false
    /// Group this tab belongs to. Ignored for pinned tabs (Chrome rule) and
    /// for ids missing from `TabStripModel.groups`.
    public var groupID: TabGroupID?

    public init(
        id: TabID,
        title: String,
        subtitle: String? = nil,
        icon: TabIcon = .symbol("terminal"),
        isPinned: Bool = false,
        isUnread: Bool = false,
        isBusy: Bool = false,
        status: TabStatus = .none,
        groupID: TabGroupID? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isPinned = isPinned
        self.isUnread = isUnread
        self.isBusy = isBusy
        self.status = status
        self.groupID = groupID
    }
}
