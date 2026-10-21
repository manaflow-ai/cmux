public import CmuxNextDesign

/// One tab as the strip displays it. The App fills these from daemon state.
public struct TabItem: Identifiable, Hashable, Sendable {
    public var id: TabID
    public var title: String
    /// Working directory or URL. Shown in the hover card.
    public var subtitle: String?
    public var icon: TabIcon
    public var isPinned: Bool
    /// False for a tab the person cannot close (the Home tab of a pinned
    /// dock column, `pinned-dock-v1`): it shows no close button, and Cmd-W
    /// keeps it as it keeps a pinned tab.
    public var isClosable = true
    /// Neutral notification dot (new output, unread notification).
    public var isUnread: Bool
    /// The state the icon slot shows (`StatusIndicatorLayer`): busy or
    /// paused (page or command loading), or working (an agent), with
    /// progress when known. Waiting, error and done stay on the `status` badge.
    public var indicator: StatusIndicatorState = .idle
    /// Shows the status indicator (process running, page loading, agent
    /// working) at the tab's trailing end; the icon stays. On a tab too
    /// narrow for its title it takes the icon's place.
    public var isBusy: Bool {
        get { indicator.replacesTabIcon }
        set { if newValue != isBusy { indicator = newValue ? .busy : .idle } }
    }
    /// A busy page still waiting for its first response, until the page commits and loads.
    /// Its spinner turns like every other one (same direction and phase); this is state only.
    public var isWaiting = false
    /// The reporter's indicator style hint; nil uses
    /// `appearance.statusIndicator.style`.
    public var busyStyle: StatusIndicatorStyle?
    public var status: TabStatus
    /// What a `needsInput` badge waits for (OSC 7501 `kind`), so a status
    /// icon set can mark it (`StatusIconSet`); nil for other states.
    public var blockedKind: StatusBlockedKind?
    /// The program's own words on its status (OSC 7501 title and message, one plain line), for
    /// the hover card; nil when it reported none.
    public var statusDetail: String?
    /// The page hibernated (released to save memory; reloads when
    /// selected): the icon and title are drawn dimmed.
    public var isDormant = false
    /// The tab shows the New Tab page: its title says all there is, so it
    /// takes no hover card. A blank browser tab is not one (an incognito or
    /// app tab's record keeps about:blank while its page shows a site).
    public var isNewTabPage = false
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
    /// The machine's own name, when the badge shows another (an SSH host's address): the
    /// badge's color (MachineColor) comes from it, so the tab matches the machine's sidebar
    /// rows. Nil: the badge's text.
    public var machineName: String?
    /// The terminal's own theme, when it has one: a subtle swatch dot.
    public var themeBadge: TabThemeBadge?
    /// The tab's browser profile when it differs from the one its workspace
    /// gives new tabs: a small dot of its color, named in the hover card and
    /// to VoiceOver (plans/cmux-next/data-model.md section 5).
    public var profileBadge: TabProfileBadge?
    /// The agent acting in the tab right now (cx-gg84): a dot in its presence color.
    public var presence: TabPresence?
    /// A browser tab playing sound, or muted: a speaker after the title.
    public var audio: TabAudio?
    /// What the hover card says beyond the title and subtitle (Leo 2026-10-14).
    public var hover = TabHoverFacts()

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

/// A browser tab's sound as the strip shows it (cx-d0d.24).
public enum TabAudio: Hashable, Sendable {
    case playing
    case muted
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
