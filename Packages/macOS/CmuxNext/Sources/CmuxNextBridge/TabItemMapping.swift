import CmuxNextDesign
import CmuxNextIcons
import Foundation
public import CmuxNextDaemon
public import CmuxNextTabs

/// Maps daemon tab records into tab strip items.
public struct TabItemMapping {
    public static let shared = Self()
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
            icon: isNewTabPage ? .icon(.tabNew) : icon(tab, isBrowser: isBrowser, isConversation: isConversation, harnessIcons: harnessIcons),
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
        if restarting, tab.kind != .browser, tab.kind != .remoteTerminal, !isConversation {
            if item.icon == .icon(.terminalDead) { item.icon = .icon(.terminal) }
            if item.status == .failure { item.status = .none }
            if item.subtitle == nil, let cwd = tab.relaunch?.cwd { item.subtitle = SidebarMapping.shared.abbreviate(cwd) }
        }
        applyUserIcon(tab, to: &item, asset: asset)
        return item
    }

    /// The icon the user set on the tab record replaces every derived icon (kind, agent
    /// mark, page icon, favicon). Callers that set a derived icon after ``item(_:fallbackTitle:isNewTabPage:)``
    /// apply it again last. A busy indicator still covers it while the tab loads.
    public func applyUserIcon(_ tab: TabModel, to item: inout StripTabItem, asset: (String) -> TabImage? = { _ in nil }) {
        if let icon = TabUserIcon.shared.icon(tab.userIcon, asset: asset) { item.icon = icon }
    }

    /// A tab's kind icon from the cmux icon registry. A terminal whose agent session is live,
    /// and an agent chat whose harness is known, wear the agent's brand mark (design/agent-icons),
    /// a chat on a custom harness its own icon (`harnessIcons`);
    /// others, ended sessions and agents without a mark keep their kind's icon.
    func icon(_ tab: TabModel, isBrowser: Bool, isConversation: Bool, harnessIcons: HarnessIconLookup = .none) -> TabIcon {
        if isConversation {
            // A custom harness's own icon (user 12922), else its brand mark, else the chat icon.
            return harnessIcons.tabIcon(for: tab.agentSession?.harness)
                ?? tab.agentBrand.map(TabIcon.agentMark) ?? .icon(.agentChat)
        }
        if isBrowser { return .icon(.browser) }
        if tab.dead { return .icon(.terminalDead) }
        if let brand = tab.agentBrand { return .agentMark(brand) }
        return .icon(.terminal)
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
        let untitled = tab.displayTitle.isEmpty || ((isBrowser || isConversation) && Self.isBlankPageAddress(tab.displayTitle))
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

    /// The daemon parsed running OSC 9;4 progress for the tab's terminal
    /// (every terminal, shown or not).
    func isReportingProgress(_ tab: TabModel) -> Bool {
        switch tab.progress?.state {
        case .normal?, .indeterminate?: true
        default: false
        }
    }
}
