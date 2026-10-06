import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextTabs
import Observation

/// Mirrors one daemon pane into a tab strip and shows the selected tab's
/// content. Tab selection is client-local (`WindowState.selection`); every
/// other change is a daemon command (PaneController+Intents).
final class PaneController: SurfacePresenter, PresentablePane {
    let paneKey: String
    let layoutPaneID: LayoutPaneID
    let pane: PaneModel
    /// The machine daemon that owns `pane`.
    let daemon: DaemonService
    let stripModel = TabStripModel()
    let view: PaneContentView
    unowned let services: AppServices
    /// Weak: daemon round trips (`Task`s in the intents) can outlive the
    /// window, and a closed window frees its state.
    weak var state: WindowState?
    weak var workspace: WorkspaceContentController?

    private(set) var currentTabKey: String?
    /// How near the layout reports this pane to the viewport.
    private(set) var presence: SurfacePresence = .hidden
    var isVisible: Bool { presence == .visible }
    /// Tabs closed locally while the daemon confirms, so a close looks instant.
    var pendingClosed: Set<String> = []
    /// A tab this app just created here; selected once the daemon reports it (`selectWhenReported`).
    private(set) var pendingSelectSurface: SurfaceID?
    /// Same, named by tab resource id (a reopened tab's restored view).
    private(set) var pendingSelectTab: String?
    private var observation: Task<Void, Never>?

    struct Snapshot: Equatable {
        var items: [StripTabItem]
        var groups: [TabGroupItem]
        var defaultIndex: Int
        var connected: Bool
        var generation: String?
        var surfaces: [UInt64]
    }

    init(pane: PaneModel, daemon: DaemonService, layoutPaneID: LayoutPaneID, services: AppServices, state: WindowState) {
        self.pane = pane
        self.daemon = daemon
        paneKey = pane.id
        self.layoutPaneID = layoutPaneID
        self.services = services
        self.state = state
        view = PaneContentView(stripModel: stripModel)
        stripModel.intentHandler = { [weak self] intent in self?.handle(intent) }
        view.stripView.previewProvider = services.previews
        view.stripView.resourceSource = services.resources
        view.stripView.contextMenuProvider = { [weak self] target in self?.contextMenu(for: target) }
        view.stripView.hoverCards = services.hoverCards
        view.onResize = { [weak services] in services?.surfaceInvariant.noteChange() }
        observe()
    }

    func teardown() {
        observation?.cancel()
        services.presentation.cancel(self)
        // No-op for a tab that moved to another pane: its new pane owns it.
        services.cache.removePresenter(self)
        // Page tabs of panes the live tree no longer lists close now
        // rather than at the store's next observation; a workspace switch or
        // a layout move keeps the pane listed, so its tabs stay.
        services.closeGoneLocalTabs(in: daemon.store)
        currentTabKey = nil
        view.detachContent()
        services.surfaceInvariant.noteChange()
    }

    // MARK: Sync

    private func observe() {
        observation = Task { [weak self] in
            guard let self else { return }
            for await snapshot in Observations({ [weak self] in self?.snapshot() }) {
                guard let snapshot else { return }
                self.apply(snapshot)
            }
        }
        apply(snapshot())
    }

    func snapshot() -> Snapshot {
        let store = daemon.store
        let fallback = Strings.untitledTerminal
        // Terminals on another machine carry its name; browsers always run here.
        let machine = daemon.isLocal ? nil : services.machines.machineBadge(daemon.machineID)
        let workspaceID = store.workspace(containing: pane.handle)?.id
        var items = pane.tabs.filter { !pendingClosed.contains($0.id) }.map { tab -> StripTabItem in
            // A new tab page is "New Tab" until it becomes a chat (then the chat's title).
            let untitled = tab.agentSession != nil
                ? services.agentTabs.pageTabs.ids.contains(tab.id) ? Strings.untitledBrowser : AgentPaneModel.tabTitle
                : tab.kind == .conversation ? services.home.tabTitle(for: tab) : tab.kind == .browser ? Strings.untitledBrowser : fallback
            var item = TabItemMapping.shared.item(tab, fallbackTitle: untitled)
            if tab.page != nil, let page = services.pages.storeTabItem(tab) {
                // A page tab names and badges itself like the page it shows.
                item.title = page.title
                item.icon = page.icon
            }
            item.groupID = tab.tabGroup.map { TabGroupID($0.rawValue) }
            if !DesignSettings.shared.attention.showsOnTab { item.isUnread = false }
            item.isDormant = services.cache.dormantTabs.contains(tab.id)
            if tab.kind == .remoteTerminal {
                // Its terminal runs on another machine: that machine's name.
                item.machineBadge = services.remoteTerminals.badge(for: tab)
                item.icon = .icon(.terminal)
            } else if tab.kind != .browser {
                item.machineBadge = machine
                item.themeBadge = services.themes.badge(forTerminal: TerminalThemeKey(machine: daemon.machineID, tab: tab))
            } else {
                // A browser tab names the machine whose localhost it sees.
                let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
                let badge = services.remoteLocalhost.badge(for: tab, url: tab.url.flatMap(URL.init(string:)), engine: engine)
                item.machineBadge = badge?.text
                item.machineBadgeHelp = badge?.help
                // Incognito tabs have only a placeholder record in the daemon.
                let incognito = services.cache.browserTabs.isIncognitoTab(tab.id)
                if incognito {
                    let live = services.cache.incognitoDisplay(tab)
                    item.title = live.title ?? Strings.untitledBrowser
                    item.subtitle = live.url
                } else {
                    item.profileBadge = services.browserProfiles.tabBadge(for: tab, workspaceID: workspaceID)
                }
                browserIcon(key: tab.id, recordFavicon: incognito ? nil : tab.faviconURL, recordURL: tab.url).apply(to: &item)
            }
            return item
        }
        for local in state?.localBrowserTabs[paneKey] ?? [] where !pendingClosed.contains(local.id) {
            let page = services.cache.existingBrowser(local.id)?.tab.state
            let title = page?.title.flatMap { $0.isEmpty ? nil : $0 } ?? page?.url?.host() ?? Strings.untitledBrowser
            var item = StripTabItem(id: StripTabID(local.id), title: title, subtitle: page?.url?.absoluteString,
                                    icon: .icon(.browser))
            item.isDormant = services.cache.dormantTabs.contains(local.id)
            browserIcon(key: local.id, recordFavicon: nil).apply(to: &item)
            items.append(item)
        }
        items += services.localTabItems(in: paneKey, hiding: pendingClosed)
        let saved = Set(store.savedTabGroups.compactMap(\.openGroup))
        let groups = pane.tabGroups.map { group in
            TabGroupItem(id: TabGroupID(group.id.rawValue), name: group.name,
                         colorToken: group.color.flatMap(GroupColor.init(rawValue:)) ?? .grey,
                         isCollapsed: group.collapsed, isSaved: saved.contains(group.id))
        }
        let connected = if case .connected = store.connectionState { true } else { false }
        return Snapshot(items: items, groups: groups, defaultIndex: pane.defaultTabIndex, connected: connected,
                        generation: store.generation?.rawValue, surfaces: pane.tabs.map(\.surface.rawValue))
    }

    /// The page icon, favicon, throbber or globe of browser tab `key`: its live page's
    /// address, load state and favicon, else the address and favicon its record names.
    private func browserIcon(key: String, recordFavicon: String?, recordURL: String? = nil) -> BrowserTabIconState {
        _ = services.cache.pageInstalls.revision
        let page = services.cache.existingBrowser(key)?.tab.state
        let address = page.map { $0.faviconURL?.absoluteString } ?? recordFavicon
        let image = services.favicons.image(for: address, profile: services.browserProfiles.engineProfile(forTab: key))
        let url = page?.url ?? recordURL.flatMap(URL.init(string:))
        return .resolve(isLoading: page?.isLoading ?? false, isDormant: services.cache.dormantTabs.contains(key), favicon: image, url: url)
    }

    /// Pushes daemon truth into the strip. `force` resets optimistic strip
    /// state after a rejected command (order, membership, closes).
    func apply(_ snapshot: Snapshot, force: Bool = false) {
        if force { view.stripView.discardPendingReorder() }
        if stripModel.groups != snapshot.groups { stripModel.groups = snapshot.groups }
        if stripModel.tabs != snapshot.items { stripModel.tabs = snapshot.items }
        if !snapshot.items.isEmpty { LaunchReveal.shared.markReady(.tabs) }
        var selectNew = false
        if let pending = pendingSelectSurface, let tab = pane.tabs.first(where: { $0.surface == pending }) {
            state?.selection.select(tab.id, in: paneKey)
            pendingSelectSurface = nil
            selectNew = true
        } else if let pending = pendingSelectTab, let tab = pane.tabs.first(where: { $0.id == pending }) {
            state?.selection.select(tab.id, in: paneKey)
            pendingSelectTab = nil
            selectNew = true
        }
        // Members of a collapsed group are hidden: a closed selected tab's
        // successor skips them while a shown tab survives (close-focus.md).
        let collapsed = Set(snapshot.groups.filter(\.isCollapsed).map(\.id))
        let hidden = Set(snapshot.items.filter { $0.groupID.map(collapsed.contains) ?? false }.map(\.id.rawValue))
        let selected = state?.selection.resolve(pane: paneKey, tabs: snapshot.items.map(\.id.rawValue),
                                                defaultIndex: snapshot.defaultIndex, hidden: hidden)
        let selectedID = selected.map { StripTabID($0) }
        if stripModel.selectedID != selectedID { stripModel.selectedID = selectedID }
        if selectNew {
            // A tab this window created: show it now (focus is the
            // coordinator's expectation, not decided here).
            showSelected()
        } else {
            // Model-driven: show on the next frame, coalescing transient selections.
            services.presentation.setNeedsShowSelected(self)
        }
        // Focus follows selection; the coordinator re-targets the keyboard.
        workspace?.sendTopology()
    }

    /// Selects the tab on `surface`, which this app just created here, once
    /// the daemon reports it, and shows it now when it already does. An
    /// action run without view-change permission (a CLI, script or agent
    /// run without `focus: true`) creates the tab in the background.
    func selectWhenReported(surface: SurfaceID) {
        guard ActionRunScope.viewChangeAllowed() else { return apply(snapshot()) }
        pendingSelectSurface = surface
        apply(snapshot())
    }

    /// Same, for a tab named by its resource id (a reopened tab).
    func selectWhenReported(tab: String) {
        guard ActionRunScope.viewChangeAllowed() else { return apply(snapshot()) }
        pendingSelectTab = tab
        apply(snapshot())
    }

    /// Re-pushes daemon truth after a rejection.
    func resyncStrip() {
        apply(snapshot(), force: true)
    }

    /// Pushes the store's current tabs into the strip now (no reset of
    /// optimistic strip state), ahead of the next observation step.
    func syncStripFromStore() {
        apply(snapshot())
    }

    // MARK: Content

    func showSelected() {
        let key = stripModel.selectedID?.rawValue
        if key != currentTabKey {
            InputJournal.shared.append(window: state?.id, .content(tab: key ?? "-", event: "show pane=\(paneKey) from=\(currentTabKey ?? "-")"))
        }
        if let currentTabKey, currentTabKey != key { services.cache.withdraw(currentTabKey, by: self) }
        // May replace a stale surface, displacing the view shown here.
        let content = key.flatMap(content(for:))
        currentTabKey = key
        if let key, content != nil { services.cache.present(key, by: self, presence: presence) }
        view.show(content?.view)
        // Terminals come in on their first frame (`LaunchSettle`); other
        // content (a page, an agent) is ready once shown.
        if let content, !content.isTerminal { LaunchReveal.shared.markReady(.pane) }
        // The content view exists now: the coordinator re-applies focus if
        // this pane has it (content is shown a frame after selection).
        if workspace?.isParked == false { workspace?.focus.send(.contentPresented(pane: paneKey)) }
        services.surfaceInvariant.noteChange()
    }

    /// Another pane took `key`'s view (the tab moved there) or its surface
    /// was destroyed. Let the view go without pausing it; re-present when
    /// this pane shows the tab again.
    func surfaceWasDisplaced(_ key: String) {
        guard currentTabKey == key else { return }
        currentTabKey = nil
        view.detachContent()
        services.surfaceInvariant.noteChange()
    }

    /// This pane is its workspace's focused pane.
    var isFocusedInWorkspace: Bool {
        workspace?.focus.state.pane == paneKey
    }

    func content(for key: String) -> TabContent? {
        if key.hasPrefix(LocalPageTab.prefix) { return services.pages.view(for: key).map(TabContent.page) }
        if key.hasPrefix(LocalBrowserTab.prefix) {
            let local = state?.localBrowserTabs[paneKey]?.first { $0.id == key }
            // A local tab of an incognito window uses its off-the-record profile.
            let incognito = state.map { services.windows.isIncognito(window: $0.id) } == true
            let profile = incognito ? services.windows.incognitoProfile() : nil
            return .browser(services.cache.browser(for: key, url: local?.url, profile: profile))
        }
        guard let tab = pane.tabs.first(where: { $0.id == key }) else { return nil }
        switch tab.kind {
        case .pty:
            let entry = BenchSpans.measure("terminal.surface") { services.cache.terminal(for: tab, daemon: daemon) }
            services.themes.terminalDidMount(entry)
            return .terminal(entry)
        case .browser where tab.isFrontendOwned:
            return services.cache.browser(for: tab).map(TabContent.browser)
        case .remoteTerminal:
            return services.remoteTerminals.content(for: tab, home: daemon)
        case .conversation where tab.agentSession != nil: return AgentTabContent(pane: self).content(key)
        case .conversation where tab.page != nil:
            return services.pages.view(forStoreTab: tab, in: daemon.store, window: state.flatMap { services.windows.controller(for: $0.id) })
                .map(TabContent.page)
        case .conversation: return services.home.tabView(for: tab).map(TabContent.conversation)
        default:
            return nil
        }
    }

    /// The shown tab's live content. Never creates a surface.
    var currentContent: TabContent? { currentTabKey.flatMap(existingContent(for:)) }

    /// `key`'s live content, if its surface or page exists.
    func existingContent(for key: String) -> TabContent? {
        if let entry = services.cache.existingTerminal(key) { return .terminal(entry) }
        if let view = services.agentTabs.existingView(key) { return .agent(view) }
        if let notice = services.agentTabs.notices[services.agentTabs.resolve(key)] { return .notice(notice) }
        if let view = services.pages.existingView(key) { return .page(view) }
        if let placeholder = services.remoteTerminals.existingPlaceholder(key) { return .placeholder(placeholder) }
        if let home = services.home.existingTabView(key) { return .conversation(home) }
        return services.cache.existingBrowser(key).map(TabContent.browser)
    }

    /// True when showing the selection needs no new surface or page.
    var selectedContentIsAlive: Bool {
        guard let key = stripModel.selectedID?.rawValue else { return true }
        return (key == currentTabKey && view.hostsContent) || services.cache.hasContent(for: key)
            || services.agentTabs.existingView(key) != nil || services.pages.existingView(key) != nil
    }

    /// The layout reported this pane on screen, in the keep-alive band, or away.
    func setPresence(_ presence: SurfacePresence) {
        guard self.presence != presence else { return }
        self.presence = presence
        services.cache.setPresence(presence, presenter: self)
        // Content destroyed while away re-attaches (daemon replay) as soon as
        // the pane nears the viewport, so it is ready before it scrolls in.
        if presence != .hidden, stripModel.selectedID != nil, currentTabKey == nil || !view.hostsContent {
            // On screen: show now (a split's new pane draws with the layout
            // change, no blank frame), within the one-surface-per-frame budget.
            if presence == .visible {
                services.presentation.showNow(self)
            } else {
                services.presentation.setNeedsShowSelected(self)
            }
        }
        services.surfaceInvariant.noteChange()
    }

    /// Focuses this pane's selected content through the window's focus
    /// coordinator (the only writer of focus).
    func focusContent(source: FocusEvent.Source = .intent) {
        workspace?.focus.send(.focusPane(paneKey, source: source))
    }

    // MARK: Lookup

    func tab(_ id: StripTabID) -> TabModel? { pane.tabs.first { $0.id == id.rawValue } }

    var selectedTab: TabModel? { stripModel.selectedID.flatMap(tab) }

    var orderedIDs: [StripTabID] { stripModel.orderedTabs.map(\.id) }
}
