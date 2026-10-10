public import CmuxNextDesign

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
    /// The state the icon slot shows (`StatusIndicatorLayer`): busy or
    /// paused (page or command loading), or working (an agent), with
    /// progress when known. Waiting, error and done stay on the `status` badge.
    public var indicator: StatusIndicatorState = .idle
    /// Replaces the icon with the status indicator (process running, page
    /// loading, agent working).
    public var isBusy: Bool {
        get { indicator.replacesTabIcon }
        set { if newValue != isBusy { indicator = newValue ? .busy : .idle } }
    }
    /// The reporter's indicator style hint; nil uses
    /// `appearance.statusIndicator.style`.
    public var busyStyle: StatusIndicatorStyle?
    public var status: TabStatus
    /// What a `needsInput` badge waits for (OSC 7501 `kind`), so a status
    /// icon set can mark it (`StatusIconSet`); nil for other states.
    public var blockedKind: StatusBlockedKind?
    /// The page hibernated (released to save memory; reloads when
    /// selected): the icon and title are drawn dimmed.
    public var isDormant = false
    /// Group this tab belongs to. Ignored for pinned tabs and
    /// for ids missing from `TabStripModel.groups`.
    public var groupID: TabGroupID?
    /// User color of this tab (screens carry one). Tints the icon; a tab
    /// with no icon shows a dot of this color instead.
    public var tint: GroupColor?
    /// The machine the tab's terminal runs on when it is not this Mac: a
    /// very subtle trailing label (plans/cmux-next/data-model.md 1.2b).
    public var machineBadge: String?
    /// Explains the machine badge in the hover card and to VoiceOver (a
    /// remote-localhost browser tab: "localhost is build-box").
    public var machineBadgeHelp: String?
    /// The terminal's own theme, when it has one: a subtle swatch dot.
    public var themeBadge: TabThemeBadge?
    /// The tab's browser profile when it differs from the one its workspace
    /// gives new tabs: a small dot of its color, named in the hover card and
    /// to VoiceOver (plans/cmux-next/data-model.md section 5).
    public var profileBadge: TabProfileBadge?

    public init(
        id: TabID,
        title: String,
        subtitle: String? = nil,
        icon: TabIcon = .symbol("terminal"),
        isPinned: Bool = false,
        isUnread: Bool = false,
        isBusy: Bool = false,
        status: TabStatus = .none,
        groupID: TabGroupID? = nil,
        tint: GroupColor? = nil,
        machineBadge: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isPinned = isPinned
        self.isUnread = isUnread
        self.indicator = isBusy ? .busy : .idle
        self.status = status
        self.groupID = groupID
        self.tint = tint
        self.machineBadge = machineBadge
    }
}

/// A tab's browser profile as the strip shows it.
public struct TabProfileBadge: Hashable, Sendable {
    public var name: String
    public var color: GroupColor?

    public init(name: String, color: GroupColor?) {
        self.name = name
        self.color = color
    }
}
