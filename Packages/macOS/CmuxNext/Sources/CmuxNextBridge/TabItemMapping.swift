public import CmuxNextDesign
import CmuxAgentBrands
import CmuxNextIcons
import Foundation
public import CmuxNextDaemon
public import CmuxNextTabs

/// Maps daemon tab records into tab strip items.
public struct TabItemMapping {
    public static let shared = Self()

    /// The small projection used by Home's first-run agent list. Unlike `item`, this does not
    /// read hover facts, presence, user icons, or the session's usage/detail mirror. Those facts
    /// are useful when a tab is drawn or hovered, but Home only needs its title and indicator;
    /// reading them here made every usage update re-track every agent chat.
    public struct Glance: Hashable, Sendable {
        public var title: String
        public var status: TabStatus
        public var indicator: StatusIndicatorState
        public var style: StatusIndicatorStyle?

        public init(title: String, status: TabStatus, indicator: StatusIndicatorState = .idle, style: StatusIndicatorStyle?) {
            self.title = title
            self.status = status
            self.indicator = indicator
            self.style = style
        }
    }

    /// Maps only the facts needed by Home's first-run agent rows.
    public func glance(_ tab: TabModel, fallbackTitle: String) -> Glance {
        let busy = StatusMapping.shared.loading(tab)
        var indicator = busy.state.replacesTabIcon ? busy.state : .idle
        // A terminal's title spinner is a working mark even when no status report replaces it.
        if indicator == .idle, tab.titleActivity == .working,
           DesignSettings.shared.statusIndicator.showsAgentWorkingOnTabs {
            indicator = .working
        }
        return Glance(title: title(tab, fallbackTitle: fallbackTitle), status: status(tab), indicator: indicator, style: busy.style)
    }
    /// `fallbackTitle` names a tab whose program set no title yet
    /// (localized by the App), and a browser tab on the New Tab or blank
    /// page, whose recorded title is that page's address.
    /// A conversation tab (conversation-tabs-v1) rides a frontend browser
    /// record titled with the blank page's address: it shows `fallbackTitle`
    /// (the conversation's) and the agent chat icon. `isNewTabPage` marks a
    /// tab still on the New Tab page, which draws the new-tab icon instead.

    /// `asset` draws a stored image or SVG user icon (``TabUserIcon``).
    /// `restarting`: a kept tab this launch restarts (`DaemonService.restartsKeptTab`) draws as the
    /// running terminal it becomes, from the first frame (the app shows its own intent): the
    /// terminal icon, no failure mark, the directory its new shell starts in, so its item stays
    /// the same when the new shell runs (cx-8w027.23).
    public func item(_ tab: TabModel, fallbackTitle: String, isNewTabPage: Bool = false, restarting: Bool = false,
                     asset: (String) -> TabImage? = { _ in nil }, turns: AgentTurnStateStore = .shared,
                     harnessIcons: HarnessIconLookup = .none) -> StripTabItem {
        let isBrowser = tab.kind == .browser
        let isConversation = tab.kind == .conversation
        let title = title(tab, fallbackTitle: fallbackTitle)
        let busy = StatusMapping.shared.loading(tab)
        var item = StripTabItem(
            id: StripTabID(tab.id),
            title: title,
            // The New Tab and blank pages' addresses are no place a person went: no address line.
            subtitle: isConversation ? nil : isBrowser ? tab.url.flatMap { Self.isBlankPageAddress($0) ? nil : $0 }
                : tab.cwd.map(SidebarMapping.shared.abbreviate),
            icon: isNewTabPage ? .icon(.tabNew) : icon(tab, isBrowser: isBrowser, isConversation: isConversation, harnessIcons: harnessIcons,
                                                       turns: turns),
            isPinned: tab.pinned,
            isUnread: tab.showsUnread,
            isBusy: busy.state.isLoading || isReportingProgress(tab),
            status: status(tab)
        )
        item.isNewTabPage = isNewTabPage
        if busy.state.replacesTabIcon { item.indicator = busy.state }
        // A terminal title's spinner glyph (`⠐ Fix the bug`) shows as the working mark, not as text.
        else if item.indicator == .idle, tab.titleActivity == .working, DesignSettings.shared.statusIndicator.showsAgentWorkingOnTabs { item.indicator = .working(progress: nil) }
        item.busyStyle = busy.style
        if item.status == .needsInput { item.blockedKind = StatusMapping.shared.blockedKind(tab) }
        item.presence = presence(tab)
        item.statusDetail = StatusMapping.shared.detail(tab)
        let hover = hoverFacts(tab, turns: turns)
        item.hover = hover.facts
        if isConversation { item.subtitle = hover.folder }
        if hover.facts.kind == .agentChat { item.agentBadgeCount = agentBadgeCount(tab) }
        if restarting, tab.kind != .browser, tab.kind != .remoteTerminal, !isConversation {
            if item.icon == .terminalDead { item.icon = .terminal }
            if item.status == .failure { item.status = .none }
            if item.subtitle == nil, let cwd = tab.relaunch?.cwd { item.subtitle = SidebarMapping.shared.abbreviate(cwd) }
        }
        applyUserIcon(tab, to: &item, asset: asset)
        return item
    }

    /// A subagent pane's tab icon (`SubagentTabTitles.icon(ofTab:)`): the subagent mark (`task.ai`),
    /// or the brand mark of `harness`, the harness its row draws (the subagent mark when cmux lists
    /// no such brand).
    public static func subagentIcon(harness: String?) -> TabIcon {
        // A listed brand with no mark (AgentBrandCatalog.spec nil) draws the subagent mark, as the row's fallback does.
        guard let brand = harness.flatMap({ AgentBrandCatalog.brand(for: $0) }), AgentBrandCatalog.spec(for: brand) != nil else { return .icon(.taskAi) }
        return .agentMark(brand.rawValue)
    }

    /// The icon the user set on the tab record replaces every derived icon (kind, agent
    /// mark, page icon, favicon). Callers that set a derived icon after ``item(_:fallbackTitle:isNewTabPage:)``
    /// apply it again last. A busy indicator still covers it while the tab loads.
    public func applyUserIcon(_ tab: TabModel, to item: inout StripTabItem, asset: (String) -> TabImage? = { _ in nil }) {
        if let icon = TabUserIcon.shared.icon(tab.userIcon, asset: asset) { item.icon = icon }
    }

    /// A tab's kind icon from the cmux icon registry. A terminal whose agent session is live,
    /// and an agent chat whose harness is known, wear the agent's brand mark (design/agent-icons),
    /// a chat on a custom harness its own icon (`harnessIcons`), and a chat whose session set its own icon
    /// (acpmux `icon`, ``AgentSessionIdentity``) that one; others, ended sessions and agents without a mark keep
    /// their kind's icon. The user's per-tab icon (``applyUserIcon(_:to:asset:)``) still wins over all of these.
    func icon(_ tab: TabModel, isBrowser: Bool, isConversation: Bool, harnessIcons: HarnessIconLookup = .none,
              turns: AgentTurnStateStore = .shared) -> TabIcon {
        if isConversation {
            // The session's own icon (Leo: "SET CUSTOM ICONS FOR YOURSELVES IN THE TABS"), else a custom
            // harness's (user 12922), else its brand mark, else the chat icon.
            return tab.agentSession.flatMap(turns.iconArt(for:)).map(HarnessIconLookup.tabIcon)
                ?? harnessIcons.tabIcon(for: tab.agentSession?.harness)
                ?? tab.agentBrand.map(TabIcon.agentMark) ?? .icon(.agentChat)
        }
        if isBrowser { return .browser }
        if tab.dead { return .terminalDead }
        if let brand = tab.agentBrand { return .agentMark(brand) }
        return .terminal
    }

    /// A browser tab whose page was never shown keeps the record the daemon
    /// wrote at creation, titled with the full address: it shows the host
    /// until the page reports its own title. A user name, a page title and
    /// an address without a host (file:) stay as they are.
    static func browserTitle(_ tab: TabModel) -> String {
        let title = tab.displayTitle
        guard tab.name?.isEmpty ?? true, title == tab.url,
              let host = URL(string: title)?.host(), !host.isEmpty else { return title }
        return host
    }

    /// The strip title of `tab`, with `fallbackTitle` for a tab that has
    /// none of its own (see ``item(_:fallbackTitle:isNewTabPage:)``). The
    /// App's `TabTitleResolver` picks the fallback.
    public func title(_ tab: TabModel, fallbackTitle: String) -> String {
        let isBrowser = tab.kind == .browser
        let isConversation = tab.kind == .conversation
        let untitled = tab.displayTitle.isEmpty
            || (!isBrowser && !isConversation && (tab.name?.isEmpty ?? true) && TerminalTitle.isBareShell(tab.titleText))
            || ((isBrowser || isConversation) && Self.isBlankPageAddress(tab.displayTitle))
        // A terminal its shell has not titled yet shows its folder, which the
        // shell's first title usually is, so the label does not change a
        // frame after the tab opens.
        let folder = untitled && !isBrowser && !isConversation ? tab.cwd.map(SidebarMapping.shared.abbreviate) : nil
        return untitled ? folder ?? fallbackTitle : isBrowser ? Self.browserTitle(tab) : tab.displayTitle
    }

    /// The New Tab page's and the blank page's addresses
    /// (`BrowserNewTabPage` in CmuxNextBrowser), which a page that never
    /// names itself keeps as its title.
    static func isBlankPageAddress(_ text: String) -> Bool {
        ["chrome://newtab/", "chrome://newtab", "about:blank"].contains(text.lowercased())
    }

    func status(_ tab: TabModel) -> TabStatus {
        // An agent chat's acpmux turn or an OSC 7501 program waits for the user.
        if StatusMapping.shared.needsInput(tab) { return .needsInput }
        // An OSC 7501 error or done the user has not seen yet.
        if let outcome = StatusMapping.shared.outcome(tab) { return outcome }
        return switch tab.agent?.state {
        case .blocked: .needsInput
        case .done: .success
        default: tab.dead || tab.progress?.state == .error ? .failure : .none
        }
    }

    /// An agent chat tab's count for `experiments.agentBadges`: unread agent messages plus pending approvals, from
    /// what this Mac mirrors. Neither is a true count today: acpmux's session summary carries an `unread` flag and an
    /// `input` indicator (one waiting prompt), and a tab holds one retained notification. So the count is 1 for
    /// unread (an unread notification, the manual mark, or a turn that ended unseen) plus 1 for a pending
    /// approval (the turn waits on the person, or the agent asked for the person's attention): 0, 1 or 2. A real
    /// per-chat message count or approval list from acpmux would replace these two terms.
    func agentBadgeCount(_ tab: TabModel) -> Int {
        let unread = tab.hasUnread || tab.markedUnread || StatusMapping.shared.turn(tab) == .done
        let pending = StatusMapping.shared.needsInput(tab) || tab.attention != nil
        return (unread ? 1 : 0) + (pending ? 1 : 0)
    }

    /// The daemon parsed running OSC 9;4 progress for the tab's terminal
    /// (every terminal, shown or not).
    func isReportingProgress(_ tab: TabModel) -> Bool {
        switch tab.progress?.state {
        case .normal?, .indeterminate?: true
        default: false
        }
    }
}
